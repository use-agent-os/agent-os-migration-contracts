#!/usr/bin/env node
// Builds tree.csv (the input of build-tree.mjs) from the frozen MigrationVault ledger on Base and
// the DACKIE long-lock snapshot.
//
//   node offchain/build-claims.mjs \
//     --rpc <Base archive RPC> --vault 0x... --from-block <vault deployment block> \
//     --longlock <long-lock csv> --exclude <team addresses file | none> \
//     --claim-start 1798675200 \
//     [--max-total <wei>] [--out-csv tree.csv] [--out-report claims-report.json] [--chunk 5000]
//     [--block <n>]   re-run at a known freeze block (it is still checked against the deadline)
//
// Everything is read from the chain at ONE block: the first block after the deposit deadline.
// State (deposits, recipients, blocklist, rates) is read with eth_call at that block. Events are
// only used to discover who deposited, and the result is checked against totalDeposited, so a
// missed event aborts the run instead of silently dropping someone.
//
// Every leaf vests from claim open (plan decision #2): a wallet gets ONE leaf with everything it is
// owed, deposits and long locks together. Nothing is written when the run fails or is over budget.
import { readFileSync, writeFileSync } from "node:fs";
import { createPublicClient, http, parseAbi, getAddress } from "viem";
import { parseArgs } from "./tree-lib.mjs";
import {
  parseLongLockCsv, parseAddressList, computeClaims, collectWarnings, claimDeadlineOf, rowsToCsv, bigintReplacer,
} from "./claims-lib.mjs";

const VAULT_ABI = parseAbi([
  "event Deposited(address indexed account, address indexed token, uint256 amount, address indexed recipient)",
  "function CAP() view returns (address)",
  "function DACKIE() view returns (address)",
  "function depositDeadline() view returns (uint64)",
  "function cancelled() view returns (bool)",
  "function ratesSet() view returns (bool)",
  "function capRate() view returns (uint256)",
  "function dackieRate() view returns (uint256)",
  "function totalDeposited(address token) view returns (uint256)",
  "function depositOf(address token, address account) view returns (uint256)",
  "function recipientOf(address account) view returns (address)",
  "function isBlocked(address account) view returns (bool)",
  "function allocationOf(address account) view returns (uint256)",
]);
const ZERO = "0x0000000000000000000000000000000000000000";

const args = parseArgs(process.argv.slice(2));
for (const key of ["rpc", "vault", "from-block", "longlock", "exclude", "claim-start"]) {
  if (args[key] === undefined) {
    console.error(
      "usage: build-claims.mjs --rpc <url> --vault <address> --from-block <n> --longlock <csv> --exclude <file|none>\n" +
        "         --claim-start <unix> [--max-total <wei>]\n" +
        "         [--out-csv tree.csv] [--out-report claims-report.json] [--chunk 5000]"
    );
    console.error(`missing --${key}`);
    process.exit(1);
  }
}
if (args["longlock-vesting"] !== undefined) {
  // The distributor has one schedule for every leaf. Fail loudly instead of ignoring the flag.
  console.error("--longlock-vesting was removed: every leaf vests from claim open (plan decision #2)");
  process.exit(1);
}

const vault = getAddress(args.vault);
const fromBlock = BigInt(args["from-block"]);
const claimStart = BigInt(args["claim-start"]);
const chunk = BigInt(args.chunk ?? "5000");

const longLockRows = parseLongLockCsv(readFileSync(args.longlock, "utf8"));
const excluded = args.exclude === "none" ? new Set() : parseAddressList(readFileSync(args.exclude, "utf8"));

// JSON-RPC batching keeps a few thousand eth_calls to a handful of HTTP requests.
const client = createPublicClient({ transport: http(args.rpc, { batch: { batchSize: 100 }, retryCount: 5, timeout: 60_000 }) });
const read = (functionName, fnArgs, blockNumber) =>
  client.readContract({ address: vault, abi: VAULT_ABI, functionName, args: fnArgs, blockNumber });

