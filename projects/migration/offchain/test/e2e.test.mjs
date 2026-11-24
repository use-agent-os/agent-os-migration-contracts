// End-to-end rehearsal of the whole settlement pipeline on a local anvil chain:
//
//   real MigrationVault  ->  build-claims.mjs  ->  build-tree.mjs  ->  verify-tree.mjs
//                        ->  real MerkleVestingDistributor.commitRoot  ->  claim
//
// Needs `forge build` first (it loads the compiled contracts from out/) and `anvil` on PATH.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdtempSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, createTestClient, createWalletClient, http, getAddress } from "viem";
import { mnemonicToAccount } from "viem/accounts";
import { foundry } from "viem/chains";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const PORT = 18545 + Math.floor(Math.random() * 2000);
const RPC = `http://127.0.0.1:${PORT}`;
const E18 = 10n ** 18n;
const DAY = 86400n;
const CAP_RATE = 25_500000000000000000n;
const DACKIE_RATE = 18_123456789000000000n;
const BUDGET = 5_000_000_000n * E18;
const DEPOSIT_CAP = 4_200_000_000n * E18;

// anvil's well-known development mnemonic: local test keys only.
const MNEMONIC = "test test test test test test test test test test test junk";
const acct = (i) => mnemonicToAccount(MNEMONIC, { addressIndex: i });
const [safe, alice, bob, carol, team, leaked, msig, locker, dave] = [0, 1, 2, 3, 4, 5, 6, 7, 8].map(acct);
const treasury = getAddress("0x000000000000000000000000000000000000beef");
const r2 = getAddress("0x00000000000000000000000000000000000000b2"); // bob's recipient
const lockerRecipient = getAddress("0x00000000000000000000000000000000000000d7");
const blockedRecipient = getAddress("0x00000000000000000000000000000000000000f6");
const ghost = getAddress("0x000000000000000000000000000000000000900d"); // long-locker that never touches the vault

const artifact = (name) => {
  const path = join(ROOT, "out", `${name}.sol`, `${name}.json`);
  if (!existsSync(path)) throw new Error(`${path} not found: run \`forge build\` first`);
  const json = JSON.parse(readFileSync(path, "utf8"));
  return { abi: json.abi, bytecode: json.bytecode.object };
};

let anvil;
const transport = http(RPC);
const pub = createPublicClient({ chain: foundry, transport });
const testClient = createTestClient({ chain: foundry, mode: "anvil", transport });
const wallet = (account) => createWalletClient({ account, chain: foundry, transport });

async function deploy(name, args) {
  const { abi, bytecode } = artifact(name);
  const hash = await wallet(safe).deployContract({ abi, bytecode, args });
  const receipt = await pub.waitForTransactionReceipt({ hash });
  assert.equal(receipt.status, "success", `deploy ${name}`);
  return { address: receipt.contractAddress, abi };
}

async function send(account, contract, functionName, args = []) {
  const hash = await wallet(account).writeContract({ address: contract.address, abi: contract.abi, functionName, args });
  const receipt = await pub.waitForTransactionReceipt({ hash });
  assert.equal(receipt.status, "success", `${functionName} reverted`);
  return receipt;
}

const call = (contract, functionName, args = []) => pub.readContract({ address: contract.address, abi: contract.abi, functionName, args });
const nextBlockAt = (timestamp) => testClient.setNextBlockTimestamp({ timestamp });
const cli = (script, args) => execFileSync(process.execPath, [join(ROOT, "offchain", script), ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });

