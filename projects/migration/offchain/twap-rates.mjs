#!/usr/bin/env node
// Baseline TWAP rates: how many AGENTOS one CAP / one DACKIE is worth over a time window (plan section 5).
// Read-only. Both RPCs must serve historical state (archive) for the window.
//
//   node offchain/twap-rates.mjs --base-rpc <Base archive RPC> --rh-rpc <Robinhood archive RPC> \
//     [--from 2026-11-18T00:00:00Z] [--to <iso, default: now, never past 2026-11-25T00:00:00Z>] \
//     [--step 300] [--out-csv samples.csv]
//
// Price sources (plan section 5):
//   CAP     = CAP/VIRTUAL Uniswap V2 reserves x VIRTUAL/WETH Uniswap V2 reserves x ETH/USD
//   DACKIE  = DACKIE/WETH DackieSwap V3 1% slot0 x ETH/USD
//   AGENTOS = AGENTOS/WETH Uniswap v4 pool 0x1299aa8c...401a (Robinhood) x ETH/USD
//   ETH/USD = Chainlink ETH/USD on Base
// The plan says "VIRTUAL/USD" without naming a source; VIRTUAL/WETH V2 x Chainlink ETH/USD is used here.
//
// Method: Base pools are read every --step seconds at historical blocks. The AGENTOS price is rebuilt
// exactly from the pool's Swap events. Each price is turned into USD per sample, averaged over time,
// and rate = TWAP(token USD) / TWAP(AGENTOS USD).
import { writeFileSync } from "node:fs";
import { createPublicClient, http, parseAbi, keccak256, encodeAbiParameters, getAddress } from "viem";
import { parseArgs } from "./tree-lib.mjs";

const MULTICALL3 = getAddress("0xca11bde05977b3631167028862be2a173976ca11");
const WETH_BASE = getAddress("0x4200000000000000000000000000000000000006");
const CAP = getAddress("0xbfa733702305280f066d470afdfa784fa70e2649");
const DACKIE = getAddress("0x73326b4d0225c429bed050c11c4422d91470aaf4");
const VIRTUAL = getAddress("0x0b3e328455c4059eeb9e3f84b5543f74e24e7e1b");
const CAP_VIRTUAL_V2 = getAddress("0xc19fb7af58b67a072ce23362c2fb1d61ebe6d4ca");
const DACKIE_WETH_V3 = getAddress("0x5d9c4aacf8eba662baf392b56ea6ce2a7d3584ce");
const UNI_V2_FACTORY_BASE = getAddress("0x8909dc15e40173ff4699343b6eb8132c65e18ec6");
const CHAINLINK_ETH_USD_BASE = getAddress("0x71041dddad3595f9ced3dccfbe3d1f4b0a16bb70");
const RH_POOL_MANAGER = getAddress("0x8366a39cc670b4001a1121b8f6a443a643e40951");
const RH_AGENTOS_POOL_ID = "0x1299aa8c4ea0db5b8453757ed129ed8e916561925926a161cb89842e3987401a"; // currency0 WETH, currency1 AGENTOS
const WINDOW_END = "2026-11-25T00:00:00Z";

const V2_ABI = parseAbi(["function getReserves() view returns (uint112,uint112,uint32)", "function token0() view returns (address)"]);
const V3_ABI = parseAbi(["function slot0() view returns (uint160 sqrtPriceX96,int24 tick,uint16 a,uint16 b,uint16 c,uint32 d,bool e)", "function token0() view returns (address)"]);
const FACTORY_ABI = parseAbi(["function getPair(address,address) view returns (address)"]);
const FEED_ABI = parseAbi(["function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)", "function decimals() view returns (uint8)", "function description() view returns (string)"]);
const MC_ABI = parseAbi(["function getCurrentBlockTimestamp() view returns (uint256)"]);
const PM_ABI = parseAbi([
  "function extsload(bytes32 slot) view returns (bytes32)",
  "event Swap(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)",
]);

