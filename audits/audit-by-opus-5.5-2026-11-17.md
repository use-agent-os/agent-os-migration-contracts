# Audit by Opus 5.5 — CAP + DACKIE → AGENTOS Migration

> **Budget restatement:** This report was originally written against the 10B AGENTOS / 8.5B deposit-cap configuration. Budget figures below reflect the 5B AGENTOS / 4.20B deposit-cap release. The test results, file hashes, and audit conclusions refer to the original review, not to a new audit of the release revision.

**Date:** 2026-11-17

**Release revision:** `projects/migration` at `a4a765e7ab278ae30e5912f9f56584a336205ff2` (2026-11-24).

**Original review target:** `projects/migration` at `bb7af4634de688ff6c8e03b66691fe189e2c6be6` (2026-11-17).

**Specification:** `docs/migration_plan.md` — v1.0 release budget; Draft v3.4 for the original review.

**Previous reviews:** `audit/audit-by-gpt-sol-2026-11-17.md` (first reviewed against plan v3.1), `audit/audit-by-gpt-astra-2026-11-17.md` (first reviewed against plan v3.3). Both were later revised to plan v3.4 using the finding statuses in §2 of this report.
**Review type:** Source-code and repository review with reproduction tests. Not a formal third-party audit, not a deployment certification.

> **Revision note.** The pre-launch checklist and the action list in the release recommendation were removed from this published version, and the count of partly fixed findings in §1 was corrected (5, not 6). The findings and their evidence are unchanged.

> This report checks the code as it is in the working tree today. It does not cover deployed bytecode, the final long-lock snapshot, the final claim tree, or the sale / bridge / liquidity transactions.

---

## 0. Operating assumptions

The same model as both earlier reports, now written into the plan as **decision #10**:

1. 404AI Labs's Safe Wallet owns both contracts and is trusted to follow the published plan.
2. No independent guardian, no on-chain cross-chain proof. The control is: freeze → publish claim package → 48h public review → commit → attest on Base → 24h → release.
3. A compromised or malicious Safe is an **accepted** risk, not a finding.

Two more assumptions confirmed by the team for this report:

4. **`extendDeadline` will not be used.** The deposit deadline stays 2026-12-25 23:59:59 UTC.
5. **`setRates` is called before `DEPOSIT_START`.** No deposit can be made before the rates are known, and the deposit cap applies from the first deposit.

If either assumption changes, revisit the long-lock list (rows with `lock_end` before `MAX_DEPOSIT_DEADLINE`) and the pre-rates deposit gap.

Under a hostile-Safe model, Astra's H-02 stands as written: Base cannot verify Robinhood, so a bad Safe can attest anything and take the deposits after 24h.

---

## 1. Executive summary

The code changed a lot since the two earlier reviews. Five findings are now fixed: M-01 (on-chain deposit cap), M-02 (fixed rate-correction cutoff), L-03 (claim deadline and treasury return), L-04 (keystore deploy), and most of H-01's "locked forever" impact. The other prior findings are partly fixed or accepted.

| Question | Short answer |
|---|---|
| **0. Are the prior findings fixed?** | **Mostly.** 4 fixed, 5 partly fixed, 1 accepted by decision (H-02), 1 inherent (L-02). Details in §2. |
| **1. Does it satisfy plan v3.4?** | **Yes, for every rule the contracts can enforce.** The dates in `env.example` match the plan to the second. The remaining gaps are operational (§3.2, §3.3). |
| **2. Is security ensured?** | **Yes against outside attackers**, within the trusted-Safe model. Access control, reentrancy guards, balance-delta accounting, domain-bound leaves, immutable root, the fixed cutoff and the claim deadline are all correct and tested. |
| **3. Can funds be lost or hacked?** | **No unprivileged drain found.** Funds can still be lost through: a wrong tree or total, a cancel after the root is committed (team loses, N-04), claims not made before 2027-03-31 (by design), wrong recipients, or CAP tax. |
| **4. Can transactions revert?** | **Yes**, on purpose and in some edge cases. The full list is in §5. New reverts: `DepositCapExceeded`, `RatesFinal`, `ClaimsExpired`. |
| **5. New bugs found?** | **7 new findings: 3 Low, 1 Info / Low, 3 Informational.** None is a critical bug or an unprivileged drain. The most important are **N-02** (long-lock list can count one position twice) and **N-04** (double benefit if settlement fails after the root is committed). |

