import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import {
  parseUnits18, parseLongLockCsv, parseAddressList, computeClaims, allocationFor, rowsToCsv, claimDeadlineOf, collectWarnings,
} from "../claims-lib.mjs";

const A = "0x00000000000000000000000000000000000000a1";
const B = "0x00000000000000000000000000000000000000b2";
const C = "0x00000000000000000000000000000000000000c3";
const R = "0x00000000000000000000000000000000000000d4";
const TEAM = "0x00000000000000000000000000000000000000e5";
const E18 = 10n ** 18n;
const DEADLINE = 1_798_243_199n;
const CLAIM_START = 1_798_675_200n;
const CAP_RATE = 25_500000000000000000n;
const DACKIE_RATE = 18_123456789000000000n;

const dep = (account, cap, dackie, extra = {}) => ({ account, cap, dackie, recipient: account, blocked: false, recipientBlocked: false, ...extra });
const lock = (address, amount, lockEnd, extra = {}) => ({ source: "DackiePool", address, amount, lockEnd, recipient: address, blocked: false, recipientBlocked: false, ...extra });
const base = (over = {}) => ({
  depositors: [], longLocks: [], excluded: new Set(), capRate: CAP_RATE, dackieRate: DACKIE_RATE,
  depositDeadline: DEADLINE, claimStart: CLAIM_START, ...over,
});

test("parseUnits18 is exact and strict", () => {
  assert.equal(parseUnits18("17194749.01"), 17194749010000000000000000n);
  assert.equal(parseUnits18("0.000000000000000001"), 1n);
  assert.equal(parseUnits18("4"), 4n * E18);
  // 0.1 + 0.2 style float drift must be impossible.
  assert.equal(parseUnits18("0.1") + parseUnits18("0.2"), parseUnits18("0.3"));
  for (const bad of ["", "1e18", "-1", "1,5", "0x10", "1.", ".5", "0.0000000000000000001", " "]) {
    assert.throws(() => parseUnits18(bad, "x"), /x:/, `should reject ${JSON.stringify(bad)}`);
  }
});

test("parseLongLockCsv reads the snapshot format", () => {
  const rows = parseLongLockCsv(
    "source,address,dackie,weth,lock_end_utc,lock_end_ts,days_after_close,misses_window,label\n" +
      "DackieLPVault,0x8BA0D7704dF6a610F4ce9937d31E0Bbc19717311,17194749.01,0.550203,2027-08-08 02:48:38,1817693318,225.1,yes,\n" +
      "DackiePool,0x8BA0D7704dF6a610F4ce9937d31E0Bbc19717311,5.5,0.0,2027-01-09 01:49:01,1799459341,14.1,yes,\n"
  );
  assert.equal(rows.length, 2);
  assert.deepEqual(rows[0], { source: "DackieLPVault", address: "0x8ba0d7704df6a610f4ce9937d31e0bbc19717311", amount: 17194749010000000000000000n, lockEnd: 1817693318n });
  assert.equal(rows[1].amount, 5_500000000000000000n);
});

test("parseLongLockCsv prefers exact dackie_wei and rejects bad rows", () => {
  const [row] = parseLongLockCsv(`address,dackie,dackie_wei,lock_end_ts\n${A},1.5,1500000000000000007,1817693318\n`);
  assert.equal(row.amount, 1500000000000000007n);

  assert.throws(() => parseLongLockCsv(`address,dackie\n${A},1\n`), /lock_end_ts/);
  assert.throws(() => parseLongLockCsv(`address,lock_end_ts\n${A},1\n`), /dackie/);
  assert.throws(() => parseLongLockCsv(`address,dackie,lock_end_ts\n${A},0,1817693318\n`), /zero amount/);
  assert.throws(() => parseLongLockCsv(`address,dackie,lock_end_ts\nnope,1,1817693318\n`), /not an address/);
  assert.throws(() => parseLongLockCsv(`address,dackie,lock_end_ts\n${A},1,1817693318000.5\n`), /bad lock_end_ts/);
  assert.throws(() => parseLongLockCsv(`address,dackie,lock_end_ts,misses_window\n${A},1,1817693318,no\n`), /must deposit instead/);
  assert.throws(() => parseLongLockCsv(`source,address,dackie,lock_end_ts\nP,${A},1,1817693318\nP,${A},2,1817693318\n`), /duplicate/);
  assert.throws(() => parseLongLockCsv(`address,dackie,lock_end_ts\n${A},1\n`), /expected 3 columns/);
});