const args = parseArgs(process.argv.slice(2));
if (!args["base-rpc"] || !args["rh-rpc"]) {
  console.error("usage: twap-rates.mjs --base-rpc <url> --rh-rpc <url> [--from iso] [--to iso] [--step 300] [--out-csv file]");
  process.exit(1);
}
const sec = (iso) => Math.floor(Date.parse(iso) / 1000);
const utc = (ts) => new Date(ts * 1000).toISOString().slice(0, 19).replace("T", " ");
const retry = async (fn) => {
  for (let i = 0; ; i++) {
    try { return await fn(); } catch (e) { if (i >= 5) throw e; await new Promise((r) => setTimeout(r, 1000 * (i + 1))); }
  }
};
const pooled = async (items, n, fn) => {
  const out = new Array(items.length); let next = 0;
  await Promise.all(Array.from({ length: n }, async () => { while (next < items.length) { const i = next++; out[i] = await fn(items[i], i); } }));
  return out;
};

const base = createPublicClient({ transport: http(args["base-rpc"]) });
const rh = createPublicClient({ transport: http(args["rh-rpc"]) });
const [baseHead, rhHead] = await Promise.all([retry(() => base.getBlock()), retry(() => rh.getBlock())]);
const from = sec(args.from ?? "2026-11-18T00:00:00Z");
const to = Math.min(args.to ? sec(args.to) : Infinity, sec(WINDOW_END), Number(baseHead.timestamp), Number(rhHead.timestamp));
const step = Number(args.step ?? 300);
if (!(to > from)) throw new Error("empty window");

// First block with timestamp >= ts.
async function blockAt(client, ts, head) {
  let lo = 1n, hi = head.number;
  while (lo < hi) {
    const mid = (lo + hi) / 2n;
    const b = await retry(() => client.getBlock({ blockNumber: mid }));
    if (Number(b.timestamp) >= ts) hi = mid; else lo = mid + 1n;
  }
  return lo;
}

// ---- Base: sample pools at evenly spaced blocks, each sample carries its own block timestamp
const [baseFrom, baseTo] = await Promise.all([blockAt(base, from, baseHead), blockAt(base, to, baseHead)]);
const virtualWethV2 = await base.readContract({ address: UNI_V2_FACTORY_BASE, abi: FACTORY_ABI, functionName: "getPair", args: [VIRTUAL, WETH_BASE] });
const same = (a, b) => a.toLowerCase() === b.toLowerCase();
const [capT0, virtT0, dackieT0, feedDecimals, feedName] = await Promise.all([
  base.readContract({ address: CAP_VIRTUAL_V2, abi: V2_ABI, functionName: "token0" }),
  base.readContract({ address: virtualWethV2, abi: V2_ABI, functionName: "token0" }),
  base.readContract({ address: DACKIE_WETH_V3, abi: V3_ABI, functionName: "token0" }),
  base.readContract({ address: CHAINLINK_ETH_USD_BASE, abi: FEED_ABI, functionName: "decimals" }),
  base.readContract({ address: CHAINLINK_ETH_USD_BASE, abi: FEED_ABI, functionName: "description" }),
]);
if (feedName !== "ETH / USD") throw new Error(`unexpected Chainlink feed: ${feedName}`);
const n = Math.max(2, Math.round((to - from) / step));
const sampleBlocks = Array.from({ length: n }, (_, i) => baseFrom + ((baseTo - baseFrom) * BigInt(i)) / BigInt(n));
console.log(`window ${utc(from)} -> ${utc(to)} UTC (${((to - from) / 86400).toFixed(2)} days), ${n} samples`);
console.log(`Base blocks ${baseFrom} -> ${baseTo}, VIRTUAL/WETH V2 ${virtualWethV2}`);