async function inBatches(items, size, fn) {
  const out = [];
  for (let i = 0; i < items.length; i += size) out.push(...(await Promise.all(items.slice(i, i + size).map(fn))));
  return out;
}

// ---- 1. Freeze block: the first block whose timestamp is after the deposit deadline ----
const latest = await client.getBlock();
if ((await client.getCode({ address: vault })) === undefined) throw new Error(`no contract at ${vault}`);
if (await read("cancelled", [])) throw new Error("the migration is cancelled: there is no claim tree");
const depositDeadline = await read("depositDeadline", []);
if (latest.timestamp <= depositDeadline) throw new Error(`the deposit window is still open (deadline ${depositDeadline})`);
if (claimStart <= depositDeadline) throw new Error("--claim-start must be after the deposit deadline");

let freezeBlock;
if (args.block !== undefined) {
  freezeBlock = BigInt(args.block);
} else {
  let lo = fromBlock; // invariant: the answer is in [lo, hi]
  let hi = latest.number;
  if ((await client.getBlock({ blockNumber: lo })).timestamp > depositDeadline) throw new Error("--from-block is already after the deadline");
  while (lo < hi) {
    const mid = (lo + hi) / 2n;
    if ((await client.getBlock({ blockNumber: mid })).timestamp > depositDeadline) hi = mid;
    else lo = mid + 1n;
  }
  freezeBlock = lo;
}
const freeze = await client.getBlock({ blockNumber: freezeBlock });
const previous = await client.getBlock({ blockNumber: freezeBlock - 1n });
if (freeze.timestamp <= depositDeadline || previous.timestamp > depositDeadline) {
  throw new Error(`block ${freezeBlock} is not the first block after the deadline`);
}
console.log(`vault            ${vault}`);
console.log(`deposit deadline ${depositDeadline}`);
console.log(`freeze block     ${freezeBlock} (timestamp ${freeze.timestamp})`);

// ---- 2. Vault config at the freeze ----
const at = freezeBlock;
const [cap, dackie, ratesSet, capRate, dackieRate] = await Promise.all([
  read("CAP", [], at), read("DACKIE", [], at), read("ratesSet", [], at), read("capRate", [], at), read("dackieRate", [], at),
]);
if (!ratesSet) throw new Error("rates are not set in the vault");
const [totalCap, totalDackie] = await Promise.all([read("totalDeposited", [cap], at), read("totalDeposited", [dackie], at)]);

// ---- 3. Who ever deposited ----
const accounts = new Set();
for (let start = fromBlock; start <= freezeBlock; start += chunk) {
  const end = start + chunk - 1n > freezeBlock ? freezeBlock : start + chunk - 1n;
  const logs = await client.getContractEvents({ address: vault, abi: VAULT_ABI, eventName: "Deposited", fromBlock: start, toBlock: end });
  for (const log of logs) accounts.add(log.args.account.toLowerCase());
}
console.log(`depositors seen  ${accounts.size}`);

// 0xef0100… is an EIP-7702 delegated EOA, not a contract wallet.
const isContractCode = (code) => code !== undefined && code !== "0x" && !code.startsWith("0xef0100");

// ---- 4. Their state at the freeze ----
const depositors = await inBatches([...accounts].sort(), 50, async (account) => {
  const [capAmount, dackieAmount, registered, blocked, onchainAllocation, code] = await Promise.all([
    read("depositOf", [cap, account], at), read("depositOf", [dackie, account], at),
    read("recipientOf", [account], at), read("isBlocked", [account], at), read("allocationOf", [account], at),
    client.getCode({ address: account, blockNumber: at }),
  ]);
  const recipient = registered === ZERO ? account : registered.toLowerCase();
  const recipientBlocked = recipient === account ? blocked : await read("isBlocked", [recipient], at);
  return {
    account, cap: capAmount, dackie: dackieAmount, recipient, blocked, recipientBlocked, onchainAllocation,
    isContract: isContractCode(code),
  };
});

