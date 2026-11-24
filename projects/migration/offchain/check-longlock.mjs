#!/usr/bin/env node
// Re-reads the DACKIE long-lock positions on Base and compares them with the baseline list.
// Read-only: it never rewrites the baseline. Use --out to save the current reading next to it.
//
//   node offchain/check-longlock.mjs --rpc <Base RPC with eth_getLogs> \
//     [--baseline ../../docs/data/dackie-longlock-close-2026-12-25.csv] \
//     [--locks <csv with source,address columns>]   more known stakers to re-read (optional)
//     [--from-block 57700000]   scan for NEW stakers from here (the 11-15 13:00 UTC scan was ~57,786,000; Base has 0.2s blocks)
//     [--cutoff 2026-12-25T23:59:59Z] [--chunk 100000] [--out current.csv]
//
// A position is a long lock when its lock ends after the cutoff:
//   DackiePool    userInfo.locked && lockEndTime > cutoff, amount = shares * balanceOf / totalShares - userBoostedShare
//   DackieLPVault lockedLiquidity > 0 && lockedUntil > cutoff, amount = the DACKIE side of that liquidity at the
//                 current pool price (so it moves with price; the plan fixes it at the snapshot price)
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { createPublicClient, http, parseAbi, getAddress } from "viem";
import { parseArgs } from "./tree-lib.mjs";

const POOL = "0xF6C5b5Df9Bcee40cd474CCd6373f99b56dBCF5E5";
const FLEX = "0x5cB90378614631b3d1BAcEDDce6bC09E508B5b95"; // stakes into DackiePool itself, never locked
const VAULT = "0x645D25cC63578096eDbE941CB9EE56D20dA5fC98";

const POOL_ABI = parseAbi([
  "event Deposit(address indexed sender, uint256 amount, uint256 shares, uint256 duration, uint256 lastDepositedTime)",
  "event Lock(address indexed sender, uint256 lockedAmount, uint256 shares, uint256 lockedDuration, uint256 blockTimestamp)",
  "function userInfo(address) view returns (uint256 shares,uint256 lastDepositedTime,uint256 cakeAtLastUserAction,uint256 lastUserActionTime,uint256 lockStartTime,uint256 lockEndTime,uint256 userBoostedShare,bool locked,uint256 lockedAmount)",
  "function balanceOf() view returns (uint256)",
  "function totalShares() view returns (uint256)",
]);
const VAULT_ABI = parseAbi([
  "event Deposit(address indexed user, uint128 liquidity, uint256 a, uint256 b)",
  "event LiquidityLocked(address indexed user, uint128 liquidity, uint64 lockedUntil)",
  "event LiquidityConvertedToLocked(address indexed user, uint128 liquidity, uint64 lockedUntil)",
  "function userInfo(address) view returns (uint128 normalLiquidity,uint128 lockedLiquidity,uint64 lockedUntil,uint256 pendingWETH,uint256 pendingDACKIE)",
  "function position() view returns (uint256,uint128)",
  "function positionManager() view returns (address)",
  "function factory() view returns (address)",
  "function isWETHToken0() view returns (bool)",
]);
const NPM_ABI = parseAbi([
  "function positions(uint256) view returns (uint96 nonce,address operator,address token0,address token1,uint24 fee,int24 tickLower,int24 tickUpper,uint128 liquidity,uint256 fg0,uint256 fg1,uint128 owed0,uint128 owed1)",
]);
const FACTORY_ABI = parseAbi(["function getPool(address,address,uint24) view returns (address)"]);
const V3_ABI = parseAbi(["function slot0() view returns (uint160 sqrtPriceX96,int24 tick,uint16 a,uint16 b,uint16 c,uint32 d,bool e)"]);

const docs = (name) => fileURLToPath(new URL(`../../../docs/data/${name}`, import.meta.url));
const args = parseArgs(process.argv.slice(2));
if (!args.rpc) {
  console.error("usage: check-longlock.mjs --rpc <Base RPC> [--baseline csv] [--locks csv] [--from-block n] [--cutoff iso] [--out csv]");
  process.exit(1);
}
const baselinePath = args.baseline ?? docs("dackie-longlock-close-2026-12-25.csv");
const locksPath = args.locks;
const fromBlock = BigInt(args["from-block"] ?? 57_700_000);
const chunk = BigInt(args.chunk ?? 100_000);
const cutoff = Math.floor(Date.parse(args.cutoff ?? "2026-12-25T23:59:59Z") / 1000);

