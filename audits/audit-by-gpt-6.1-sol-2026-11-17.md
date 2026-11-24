# Audit by GPT-Sol — CAP + DACKIE → AGENTOS Migration

**Date:** 2026-11-17  

**Release revision:** `projects/migration` at `a4a765e7ab278ae30e5912f9f56584a336205ff2` (2026-11-24).

**Original review target:** `projects/migration` at `bb7af4634de688ff6c8e03b66691fe189e2c6be6` (2026-11-17).

**Specification:** `docs/migration_plan.md` — v1.0 release budget; Draft v3.4 for the original review.

**Scope:** `MigrationVault.sol`, `MerkleVestingDistributor.sol`, interfaces, deployment scripts, claim-tree tooling, tests, and the repository README.

> **Important disclaimer:** This is a code review by GPT-Sol, not a formal third-party security audit, guarantee, or certification. It does not verify the actual deployed bytecode, final claim CSV, long-lock snapshot, sale transactions, bridge route, or liquidity transactions.

> **Budget restatement:** This report was originally written against the 10B AGENTOS / 8.5B deposit-cap configuration. Budget figures below reflect the 5B AGENTOS / 4.20B deposit-cap release. The test results, file hashes, and audit conclusions refer to the original review, not to a new audit of the release revision.

### Assumed operating model

This report evaluates the migration under the operating assumptions supplied by the project team, now written into the plan as **decision #10**:

- 404AI Labs's Safe Wallet is owned and operated by **404AI Labs** and is the owner of this migration solution.
- 404AI Labs's Safe Wallet and project team are trusted to follow the published migration plan and execute the migration honestly.
- No on-chain cross-chain verification is required for this migration. The operational control is the published schedule: freeze the ledger, publish the claim proof, allow **48 hours of public review**, commit the root, attest it on Base, wait 24 hours, then release.
- The project team is assumed to execute the freeze, proof review, sale, bridge, liquidity, release, and claim-opening steps as announced.

Accordingly, this report does not require a Guardian and does not treat the absence of cross-chain verification as a finding. The code keeps an optional `GUARDIAN`, set to none by default.

## 1. Executive verdict

### Overall conclusion

The contracts implement a substantial and careful escrow/distribution system. Under the trusted 404AI Labs operating model and the published freeze plus 48-hour public-review schedule, the design is consistent with migration plan v3.4. The code includes an on-chain deposit cap, a fixed rate-correction cutoff and a claim deadline with treasury return. The remaining controls—claim-tree correctness, long-lock input correctness, recipient routing, and settlement timing—depend on the documented operational process.

The strongest contract-level protections are present:

- no upgradeability or delegatecall;
- two-step ownership with renouncement disabled;
- reentrancy protection around token-moving functions;
- user withdrawals during the window and permissionless refunds after cancellation/timeout;
- balance-delta accounting for deposits;
- an immutable deposit cap (`MAX_DEPOSIT_ALLOCATION` = 4.20B AGENTOS), checked on every deposit once rates are set;
- an immutable rate-correction cutoff (`RATE_CORRECTION_CUTOFF` = 2026-12-10 23:59:59 UTC) that a deadline extension cannot move;
- Merkle leaves bound to chain ID and distributor address;
- immutable root after commitment;
- a 5B ceiling at the distributor;
- a fixed claim deadline (`claimDeadline()` = 2027-03-31 00:00:00 UTC), after which unclaimed AGENTOS can be returned to treasury;
- extensive unit, fuzz, invariant, end-to-end, off-chain, and Base-fork tests.

The contracts intentionally use 404AI Labs's Safe Wallet and the published settlement schedule as the operational trust boundary. They do not execute the sale, bridge, liquidity, or claim-tree publication workflow; those steps are operational requirements, not missing trustless automation.

### Answers to the requested questions