// Completeness: every wei the vault holds for depositors is attributed to a discovered account.
const sumCap = depositors.reduce((s, d) => s + d.cap, 0n);
const sumDackie = depositors.reduce((s, d) => s + d.dackie, 0n);
if (sumCap !== totalCap || sumDackie !== totalDackie) {
  throw new Error(
    `ledger mismatch: found CAP ${sumCap} / DACKIE ${sumDackie}, vault says ${totalCap} / ${totalDackie}. ` +
      "A Deposited event was missed: check --from-block and the RPC."
  );
}

// ---- 5. Long-lockers: recipient and blocklist at the freeze ----
const longLocks = await inBatches(longLockRows, 50, async (l) => {
  const [registered, blocked, code] = await Promise.all([
    read("recipientOf", [l.address], at), read("isBlocked", [l.address], at), client.getCode({ address: l.address, blockNumber: at }),
  ]);
  const recipient = registered === ZERO ? l.address : registered.toLowerCase();
  const recipientBlocked = recipient === l.address ? blocked : await read("isBlocked", [recipient], at);
  return { ...l, recipient, blocked, recipientBlocked, isContract: isContractCode(code), registered: registered !== ZERO };
});

// ---- 6. Compute ----
const input = { depositors, longLocks, excluded, capRate, dackieRate, depositDeadline, claimStart };
const { rows, report } = computeClaims(input);

// The contract is the source of truth for the conversion formula.
for (const d of report.depositors) {
  const onchain = depositors.find((x) => x.account === d.account).onchainAllocation;
  if (onchain !== d.allocation) throw new Error(`allocation mismatch for ${d.account}: computed ${d.allocation}, vault.allocationOf says ${onchain}`);
}

// ---- 7. Budget. Checked before anything is written: a tree that cannot be committed must not
//         leave files behind that look publishable. ----
if (args["max-total"] !== undefined && report.totals.total > BigInt(args["max-total"])) {
  console.error(`OVER BUDGET: totalAllocation ${report.totals.total} exceeds --max-total ${args["max-total"]}. Nothing was written.`);
  process.exit(2);
}

// ---- 8. Warnings a human must look at ----
const warnings = collectWarnings(input, report, getAddress);

// ---- 9. Write ----
const claimDeadline = claimDeadlineOf(claimStart);
const outCsv = args["out-csv"] ?? "tree.csv";
const outReport = args["out-report"] ?? "claims-report.json";
writeFileSync(outCsv, rowsToCsv(rows, getAddress));
writeFileSync(
  outReport,
  JSON.stringify(
    {
      vault, chainId: await client.getChainId(), freezeBlock, freezeTimestamp: freeze.timestamp, depositDeadline, claimStart,
      // Last second a claim is accepted. After it the unclaimed AGENTOS goes back to treasury.
      claimDeadline,
      capRate, dackieRate,
      totalDeposited: { cap: totalCap, dackie: totalDackie },
      totals: report.totals, leaves: rows.length, warnings,
      depositors: report.depositors, longLocks: report.longLocks,
    },
    bigintReplacer,
    2
  ) + "\n"
);

console.log(`rates            CAP ${capRate}  DACKIE ${dackieRate}`);
console.log(`deposit leaves   ${report.totals.deposits}`);
console.log(`long-lock leaves ${report.totals.longLocks}`);
console.log(`excluded team    ${report.totals.excludedTeam}`);
console.log(`excluded blocked ${report.totals.excludedBlocked}`);
console.log(`totalAllocation  ${report.totals.total}`);
console.log(`leaves           ${rows.length}`);
console.log(`claim deadline   ${claimDeadline} (${new Date(Number(claimDeadline) * 1000).toISOString()})`);
console.log(`written          ${outCsv}, ${outReport}`);
for (const w of warnings) console.warn(`WARNING: ${w}`);