const readCsv = (path) => {
  const [head, ...lines] = readFileSync(path, "utf8").trim().split(/\r?\n/);
  const cols = head.split(",");
  return lines.map((l) => Object.fromEntries(l.split(",").map((c, i) => [cols[i], c])));
};
const retry = async (fn) => {
  for (let i = 0; ; i++) {
    try { return await fn(); } catch (e) { if (i >= 5) throw e; await new Promise((r) => setTimeout(r, 1000 * (i + 1))); }
  }
};
const pooled = async (items, n, fn) => {
  const out = new Array(items.length); let next = 0;
  await Promise.all(Array.from({ length: n }, async () => { while (next < items.length) { const i = next++; out[i] = await fn(items[i]); } }));
  return out;
};
const utc = (ts) => new Date(ts * 1000).toISOString().slice(0, 19).replace("T", " ");

const client = createPublicClient({ transport: http(args.rpc) });
const head = await retry(() => client.getBlock());
const blockNumber = head.number;
const at = { blockNumber };
console.log(`Base block ${blockNumber} (${utc(Number(head.timestamp))} UTC), cutoff ${utc(cutoff)} UTC`);

// ---- who to read: every known staker + anyone who deposited / locked since --from-block
const baseline = readCsv(baselinePath);
const users = { DackiePool: new Set(), DackieLPVault: new Set() };
for (const r of [...(locksPath ? readCsv(locksPath) : []), ...baseline]) if (users[r.source]) users[r.source].add(getAddress(r.address));
const known = { DackiePool: users.DackiePool.size, DackieLPVault: users.DackieLPVault.size };
for (const [source, address, abi] of [["DackiePool", POOL, POOL_ABI], ["DackieLPVault", VAULT, VAULT_ABI]]) {
  for (let b = fromBlock; b <= blockNumber; b += chunk) {
    const toBlock = b + chunk - 1n > blockNumber ? blockNumber : b + chunk - 1n;
    const logs = await retry(() => client.getLogs({ address, events: abi.filter((x) => x.type === "event"), fromBlock: b, toBlock }));
    for (const l of logs) users[source].add(getAddress(l.args.sender ?? l.args.user));
  }
  console.log(`${source}: ${known[source]} known stakers, ${users[source].size - known[source]} new since block ${fromBlock}`);
}

// ---- DackiePool
const [pBal, pTot] = await Promise.all([
  client.readContract({ address: POOL, abi: POOL_ABI, functionName: "balanceOf", ...at }),
  client.readContract({ address: POOL, abi: POOL_ABI, functionName: "totalShares", ...at }),
]);
const current = [];
await pooled([...users.DackiePool].filter((u) => u !== FLEX), 6, async (u) => {
  const [shares, , , , , lockEndTime, userBoostedShare, locked] =
    await retry(() => client.readContract({ address: POOL, abi: POOL_ABI, functionName: "userInfo", args: [u], ...at }));
  if (!locked || shares === 0n || Number(lockEndTime) <= cutoff) return;
  current.push({ source: "DackiePool", address: u, dackie: Number((shares * pBal) / pTot - userBoostedShare) / 1e18, weth: 0, lockEnd: Number(lockEndTime) });
});

// ---- DackieLPVault: one V3 position shared by every user, split by liquidity
const [[tokenId], npm, factory, wethIs0] = await Promise.all([
  client.readContract({ address: VAULT, abi: VAULT_ABI, functionName: "position", ...at }),
  client.readContract({ address: VAULT, abi: VAULT_ABI, functionName: "positionManager", ...at }),
  client.readContract({ address: VAULT, abi: VAULT_ABI, functionName: "factory", ...at }),
  client.readContract({ address: VAULT, abi: VAULT_ABI, functionName: "isWETHToken0", ...at }),
]);
const pos = await client.readContract({ address: npm, abi: NPM_ABI, functionName: "positions", args: [tokenId], ...at });
const [, , token0, token1, fee, tickLower, tickUpper] = pos;
const v3pool = await client.readContract({ address: factory, abi: FACTORY_ABI, functionName: "getPool", args: [token0, token1, fee], ...at });
const [sqrtPriceX96] = await client.readContract({ address: v3pool, abi: V3_ABI, functionName: "slot0", ...at });
const sq = Number(sqrtPriceX96) / 2 ** 96;
const sqA = Math.sqrt(1.0001 ** tickLower), sqB = Math.sqrt(1.0001 ** tickUpper);
const sqIn = Math.min(Math.max(sq, sqA), sqB);
const per0 = (sqB - sqIn) / (sqIn * sqB) / 1e18, per1 = (sqIn - sqA) / 1e18; // token amounts per unit of liquidity
const [dPer, wPer] = wethIs0 ? [per1, per0] : [per0, per1];
await pooled([...users.DackieLPVault], 6, async (u) => {
  const [, lockedLiquidity, lockedUntil] =
    await retry(() => client.readContract({ address: VAULT, abi: VAULT_ABI, functionName: "userInfo", args: [u], ...at }));
  if (lockedLiquidity === 0n || Number(lockedUntil) <= cutoff) return;
  const l = Number(lockedLiquidity);
  current.push({ source: "DackieLPVault", address: u, dackie: l * dPer, weth: l * wPer, lockEnd: Number(lockedUntil), liquidity: lockedLiquidity });
});