| Question | Assessment |
|---|---|
| 1. Does it satisfy the plan? | **Yes, for every rule the contracts can enforce.** Dates, rate cutoff, deposit cap, 5B budget, vesting (20% + 80% over 60 days, same for long-locks), claim deadline and treasury return match plan v3.4. TWAP calculation, snapshot production, position extraction, sale and liquidity remain operational steps. |
| 2. Is security ensured? | **Yes for the assumed threat model.** The code has strong access-control, accounting, reentrancy, Merkle-proof, and vesting protections. Residual risks are input correctness, recipient handling, token behavior, and transaction timing. |
| 3. Can funds be lost or hacked? | **No unprivileged drain was identified.** Funds can still be affected by incorrect claim inputs, unusable recipient mappings, token tax behavior, or failed external settlement transactions. These are addressed through the freeze/review controls. |
| 4. Can transactions revert? | **Yes, intentionally and operationally.** §6 lists the main revert paths, including the v3.4 additions `DepositCapExceeded`, `RatesFinal` and `ClaimsExpired`. |

### Release assessment

Under the 404AI Labs trusted-Safe model, the code is suitable for a controlled launch, provided the freeze, the 48-hour public review of the exact claim package, and the announced settlement sequence are carried out as published. No Guardian or on-chain cross-chain verification is required under this model.

## 2. Files and components reviewed

### On-chain contracts

- `src/MigrationVault.sol`
- `src/MerkleVestingDistributor.sol`
- `src/interfaces/IMigrationVault.sol`
- `src/interfaces/IMerkleVestingDistributor.sol`

### Off-chain and deployment code

- `offchain/build-claims.mjs`
- `offchain/claims-lib.mjs`
- `offchain/build-tree.mjs`
- `offchain/tree-lib.mjs`
- `offchain/verify-tree.mjs`
- `scripts/DeployBase.s.sol`
- `scripts/DeployVault.s.sol`
- `scripts/DeployDistributor.s.sol`
- `scripts/BlocklistBatches.s.sol`

### Documentation and tests

- `projects/migration/README.md`
- `docs/migration_plan.md` (Draft v3.4)
- unit tests, fuzz tests, invariant tests, end-to-end migration tests, off-chain tests, and `test/fork/BaseFork.t.sol`.

