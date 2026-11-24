// Shared helpers for the claim tree. The leaf layout MUST match MerkleVestingDistributor.leafOf:
//   keccak256(bytes.concat(keccak256(abi.encode(chainId, distributor, account, allocation))))
// which is exactly OpenZeppelin StandardMerkleTree with the types below. One leaf per account:
// every leaf vests from claim open, so everything an account is owed is one row.
import { readFileSync } from "node:fs";
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";

export const LEAF_TYPES = ["uint256", "address", "address", "uint256"];

const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const ZERO = "0x0000000000000000000000000000000000000000";
// Mirror MerkleVestingDistributor.VESTING_DURATION and CLAIM_GRACE.
export const VESTING_DURATION = 60n * 86400n;
export const CLAIM_GRACE = 30n * 86400n;

/// A claim start must be a plausible unix time in seconds. Catches milliseconds before they are
/// published in a tree.json.
export function checkClaimStart(claimStart) {
  if (claimStart < 1_600_000_000n || claimStart > 4_102_444_800n) {
    throw new Error(`claim start ${claimStart} is not a plausible unix time in seconds`);
  }
}

/// Last second a claim is accepted, same formula as MerkleVestingDistributor.claimDeadline().
export function claimDeadlineOf(claimStart) {
  return claimStart + VESTING_DURATION + CLAIM_GRACE;
}

export function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    const key = argv[i];
    if (!key.startsWith("--")) throw new Error(`unexpected argument: ${key}`);
    const value = argv[i + 1];
    if (value === undefined || value.startsWith("--")) throw new Error(`missing value for ${key}`);
    args[key.slice(2)] = value;
    i++;
  }
  return args;
}

export function requireAddress(value, label) {
  if (!ADDRESS_RE.test(value ?? "")) throw new Error(`${label}: not an address: ${value}`);
  if (value.toLowerCase() === ZERO) throw new Error(`${label}: zero address`);
  return value;
}

function parseUint(value, label) {
  if (!/^[0-9]+$/.test(value ?? "")) throw new Error(`${label}: not a non-negative integer (wei, no decimals): ${value}`);
  return BigInt(value);
}

/// Reads `account,allocation` rows. Allocation is in wei.
export function readCsv(path) {
  const lines = readFileSync(path, "utf8").split(/\r?\n/).map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));
  if (lines.length === 0) throw new Error("empty csv");
  const header = lines[0].toLowerCase().replace(/\s/g, "");
  if (header === "account,allocation,vestingstart") {
    throw new Error("bad header: the vestingStart column was removed, every leaf vests from claim open. Rebuild tree.csv with build-claims.mjs");
  }
  if (header !== "account,allocation") throw new Error(`bad header: ${lines[0]}`);

  const seen = new Set();
  return lines.slice(1).map((line, i) => {
    const row = i + 2;
    const cells = line.split(",").map((c) => c.trim());
    if (cells.length !== 2) throw new Error(`row ${row}: expected 2 columns`);
    const account = requireAddress(cells[0], `row ${row} account`);
    const allocation = parseUint(cells[1], `row ${row} allocation`);
    if (allocation === 0n) throw new Error(`row ${row}: zero allocation`);
    // One leaf per account. Two rows for one account must be merged upstream: two identical
    // leaves would share one claimed counter on-chain, and the second amount would be lost.
    const key = account.toLowerCase();
    if (seen.has(key)) throw new Error(`row ${row}: duplicate account, merge the rows`);
    seen.add(key);
    return { account, allocation };
  });
}

export function buildTree(chainId, distributor, rows) {
  const values = rows.map((r) => [chainId.toString(), distributor, r.account, r.allocation.toString()]);
  return StandardMerkleTree.of(values, LEAF_TYPES);
}

export function sum(rows) {
  return rows.reduce((acc, r) => acc + BigInt(r.allocation), 0n);
}