test("parseLongLockCsv: one economic position cannot be counted twice under two source labels", () => {
  const header = "source,address,dackie,lock_end_ts\n";
  // Same wallet, same lock end, different label: the same position listed twice.
  assert.throws(
    () => parseLongLockCsv(`${header}DackiePool,${A},1,1817693318\nDackieLPVault,${A},1,1817693318\n`),
    /duplicate \(address, lock_end_ts\)/
  );
  // Case and label spelling do not hide it.
  assert.throws(
    () => parseLongLockCsv(`${header}DackiePool,${A},1,1817693318\ndackiepool ,${A.toUpperCase().replace("0X", "0x")},2,1817693318\n`),
    /duplicate \(address, lock_end_ts\)/
  );
  // Different lock ends are different positions.
  assert.equal(parseLongLockCsv(`${header}DackiePool,${A},1,1817693318\nDackieLPVault,${A},1,1817693319\n`).length, 2);
});

test("parseLongLockCsv: position_id tells two real positions with the same lock end apart", () => {
  const header = "source,position_id,address,dackie,lock_end_ts\n";
  const rows = parseLongLockCsv(`${header}DackiePool,pool-7,${A},1,1817693318\nDackieLPVault,lp-7,${A},2,1817693318\n`);
  assert.deepEqual(rows.map((r) => r.positionId), ["pool-7", "lp-7"]);
  // The same position id twice is the same position, whatever else differs.
  assert.throws(
    () => parseLongLockCsv(`${header}DackiePool,pool-7,${A},1,1817693318\nDackiePool,pool-7,${B},2,1817693999\n`),
    /duplicate position_id/
  );
  // With the column present every row needs one: a blank would fall back to the weaker check.
  assert.throws(() => parseLongLockCsv(`${header}DackiePool,,${A},1,1817693318\n`), /empty position_id/);
});

test("parseAddressList", () => {
  const set = parseAddressList(`# team\n${TEAM.toUpperCase().replace("0X", "0x")}\n\n${A}, label\n`);
  assert.deepEqual([...set].sort(), [A, TEAM].sort());
  assert.throws(() => parseAddressList("0x0000000000000000000000000000000000000000\n"), /zero address/);
});

test("deposit allocation uses the vault formula: each token floored on its own", () => {
  // 1 wei of each: floor(25.5) + floor(18.123456789) = 25 + 18, not floor(43.62)
  assert.equal(allocationFor(1n, 1n, CAP_RATE, DACKIE_RATE), 43n);
  const { rows, report } = computeClaims(base({ depositors: [dep(A, 1000n * E18, 3n), dep(B, 0n, 7n * E18)] }));
  assert.deepEqual(rows, [
    { account: A, allocation: 25_500n * E18 + 54n },
    { account: B, allocation: 126_864197523000000000n },
  ]);
  assert.equal(report.totals.total, rows[0].allocation + rows[1].allocation);
});

test("recipient routing and merging", () => {
  // A and B both name R. C names nobody.
  const { rows } = computeClaims(
    base({ depositors: [dep(A, E18, 0n, { recipient: R }), dep(B, 2n * E18, 0n, { recipient: R }), dep(C, 0n, E18)] })
  );
  assert.deepEqual(rows, [
    { account: C, allocation: DACKIE_RATE },
    { account: R, allocation: 3n * CAP_RATE },
  ]);
});

