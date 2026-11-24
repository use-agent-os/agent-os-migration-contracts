// The tree file format and the public verifier: what build-tree accepts and what verify-tree refuses.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { readCsv, buildTree, sum, claimDeadlineOf, checkClaimStart, LEAF_TYPES } from "../tree-lib.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const A = "0x00000000000000000000000000000000000A11cE";
const B = "0x0000000000000000000000000000000000000B0b";
const DISTRIBUTOR = "0x00000000000000000000000000000000d157A1b0";
const CLAIM_START = "1798675200";
const BUDGET = 5_000_000_000n * 10n ** 18n;
const dir = mkdtempSync(join(tmpdir(), "tree-lib-"));
const csv = (name, text) => {
  const path = join(dir, name);
  writeFileSync(path, text);
  return path;
};
const cli = (script, args) => execFileSync(process.execPath, [join(ROOT, "offchain", script), ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });

test("the leaf is (chainId, distributor, account, allocation): no per-leaf vesting start", () => {
  assert.deepEqual(LEAF_TYPES, ["uint256", "address", "address", "uint256"]);
});

test("readCsv reads account,allocation rows", () => {
  const rows = readCsv(csv("ok.csv", `# comment\naccount,allocation\n${A},25\n${B},7\n`));
  assert.deepEqual(rows, [{ account: A, allocation: 25n }, { account: B, allocation: 7n }]);
  assert.equal(sum(rows), 32n);
});

test("readCsv refuses a second row for the same account, whatever the case", () => {
  assert.throws(() => readCsv(csv("dup.csv", `account,allocation\n${A},25\n${A.toLowerCase()},7\n`)), /duplicate account/);
});

test("readCsv refuses the old three-column format and malformed rows", () => {
  assert.throws(() => readCsv(csv("old.csv", `account,allocation,vestingStart\n${A},25,0\n`)), /vestingStart column was removed/);
  assert.throws(() => readCsv(csv("cols.csv", `account,allocation\n${A},25,0\n`)), /expected 2 columns/);
  assert.throws(() => readCsv(csv("zero.csv", `account,allocation\n${A},0\n`)), /zero allocation/);
  assert.throws(() => readCsv(csv("dec.csv", `account,allocation\n${A},1.5\n`)), /not a non-negative integer/);
  assert.throws(() => readCsv(csv("addr.csv", `account,allocation\nnope,1\n`)), /not an address/);
  assert.throws(() => readCsv(csv("empty.csv", `\n`)), /empty csv/);
});

test("claim deadline: claim start + 90 days, and a claim start in milliseconds is refused", () => {
  assert.equal(claimDeadlineOf(1798675200n), 1806451200n);
  checkClaimStart(1798675200n);
  assert.throws(() => checkClaimStart(1798675200000n), /not a plausible unix time/);
  assert.throws(() => checkClaimStart(0n), /not a plausible unix time/);
});

// ---- the public verifier, run the way a reviewer runs it ----
const treeCsv = csv("tree.csv", `account,allocation\n${A},25500000000000000000000\n${B},7\n`);
const treeJson = join(dir, "tree.json");
cli("build-tree.mjs", ["--input", treeCsv, "--chain-id", "4663", "--distributor", DISTRIBUTOR, "--claim-start", CLAIM_START, "--max-total", "5000000000000000000000000000", "--out", treeJson]);
const good = JSON.parse(readFileSync(treeJson, "utf8"));
const verify = (file, over = {}) => {
  const path = csv(`v-${Math.random().toString(36).slice(2)}.json`, JSON.stringify(file));
  return cli("verify-tree.mjs", [
    "--tree", path, "--chain-id", over.chainId ?? "4663", "--distributor", over.distributor ?? DISTRIBUTOR,
    "--root", over.root ?? good.root, "--total", over.total ?? good.totalAllocation,
  ]);
};
const clone = () => JSON.parse(JSON.stringify(good));

test("verify-tree accepts the file build-tree wrote", () => {
  assert.equal(good.count, 2);
  assert.equal(good.claimDeadline, "1806451200");
  assert.equal(good.sample.vestingStart, undefined);
  assert.equal(buildTree(4663n, DISTRIBUTOR, readCsv(treeCsv)).root, good.root);
  assert.match(verify(good), /OK: domain, root, total and every proof verify/);
});

test("verify-tree refuses a wrong total, root, chain or distributor read from the chain", () => {
  assert.throws(() => verify(good, { total: (BigInt(good.totalAllocation) - 1n).toString() }), /summed total/);
  assert.throws(() => verify(good, { root: "0x" + "11".repeat(32) }), /rebuilt root/);
  assert.throws(() => verify(good, { chainId: "8453" }), /chainId/);
  assert.throws(() => verify(good, { distributor: "0x00000000000000000000000000000000DeaDBeef" }), /distributor/);
});

test("verify-tree refuses a tampered file", () => {
  const bigger = clone();
  bigger.claims[0].allocation = (BigInt(bigger.claims[0].allocation) + 1n).toString();
  assert.throws(() => verify(bigger), /FAILED/);

  const twice = clone();
  twice.claims.push({ ...twice.claims[0] });
  twice.count = 3;
  assert.throws(() => verify(twice), /duplicate account/);

  const oldFormat = clone();
  oldFormat.claims[0].vestingStart = "0";
  assert.throws(() => verify(oldFormat), /built for an older contract/);

  const wrongDeadline = clone();
  wrongDeadline.claimDeadline = "1806451201";
  assert.throws(() => verify(wrongDeadline), /claimDeadline/);

  const badProof = clone();
  badProof.claims[0].proof = badProof.claims[1].proof;
  assert.throws(() => verify(badProof), /proof does not verify/);
});

test("build-tree refuses a tree over the budget and a claim start in milliseconds", () => {
  const args = (over) => ["--input", treeCsv, "--chain-id", "4663", "--distributor", DISTRIBUTOR, "--claim-start", CLAIM_START, "--max-total", "5000000000000000000000000000", "--out", join(dir, "no.json"), ...over];
  assert.throws(() => cli("build-tree.mjs", args(["--max-total", "25500000000000000000006"])), /exceeds --max-total/);
  assert.throws(() => cli("build-tree.mjs", args(["--claim-start", "1798675200000"])), /not a plausible unix time/);
});

test("build-tree accepts exactly 5B and writes no output at 5B plus one wei", () => {
  const build = (allocation, name) => {
    const path = join(dir, `${name}.json`);
    const input = csv(`${name}.csv`, `account,allocation\n${A},${allocation}\n`);
    return { path, run: () => cli("build-tree.mjs", ["--input", input, "--chain-id", "4663", "--distributor", DISTRIBUTOR, "--claim-start", CLAIM_START, "--max-total", BUDGET.toString(), "--out", path]) };
  };
  const exact = build(BUDGET, "exact-budget");
  exact.run();
  assert.equal(JSON.parse(readFileSync(exact.path, "utf8")).totalAllocation, BUDGET.toString());
  const over = build(BUDGET + 1n, "over-budget");
  assert.throws(over.run, /exceeds --max-total/);
  assert.equal(existsSync(over.path), false);
});
