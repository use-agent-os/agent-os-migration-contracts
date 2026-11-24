#!/usr/bin/env node
// Builds the claim tree for MerkleVestingDistributor.
//
//   node offchain/build-tree.mjs --input tree.csv --chain-id 4663 --distributor 0x... \
//        --claim-start 1798675200 --max-total 5000000000000000000000000000 [--out tree.json]
//
// tree.csv:  account,allocation   (allocation in wei, one row per account)
import { writeFileSync } from "node:fs";
import { parseArgs, requireAddress, readCsv, buildTree, sum, checkClaimStart, claimDeadlineOf } from "./tree-lib.mjs";

const args = parseArgs(process.argv.slice(2));
for (const key of ["input", "chain-id", "distributor", "claim-start", "max-total"]) {
  if (args[key] === undefined) {
    console.error("usage: build-tree.mjs --input <csv> --chain-id <id> --distributor <address> --claim-start <unix> --max-total <wei> [--out <json>]");
    console.error(`missing --${key}`);
    process.exit(1);
  }
}

const chainId = BigInt(args["chain-id"]);
const distributor = requireAddress(args.distributor, "distributor");
const claimStart = BigInt(args["claim-start"]);
checkClaimStart(claimStart);
const rows = readCsv(args.input);
const total = sum(rows);
if (total > BigInt(args["max-total"])) {
  throw new Error(`total allocation ${total} exceeds --max-total ${args["max-total"]}`);
}

const tree = buildTree(chainId, distributor, rows);
const claims = [];
for (const [i, v] of tree.entries()) {
  // Everything numeric is a decimal string: uint256 does not fit a JSON number safely.
  claims.push({ account: v[2], allocation: v[3], proof: tree.getProof(i) });
}

const out = {
  chainId: Number(chainId),
  distributor,
  claimStart: claimStart.toString(),
  // Last second a claim is accepted (claim start + 60 days of vesting + 30 days). After it the
  // unclaimed AGENTOS goes back to treasury. It moves if claims are postponed: the chain decides.
  claimDeadline: claimDeadlineOf(claimStart).toString(),
  root: tree.root,
  totalAllocation: total.toString(),
  count: claims.length,
  // Pass this leaf to commitRoot(): it proves on-chain that the tree fits the distributor.
  sample: claims[0],
  claims,
};
const path = args.out ?? "tree.json";
writeFileSync(path, JSON.stringify(out, null, 2) + "\n");

console.log(`root            ${tree.root}`);
console.log(`totalAllocation ${total}`);
console.log(`leaves          ${claims.length}`);
console.log(`claim deadline  ${claimDeadlineOf(claimStart)} (${new Date(Number(claimDeadlineOf(claimStart)) * 1000).toISOString()})`);
console.log(`written         ${path}`);