test("withdrawn, team, blocked and blocked-recipient depositors get no leaf", () => {
  const { rows, report } = computeClaims(
    base({
      excluded: new Set([TEAM]),
      depositors: [
        dep(A, 0n, 0n), // withdrew
        dep(TEAM, 100n * E18, 0n),
        dep(B, 10n * E18, 0n, { blocked: true }),
        dep(C, 4n * E18, 0n, { recipient: R, recipientBlocked: true }),
      ],
    })
  );
  assert.deepEqual(rows, []);
  assert.equal(report.totals.total, 0n);
  assert.equal(report.totals.excludedTeam, 100n * CAP_RATE);
  assert.equal(report.totals.excludedBlocked, 14n * CAP_RATE);
  assert.deepEqual(report.depositors.map((d) => d.status), ["excluded:team", "excluded:blocked", "excluded:recipient-blocked"]);
});

test("a wallet that deposits and also has a long lock gets ONE leaf", () => {
  const lockEnd = CLAIM_START + 200n * 86400n;
  const { rows, report } = computeClaims(
    base({ depositors: [dep(A, E18, 0n)], longLocks: [lock(A, 10n * E18, lockEnd), lock(B, E18, lockEnd, { recipient: R })] })
  );
  assert.deepEqual(rows, [
    { account: A, allocation: CAP_RATE + 10n * DACKIE_RATE },
    { account: R, allocation: DACKIE_RATE },
  ]);
  assert.equal(report.totals.deposits, CAP_RATE);
  assert.equal(report.totals.longLocks, 11n * DACKIE_RATE);
});

test("every lock of one wallet merges into its single leaf, whatever the lock ends", () => {
  const e1 = CLAIM_START + 100n * 86400n;
  const e2 = CLAIM_START + 300n * 86400n;
  const { rows } = computeClaims(
    base({ longLocks: [lock(A, E18, e1, { source: "DackiePool" }), lock(A, 2n * E18, e1, { source: "DackieLPVault" }), lock(A, 4n * E18, e2), lock(A, E18, DEADLINE + 40_000n)] })
  );
  assert.deepEqual(rows, [{ account: A, allocation: 8n * DACKIE_RATE }]);
  assert.equal(new Set(rows.map((r) => r.account)).size, rows.length, "one leaf per account");
});

test("claimDeadlineOf mirrors the distributor: claim open + 60 days of vesting + 30 days", () => {
  assert.equal(claimDeadlineOf(CLAIM_START), 1_806_451_200n); // 2027-03-31 00:00:00 UTC
});

test("guards", () => {
  assert.throws(() => computeClaims(base({ longLocks: [lock(A, E18, DEADLINE)] })), /not after the deposit deadline/);
  assert.throws(() => computeClaims(base({ capRate: 0n })), /rates are not set/);
  assert.throws(() => computeClaims(base({ claimStart: DEADLINE })), /claimStart must be after/);
  assert.throws(() => computeClaims(base({ depositors: [dep(A, 1n, 0n), dep(A, 1n, 0n)] })), /duplicate depositor/);
});

test("blocked or team long-lockers get no leaf", () => {
  const lockEnd = CLAIM_START + 86400n;
  const { rows, report } = computeClaims(
    base({ excluded: new Set([TEAM]), longLocks: [lock(TEAM, E18, lockEnd), lock(B, E18, lockEnd, { blocked: true }), lock(C, E18, lockEnd)] })
  );
  assert.deepEqual(rows, [{ account: C, allocation: DACKIE_RATE }]);
  assert.deepEqual(report.longLocks.map((l) => l.status), ["excluded:team", "excluded:blocked", "included"]);
  // What the blocklist kept out of the tree is owed on the manual path: it is counted, not lost.
  assert.equal(report.totals.excludedBlocked, DACKIE_RATE);
  assert.equal(report.totals.excludedTeam, DACKIE_RATE);
});

