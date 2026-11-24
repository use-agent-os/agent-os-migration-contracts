# Audit by GPT-Astra — CAP + DACKIE → AGENTOS Migration

**Date:** 2026-11-17  

**Release revision:** `projects/migration` at `a4a765e7ab278ae30e5912f9f56584a336205ff2` (2026-11-24).

**Original review target:** `projects/migration` at `bb7af4634de688ff6c8e03b66691fe189e2c6be6` (2026-11-17).

**Specification:** `docs/migration_plan.md` — v1.0 release budget; Draft v3.4 for the original review.

**Previous review:** `audit/audit-by-gpt-sol-2026-11-17.md`  
**Review type:** Source-code and repository audit; not a formal third-party audit or deployment certification

> **Budget restatement:** This report was originally written against the 10B AGENTOS / 8.5B deposit-cap configuration. Budget figures below reflect the 5B AGENTOS / 4.20B deposit-cap release. The test results, file hashes, and audit conclusions refer to the original review, not to a new audit of the release revision.

## Executive summary

The current implementation is a well-defended escrow and Merkle-vesting framework. The Solidity tests and off-chain tests pass, and no permissionless token-drain exploit was identified in the reviewed code. The implementation represents migration plan v3.4 for every rule a contract can enforce. Several economically critical properties remain off-chain and depend on 404AI Labs's Safe Wallet executing the published process correctly.

The most important conclusion is:

> **The contracts are suitable for a controlled launch once the claim inputs, Safe configuration, final root, budget and recipient mappings have been checked in the published 48-hour review. They do not provide trustless cross-chain enforcement.**

Under the operating assumption—that 404AI Labs's Safe Wallet is trusted and follows the published freeze and 48-hour review process (plan decision #10)—the implementation is acceptable. Under a hostile or compromised Safe threat model, users can lose deposited CAP/DACKIE after the release conditions are met, because Base cannot verify that the attested root exists or is correct on Robinhood.

## Direct answers

| Question | Assessment |
|---|---|
| 1. Does it satisfy the migration plan? | **Yes, for every rule the contracts can enforce.** The vault lifecycle, fixed rates with a fixed correction cutoff, the 4.20B deposit cap, withdrawals, root attestation delay, release/refund paths, Merkle claims, 20% + 80%/60-day vesting, the 5B distributor ceiling and the 2027-03-31 claim deadline are all implemented. TWAP computation, long-lock snapshot correctness, sale, bridge, liquidity, and public review remain operational responsibilities. |
| 2. Is security ensured? | **Strong against unprivileged attackers; not trustless against a compromised Safe or incorrect inputs.** Access control, reentrancy protection, accounting, Merkle-domain binding, immutable roots, and refund paths are strong. |
| 3. Could money be lost or funds be hacked? | **No unprivileged drain was found.** Funds can nevertheless be lost or become inaccessible through a malicious/compromised Safe, incorrect immutable claim data, incorrect recipient mappings, token tax or transfer behavior, or failed external settlement. |
| 4. Can transactions revert? | **Yes.** Reverts are intentionally used for invalid state, timing, proofs, underfunding, the deposit cap, the rate cutoff, the claim deadline and token-transfer failures. The detailed matrix appears below. |
| 5. Do the findings of the previous report remain? | **Mostly resolved.** M-01, M-02, L-03 and L-04 are fixed. H-01, M-03, M-04, M-05 and L-01 are partly fixed, with the remainder handled by the published review. L-02 is an inherent token risk. H-02 is accepted by plan decision #10. |
| 6. How does unused AGENTOS return to treasury? | **In two steps, both through `sweepExcess(treasury)`:** the budget never allocated in the tree can be returned right after `commitRoot`; allocations nobody claimed can be returned after `claimDeadline()` (2027-03-31 00:00:00 UTC). See L-03. |

## Scope and assumptions

### Reviewed

- `src/MigrationVault.sol`
- `src/MerkleVestingDistributor.sol`
- interfaces under `src/interfaces/`
- `offchain/build-claims.mjs`
- `offchain/claims-lib.mjs`
- `offchain/build-tree.mjs`
- `offchain/verify-tree.mjs`
- deployment and blocklist scripts
- migration README and tests
- the v3.4 migration plan
- the previous GPT-Sol report

### Operating assumptions

This report assumes:

