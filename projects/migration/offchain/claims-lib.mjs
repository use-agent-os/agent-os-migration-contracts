// Pure logic that turns the frozen vault ledger + the DACKIE long-lock snapshot into claim rows.
// No network, no clock: everything it needs is passed in, so it can be tested and re-run by anyone.
//
// Rules (they mirror the plan and MigrationVault.allocationOf):
//   - depositor allocation = floor(cap * capRate / 1e18) + floor(dackie * dackieRate / 1e18)
//   - long-lock allocation = floor(lockedDackie * dackieRate / 1e18)
//   - AGENTOS goes to the recipient registered on Base, else to the same address
//   - excluded accounts (team) get no leaf
//   - an account blocked at the freeze, or whose recipient is blocked, gets no leaf (manual path)
//   - ONE leaf per recipient: everything a recipient is owed (deposits and long locks, from any
//     number of accounts) is summed. Every leaf vests from claim open (plan decision #2).

const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const ZERO = "0x0000000000000000000000000000000000000000";
export const RATE_PRECISION = 10n ** 18n;

// Mirror MerkleVestingDistributor.VESTING_DURATION and CLAIM_GRACE.
export const VESTING_DURATION = 60n * 86400n;
export const CLAIM_GRACE = 30n * 86400n;

/// Last second a claim is accepted, same formula as MerkleVestingDistributor.claimDeadline().
export function claimDeadlineOf(claimStart) {
  return claimStart + VESTING_DURATION + CLAIM_GRACE;
}

export function normalizeAddress(value, label) {
  if (typeof value !== "string" || !ADDRESS_RE.test(value)) throw new Error(`${label}: not an address: ${value}`);
  if (value.toLowerCase() === ZERO) throw new Error(`${label}: zero address`);
  return value.toLowerCase();
}

/// "17194749.01" -> 17194749010000000000000000n. Exact: no floats anywhere.
export function parseUnits18(value, label) {
  const text = String(value ?? "").trim();
  if (!/^[0-9]+(\.[0-9]+)?$/.test(text)) throw new Error(`${label}: not a decimal amount: ${value}`);
  const [whole, fraction = ""] = text.split(".");
  if (fraction.length > 18) throw new Error(`${label}: more than 18 decimals: ${value}`);
  return BigInt(whole) * RATE_PRECISION + BigInt(fraction.padEnd(18, "0") || "0");
}

function splitCsv(text) {
  return text.split(/\r?\n/).map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));
}

/// Long-lock snapshot. Required columns: address, lock_end_ts, and dackie_wei (exact) or dackie
/// (decimal tokens). Optional: source, position_id, misses_window (must be "yes" when present).
///
/// One economic position must be one row. Without a position_id column, two rows with the same
/// (address, lock_end_ts) are refused whatever their source label says: a lock end is a timestamp
/// to the second, so two rows sharing it are the same position listed twice. With a position_id
/// column (the authoritative id from the pool / LP vault) every row needs one and ids must be unique.
export function parseLongLockCsv(text) {
  const lines = splitCsv(text);
  if (lines.length === 0) throw new Error("long-lock csv is empty");
  const header = lines[0].split(",").map((c) => c.trim().toLowerCase());
  const col = (name) => header.indexOf(name);
  if (col("address") < 0 || col("lock_end_ts") < 0) throw new Error("long-lock csv needs columns: address, lock_end_ts");
  if (col("dackie_wei") < 0 && col("dackie") < 0) throw new Error("long-lock csv needs a dackie_wei or dackie column");

  const hasPositionId = col("position_id") >= 0;
  const seen = new Set();
  return lines.slice(1).map((line, i) => {
    const row = i + 2;
    const cells = line.split(",").map((c) => c.trim());
    if (cells.length !== header.length) throw new Error(`long-lock row ${row}: expected ${header.length} columns, got ${cells.length}`);
    const address = normalizeAddress(cells[col("address")], `long-lock row ${row} address`);
    const lockEndText = cells[col("lock_end_ts")];
    if (!/^[0-9]+$/.test(lockEndText)) throw new Error(`long-lock row ${row}: bad lock_end_ts: ${lockEndText}`);
    const lockEnd = BigInt(lockEndText);
    const amount = col("dackie_wei") >= 0 && cells[col("dackie_wei")] !== ""
      ? BigInt(cells[col("dackie_wei")])
      : parseUnits18(cells[col("dackie")], `long-lock row ${row} dackie`);
    if (amount <= 0n) throw new Error(`long-lock row ${row}: zero amount`);
    if (col("misses_window") >= 0 && cells[col("misses_window")].toLowerCase() !== "yes") {
      throw new Error(`long-lock row ${row}: misses_window is not "yes", this position must deposit instead`);
    }
    const source = col("source") >= 0 ? cells[col("source")] : "";
    if (hasPositionId) {
      const positionId = cells[col("position_id")];
      if (positionId === "") throw new Error(`long-lock row ${row}: empty position_id`);
      const key = `${source.toLowerCase()}:${positionId}`;
      if (seen.has(key)) throw new Error(`long-lock row ${row}: duplicate position_id ${positionId}`);
      seen.add(key);
      return { source, positionId, address, amount, lockEnd };
    }
    const key = `${address}:${lockEnd}`;
    if (seen.has(key)) throw new Error(`long-lock row ${row}: duplicate (address, lock_end_ts), the same position is listed twice`);
    seen.add(key);
    return { source, address, amount, lockEnd };
  });
}