const baseSamples = await pooled(sampleBlocks, 8, async (blockNumber) => {
  const r = await retry(() => base.multicall({
    blockNumber, allowFailure: false, multicallAddress: MULTICALL3,
    contracts: [
      { address: MULTICALL3, abi: MC_ABI, functionName: "getCurrentBlockTimestamp" },
      { address: CAP_VIRTUAL_V2, abi: V2_ABI, functionName: "getReserves" },
      { address: virtualWethV2, abi: V2_ABI, functionName: "getReserves" },
      { address: DACKIE_WETH_V3, abi: V3_ABI, functionName: "slot0" },
      { address: CHAINLINK_ETH_USD_BASE, abi: FEED_ABI, functionName: "latestRoundData" },
    ],
  }));
  const [ts, capRes, virtRes, slot0, round] = r;
  const ratio = (res, quoteIsToken1) => (quoteIsToken1 ? Number(res[1]) / Number(res[0]) : Number(res[0]) / Number(res[1]));
  const capVirtual = ratio(capRes, same(capT0, CAP)); // VIRTUAL per CAP
  const virtualEth = ratio(virtRes, same(virtT0, VIRTUAL)); // WETH per VIRTUAL
  const p = (Number(slot0[0]) / 2 ** 96) ** 2; // token1 per token0
  const dackieEth = same(dackieT0, DACKIE) ? p : 1 / p; // WETH per DACKIE
  const ethUsd = Number(round[1]) / 10 ** feedDecimals;
  return { ts: Number(ts), blockNumber, capVirtual, virtualEth, dackieEth, ethUsd };
});

// ---- Robinhood: exact AGENTOS/WETH price path from Swap events
const [rhFrom, rhTo] = await Promise.all([blockAt(rh, from, rhHead), blockAt(rh, to, rhHead)]);
const slot0Slot = keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], [RH_AGENTOS_POOL_ID, 6n]));
const agentosEthOf = (sqrtPriceX96) => 1 / (Number(sqrtPriceX96) / 2 ** 96) ** 2; // WETH per AGENTOS
const CHUNK = 100_000n;
const swapLogs = (fromBlock, toBlock) =>
  retry(() => rh.getLogs({ address: RH_POOL_MANAGER, event: PM_ABI[1], args: { id: RH_AGENTOS_POOL_ID }, fromBlock, toBlock }));
// Price at the window start: slot0 at that block, or (RPC without historical state) the last Swap before it.
let startSqrt;
try {
  const word = await rh.readContract({ address: RH_POOL_MANAGER, abi: PM_ABI, functionName: "extsload", args: [slot0Slot], blockNumber: rhFrom });
  startSqrt = BigInt(word) & ((1n << 160n) - 1n);
} catch {
  for (let hi = rhFrom; startSqrt === undefined && hi > 0n; hi -= CHUNK) {
    const logs = await swapLogs(hi > CHUNK ? hi - CHUNK + 1n : 1n, hi);
    if (logs.length) startSqrt = logs[logs.length - 1].args.sqrtPriceX96;
  }
  if (startSqrt === undefined) throw new Error("no AGENTOS/WETH swap before the window start");
  console.log("Robinhood RPC has no historical state: start price taken from the last Swap before the window");
}
const swaps = [];
const ranges = [];
for (let b = rhFrom + 1n; b <= rhTo; b += CHUNK) ranges.push([b, b + CHUNK - 1n > rhTo ? rhTo : b + CHUNK - 1n]);
for (const logs of await pooled(ranges, 4, ([fromBlock, toBlock]) => swapLogs(fromBlock, toBlock))) swaps.push(...logs);
const stamps = new Map();
await pooled([...new Set(swaps.map((l) => l.blockNumber))], 8, async (bn) => {
  const hit = swaps.find((l) => l.blockNumber === bn && l.blockTimestamp !== undefined);
  stamps.set(bn, hit ? Number(BigInt(hit.blockTimestamp)) : Number((await retry(() => rh.getBlock({ blockNumber: bn }))).timestamp));
});
const path = [{ ts: from, price: agentosEthOf(startSqrt) }];
for (const l of swaps.sort((a, b) => (a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : a.blockNumber < b.blockNumber ? -1 : 1))) {
  path.push({ ts: stamps.get(l.blockNumber), price: agentosEthOf(l.args.sqrtPriceX96) });
}
console.log(`Robinhood blocks ${rhFrom} -> ${rhTo}, ${swaps.length} AGENTOS/WETH swaps`);