**Release assessment:** The contracts are fit for a controlled launch on 11-25 under the trusted-Safe model. The open points (N-02, N-04) concern the snapshot and settlement process, not the core result of this review.

---

## 2. Status of prior findings

| ID | Prior severity | Status now | Evidence |
|---|---|---|---|
| **H-01** Total / tree not provable on-chain | High | **Partly fixed.** If the stated total is **too high**, the extra is no longer locked forever: it can be swept after `claimDeadline()`. If it is **too low**, the last claimants still revert with `AllocationExceeded`, and a top-up cannot fix this because the check uses the committed `totalAllocation`. Tooling is much better: `build-claims.mjs` rebuilds the ledger from events, checks it against `totalDeposited`, checks every allocation against `vault.allocationOf`, and `verify-tree.mjs` takes root and total from the chain. **Now Medium (process control).** | `MerkleVestingDistributor.sol:122,257-260`; tests `test_claim_cannotExceedCommittedTotal`, `test_commit_overstatedTotalIsReservedUntilTheDeadline` |
| **H-02** (Astra) Attestation is not cross-chain proven | High under hostile Safe | **Accepted** (decision #10). An optional `GUARDIAN` exists in code, set to none by default. README §"Guardian" explains the trade-off. | `MigrationVault.sol:304-319,344-356` |
| **M-01** No budget check at deposit time | Medium | **Fixed.** `MAX_DEPOSIT_ALLOCATION` (4.20B, immutable) is checked in `deposit` once rates are set. Withdrawals are never capped. Invariant `invariant_depositsRespectTheCap`. The cap applies from the first deposit because rates are set before `DEPOSIT_START` (§0 assumption 5). A rate correction can still push existing deposits over the cap; new deposits then stop (documented). | `MigrationVault.sol:190-192` |
| **M-02** Extending the deadline reopens rate changes | Medium | **Fixed.** `RATE_CORRECTION_CUTOFF = initial deadline − MIN_RATE_NOTICE` is immutable (= 1796947199 = **2026-12-10 23:59:59 UTC**, same as the plan). `extendDeadline` does not move it, and it will not be used anyway (§0 assumption 4). Invariant `invariant_ratesAreFinalAfterTheCutoff`. | `MigrationVault.sol:148,273` |
| **M-03** Long-lock CSV is trusted input / duplicates | Medium | **Partly fixed.** Without `position_id`, duplicates are now keyed on `(address, lock_end_ts)` whatever the source label. With `position_id`, ids must be unique. `misses_window` must be `yes`. Still open: the snapshot is not built from the chain by any tool in the repo, and the dedup has gaps (N-02). | `claims-lib.mjs:52-91` |
| **M-04** Deploy / blocklist are operational | Medium | **Partly fixed.** `ALLOW_EOA_OWNER` / `ALLOW_ANY_CHAIN` now revert on 8453 and 4663. The owner must be a Safe with threshold ≥ 2. Rough unit-bound checks were added on `MAX_DEPOSIT_ALLOCATION`. Still open: no signed manifest (dates are not checked against the plan), and the blocklist is still a separate Safe batch. | `DeployBase.s.sol:21-50`, `DeployVault.s.sol:51-53` |
| **M-05** Manual-path claims have no reserve | Medium | **Partly fixed.** The warning now covers blocked long-lock rows and prints the wei owed. There is still no on-chain reserve: after commit, `sweepExcess` returns that budget to treasury, and the treasury must pay it by hand. **Now Low.** | `claims-lib.mjs:209-217` |
| **L-01** Recipient not validated on Robinhood | Low | **Partly fixed.** Warnings now flag contract wallets (EIP-7702 excluded) that receive at their own address. Still open in principle, plus a new path to it (N-03). | `claims-lib.mjs:184-197` |
| **L-02** CAP tax / token behaviour | Low | **Unchanged (inherent).** A fork test shows the vault stays solvent if CAP's owner flags it as a pool. | `test/fork/BaseFork.t.sol` |
| **L-03** No expiry for unclaimed AGENTOS | Low | **Fixed** (decision #8). `claimDeadline() = claimStart + 60d + 30d` = **2027-03-31 00:00:00 UTC**, inclusive, derived from constants, and moves only with `postponeClaimStart`. After it, `outstanding()` is 0 and `sweepExcess` returns everything. | `MerkleVestingDistributor.sol:47,107-108,250-260` |
| **L-04** `$PRIVATE_KEY` expanded before `dotenv` | Low | **Fixed.** Now uses `dotenv -e .env -- sh -c '… --account "${DEPLOYER_ACCOUNT:?…}"'` (Foundry keystore, expanded after `.env` loads). | `package.json:21-22` |

Astra's original answer to Q6 ("unclaimed allocations are never returned to treasury") was correct for plan v3.3 and **no longer applies**. Since v3.4, both unused budget (after commit) and unclaimed allocations (after 2027-03-31) can be swept.

---

## 3. Plan v3.4 conformance

### 3.1 Parameters (env.example vs plan)

| Plan item | Value in code / env | Match |
|---|---|---|
| Window opens 11-25 00:00 | `DEPOSIT_START=1795564800` = 2026-11-25 00:00:00 | ✅ |
| Window closes 12-25 23:59:59 | `DEPOSIT_DEADLINE=1798243199` | ✅ |
| Last rate correction 12-10 23:59:59 | `RATE_CORRECTION_CUTOFF` = 1796947199 | ✅ |
| 15 days to withdraw after final rates | `MIN_RATE_NOTICE=15d` | ✅ |
| Refund if not settled by 01-08 | `settlementDeadline()` = 2027-01-08 23:59:59 | ✅ |
| 24h after attestation | `RELEASE_DELAY=86400` | ✅ |
| Deposit cap 4.20B | `MAX_DEPOSIT_ALLOCATION=4.2e27` | ✅ |
| Budget 5B | `MAX_TOTAL_ALLOCATION=5e27` | ✅ |
| Claims open 12-31 | `claimStart=1798675200` (commit argument) | ✅ |
| Vesting 20% + 80% / 60d, same for long-locks | `INITIAL_UNLOCK_BPS=2000`, `VESTING_DURATION=60d`, one schedule per leaf | ✅ |
| Vesting ends 2027-03-01 | 1803859200 | ✅ |
| Claim deadline 2027-03-31 00:00 | 1806451200, inclusive | ✅ |
| Later claim open moves both dates | `postponeClaimStart` (≤ commit + 30d) | ✅ |
| Root locked once committed | `RootAlreadyCommitted` | ✅ |
| One combined claim per wallet | `computeClaims` merges by recipient, `readCsv` rejects duplicates | ✅ |
| Anyone can claim for any wallet | `claim(account, …)` pays `account` only | ✅ |
| No guardian (decision #10) | `GUARDIAN` unset by default | ✅ |

### 3.2 Where code and plan disagree

| Plan says | Code does | Ref |
|---|---|---|
| "Distributor funded with 5B before the window opens" (§2) | Before `commitRoot` the Safe can sweep 100% back. Funding early is a signal, not a lock. | N-05 |
| Refund if cancelled / not settled (§2) | Correct. But a refund *after* the root is committed lets depositors keep their tokens **and** their AGENTOS claim. The README lists this; the plan does not. | N-04 |

### 3.3 Not enforced by the contracts (unchanged, operational)

These are all runbook steps:
- the 7-day TWAP and the no-trading baseline (no TWAP script in the repo);
- calling `setRates` before `DEPOSIT_START`, and never calling `extendDeadline` (§0);
- the long-lock snapshot at the 11-25 block and the LP → DACKIE conversion;
- the two CAP airdrops calling `adminWithdraw`;
- the stCAP / sCAP / CAPU unwind;
- sale routing and minimum output;
- Across V5;
- Uni v4 range;
- publishing the 48h review package;
- the manual path for blocked wallets.

---

## 4. New findings

| ID | Severity | Title |
|---|---|---|
| N-01 | Low | Deposit cap can be held and released at the last inclusive second |
| N-02 | Low | Gaps in long-lock deduplication, and the draft CSV is not snapshot-grade |
| N-03 | Low | `deposit` silently overwrites a registered recipient |
| N-04 | Info / Low | Cancel or timeout after `commitRoot` = double benefit (not in the plan) |
| N-05 | Info | Distributor pre-funding gives no on-chain guarantee before commit |
| N-06 | Info | `build-claims.mjs --max-total` is optional |
| N-07 | Info | AGENTOS token behaviour on Robinhood is untested |

### N-01 — Low — Cap squatting

**Where:** `MigrationVault.sol:190-205`.

The cap is first come, first served and withdrawals are allowed up to and including the deadline second. A holder can fill the remaining room early, keep it full for the whole window, and withdraw at `depositDeadline`. Everyone else is refused until then and cannot deposit after it. With no deadline extension planned (§0), there is no way to give the others more time.

**Economics:** Under the current 5B budget, the old 50–75% participation scenarios are no longer valid as claim-capacity estimates. The 4.20B deposit cap is first come, first served, and approximately 0.80B remains for long-locks. A depositor can still fill the cap and withdraw late; monitor concentration and room through the window.

**Reproduced:** `test_N01_capSquatReleasedAtTheLastSecond`.

**Recommendation:**
- Publish `totalDepositAllocation()` live in the UI.
- If a squat appears, the Safe can `cancel` and redeploy; there is no gentler on-chain tool.
- Optionally, close withdrawals a few hours before deposits (two deadlines) so the last-second exit cannot be used to crowd others out.

### N-02 — Low — Long-lock deduplication gaps; draft CSV is not snapshot-grade

**Where:** `claims-lib.mjs:78-89`; `docs/data/dackie-longlock-close-2026-12-25.csv`.

1. With a `position_id` column, the duplicate key is `${source}:${positionId}`, where `source` is free text. The same position under two spellings (`DackieLPVault` / `Dackie_LPVault`) is accepted twice. **Reproduced:** `N-02a`, long-lock total doubled.
2. Without `position_id`, the key is `(address, lock_end_ts)`. DackiePool keeps **one position per address**, so two rows for one DackiePool address with different lock ends both pass, e.g. a re-export after the user extended the lock. **Reproduced:** `N-02b`.
3. The draft CSV has `dackie` rounded to 2 decimals, and no `dackie_wei` or `position_id`. That is fine for a draft, but the final list must be raw values read at the snapshot block. There is no tool in the repo that builds it (M-03 residual).

**Recommendation:**
- Allowlist `source ∈ {DackiePool, DackieLPVault}`.
- For DackiePool, enforce one row per address.
- For LPVault, require `position_id`.
- Add a `build-longlock.mjs` that reads `userInfo` / LP positions at the 11-25 snapshot block from an archive node and writes `dackie_wei`, `position_id` and `lock_end_ts`. Publish it with the 48h review package.

### N-03 — Low — `deposit` silently overwrites the registered recipient

**Where:** `MigrationVault.sol:179,475-484`.

Every `deposit` call requires a `recipient` and replaces the account's recipient. A contract wallet (or a long-locker) that called `registerRecipient(X)` and later deposits through a UI that fills `recipient = msg.sender` loses `X` with no warning. Its leaf then goes to its own address on Robinhood, which may not exist there for a contract wallet. `build-claims.mjs` warns only if the account is a contract on Base, not for EOAs that chose a different Robinhood address.

**Reproduced:** `test_N03_depositSilentlyOverwritesARegisteredRecipient` (also matches the existing `test_deposit_laterDepositReplacesRecipient`).

**Recommendation:** Either accept `recipient == address(0)` in `deposit` as "keep the current one" (with the current zero check moved to `registerRecipient` only), or make the frontend pre-fill the field from `recipientOf(msg.sender)` and show the `RecipientRegistered` history. Add a report column `recipientChangedAfterRegistration`.

### N-04 — Info / Low — Double benefit if the vault refunds after `commitRoot`

**Where:** `MigrationVault.sol:344-356,461-464`; README "Known limits"; plan §2 / §6 (not mentioned).

The order is: commit on Robinhood (immutable) → attest → 24h → release. If release never happens — Safe signers unavailable over the holidays, a CAP transfer revert, or an owner `cancel` — refunds open, but the committed tree stays claimable on 12-31. Depositors get CAP / DACKIE back **and** AGENTOS. The team loses up to the committed total (≤ 5B in total, with ≤ 4.20B from the deposit path) with no ETH buy wall in return.

**Reproduced:** `test_N04_cancelAfterAttestationRefundsDepositors` (the vault side; the distributor side cannot be undone by design).

**Recommendation:**
- Add this to the plan's §9 risk table.
- Operationally:
  - fork-simulate `release()` and both sale txs before `commitRoot`;
  - attest within minutes of committing;
  - have signers on call for `release` at exactly +24h;
  - remember the slack to the 01-08 timeout is ~10 days.

### N-05 — Info — Pre-funding is not a lock

`outstanding()` is 0 before `commitRoot`, so `sweepExcess` can take the whole 5B back (`test_sweep_beforeCommitTakesEverything`). The plan presents early funding as a trust step. Say plainly in Post #1 that the 5B becomes untouchable only at commit (12-28).

### N-06 — Info — `build-claims.mjs --max-total` is optional

If it is left out, no budget check runs before `tree.csv` is written. `build-tree.mjs` requires it and `commitRoot` enforces it, so this is defence in depth only. Make it mandatory (default `5e27`) and also print `total vs MAX_TOTAL_ALLOCATION − deposits` headroom.

### N-07 — Info — AGENTOS token on Robinhood is untested

There is a fork test for CAP / DACKIE on Base but none for AGENTOS on Robinhood. The distributor stays solvent whatever the token does (`safeTransfer`, balance checks). But a transfer tax, a pause / blocklist, or "pool" flagging on AGENTOS would make claimants receive less, or make claims revert. Run one fork test against `0x6eDA…bba3` on 4663: transfer from a contract to an EOA, and check owner / tax / pause functions, before funding.

*Cross-reference:* the Gemini-Carbon review's read-only inspection of this token on Robinhood found a standard Clanker `ERC20Votes` implementation with 18 decimals, no transfer tax and no pause function. A transfer test on a fork was not run.

---

## 5. Revert analysis (current code)

### MigrationVault

| Function | Reverts when |
|---|---|
| constructor | zero / equal / no-code tokens; notice ∉ [7d, 30d]; delay ∉ [12h, 7d]; grace < delay + 2d or > 60d; window < 14d or < notice; max deadline < deadline or > opening + 180d; guardian == owner; cap == 0 |
| `deposit` | unsupported token; before start / after deadline / cancelled (`DepositsNotOpen`); paused; amount 0; recipient 0; sender or recipient blocked; transfer fails; 0 received; **`DepositCapExceeded`** (once rates are set, including after a rate correction raised the ledger above the cap) |
| `withdraw` | unsupported token; `WithdrawalsClosed` (between deadline and settlement deadline, or after release); amount 0 or > own deposit; transfer fails |
| `refund` | not cancelled and not timed out; released; account has nothing; **either** token transfer fails (atomic; use per-token `withdraw` instead) |
| `registerRecipient` | cancelled; after deadline; zero / blocked |
| `setRates` | non-owner; cancelled; rate ∉ [1e15, 1e24]; **`RatesFinal`** (already set and past 12-10 23:59:59); `RateNoticeTooShort` (now + 15d > deadline) |
| `extendDeadline` | non-owner; cancelled; window closed; not later; > `MAX_DEPOSIT_DEADLINE` (not planned to be used) |
| `attestClaimRoot` | non-owner; cancelled / released; window open; after settlement deadline; rates not set; root / total / distributor zero; now + 24h > settlement deadline |
| `release` | non-owner; cancelled / released; window open; after settlement deadline; not attested; 24h not elapsed; token transfer fails |
| `cancel` | not owner / guardian; guardian outside the attested-and-not-released phase; released; already cancelled |
| `rescue` | non-owner; zero to / amount; amount > `excessOf` |
| `renounceOwnership` | always |

### MerkleVestingDistributor

| Function | Reverts when |
|---|---|
| constructor | zero / no-code token; budget 0 |
| `claim` | no root; before `claimStart`; **`ClaimsExpired`** (after 2027-03-31 00:00:00); bad proof (wrong chain, contract, account or amount); nothing newly vested; `AllocationExceeded` (understated total, H-01); transfer fails |
| `commitRoot` | non-owner; already committed; root 0; total 0 or > 5B; claimStart ≤ now or > now + 30d; balance < total; bad sample leaf |
| `postponeClaimStart` | non-owner; no root; claims already open; not later or > `latestClaimStart` |
| `sweepExcess` | non-owner; to = 0; nothing above `outstanding()` |
| `rescue` | non-owner; AGENTOS; zero to / amount |

### Off-chain (abort before anything is written)

- **build-claims:** cancelled vault; window still open; rates not set; claimStart ≤ deadline; the freeze block is not the first block after the deadline; ledger does not match `totalDeposited` (a missed event); an allocation differs from `allocationOf`; long-lock duplicate / bad row / lock end ≤ deadline; over `--max-total` (exit 2, nothing written).
- **build-tree:** old 3-column format; duplicate account; zero allocation; implausible claimStart; over `--max-total`.
- **verify-tree:** domain, root, total, count or any proof mismatch with the values read from the chain.

### External settlement (outside these contracts)

- CAP tax or flag changes;
- router path / slippage / minimum output;
- WETH unwrap;
- Across limits or fees;
- Uni v4 pool id / ticks / hook;
- Safe nonce or gas;
- AGENTOS token behaviour (N-07).

---

## 6. Loss / hack scenarios

| Scenario | Who loses | Possible? | Control |
|---|---|---|---|
| Outside attacker drains vault or distributor | — | **No path found** | Access control, reentrancy guard, balance-delta, domain-bound double-hashed leaves |
| Safe compromised: false attestation, then release | Depositors | Yes (accepted, decision #10) | Public 24h delay; optional guardian not used |
| Understated `totalAllocation` | Last claimants | Yes, permanent | `verify-tree.mjs --total` from chain, 48h review |
| Overstated `totalAllocation` | Treasury (temporary) | Yes, recovered after 2027-03-31 | Same |
| Refund after commit (N-04) | Team / treasury | Yes | Run `release` on schedule |
| Long-lock double count (N-02) | Treasury | Yes | Snapshot tool, strict dedup |
| Claimant misses 2027-03-31 | Claimant | Yes, by design | Comms: Post #1, 03-01, 03-24 |
| Wrong recipient (L-01, N-03) | Claimant | Yes | Warnings, UI pre-fill |
| CAP tax enabled on the vault | Depositors / Safe (~1%) | Yes, third party | Fork test, check before release |
| Leaked key moves funds to a clean wallet first | Original owner | Yes | Blocklist is advisory (documented) |

---

## 7. Verification performed

Run on the working tree on 2026-11-17:

| Command | Result |
|---|---|
| `forge test` | **133 passed, 0 failed, 1 skipped** (fork suite without RPC) |
| `FOUNDRY_PROFILE=ci forge test` (10k fuzz, 1k×100 invariants) | **133 passed, 0 failed, 1 skipped** |
| `BASE_RPC_URL=https://mainnet.base.org forge test --match-path 'test/fork/*'` | **4 passed** (real CAP / DACKIE, unpinned block) |
| `node --test offchain/test/*.test.mjs` | **30 passed** |
| Opus repro, on-chain (`OpusAuditRepro.t.sol`, run from `test/` then removed) | **3 passed**: N-01, N-03, N-04 |
| Opus repro, off-chain (`offchain-repro.test.mjs`) | **2 passed**: N-02a, N-02b |

The repro tests check that the risky behaviour happens: a pass confirms the finding, not a fix. They are kept outside the repo, as in the earlier reviews. Nothing in the repo was changed apart from adding this report.

**Not covered:**
- Slither, Mythril or formal verification;
- deployed bytecode;
- the Robinhood AGENTOS token;
- the real snapshot;
- sale, bridge and liquidity transactions.

SHA-256 of the reviewed files:

```text
9f7a80f59334c0381c987f3e5b5060422f4a8c56536e9b23a34690c2789c072d  src/MigrationVault.sol
0ad920889a816f01917c3009db5aafe6e37dd2769e0ec73d74923e070fbd57a9  src/MerkleVestingDistributor.sol
907178928e812e6175c1d5b5cf859ff3d2349242713cffa19c2975d5e8a22b8f  offchain/build-claims.mjs
ce4580dba4115ed80910dba81979267771547b6299635452dd7ab28338613c1f  offchain/claims-lib.mjs
ccb929dc7fbccf56a66f0bfa4bd3d021e4a00dcde6f9f014efe28aa686a2e514  offchain/tree-lib.mjs
90aefe445681773de84a8a07959ab852f4e57dff8b0f6cf21becf1c7c20aa9dc  offchain/build-tree.mjs
7c9dc04164a1301873f9cbd7bd5f7fd5adf9a41090bc8cb6497b11372b9650fe  offchain/verify-tree.mjs
```

The working tree is uncommitted on top of `1be2046`. Commit it and record the commit hash before any external audit or deploy, so the bytecode can be rebuilt.

---

## 8. Final assessment

The code is a clean, non-upgradeable escrow plus a Merkle-vesting design, and it is well tested. It enforces every rule of plan v3.4 that a contract can enforce: fixed dates, the cutoff, the cap, vesting, and the claim deadline with treasury return. No vulnerability was found that an outside party could use to take funds. The prior Medium findings M-01 and M-02 and the Low findings L-03 and L-04 are properly fixed.

What is left is about **process and edge cases**, not code safety:
- the long-lock snapshot and its deduplication (N-02);
- the double benefit if settlement fails after commit (N-04);
- the long-standing trusted-input points: tree total, recipients, and the trusted Safe.

With rates set before the window opens, no deadline extension, and the published freeze → 48h review → commit → attest → 24h → release process followed, the migration is fit for a controlled launch under the 404AI Labs trusted-Safe model.