/// One address per line, '#' comments and blank lines skipped. Returns a Set of lowercase addresses.
export function parseAddressList(text) {
  const out = new Set();
  splitCsv(text).forEach((line, i) => out.add(normalizeAddress(line.split(",")[0].trim(), `address list line ${i + 1}`)));
  return out;
}

export function allocationFor(cap, dackie, capRate, dackieRate) {
  return (cap * capRate) / RATE_PRECISION + (dackie * dackieRate) / RATE_PRECISION;
}

/// @param input.depositors  [{ account, cap, dackie, recipient, blocked, recipientBlocked }]
///                          recipient = registered recipient or the account itself (lowercase)
/// @param input.longLocks   [{ source, address, amount, lockEnd, recipient, blocked, recipientBlocked }]
/// @param input.excluded    Set of lowercase addresses that never get a leaf (team)
/// @param input.capRate, input.dackieRate   1e18-scaled, from the vault
/// @param input.depositDeadline, input.claimStart   unix seconds (bigint)
/// @returns { rows: [{ account, allocation }], report }
export function computeClaims(input) {
  const { depositors, longLocks, excluded, capRate, dackieRate, depositDeadline, claimStart } = input;
  if (capRate <= 0n || dackieRate <= 0n) throw new Error("rates are not set");
  if (claimStart <= depositDeadline) throw new Error("claimStart must be after the deposit deadline");

  const leaves = new Map(); // recipient -> { account, allocation }
  const addLeaf = (recipient, allocation) => {
    const leaf = leaves.get(recipient) ?? { account: recipient, allocation: 0n };
    leaf.allocation += allocation;
    leaves.set(recipient, leaf);
  };
  const statusOf = (account, entry) => {
    if (excluded.has(account)) return "excluded:team";
    if (entry.blocked) return "excluded:blocked";
    if (entry.recipientBlocked) return "excluded:recipient-blocked";
    return "included";
  };

  const report = {
    depositors: [],
    longLocks: [],
    totals: { deposits: 0n, longLocks: 0n, total: 0n, excludedTeam: 0n, excludedBlocked: 0n },
  };

  const seenDepositors = new Set();
  for (const d of depositors) {
    if (seenDepositors.has(d.account)) throw new Error(`duplicate depositor ${d.account}`);
    seenDepositors.add(d.account);
    if (d.cap === 0n && d.dackie === 0n) continue; // withdrew everything before the freeze
    const allocation = allocationFor(d.cap, d.dackie, capRate, dackieRate);
    let status = statusOf(d.account, d);
    if (status === "included" && allocation === 0n) status = "excluded:dust";
    if (status === "included") {
      addLeaf(d.recipient, allocation);
      report.totals.deposits += allocation;
    } else if (status === "excluded:team") report.totals.excludedTeam += allocation;
    else report.totals.excludedBlocked += allocation;
    report.depositors.push({ account: d.account, recipient: d.recipient, cap: d.cap, dackie: d.dackie, allocation, status });
  }

  for (const l of longLocks) {
    // A lock that ends inside the window is not a long lock: that holder had to withdraw and deposit.
    if (l.lockEnd <= depositDeadline) {
      throw new Error(`long-lock ${l.address}: lock_end_ts ${l.lockEnd} is not after the deposit deadline ${depositDeadline}`);
    }
    const allocation = (l.amount * dackieRate) / RATE_PRECISION;
    let status = statusOf(l.address, l);
    if (status === "included" && allocation === 0n) status = "excluded:dust";
    if (status === "included") {
      addLeaf(l.recipient, allocation);
      report.totals.longLocks += allocation;
    } else if (status === "excluded:team") report.totals.excludedTeam += allocation;
    else report.totals.excludedBlocked += allocation;
    report.longLocks.push({
      source: l.source, ...(l.positionId !== undefined ? { positionId: l.positionId } : {}),
      address: l.address, recipient: l.recipient, amount: l.amount, lockEnd: l.lockEnd, allocation, status,
    });
  }

  // Deterministic order: anyone who re-runs this gets a byte-identical tree.csv.
  const rows = [...leaves.values()].sort((a, b) => (a.account < b.account ? -1 : 1));
  report.totals.total = rows.reduce((sum, r) => sum + r.allocation, 0n);
  if (report.totals.total !== report.totals.deposits + report.totals.longLocks) {
    throw new Error("internal error: leaf sum does not match the included allocations");
  }
  return { rows, report };
}