// ---- compare
const key = (r) => `${r.source}:${r.address.toLowerCase()}`;
const baseMap = new Map(baseline.map((r) => [key(r), r]));
const curMap = new Map(current.map((r) => [key(r), r]));
const median = (xs) => { const s = [...xs].sort((a, b) => a - b); return s.length ? s[Math.floor(s.length / 2)] : 1; };
const sum = (rows, f) => rows.reduce((a, r) => a + f(r), 0);
const fmt = (n) => n.toLocaleString("en-US", { maximumFractionDigits: 2 });

console.log("\n== Totals (baseline -> now) ==");
for (const s of ["DackiePool", "DackieLPVault"]) {
  const b = baseline.filter((r) => r.source === s), c = current.filter((r) => r.source === s);
  console.log(`${s.padEnd(14)} positions ${b.length} -> ${c.length}   DACKIE ${fmt(sum(b, (r) => +r.dackie))} -> ${fmt(sum(c, (r) => r.dackie))}`);
}
const wallets = (rows) => new Set(rows.map((r) => r.address.toLowerCase())).size;
console.log(`${"All".padEnd(14)} positions ${baseline.length} -> ${current.length}   wallets ${wallets(baseline)} -> ${wallets(current)}   DACKIE ${fmt(sum(baseline, (r) => +r.dackie))} -> ${fmt(sum(current, (r) => r.dackie))}`);

const added = current.filter((r) => !baseMap.has(key(r)));
const removed = baseline.filter((r) => !curMap.has(key(r)));
console.log(`\n== New long-lock positions: ${added.length} ==`);
for (const r of added) console.log(`  ${r.source} ${r.address} ${fmt(r.dackie)} DACKIE, lock ends ${utc(r.lockEnd)}`);
console.log(`== Positions no longer on the list: ${removed.length} ==`);
for (const r of removed) console.log(`  ${r.source} ${r.address} ${r.dackie} DACKIE (baseline lock end ${r.lock_end_utc})`);

const both = current.filter((r) => baseMap.has(key(r)));
const endChanged = both.filter((r) => r.lockEnd !== Number(baseMap.get(key(r)).lock_end_ts));
console.log(`== Lock end changed: ${endChanged.length} ==`);
for (const r of endChanged) console.log(`  ${r.source} ${r.address} ${baseMap.get(key(r)).lock_end_utc} -> ${utc(r.lockEnd)}`);

// Amounts drift for everyone at once (pool rewards compounding, LP price moving). A position that moves
// differently from its group's median added or removed stake.
console.log("== Amount changed beyond the group drift ==");
let odd = 0;
for (const s of ["DackiePool", "DackieLPVault"]) {
  const rows = both.filter((r) => r.source === s && +baseMap.get(key(r)).dackie >= 100);
  const drift = median(rows.map((r) => r.dackie / +baseMap.get(key(r)).dackie));
  console.log(`  ${s}: group drift ${((drift - 1) * 100).toFixed(3)}%`);
  for (const r of both.filter((x) => x.source === s)) {
    const b = +baseMap.get(key(r)).dackie, rel = r.dackie / b / drift - 1;
    if (Math.abs(rel) > 0.002 && Math.abs(r.dackie - b * drift) > 1) {
      odd++; console.log(`    ${r.address} ${fmt(b)} -> ${fmt(r.dackie)} DACKIE (${(rel * 100).toFixed(2)}% vs drift)`);
    }
  }
}
if (!odd) console.log("  none");

if (args.out) {
  const rows = [...current].sort((a, b) => (a.source < b.source ? 1 : a.source > b.source ? -1 : b.dackie - a.dackie));
  const lines = ["source,address,dackie,weth,lock_end_utc,lock_end_ts,days_after_close,misses_window,label,liquidity,block"];
  for (const r of rows) {
    lines.push([r.source, r.address, r.dackie.toFixed(2), r.weth ? r.weth.toFixed(6) : "0.0", utc(r.lockEnd), r.lockEnd,
      ((r.lockEnd - cutoff) / 86400).toFixed(1), "yes", baseMap.get(key(r))?.label ?? "", r.liquidity ?? "", blockNumber].join(","));
  }
  writeFileSync(args.out, lines.join("\n") + "\n");
  console.log(`\nwrote ${args.out} (${rows.length} positions at block ${blockNumber})`);
}