Draft v3.4 is the single canonical plan. It settles the decisions that were open in earlier drafts: pure TWAP, claim-open vesting for long lockers, no LP-vault WETH compensation, ineligibility of the two CAP airdrops, Across V5, the claim deadline (decision #8), the deposit cap (decision #9) and the trust model (decision #10).

## 3. Severity summary

| ID | Original severity | Status at v3.4 | Finding |
|---|---|---|---|
| H-01 | High | **Partly fixed — now Medium (process control)** | The contract cannot sum all leaves on-chain. An overstated total is no longer locked forever; an understated total still makes the last claims revert. |
| M-01 | Medium | **Fixed** | Immutable 4.20B deposit cap enforced in `deposit` once rates are set. |
| M-02 | Medium | **Fixed** | Immutable rate-correction cutoff; `extendDeadline` cannot reopen rate changes. |
| M-03 | Medium | **Partly fixed** | Long-lock rows are deduplicated by `(address, lock_end_ts)` whatever the source label; the snapshot itself is still an operational input. |
| M-04 | Medium | **Partly fixed** | Bypass flags revert on Base and Robinhood; owner must be a Safe with threshold ≥ 2. Parameters still come from the environment; the blocklist is a separate Safe batch. |
| M-05 | Medium | **Partly fixed — now Low** | Blocked depositors and blocked long-lock rows are both reported with the exact amount owed; there is still no on-chain reserve. |
| L-01 | Low | **Partly fixed** | Warnings for contract wallets that receive at their own address. Robinhood usability is still not proven. |
| L-02 | Low | **Unchanged (inherent)** | CAP transfer-tax behavior is outside the vault's control; the vault stays solvent. |
| L-03 | Low | **Fixed** | Fixed claim deadline; unclaimed AGENTOS returns to treasury after it. |
| L-04 | Low | **Fixed** | Deploy commands use a Foundry keystore, expanded after `.env` loads. |

No confirmed permissionless critical vulnerability or unprivileged drain was found in the reviewed Solidity paths.

## 4. Detailed findings

### H-01 — Incorrect `totalAllocation` or tree sum can underpay claimants

**Status:** Partly fixed — now Medium (process control).  
**Location:** `src/MerkleVestingDistributor.sol` (`commitRoot`, `claim`, `outstanding`, `claimDeadline`); `offchain/build-claims.mjs`; `offchain/verify-tree.mjs`.

**Description:**

The distributor stores the owner-supplied `totalAllocation_`. During claims, it rejects any payment that would make `totalClaimed > totalAllocation`. It does not calculate the sum of all Merkle leaves, which is infeasible on-chain. The sample proof checked by `commitRoot` proves inclusion of one leaf, not the total.

**Cases at v3.4:**

- If the stated total is **less** than the sum of leaves, earlier claimants are paid and later claimants revert with `AllocationExceeded`. A top-up cannot fix this, because the check uses the committed total.
- If the stated total is **greater** than the sum of leaves, the difference is no longer locked forever: after `claimDeadline()` the contract treats nothing as outstanding and `sweepExcess` returns it to treasury.
- If the root is valid but the tree uses a wrong account or amount, the contract cannot distinguish operator error from an intended allocation.

**What changed:** `build-claims.mjs` rebuilds the ledger from deposit events, checks it against `vault.totalDeposited`, and checks every allocation against `vault.allocationOf`. `verify-tree.mjs` reads the root and total from the chain. Tests `test_claim_cannotExceedCommittedTotal` and `test_commit_overstatedTotalIsReservedUntilTheDeadline` cover both cases.

**Recommendation:** Treat the exact tree build and verification as a release-critical artifact, verified independently and published for the 48-hour review before `commitRoot`.

### M-01 — On-chain budget check at deposit time

**Status:** Fixed.  
**Location:** `src/MigrationVault.sol` (`deposit`, `MAX_DEPOSIT_ALLOCATION`).

`MAX_DEPOSIT_ALLOCATION` (4.20B AGENTOS, immutable) is checked in `deposit` once rates are set; withdrawals are never capped. The invariant `invariant_depositsRespectTheCap` covers it. The cap applies from the first deposit when rates are set before `DEPOSIT_START` (team-confirmed operating assumption). A rate correction before the cutoff can still push existing deposits over the cap; new deposits then stop. This is documented.

### M-02 — Deadline extension and the rate-correction date

**Status:** Fixed.  
**Location:** `src/MigrationVault.sol` (`setRates`, `RATE_CORRECTION_CUTOFF`).

`RATE_CORRECTION_CUTOFF = initial deadline − MIN_RATE_NOTICE` is immutable (= 2026-12-10 23:59:59 UTC, the same as the plan). `setRates` reverts with `RatesFinal` after it, and `extendDeadline` does not move it. The team has also confirmed that `extendDeadline` will not be used. The invariant `invariant_ratesAreFinalAfterTheCutoff` covers it.

### M-03 — Long-lock snapshot input requires public-review validation

**Status:** Partly fixed.  
**Location:** `offchain/claims-lib.mjs` (`parseLongLockCsv`), `offchain/build-claims.mjs`.

**What changed:** Without a `position_id` column, duplicates are keyed on `(address, lock_end_ts)` whatever the source label, so the same position listed under two labels is refused. With `position_id`, ids must be unique. `misses_window` must be `yes`.

**Residual:** The CSV is still an operational input to the freeze and 48-hour review. No tool in the repository reads the positions from DackiePool / DackieLPVault at the snapshot block, and in `position_id` mode the source label is free text, so one position under two spellings could still pass. An incorrect CSV could overpay a long locker or omit a valid one, and the root cannot be corrected after commitment.

**Recommendation:** Build the snapshot from archive-node reads of the source contracts at the snapshot block, include position IDs and raw values in the public review package, and restrict `source` to the two known contracts.

### M-04 — Deployment and blocklist safeguards

**Status:** Partly fixed.  
**Location:** `scripts/DeployBase.s.sol`, `scripts/DeployVault.s.sol`, `scripts/DeployDistributor.s.sol`, `scripts/BlocklistBatches.s.sol`.

**What changed:** `ALLOW_EOA_OWNER` and `ALLOW_ANY_CHAIN` now revert on Base (8453) and Robinhood (4663). The owner must be a Safe with threshold ≥ 2. `MAX_DEPOSIT_ALLOCATION` has rough unit-bound checks.

**Residual:** Deployment parameters still come from environment variables and are not checked against a signed manifest. The blocklist is executed as a separate Safe batch after deployment, and it cannot stop a leaked holder who already moved funds to a clean address (documented).

### M-05 — Manual-path liabilities have no dedicated claim reserve

**Status:** Partly fixed — now Low.  
**Location:** `offchain/claims-lib.mjs`; `offchain/build-claims.mjs`; `src/MerkleVestingDistributor.sol` (`sweepExcess`).

Blocked accounts and blocked recipients receive no leaf. The pipeline now warns for both blocked depositors and blocked long-lock rows and prints the exact amount owed. There is still no on-chain reserve: after commitment, `sweepExcess` returns that budget to treasury, and the treasury pays verified manual claims. This is an accounting/runbook matter, not a permissionless drain.

### L-01 — Recipient is not validated on Robinhood

**Status:** Partly fixed.  
**Location:** `src/MigrationVault.sol` (`registerRecipient`, `deposit`); `offchain/build-claims.mjs`.

The Base vault accepts any nonzero, non-blocked `recipient`, and the distributor transfers AGENTOS to that address on Robinhood. The tooling now warns when a Base contract wallet (EIP-7702 delegations excluded) receives at its own address. It cannot prove that a recipient exists, is controlled by the user, or can use AGENTOS on chain 4663. A wrong recipient can make the allocation practically unrecoverable; this is user/operator error, not an unauthorized drain.

### L-02 — Token taxes can reduce economic proceeds

**Status:** Unchanged (inherent).  
**Location:** `src/MigrationVault.sol` (`deposit`, `withdraw`, `release`); `test/fork/BaseFork.t.sol`.

The vault credits the balance delta received on deposit. If CAP's owner flags the vault as a taxed pool, deposits and outgoing transfers can be taxed. The fork test shows the ledger stays solvent in that case, but users receive less on withdrawal/refund and the Safe may receive less at release. Balance-delta deposits do not protect existing liabilities against a negative rebase or a token administrator freezing transfers.

### L-03 — Expiry and recovery for unclaimed AGENTOS

**Status:** Fixed (plan decision #8).  
**Location:** `src/MerkleVestingDistributor.sol` (`claimDeadline`, `outstanding`, `sweepExcess`).

`claimDeadline() = claimStart + 60 days + 30 days` = 2027-03-31 00:00:00 UTC (inclusive), derived from constants and moved only by `postponeClaimStart`. After it, `claim` reverts with `ClaimsExpired`, `outstanding()` is 0 and `sweepExcess` returns everything to treasury.

### L-04 — Deployment key handling

**Status:** Fixed.  
**Location:** `package.json`.

The deploy commands now run `dotenv -e .env -- sh -c '… --account "${DEPLOYER_ACCOUNT:?…}"'`, using a Foundry encrypted keystore expanded after `.env` loads. No raw private key appears on the command line.

## 5. Does the implementation satisfy the migration plan?

### Implemented or substantially represented

- CAP/DACKIE deposit ledger on Base.
- Deposit window 2026-11-25 00:00:00 → 2026-12-25 23:59:59 UTC, inclusive deadline.
- User withdrawals through the deadline.
- Recipient registration for contract wallets and long lockers.
- Owner blocklist mechanism.
- On-chain rates with a 15-day notice period and a fixed correction cutoff (2026-12-10 23:59:59 UTC).
- 4.20B AGENTOS deposit cap, first come first served.
- Root attestation and 24-hour delay before vault release.
- Cancellation and timeout refund paths (refund if not settled by 2027-01-08 23:59:59 UTC).
- Fixed 20% + 80%/60-day vesting curve, the same for long-locks; one combined leaf per wallet.
- One-time Merkle root commitment.
- 5B distributor ceiling.
- Claim deadline 2027-03-31 00:00:00 UTC with treasury return of unused and unclaimed AGENTOS.
- No minting performed by these contracts.
- Safe ownership checks in the deployment scripts.

### Not enforced by the contracts

The following plan requirements are operational responsibilities, not protocol guarantees:

1. The 7-day TWAP calculation and no-team-trading baseline.
2. Correct CAP/VIRTUAL, DACKIE/WETH, and AGENTOS/WETH price sources.
3. Setting rates before `DEPOSIT_START`, and not using `extendDeadline` (team-confirmed).
4. The exact first-block snapshot at 2026-11-25 00:00 UTC.
5. Correct extraction of DackiePool and DackieLPVault long-lock positions and conversion of LP locked liquidity to DACKIE.
6. Exclusion of the two CAP Merkle airdrops.
7. Sale routing, fee/tax handling, and minimum-output guards.
8. Across V5 bridge correctness and destination-chain receipt.
9. AGENTOS/WETH Uni v4 liquidity placement and "buy wall" range.
10. Publication and independent review of the claim tree.
11. The manual path for blocked wallets.

`MAX_TOTAL_ALLOCATION` is a constructor parameter; the deployment configuration sets it to 5B (`5e27`), matching the plan.

## 6. Revert and failure analysis (v3.4 code)

### `MigrationVault` reverts

| Function | Revert condition |
|---|---|
| Constructor | Zero owner; zero/equal/non-contract token addresses; invalid notice, delay, grace, window, or deadline bounds; guardian equal to owner; zero deposit cap. Deployment scripts additionally revert for non-18-decimal tokens. |
| `deposit` | Unsupported token; before `DEPOSIT_START`, after `depositDeadline` or cancelled; paused; zero amount/recipient; blocked depositor or recipient; token transfer failure; zero received amount; **`DepositCapExceeded`** once rates are set. |
| `withdraw` | Unsupported token; outside the open/refund windows or after release; zero amount; amount larger than the caller's own deposit; token transfer failure. |
| `refund` | Before cancellation or timeout; after release; zero account balance; transfer failure. Anyone may call it, but tokens go only to the recorded account. |
| `registerRecipient` | Cancelled; after deadline; zero or blocked recipient/account. |
| `setBlocked` | Non-owner; possible out-of-gas if an impractically large batch is passed. |
| `setRates` | Non-owner; cancelled; rate outside `[1e15, 1_000_000e18]`; **`RatesFinal`** (already set and past 2026-12-10 23:59:59 UTC); `RateNoticeTooShort`. |
| `extendDeadline` | Cancelled; current window already closed; new deadline not later; above immutable maximum; non-owner. (Not planned to be used.) |
| `attestClaimRoot` | Cancelled/already released; window still open; after settlement deadline; rates not set; zero root/total/distributor; too late to leave the delay before the settlement deadline; non-owner. |
| `release` | Cancelled/already released; window open; settlement deadline passed; no attestation; delay not elapsed; token transfer failure. |
| `cancel` | Unauthorized caller; already released/cancelled; an optional guardian calling outside its permitted veto window. |
| `rescue` | Non-owner; zero recipient/amount; amount exceeds calculated excess for a migration token. |
| `renounceOwnership` | Always. |

### `MerkleVestingDistributor` reverts

| Function | Revert condition |
|---|---|
| Constructor | Zero owner; zero/non-contract token; zero budget. Deployment script also rejects a budget above token total supply and non-18-decimal AGENTOS. |
| `commitRoot` | Root already committed; zero root; zero/over-budget total; claim start not strictly in the future or more than 30 days after commit; balance below stated total; invalid sample leaf/proof; non-owner. |
| `claim` | Root not committed; claims not open; **`ClaimsExpired`** after 2027-03-31 00:00:00 UTC; invalid proof (wrong chain, contract, account or amount); nothing newly vested; cumulative claimed amount exceeds committed total; AGENTOS transfer failure. |
| `postponeClaimStart` | No root; claims already open; new start not later or above the latest allowed start; non-owner. |
| `sweepExcess` | Zero recipient; nothing above `outstanding()`; non-owner. |
| `rescue` | Distributed token passed as the rescue token; zero recipient/amount; non-owner. |

### Off-chain tooling can abort before any transaction

`build-claims.mjs` and `build-tree.mjs` fail on malformed addresses, empty/invalid CSVs, duplicate accounts or long-lock positions, implausible claim start, missing rates, claim start before the deadline, an open deposit window, a freeze block that is not the first block after the deadline, missed deposit events/ledger mismatch, an allocation that differs from `vault.allocationOf`, invalid long-lock rows, or a total over `--max-total`. In v3.4, an over-budget run exits **before** any file is written. Blocked recipients are excluded, not a hard stop (see M-05).

Additional edge cases:

- If the deposit deadline were extended past a long lock's end, `computeClaims()` would reject that row. The team has confirmed `extendDeadline` will not be used.
- `refund(account)` transfers both deposited tokens atomically. If either transfer reverts, neither refund completes; the account can still call per-token `withdraw` for an unaffected token.
- `claimableAmount()` does not verify a proof or aggregate capacity; a positive preview is not a guarantee that `claim()` succeeds.

### External settlement reverts not covered by these contracts

- CAP transfer tax or pool flag changes;
- router path/token ordering/fee-tier mistakes;
- slippage/min-output failure;
- insufficient pool liquidity or price movement;
- WETH unwrap/ETH transfer failure;
- Across V5 route limits, fee changes, or destination finality issues;
- Uni v4 pool ID, hook, tick range, or liquidity parameter errors;
- gas/nonce/Safe execution failures.

## 7. Verification evidence

Recorded repository test results for the reviewed v3.4 snapshot:

| Verification | Recorded result |
|---|---|
| `forge test` | 133 passed, 0 failed, 1 skipped (fork suite without RPC) |
| `FOUNDRY_PROFILE=ci forge test` | 133 passed, 0 failed, 1 skipped; 10,000-run fuzz and 1,000-run invariants |
| Base fork suite | 4 passed against real CAP/DACKIE token addresses |
| Off-chain tests | 30 passed, 0 failed |

Relevant guard behaviors in this snapshot:

1. An understated total makes later claims revert with `AllocationExceeded` (H-01).
2. An overstated total is reserved until `claimDeadline()`, then recoverable through `sweepExcess`.
3. A deadline extension cannot reopen rate changes; `RatesFinal` applies after the fixed cutoff.
4. Without `position_id`, one long-lock position under two source labels is rejected; see M-03 for the residual `position_id` case.

These results show that the intended guards and documented trust-boundary behaviors are reproducible. They do **not** prove correctness of production deployment parameters, Safe configuration, the final CSV, or external settlement transactions. Invariant handlers use mock tokens and tolerate expected reverts; solvency assertions do not prove snapshot-input correctness or settlement liveness. Slither, Semgrep and Mythril were not run; no formal verification or audit-firm sign-off was performed.

SHA-256 of the reviewed snapshot files:

```text
9f7a80f59334c0381c987f3e5b5060422f4a8c56536e9b23a34690c2789c072d  src/MigrationVault.sol
0ad920889a816f01917c3009db5aafe6e37dd2769e0ec73d74923e070fbd57a9  src/MerkleVestingDistributor.sol
907178928e812e6175c1d5b5cf859ff3d2349242713cffa19c2975d5e8a22b8f  offchain/build-claims.mjs
ce4580dba4115ed80910dba81979267771547b6299635452dd7ab28338613c1f  offchain/claims-lib.mjs
ccb929dc7fbccf56a66f0bfa4bd3d021e4a00dcde6f9f014efe28aa686a2e514  offchain/tree-lib.mjs
90aefe445681773de84a8a07959ab852f4e57dff8b0f6cf21becf1c7c20aa9dc  offchain/build-tree.mjs
7c9dc04164a1301873f9cbd7bd5f7fd5adf9a41090bc8cb6497b11372b9650fe  offchain/verify-tree.mjs
```

## 8. Final assessment

The implementation is a well-tested, non-upgradeable escrow and Merkle vesting framework with good local defensive engineering. Of the ten findings in the first GPT-Sol review, four are fixed in code (M-01, M-02, L-03, L-04), five are partly fixed with the remainder handled by the published review process (H-01, M-03, M-04, M-05, L-01), and one is an inherent external token risk (L-02).

Under the 404AI Labs trusted-Safe model and the published freeze → 48-hour public review → commit → attest → 24h → release schedule, the code is consistent with migration plan v3.4 and suitable for a controlled launch. The principal residual risks are incorrect claim inputs, manual-path accounting, recipient mapping, token behavior, deployment configuration, and ordinary transaction reverts.
