#!/usr/bin/env node
// Independently re-checks a published tree.json. Anyone can run this during the review window.
//
//   node offchain/verify-tree.mjs --tree tree.json --chain-id 4663 --distributor 0x... \
//        --root 0x... --total <wei>
//
// Every flag is mandatory and must come from the chain, NOT from the file:
//   --chain-id     the chain the distributor lives on (4663)
//   --distributor  the distributor address (also vault.attestedDistributor() on Base)
//   --root         distributor.merkleRoot()      (also vault.claimRoot() on Base)
//   --total        distributor.totalAllocation() (also vault.attestedTotalAllocation() on Base)
// Before the root is committed, pass the root and total the team announced.
import { readFileSync } from "node:fs";
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import { parseArgs, requireAddress, buildTree, sum, claimDeadlineOf, LEAF_TYPES } from "./tree-lib.mjs";

const args = parseArgs(process.argv.slice(2));
for (const key of ["tree", "chain-id", "distributor", "root", "total"]) {
  if (args[key] === undefined) {
    console.error("usage: verify-tree.mjs --tree <json> --chain-id <id> --distributor <address> --root <bytes32> --total <wei>");
    console.error(`missing --${key}`);
    process.exit(1);
  }
}

const file = JSON.parse(readFileSync(args.tree, "utf8"));
// The domain comes from the flags. A file built for another chain or address fails here.
const chainId = BigInt(args["chain-id"]);
const distributor = requireAddress(args.distributor, "distributor");
const failures = [];

if (BigInt(file.chainId) !== chainId) failures.push(`file chainId ${file.chainId} != --chain-id ${chainId}`);
if ((file.distributor ?? "").toLowerCase() !== distributor.toLowerCase()) {
  failures.push(`file distributor ${file.distributor} != --distributor ${distributor}`);
}

const seen = new Set();
const rows = file.claims.map((c, i) => {
  requireAddress(c.account, `claim ${i} account`);
  const allocation = BigInt(c.allocation);
  // The contract has one schedule for every leaf. A per-leaf vesting start is not part of a leaf.
  if (c.vestingStart !== undefined) failures.push(`claim ${i}: has a vestingStart, this file was built for an older contract`);
  const key = c.account.toLowerCase();
  if (seen.has(key)) failures.push(`claim ${i}: duplicate account`);
  seen.add(key);
  if (allocation === 0n) failures.push(`claim ${i}: zero allocation`);
  return { account: c.account, allocation };
});

const tree = buildTree(chainId, distributor, rows);
const total = sum(rows);

if (tree.root.toLowerCase() !== args.root.toLowerCase()) failures.push(`rebuilt root ${tree.root} != --root ${args.root}`);
if (total !== BigInt(args.total)) failures.push(`summed total ${total} != --total ${args.total}`);
if (tree.root !== file.root) failures.push(`rebuilt root ${tree.root} != file root ${file.root}`);
if (total.toString() !== file.totalAllocation) failures.push(`summed total ${total} != file total ${file.totalAllocation}`);
if (file.count !== rows.length) failures.push(`count mismatch: ${rows.length} claims, file says ${file.count}`);

file.claims.forEach((c, i) => {
  const leaf = [chainId.toString(), distributor, c.account, c.allocation.toString()];
  if (!StandardMerkleTree.verify(tree.root, LEAF_TYPES, leaf, c.proof)) failures.push(`claim ${i}: proof does not verify`);
});

console.log(`root            ${tree.root}`);
console.log(`totalAllocation ${total}`);
console.log(`leaves          ${rows.length}`);
if (file.claimStart !== undefined) {
  const claimStart = BigInt(file.claimStart);
  const deadline = claimDeadlineOf(claimStart);
  if (file.claimDeadline !== undefined && BigInt(file.claimDeadline) !== deadline) {
    failures.push(`file claimDeadline ${file.claimDeadline} != claimStart + 90 days (${deadline})`);
  }
  // Informational: the chain decides. Compare with distributor.claimStart() / claimDeadline().
  console.log(`claim start     ${claimStart} (file)`);
  console.log(`claim deadline  ${deadline} (${new Date(Number(deadline) * 1000).toISOString()}, unclaimed AGENTOS returns to treasury after it)`);
}
if (failures.length) {
  console.error(`\nFAILED (${failures.length}):`);
  for (const f of failures.slice(0, 50)) console.error(`  - ${f}`);
  process.exit(1);
}
console.log("OK: domain, root, total and every proof verify");