/// Things a human must look at before the tree is published. Pure: same input, same list.
/// @param input   what computeClaims received. Depositors and long-lockers may carry `isContract`
///                (has code on Base, EIP-7702 delegations excluded) and long-lockers `registered`
///                (called registerRecipient).
/// @param report  what computeClaims returned.
export function collectWarnings(input, report, format = (a) => a) {
  const { depositors, longLocks, excluded } = input;
  const warnings = [];

  for (const l of longLocks) {
    if (l.isContract && !l.registered) {
      warnings.push(`long-locker ${format(l.address)} is a contract on Base and registered no recipient: its leaf goes to the same address on Robinhood`);
    }
  }
  for (const d of depositors) {
    if (d.isContract && d.recipient === d.account && (d.cap !== 0n || d.dackie !== 0n)) {
      warnings.push(`depositor ${format(d.account)} is a contract on Base and named itself as recipient: its leaf goes to the same address on Robinhood, check that it controls it there`);
    }
  }

  const depositorAccounts = new Set(depositors.map((d) => d.account));
  for (const d of depositors) {
    if (excluded.has(d.account) && d.cap === 0n && d.dackie === 0n) warnings.push(`excluded address ${format(d.account)} has no deposit at the freeze`);
  }
  for (const address of excluded) {
    if (!depositorAccounts.has(address) && !longLocks.some((l) => l.address === address)) {
      warnings.push(`excluded address ${format(address)} never deposited and is not a long-locker`);
    }
  }

  const isBlocked = (row) => row.status === "excluded:blocked" || row.status === "excluded:recipient-blocked";
  const blockedDepositors = report.depositors.filter(isBlocked).length;
  const blockedLongLocks = report.longLocks.filter(isBlocked).length;
  if (blockedDepositors + blockedLongLocks > 0) {
    warnings.push(
      `${blockedDepositors} depositor(s) and ${blockedLongLocks} long-lock row(s) excluded by the blocklist: handle them on the manual verified path. ` +
        `${report.totals.excludedBlocked} wei of AGENTOS is owed to them and is NOT in the tree: keep it available in treasury`
    );
  }
  return warnings;
}

export function rowsToCsv(rows, checksum = (a) => a) {
  const lines = ["account,allocation"];
  for (const r of rows) lines.push(`${checksum(r.account)},${r.allocation}`);
  return lines.join("\n") + "\n";
}

/// JSON.stringify replacer: bigint -> decimal string.
export function bigintReplacer(_key, value) {
  return typeof value === "bigint" ? value.toString() : value;
}