1. 404AI Labs's Safe Wallet is owned and operated by 404AI Labs.
2. The Safe and team are trusted to follow the published schedule honestly.
3. The 48-hour claim-tree review is performed before irreversible settlement.
4. Cross-chain verification is operational rather than enforced by a bridge or guardian (plan decision #10).
5. `setRates` is called before `DEPOSIT_START`, and `extendDeadline` is not used (team-confirmed).

If these assumptions are not accepted, the cross-chain trust issue must be treated as a high-severity design risk rather than an operational limitation.

## Severity summary

| ID | Original severity | Status at v3.4 |
|---|---|---|
| H-01 | **High** | **Partly fixed — now Medium (process control).** An overstated total is recoverable after the claim deadline; an understated total still makes the last claims revert. |
| H-02 | **High under hostile-admin model** | **Accepted** (plan decision #10). An optional `GUARDIAN` exists in code, set to none by default. |
| M-01 | **Medium** | **Fixed.** Immutable 4.20B deposit cap enforced on deposit. |
| M-02 | **Medium** | **Fixed.** Immutable rate-correction cutoff (2026-12-10 23:59:59 UTC). |
| M-03 | **Medium** | **Partly fixed.** Cross-label duplicates refused; the snapshot is still operational input. |
| M-04 | **Medium** | **Partly fixed.** Bypass flags revert on production chains; owner must be a Safe with threshold ≥ 2. |
| M-05 | **Medium** | **Partly fixed — now Low.** Exact amount owed is reported; no on-chain reserve. |
| L-01 | **Low** | **Partly fixed.** Contract-wallet warnings added. |
| L-02 | **Low** | **Unchanged (inherent).** |
| L-03 | **Low** | **Fixed.** Claim deadline and treasury return (plan decision #8). |
| L-04 | **Low** | **Fixed.** Foundry keystore, expanded after `.env` loads. |

## Findings

### H-01 — Incorrect tree total or leaf data can underpay users

**Status:** Partly fixed — now Medium (process control).  
**Locations:** `MerkleVestingDistributor.sol` (`commitRoot`, `claim`, `outstanding`, `claimDeadline`); `offchain/build-claims.mjs`; `offchain/verify-tree.mjs`.

`commitRoot` checks that:

- the root is nonzero;
- the declared total is nonzero and within the configured ceiling;
- the distributor has at least that balance; and
- one supplied sample proof verifies.

It cannot calculate the sum of all Merkle leaves on-chain. Therefore:

- a declared total below the real leaf sum causes later claims to revert with `AllocationExceeded`, and a top-up cannot fix it;
- a declared total above the real leaf sum is reserved only until `claimDeadline()`, after which it can be swept to treasury;
- an otherwise valid root containing a wrong account, amount or omitted user cannot be corrected after commitment.

`build-claims.mjs` now rebuilds the ledger from deposit events, checks it against `totalDeposited`, and checks every allocation against `vault.allocationOf`. `verify-tree.mjs` takes the root and total from the chain. These checks prove that the published file matches the frozen vault ledger; the long-lock part still relies on the snapshot input (M-03).

**Recommendation:** Independently rebuild every row, root, count, proof, and total from the frozen inputs, and compare the final tuple with both chains during the 48-hour review before `commitRoot`.

### H-02 — Cross-chain attestation is not cryptographically enforced

**Status:** Accepted (plan decision #10).  
**Locations:** `MigrationVault.sol` (`attestClaimRoot`, `release`, `cancel`); `README.md` cross-chain and "Guardian" sections.

Base cannot read Robinhood state. `attestClaimRoot(root, totalAllocation, distributor)` accepts the owner's statement and only checks local timing and nonzero values. It does not verify that:

- `root` equals `distributor.merkleRoot()` on Robinhood;
- `totalAllocation` equals `distributor.totalAllocation()`;
- the distributor has enough AGENTOS; or
- the committed tree matches the Base ledger.

After the 24-hour delay, the Safe can release all deposited CAP and DACKIE even if the attestation is false. This is the primary security boundary of the system. It is documented in the README and accepted in plan decision #10; the control is the public commit → attest → 24h delay, during which anyone can compare the attested values with Robinhood. An optional `GUARDIAN` with a limited veto exists in code and is set to none by default. A trustless cross-chain proof would be a protocol-level redesign.

### M-01 — Deposit-time budget reservation

**Status:** Fixed.  
**Locations:** `MigrationVault.sol` (`deposit`, `MAX_DEPOSIT_ALLOCATION`).

`MAX_DEPOSIT_ALLOCATION` (4.20B AGENTOS, immutable) is checked in `deposit` once rates are set, leaving 0.80B of the 5B budget for long-locks. Withdrawals are never capped. The invariant `invariant_depositsRespectTheCap` covers it. Because rates are set before `DEPOSIT_START`, the cap applies from the first deposit. A rate correction can still push existing deposits over the cap; new deposits then stop (documented).

### M-02 — Deadline extension and the rate-correction period

**Status:** Fixed.  
**Locations:** `MigrationVault.sol` (`setRates`, `RATE_CORRECTION_CUTOFF`).

`RATE_CORRECTION_CUTOFF = initial deadline − MIN_RATE_NOTICE` is immutable (= 2026-12-10 23:59:59 UTC, the date in the plan). `setRates` reverts with `RatesFinal` after it. `extendDeadline` does not move it, and the team has confirmed `extendDeadline` will not be used. The invariant `invariant_ratesAreFinalAfterTheCutoff` covers it.

### M-03 — Long-lock snapshot is not proven by the code

**Status:** Partly fixed.  
**Locations:** `claims-lib.mjs` (`parseLongLockCsv`, `computeClaims`); `build-claims.mjs`.

The parser validates CSV syntax, positive amounts, `misses_window = yes` and lock-end timing relative to the deposit deadline. Without a `position_id` column, duplicates are now keyed on `(address, lock_end_ts)` whatever the source label, so the same position under two labels is refused. With `position_id`, ids must be unique.

The code still does not query DackiePool or DackieLPVault to establish that the position existed at the 2026-11-25 snapshot block, that the LP conversion is correct, or that the position was not already deposited. In `position_id` mode the source label is free text, so one position under two spellings could still pass.

**Impact:** Overpayment, duplicate allocation or omission of eligible lockers, and irreversible root errors.

**Recommendation:** Generate the snapshot from archive-node calls at the snapshot block, include position IDs and raw values in the review package, and restrict `source` to the two known contracts.

### M-04 — Production deployment and blocklist state are not protocol invariants

**Status:** Partly fixed.  
**Locations:** `scripts/DeployBase.s.sol`, `DeployVault.s.sol`, `DeployDistributor.s.sol`, `BlocklistBatches.s.sol`.

`ALLOW_EOA_OWNER` and `ALLOW_ANY_CHAIN` now revert on Base (8453) and Robinhood (4663). The owner must be a Safe with threshold ≥ 2, and `MAX_DEPOSIT_ALLOCATION` has unit-bound checks. Production parameters are still supplied through environment variables without a signed manifest, and the blocklist is executed as a separate Safe batch. A leaked holder can also move funds to a clean address before the blocklist is applied (documented).

### M-05 — Manual-path claims are not reserved in the committed distributor budget

**Status:** Partly fixed — now Low.  
**Locations:** `claims-lib.mjs`; `build-claims.mjs`; `MerkleVestingDistributor.sol` (`sweepExcess`).

Blocked accounts and blocked recipients receive no Merkle leaf. The report now warns for both blocked depositors and blocked long-lock rows and prints the exact amount owed. There is no on-chain reserve: after commitment, `sweepExcess` returns that budget to treasury, and the treasury pays verified manual claims. This is an accounting and governance matter rather than an unprivileged drain.

### L-01 — Recipient usability on Robinhood is not validated

**Status:** Partly fixed.  
**Locations:** `MigrationVault.sol` (`registerRecipient`, `deposit`); `build-claims.mjs`; distributor claim transfer.

The vault accepts any nonzero recipient not on the Base blocklist. The tooling now warns when a Base contract wallet (EIP-7702 delegations excluded) receives at its own address. The vault cannot confirm that the address exists, is controlled by the user, or can use AGENTOS on Robinhood. A wrong EOA or unsupported contract-wallet mapping can make a claim practically unrecoverable.

### L-02 — CAP token behavior can reduce economic proceeds

**Status:** Unchanged (inherent).  
**Locations:** `MigrationVault.sol` (`deposit`, `withdraw`, `release`); `test/fork/BaseFork.t.sol`.

Balance-delta accounting records the amount received by the vault. It does not protect against later token-admin behavior such as transfer taxes, pool flags, rebasing or freezing. A fork test shows the vault stays solvent if CAP's owner flags it as a taxed pool; users or the Safe would receive less.

### L-03 — Unclaimed AGENTOS and the treasury-return mechanism

**Status:** Fixed (plan decision #8).  
**Locations:** `MerkleVestingDistributor.sol` (`claimDeadline`, `outstanding`, `sweepExcess`).

`claimDeadline() = claimStart + 60 days + 30 days` = 2027-03-31 00:00:00 UTC (inclusive). It is derived from constants and moves only with `postponeClaimStart`.

### Exact treasury-return mechanism

1. The treasury funds the distributor with 5B AGENTOS.
2. The final Merkle tree is built and publicly reviewed for 48 hours.
3. `commitRoot` stores `totalAllocation`.
4. Right after commitment, `sweepExcess(treasury)` can return the budget never allocated in the tree, for example `5B − totalAllocation`. Before commitment, `outstanding()` is 0, so funding the distributor early is a signal, not a lock.
5. From commitment until `claimDeadline()`, the distributor protects `outstanding() = totalAllocation − totalClaimed`; `sweepExcess` can take only balance above that.
6. After `claimDeadline()`, `claim` reverts with `ClaimsExpired`, `outstanding()` is 0, and `sweepExcess(treasury)` returns everything left, including allocations nobody claimed.

### L-04 — Deployment command and key handling

**Status:** Fixed.  
**Location:** `projects/migration/package.json`.

The commands now run `dotenv -e .env -- sh -c '… --account "${DEPLOYER_ACCOUNT:?…}"'`: a Foundry encrypted keystore, expanded after `.env` loads. No raw private key is passed on the command line.

## Migration-plan conformance

### Represented in the implementation

- CAP/DACKIE deposit ledger on Base.
- Deposit and withdrawal window (2026-11-25 00:00:00 → 2026-12-25 23:59:59 UTC).
- Recipient registration for contract wallets and long-lockers.
- Blocklist hooks.
- On-chain rates with a 15-day notice and a fixed correction cutoff (2026-12-10 23:59:59 UTC).
- 4.20B AGENTOS deposit cap.
- Merkle root commitment and domain binding; one combined leaf per wallet.
- Root attestation plus 24-hour release delay.
- Release, cancellation, and timeout refund paths (timeout 2027-01-08 23:59:59 UTC).
- 20% initial unlock and 80% linear vesting for 60 days, the same for long-locks.
- 5B distributor allocation ceiling.
- Claim deadline 2027-03-31 00:00:00 UTC with treasury return.
- No AGENTOS minting in these contracts.
- Safe-owner deployment guards.

### Not enforced by the contracts

1. The seven-day pure-TWAP calculation and no-team-trading baseline.
2. Correct price-source selection.
3. Setting rates before `DEPOSIT_START`, and not using `extendDeadline`.
4. The exact snapshot block and the long-lock CSV.
5. LP locked-liquidity conversion to DACKIE.
6. CAP-airdrop exclusions.
7. Correct recipient mapping on Robinhood.
8. Correct sale routes, minimum output, tax/fee treatment, and MEV controls.
9. Across V5 bridge completion and destination receipt.
10. Uni v4 AGENTOS liquidity placement and buy-wall range.
11. The 48-hour publication and independent review process.
12. Manual-path settlement for blocked users.

The docs correctly say that these are operational responsibilities. They remain material to whether the migration succeeds.

## Revert and failure analysis

### MigrationVault

| Function | Important revert/failure conditions |
|---|---|
| Constructor | Zero/non-contract/equal token addresses; invalid timing or delay bounds; guardian equal to owner; bad window configuration; zero deposit cap. Deployment scripts additionally require 18-decimal tokens and a Safe owner. |
| `deposit` | Unsupported token; outside start/deadline or cancelled; paused; zero amount/recipient; blocked sender or recipient; transfer failure; zero received amount; **`DepositCapExceeded`** once rates are set. |
| `withdraw` | Unsupported token; between the deadline and the settlement deadline, or after release; zero amount; amount greater than caller's deposit; token transfer failure. |
| `refund` | Before cancellation/timeout; after release; no balance; transfer failure. A full two-token refund reverts atomically if either token transfer fails; per-token `withdraw` remains available. |
| `registerRecipient` | Cancelled; after deadline; zero/blocked recipient or blocked caller. |
| `setBlocked` | Non-owner; impractical gas for a very large batch. |
| `setRates` | Cancelled; invalid rate; **`RatesFinal`** after the fixed cutoff; insufficient notice before the deadline; non-owner. |
| `extendDeadline` | Cancelled; window already closed; non-increasing deadline; beyond immutable maximum; non-owner. Not planned to be used. |
| `attestClaimRoot` | Cancelled; already released; window open; after settlement deadline; rates unset; zero root/total/distributor; too late to leave the release delay before the settlement timeout. It does not verify Robinhood state. |
| `release` | Cancelled/released; window open; timeout passed; no attestation; delay not elapsed; token transfer failure. |
| `cancel` | Unauthorized caller; already released/cancelled; an optional guardian calling outside its limited veto phase. |
| `rescue` | Non-owner; zero recipient/amount; amount exceeds token excess. |
| `renounceOwnership` | Always. |

### MerkleVestingDistributor

| Function | Important revert/failure conditions |
|---|---|
| Constructor | Zero owner/token; token has no code; zero budget. Deployment script rejects a budget above total supply or non-18-decimal AGENTOS. |
| `commitRoot` | Root already committed; zero/over-budget total; claim start not strictly future or beyond 30-day limit; underfunded distributor; invalid sample leaf/proof; non-owner. |
| `claim` | Root not committed; claims not open; **`ClaimsExpired`** after the claim deadline; invalid proof/domain/account/allocation; nothing newly vested; aggregate claimed amount above declared total; AGENTOS transfer failure. |
| `postponeClaimStart` | No root; claims already open; non-increasing or too-late start; non-owner. |
| `sweepExcess` | Zero recipient; nothing above `outstanding()`; non-owner. |
| `rescue` | Attempt to rescue AGENTOS; zero recipient/amount; non-owner. |

### Off-chain and external settlement failures

The tooling aborts, before writing anything, on malformed CSVs, invalid addresses, duplicate rows, missing rates, an open deposit window, a wrong freeze block, missed deposit events, ledger mismatch, invalid lock ends, or over-budget output. It cannot prove the correctness of the long-lock CSV's source data.

The sale, bridge, and liquidity operations are outside these contracts and can fail because of bad router paths, token ordering, slippage, insufficient liquidity, changed token taxes, WETH/ETH transfer failures, Across route limits, Uni v4 parameters, Safe nonce/gas errors, or destination-chain finality problems.

## Prior-report comparison

| Prior finding (GPT-Sol) | Status at v3.4 |
|---|---|
| H-01 incorrect total/tree sum | **Partly fixed.** Overstated total recoverable after the claim deadline; tooling rebuilds and checks the ledger. Understated total still a process risk. |
| M-01 no deposit budget cap | **Fixed.** Immutable 4.20B cap. |
| M-02 extension reopens rates | **Fixed.** Immutable cutoff; `RatesFinal`. |
| M-03 long-lock CSV duplication/input trust | **Partly fixed.** Cross-label duplicates refused; snapshot provenance is operational. |
| M-04 deployment/blocklist operational controls | **Partly fixed.** Production bypass flags blocked. |
| M-05 manual-path reserve | **Partly fixed — now Low.** |
| L-01 recipient validation | **Partly fixed.** |
| L-02 token tax/rebase behavior | **Unchanged (inherent).** |
| L-03 no claim expiry | **Fixed.** |
| L-04 dotenv/private-key expansion | **Fixed.** |

`build-claims.mjs` reconstructs the frozen deposit ledger, checks event completeness against `totalDeposited`, verifies computed allocations against `vault.allocationOf`, produces a deterministic report, and has an end-to-end off-chain rehearsal. These improvements reduce operational error risk but do not remove the trust boundary around the long-lock snapshot, final exclusions, Safe attestation, or actual settlement.

## Verification evidence

Recorded repository test results for the reviewed v3.4 snapshot:

| Verification | Recorded result |
|---|---|
| `forge test` | 133 passed, 0 failed, 1 skipped (fork suite without RPC) |
| `FOUNDRY_PROFILE=ci forge test` | 133 passed, 0 failed, 1 skipped |
| Base fork suite | 4 passed against real CAP/DACKIE token addresses |
| Off-chain tests | 30 passed, 0 failed |

The tests cover unit behavior, fuzzing, invariants, deployment guards, migration flow, off-chain tree generation, the claim deadline and treasury sweep, and the simulated safe-silent refund path. They do not verify live deployed bytecode, Robinhood state, sale transactions, Across V5, Uni v4 liquidity, or the production long-lock snapshot.

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

## Final assessment

The implementation passes its automated tests and has strong local defensive engineering. It conforms to migration plan v3.4 under the trusted-Safe operating model. The principal risks are not a reentrancy or Merkle-proof bypass; they are incorrect irreversible inputs, privileged cross-chain attestation, manual-path accounting, recipient routing, token-admin behavior, deployment configuration, and external settlement failures.

The code returns both unallocated budget (after commitment) and unclaimed allocations (after 2027-03-31 00:00:00 UTC) to treasury through `sweepExcess`, enforces the 4.20B deposit cap on-chain, and uses an immutable rate-correction cutoff. Under the 404AI Labs trusted-Safe model, with the claim package, long-lock snapshot, Safe configuration and blocklist checked in the published review, the contracts are suitable for a controlled launch.