before(async () => {
  anvil = spawn("anvil", ["--port", String(PORT), "--silent"], { stdio: "ignore" });
  for (let i = 0; i < 100; i++) {
    try {
      await pub.getChainId();
      return;
    } catch {
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  throw new Error("anvil did not start");
});

after(() => anvil?.kill());

test("vault ledger -> tree.csv -> root -> on-chain commit and claim", async () => {
  const dir = mkdtempSync(join(tmpdir(), "claims-e2e-"));
  const cap = await deploy("MockERC20", ["Capminal", "CAP"]);
  const dackie = await deploy("MockERC20", ["Dackie", "DACKIE"]);
  const agentos = await deploy("MockERC20", ["AgentOS", "AGENTOS"]);

  const t0 = (await pub.getBlock()).timestamp;
  const start = t0 + 1000n;
  const deadline = start + 20n * DAY;
  const claimStart = deadline + 3n * DAY;
  const vault = await deploy("MigrationVault", [
    {
      owner: safe.address, guardian: "0x0000000000000000000000000000000000000000", cap: cap.address, dackie: dackie.address,
      depositStart: start, depositDeadline: deadline, maxDepositDeadline: deadline + 10n * DAY,
      minRateNotice: 7n * DAY, releaseDelay: DAY / 2n, settlementGrace: 5n * DAY, maxDepositAllocation: DEPOSIT_CAP,
    },
  ]);
  const distributor = await deploy("MerkleVestingDistributor", [safe.address, agentos.address, BUDGET]);
  assert.equal(await call(vault, "MAX_DEPOSIT_ALLOCATION"), DEPOSIT_CAP);
  await send(safe, agentos, "mint", [distributor.address, BUDGET]);

  for (const user of [alice, bob, carol, team, leaked, msig, dave]) {
    await send(safe, cap, "mint", [user.address, 1_000_000n * E18]);
    await send(safe, dackie, "mint", [user.address, 1_000_000n * E18]);
    await send(user, cap, "approve", [vault.address, 2n ** 256n - 1n]);
    await send(user, dackie, "approve", [vault.address, 2n ** 256n - 1n]);
  }

  // ---- the window ----
  await nextBlockAt(start);
  await send(alice, vault, "deposit", [cap.address, 1000n * E18, alice.address]);
  await send(alice, vault, "withdraw", [cap.address, 250_500000000000000000n]); // keeps 749.5 CAP
  await send(bob, vault, "deposit", [dackie.address, 123_456789012345678901n, alice.address]); // recipient replaced below
  await send(bob, vault, "deposit", [cap.address, 1n, r2]); // 1 wei of CAP, and the final recipient
  await send(carol, vault, "deposit", [cap.address, 5n * E18, carol.address]);
  await send(carol, vault, "withdraw", [cap.address, 5n * E18]); // changed her mind: no leaf
  await send(team, vault, "deposit", [cap.address, 5000n * E18, team.address]); // sold, never claims
  await send(leaked, vault, "deposit", [cap.address, 10n * E18, leaked.address]);
  await send(safe, vault, "setBlocked", [[leaked.address], true]); // blocked after depositing
  await send(msig, vault, "deposit", [dackie.address, 77n * E18, blockedRecipient]);
  await send(safe, vault, "setBlocked", [[blockedRecipient], true]); // its recipient gets blocked later
  await send(locker, vault, "registerRecipient", [lockerRecipient]); // long-locker, never deposits
  const ratesReceipt = await send(safe, vault, "setRates", [CAP_RATE, DACKIE_RATE]);

  // A deposit mined in the very last second of the window still counts.
  await nextBlockAt(deadline);
  const lastDeposit = await send(dave, vault, "deposit", [cap.address, 2n * E18, dave.address]);
  assert.equal((await pub.getBlock({ blockNumber: lastDeposit.blockNumber })).timestamp, deadline);
  await nextBlockAt(deadline + 1n);
  await testClient.mine({ blocks: 1 });
  const expectedFreezeBlock = await pub.getBlockNumber({ cacheTime: 0 }); // viem caches the block number by default
  await testClient.mine({ blocks: 5 });

  // ---- build-claims ----
  const lockEndLocker = claimStart + 100n * DAY;
  const lockEndAlice = claimStart + 50n * DAY;
  const longlockCsv = join(dir, "longlock.csv");
  writeFileSync(
    longlockCsv,
    "source,address,dackie,weth,lock_end_utc,lock_end_ts,days_after_close,misses_window,label\n" +
      `DackieLPVault,${locker.address},1000.55,0.03,x,${lockEndLocker},100,yes,\n` +
      `DackiePool,${alice.address},5.25,0.0,x,${lockEndAlice},50,yes,\n` +
      `DackiePool,${ghost},2,0.0,x,${deadline + 3600n},0.1,yes,\n` +
      `DackiePool,${leaked.address},3,0.0,x,${lockEndAlice},50,yes,\n` // blocked: manual path, no leaf
  );
  const excludeFile = join(dir, "team.txt");
  writeFileSync(excludeFile, `# team\n${team.address}\n`);
  const treeCsv = join(dir, "tree.csv");
  const reportJson = join(dir, "claims-report.json");

  const stdout = cli("build-claims.mjs", [
    "--rpc", RPC, "--vault", vault.address, "--from-block", "0", "--longlock", longlockCsv, "--exclude", excludeFile,
    "--claim-start", claimStart.toString(), "--max-total", BUDGET.toString(),
    "--out-csv", treeCsv, "--out-report", reportJson,
  ]);
  assert.match(stdout, new RegExp(`freeze block\\s+${expectedFreezeBlock} `));

  // Expected leaves, derived here by hand from the scenario above. One leaf per recipient:
  // alice deposited CAP and also has a long lock, both land in her single leaf.
  const floorMul = (amount, rate) => (amount * rate) / E18;
  const expected = [
    [alice.address, floorMul(749_500000000000000000n, CAP_RATE) + floorMul(5_250000000000000000n, DACKIE_RATE)],
    [r2, floorMul(1n, CAP_RATE) + floorMul(123_456789012345678901n, DACKIE_RATE)],
    [dave.address, floorMul(2n * E18, CAP_RATE)],
    [ghost, floorMul(2n * E18, DACKIE_RATE)],
    [lockerRecipient, floorMul(1000_550000000000000000n, DACKIE_RATE)],
  ]
    .map(([account, allocation]) => ({ account: account.toLowerCase(), allocation }))
    .sort((a, b) => (a.account < b.account ? -1 : 1));
  const expectedCsv = "account,allocation\n" + expected.map((r) => `${getAddress(r.account)},${r.allocation}`).join("\n") + "\n";
  assert.equal(readFileSync(treeCsv, "utf8"), expectedCsv);

  const report = JSON.parse(readFileSync(reportJson, "utf8"));
  const total = expected.reduce((s, r) => s + r.allocation, 0n);
  assert.equal(report.totals.total, total.toString());
  assert.equal(report.freezeBlock, expectedFreezeBlock.toString());
  assert.equal(report.totals.excludedTeam, floorMul(5000n * E18, CAP_RATE).toString());
  const owedOnManualPath = floorMul(10n * E18, CAP_RATE) + floorMul(77n * E18, DACKIE_RATE) + floorMul(3n * E18, DACKIE_RATE);
  assert.equal(report.totals.excludedBlocked, owedOnManualPath.toString());
  assert.equal(report.claimDeadline, (claimStart + 90n * DAY).toString());
  // The blocked long-lock row is reported too, with the amount owed outside the tree.
  assert.equal(report.warnings.length, 1);
  assert.match(report.warnings[0], /2 depositor\(s\) and 1 long-lock row\(s\) excluded by the blocklist/);
  assert.ok(report.warnings[0].includes(owedOnManualPath.toString()));
  const status = Object.fromEntries(report.depositors.map((d) => [d.account, d.status]));
  assert.equal(status[team.address.toLowerCase()], "excluded:team");
  assert.equal(status[leaked.address.toLowerCase()], "excluded:blocked");
  assert.equal(status[msig.address.toLowerCase()], "excluded:recipient-blocked");
  assert.equal(status[carol.address.toLowerCase()], undefined, "fully withdrawn accounts are not listed");

  // Re-running gives a byte-identical file.
  const treeCsv2 = join(dir, "tree2.csv");
  cli("build-claims.mjs", [
    "--rpc", RPC, "--vault", vault.address, "--from-block", "0", "--longlock", longlockCsv, "--exclude", excludeFile,
    "--claim-start", claimStart.toString(), "--out-csv", treeCsv2, "--out-report", join(dir, "r2.json"),
    "--block", expectedFreezeBlock.toString(),
  ]);
  assert.equal(readFileSync(treeCsv2, "utf8"), expectedCsv);

  // A wrong --block is refused.
  assert.throws(
    () => cli("build-claims.mjs", [
      "--rpc", RPC, "--vault", vault.address, "--from-block", "0", "--longlock", longlockCsv, "--exclude", "none",
      "--claim-start", claimStart.toString(), "--out-csv", join(dir, "x.csv"), "--out-report", join(dir, "x.json"),
      "--block", (expectedFreezeBlock + 2n).toString(),
    ]),
    /not the first block after the deadline/
  );

  // The per-lock vesting mode is gone: asking for it is refused, not ignored.
  assert.throws(
    () => cli("build-claims.mjs", [
      "--rpc", RPC, "--vault", vault.address, "--from-block", "0", "--longlock", longlockCsv, "--exclude", excludeFile,
      "--claim-start", claimStart.toString(), "--longlock-vesting", "lock-end", "--out-csv", join(dir, "v.csv"), "--out-report", join(dir, "v.json"),
    ]),
    /--longlock-vesting was removed/
  );
  assert.equal(existsSync(join(dir, "v.csv")), false);

  // Starting the event scan too late misses depositors: the run must abort, not drop them.
  assert.throws(
    () => cli("build-claims.mjs", [
      "--rpc", RPC, "--vault", vault.address, "--from-block", ratesReceipt.blockNumber.toString(), "--longlock", longlockCsv, "--exclude", excludeFile,
      "--claim-start", claimStart.toString(), "--out-csv", join(dir, "z.csv"), "--out-report", join(dir, "z.json"),
    ]),
    /ledger mismatch/
  );
  assert.equal(existsSync(join(dir, "z.csv")), false, "nothing is written when the ledger does not add up");

  // Over budget exits non-zero, and leaves no file behind that could be published by mistake.
  assert.throws(
    () => cli("build-claims.mjs", [
      "--rpc", RPC, "--vault", vault.address, "--from-block", "0", "--longlock", longlockCsv, "--exclude", excludeFile,
      "--claim-start", claimStart.toString(), "--max-total", (total - 1n).toString(),
      "--out-csv", join(dir, "y.csv"), "--out-report", join(dir, "y.json"),
    ]),
    /OVER BUDGET/
  );
  assert.equal(existsSync(join(dir, "y.csv")), false, "nothing is written when the tree is over budget");
  assert.equal(existsSync(join(dir, "y.json")), false, "nothing is written when the tree is over budget");

  // ---- build-tree + verify-tree ----
  const treeJson = join(dir, "tree.json");
  cli("build-tree.mjs", [
    "--input", treeCsv, "--chain-id", "31337", "--distributor", distributor.address, "--claim-start", claimStart.toString(),
    "--max-total", BUDGET.toString(), "--out", treeJson,
  ]);
  const tree = JSON.parse(readFileSync(treeJson, "utf8"));
  assert.equal(tree.totalAllocation, total.toString());
  assert.equal(tree.count, expected.length);
  assert.equal(tree.claimDeadline, (claimStart + 90n * DAY).toString());
  assert.equal(new Set(tree.claims.map((c) => c.account)).size, tree.count, "one leaf per account");

  // ---- commit on the real distributor with the sample leaf, attest on the vault ----
  const s = tree.sample;
  await send(safe, distributor, "commitRoot", [tree.root, BigInt(tree.totalAllocation), claimStart, s.account, BigInt(s.allocation), s.proof]);
  await send(safe, vault, "attestClaimRoot", [tree.root, BigInt(tree.totalAllocation), distributor.address]);
  assert.equal(await call(vault, "claimRoot"), await call(distributor, "merkleRoot"));
  assert.equal((await call(distributor, "claimDeadline")).toString(), tree.claimDeadline, "the file and the chain agree on the deadline");
  // Unused budget goes back to treasury right away.
  await send(safe, distributor, "sweepExcess", [treasury]);
  assert.equal(await call(agentos, "balanceOf", [treasury]), BUDGET - total);

  const verified = cli("verify-tree.mjs", [
    "--tree", treeJson, "--chain-id", "31337", "--distributor", distributor.address,
    "--root", await call(distributor, "merkleRoot"), "--total", (await call(distributor, "totalAllocation")).toString(),
  ]);
  assert.match(verified, /OK: domain, root, total and every proof verify/);

  // ---- claims: every leaf of the file pays out on-chain ----
  await nextBlockAt(claimStart);
  const aliceLeaf = tree.claims.find((c) => c.account === alice.address);
  await send(dave, distributor, "claim", [aliceLeaf.account, BigInt(aliceLeaf.allocation), aliceLeaf.proof]);
  assert.equal(await call(agentos, "balanceOf", [alice.address]), BigInt(aliceLeaf.allocation) / 5n, "20% at claim open");

  // Vesting is over for everyone, long-lockers included. The ghost never shows up.
  const ghostLeaf = tree.claims.find((c) => c.account === ghost);
  await nextBlockAt(claimStart + 60n * DAY);
  for (const c of tree.claims) {
    if (c === ghostLeaf) continue;
    await send(dave, distributor, "claim", [c.account, BigInt(c.allocation), c.proof]);
  }
  assert.equal(await call(distributor, "totalClaimed"), total - BigInt(ghostLeaf.allocation));
  assert.equal(await call(distributor, "outstanding"), BigInt(ghostLeaf.allocation));

  // ---- one month after vesting ends: claims are closed, the unclaimed rest returns to treasury ----
  await nextBlockAt(BigInt(tree.claimDeadline) + 1n);
  await testClient.mine({ blocks: 1 });
  await assert.rejects(
    pub.simulateContract({
      address: distributor.address, abi: distributor.abi, functionName: "claim", account: dave,
      args: [ghostLeaf.account, BigInt(ghostLeaf.allocation), ghostLeaf.proof],
    }),
    /ClaimsExpired/
  );
  assert.equal(await call(distributor, "outstanding"), 0n);
  await send(safe, distributor, "sweepExcess", [treasury]);
  assert.equal(await call(agentos, "balanceOf", [distributor.address]), 0n);
  assert.equal(await call(agentos, "balanceOf", [treasury]), BUDGET - total + BigInt(ghostLeaf.allocation));
  assert.equal(await call(agentos, "balanceOf", [ghost]), 0n);
  assert.equal(await call(agentos, "balanceOf", [lockerRecipient]), floorMul(1000_550000000000000000n, DACKIE_RATE));
  assert.equal(await call(agentos, "balanceOf", [locker.address]), 0n, "the long-locker's AGENTOS went to its registered recipient");
  assert.equal(await call(agentos, "balanceOf", [team.address]), 0n);
  assert.equal(await call(agentos, "balanceOf", [leaked.address]), 0n);
  assert.equal(await call(agentos, "balanceOf", [blockedRecipient]), 0n);
});

test("build-claims refuses to run while the window is open", async () => {
  const cap = await deploy("MockERC20", ["Capminal", "CAP"]);
  const dackie = await deploy("MockERC20", ["Dackie", "DACKIE"]);
  const t0 = (await pub.getBlock()).timestamp;
  const vault = await deploy("MigrationVault", [
    {
      owner: safe.address, guardian: "0x0000000000000000000000000000000000000000", cap: cap.address, dackie: dackie.address,
      depositStart: t0 + 100n, depositDeadline: t0 + 100n + 20n * DAY, maxDepositDeadline: t0 + 100n + 30n * DAY,
      minRateNotice: 7n * DAY, releaseDelay: DAY / 2n, settlementGrace: 5n * DAY, maxDepositAllocation: DEPOSIT_CAP,
    },
  ]);
  const dir = mkdtempSync(join(tmpdir(), "claims-e2e-"));
  const longlockCsv = join(dir, "longlock.csv");
  writeFileSync(longlockCsv, `address,dackie,lock_end_ts\n${ghost},1,${t0 + 400n * DAY}\n`);
  assert.throws(
    () => cli("build-claims.mjs", [
      "--rpc", RPC, "--vault", vault.address, "--from-block", "0", "--longlock", longlockCsv, "--exclude", "none",
      "--claim-start", (t0 + 200n * DAY).toString(), "--out-csv", join(dir, "t.csv"), "--out-report", join(dir, "t.json"),
    ]),
    /deposit window is still open/
  );
});