test("warnings: contract wallets that will receive at their own address on Robinhood", () => {
  const input = base({
    depositors: [
      dep(A, E18, 0n, { isContract: true }), // contract, named itself
      dep(B, E18, 0n, { isContract: true, recipient: R }), // contract, named another address: fine
      dep(C, E18, 0n), // EOA
    ],
    longLocks: [
      lock(A, E18, CLAIM_START + 86400n, { isContract: true, registered: false }),
      lock(B, E18, CLAIM_START + 86400n, { isContract: true, registered: true, recipient: R }),
    ],
  });
  const warnings = collectWarnings(input, computeClaims(input).report);
  assert.equal(warnings.length, 2);
  assert.match(warnings[0], new RegExp(`long-locker ${A}.*contract.*registered no recipient`, "i"));
  assert.match(warnings[1], new RegExp(`depositor ${A}.*contract.*itself`, "i"));
});

test("warnings: everything the blocklist kept out of the tree, long locks included, with the amount owed", () => {
  const lockEnd = CLAIM_START + 86400n;
  const input = base({
    depositors: [dep(A, 10n * E18, 0n, { blocked: true }), dep(B, E18, 0n, { recipient: R, recipientBlocked: true }), dep(C, E18, 0n)],
    longLocks: [lock(A, 2n * E18, lockEnd, { blocked: true }), lock(C, E18, lockEnd)],
  });
  const { report } = computeClaims(input);
  const owed = 11n * CAP_RATE + 2n * DACKIE_RATE;
  assert.equal(report.totals.excludedBlocked, owed);
  const warnings = collectWarnings(input, report);
  assert.equal(warnings.length, 1);
  assert.match(warnings[0], /2 depositor\(s\) and 1 long-lock row\(s\) excluded by the blocklist/);
  assert.ok(warnings[0].includes(owed.toString()), "states the AGENTOS owed on the manual path");

  // Nothing blocked, nothing to say.
  const clean = base({ depositors: [dep(C, E18, 0n)] });
  assert.deepEqual(collectWarnings(clean, computeClaims(clean).report), []);
});

test("warnings: excluded (team) addresses that have nothing to exclude", () => {
  const input = base({ excluded: new Set([TEAM, A]), depositors: [dep(TEAM, 0n, 0n), dep(C, E18, 0n)] });
  const warnings = collectWarnings(input, computeClaims(input).report);
  assert.equal(warnings.length, 2);
  assert.match(warnings[0], new RegExp(`${TEAM}.*no deposit at the freeze`, "i"));
  assert.match(warnings[1], new RegExp(`${A}.*never deposited and is not a long-locker`, "i"));
});

test("output is deterministic regardless of input order", () => {
  const lockEnd = CLAIM_START + 86400n;
  const depositors = [dep(C, E18, 0n), dep(A, 2n * E18, 5n), dep(B, 0n, 9n)];
  const longLocks = [lock(B, E18, lockEnd), lock(A, E18, lockEnd)];
  const one = rowsToCsv(computeClaims(base({ depositors, longLocks })).rows);
  const two = rowsToCsv(computeClaims(base({ depositors: [...depositors].reverse(), longLocks: [...longLocks].reverse() })).rows);
  assert.equal(one, two);
  assert.match(one, /^account,allocation\n/);
});

// The final long-lock baseline kept in docs/data. Override with LONGLOCK_BASELINE to check another file.
const BASELINE = process.env.LONGLOCK_BASELINE ?? new URL("../../../../docs/data/dackie-longlock-close-2026-12-25.csv", import.meta.url).pathname;

test("the baseline long-lock snapshot parses and sums to 41,167,439.84 DACKIE", { skip: !existsSync(BASELINE) }, () => {
  const rows = parseLongLockCsv(readFileSync(BASELINE, "utf8"));
  const total = rows.reduce((s, r) => s + r.amount, 0n);
  assert.equal(rows.length, 42);
  assert.equal(new Set(rows.map((r) => r.address)).size, 36);
  assert.equal(total, parseUnits18("41167439.84"));
  const { rows: leaves } = computeClaims(base({ longLocks: rows.map((r) => ({ ...r, recipient: r.address, blocked: false, recipientBlocked: false })) }));
  assert.equal(leaves.reduce((s, r) => s + r.allocation, 0n) <= (total * DACKIE_RATE) / E18, true);
});