// ---- combine
let cursor = 0;
const samples = baseSamples.map((s, i) => {
  while (cursor + 1 < path.length && path[cursor + 1].ts <= s.ts) cursor++;
  const agentosEth = path[cursor].price;
  const next = i + 1 < baseSamples.length ? baseSamples[i + 1].ts : to;
  return {
    ...s, agentosEth, weight: Math.max(0, next - s.ts),
    capUsd: s.capVirtual * s.virtualEth * s.ethUsd, dackieUsd: s.dackieEth * s.ethUsd, agentosUsd: agentosEth * s.ethUsd,
  };
});
const twap = (rows, f) => rows.reduce((a, r) => a + f(r) * r.weight, 0) / rows.reduce((a, r) => a + r.weight, 0);
const report = (label, rows) => {
  const cap = twap(rows, (r) => r.capUsd), dackie = twap(rows, (r) => r.dackieUsd), agentos = twap(rows, (r) => r.agentosUsd);
  console.log(`${label.padEnd(22)} CAP $${cap.toPrecision(5)}  DACKIE $${dackie.toPrecision(5)}  AGENTOS $${agentos.toPrecision(5)}  ETH $${twap(rows, (r) => r.ethUsd).toFixed(0)}` +
    `  | 1 CAP = ${(cap / agentos).toFixed(3)} AGENTOS, 1 DACKIE = ${(dackie / agentos).toFixed(3)} AGENTOS`);
  return { cap, dackie, agentos };
};
console.log("\n== TWAP (USD) and rate = TWAP(token) / TWAP(AGENTOS) ==");
for (let d = from; d < to; d += 86400) {
  const rows = samples.filter((r) => r.ts >= d && r.ts < d + 86400);
  if (rows.length) report(utc(d).slice(0, 10) + (d + 86400 > to ? " (partial)" : ""), rows);
}
report("WINDOW", samples);
const last = samples[samples.length - 1];
console.log(`${"spot at window end".padEnd(22)} 1 CAP = ${(last.capUsd / last.agentosUsd).toFixed(3)} AGENTOS, 1 DACKIE = ${(last.dackieUsd / last.agentosUsd).toFixed(3)} AGENTOS`);
console.log("\n== Other ways to average, for comparison ==");
console.log(`time-average of the spot ratio:      1 CAP = ${twap(samples, (r) => r.capUsd / r.agentosUsd).toFixed(3)}, 1 DACKIE = ${twap(samples, (r) => r.dackieUsd / r.agentosUsd).toFixed(3)}`);
console.log(`ETH-denominated TWAPs (no ETH/USD):  1 CAP = ${(twap(samples, (r) => r.capVirtual * r.virtualEth) / twap(samples, (r) => r.agentosEth)).toFixed(3)}, 1 DACKIE = ${(twap(samples, (r) => r.dackieEth) / twap(samples, (r) => r.agentosEth)).toFixed(3)}`);

if (args["out-csv"]) {
  const lines = ["ts,utc,base_block,eth_usd,cap_usd,dackie_usd,agentos_usd,cap_rate,dackie_rate"];
  for (const r of samples) lines.push([r.ts, utc(r.ts), r.blockNumber, r.ethUsd, r.capUsd, r.dackieUsd, r.agentosUsd, r.capUsd / r.agentosUsd, r.dackieUsd / r.agentosUsd].join(","));
  writeFileSync(args["out-csv"], lines.join("\n") + "\n");
  console.log(`\nwrote ${args["out-csv"]}`);
}
