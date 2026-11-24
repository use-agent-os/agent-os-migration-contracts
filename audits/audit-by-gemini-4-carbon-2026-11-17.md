# Audit by Gemini-Carbon — CAP + DACKIE → AGENTOS Migration

> **Budget restatement:** This report was originally written against the 10B AGENTOS / 8.5B deposit-cap configuration. Budget figures below reflect the 5B AGENTOS / 4.20B deposit-cap release. The test results, file hashes, and audit conclusions refer to the original review, not to a new audit of the release revision.

**Date:** 2026-11-17  
**Reviewer:** Google Gemini 4 Carbon (`gemini-4-carbon`)  
**Release revision:** `projects/migration` at `a4a765e7ab278ae30e5912f9f56584a336205ff2` (2026-11-24).

**Original review target:** `projects/migration` at `bb7af4634de688ff6c8e03b66691fe189e2c6be6` (2026-11-17).

**Specification:** `docs/migration_plan.md` — v1.0 release budget; Draft v3.4 for the original review.

**Related reports:**  
- `audit/audit-by-gpt-sol-2026-11-17.md`  
- `audit/audit-by-gpt-astra-2026-11-17.md`  

> **Disclaimer:** This is an AI-assisted smart-contract and repository security review, not a formal third-party audit firm attestation or deployment warranty. It reviews source code, scripts, off-chain claim/tree tooling, automated tests, and live read-only token properties on Base (8453) and Robinhood (4663), not final deployed bytecode or live multisig settlement calldata.

---

## Inherited Operating Model & Assumptions

Consistent with the previous audit rounds (`audit-by-gpt-sol-2026-11-17.md` and `audit-by-gpt-astra-2026-11-17.md`) and Draft v3.4 Decision #10:

1. **Trusted Owner Boundary:** Both `MigrationVault` (Base, chain `8453`) and `MerkleVestingDistributor` (Robinhood, chain `4663`) are owned and operated by **404AI Labs's Safe Wallet** (`threshold >= 2`).
2. **Honest Execution of Schedule:** 404AI Labs's Safe Wallet and 404AI Labs team are trusted to execute the published operational runbook honestly—pre-funding 5B AGENTOS before opening, freezing the ledger at the deadline, publishing `tree.csv` / `tree.json` / `claims-report.json` for a **48-hour public review**, committing the verified Merkle root on Robinhood, attesting it on Base, waiting the 24-hour release delay, selling CAP/DACKIE, bridging ETH via Across V5, and provisioning the AGENTOS/WETH buy wall before claims open.
3. **No Guardian / No On-Chain Cross-Chain Proof Required:** Per Plan v3.4 Decision #10, `GUARDIAN = address(0)` and cross-chain state alignment between Base and Robinhood is enforced operationally via public attestation + 48h/24h public verifiability rather than an on-chain bridge proof. Accordingly, the absence of trustless cross-chain verification is treated as an **accepted architectural trust boundary**, not a defect.

---

## Executive Summary & Direct Answers (`0/` – `5/`)

Between the previous audits (which reviewed Draft v3.1–v3.3) and the current codebase (aligned with **Draft v3.4**), substantial upgrades were made across `MigrationVault.sol`, `MerkleVestingDistributor.sol`, deployment scripts, and off-chain tooling:

- **Added immutable deposit cap (`MAX_DEPOSIT_ALLOCATION` = 4.20B AGENTOS)** enforced directly in `MigrationVault.deposit` once rates are set (Plan Decision #9).
- **Added immutable rate-correction cutoff (`RATE_CORRECTION_CUTOFF` = `2026-12-10 23:59:59 UTC`)** so `extendDeadline()` can never reopen rate edits.
- **Simplified Merkle leaf layout to one schedule & one leaf per account** `(chainId, distributor, account, allocation)`—removing per-leaf `vestingStart` (Plan Decision #2).
- **Added fixed on-chain claim deadline (`claimDeadline()` = `claimStart + 60 days + 30 days` = `2027-03-31 00:00:00 UTC`)**, allowing `sweepExcess(treasury)` to recover unclaimed AGENTOS after expiry while keeping committed tokens untouchable until that second (Plan Decision #8).
- **Hardened deployment scripts & off-chain pipeline** (blocking `ALLOW_EOA_OWNER` / `ALLOW_ANY_CHAIN` on Base & Robinhood, switching from raw `$PRIVATE_KEY` to Foundry `--account` keystore inside `sh -c`, fixing `(address, lock_end_ts)` deduplication across source labels, aborting before file write on over-budget runs, and warning on blocked long-lock liabilities).

### Direct Answers to Requested Questions

| # | Question | Verdict & Summary |
|---|---|---|
| **0/** | **Have the prior findings been fixed?** | **Mostly YES — 4 fully fixed, 5 partly fixed, 1 accepted by design, 1 inherent external risk.** Fully fixed: `M-01` (deposit cap), `M-02` (fixed `RATE_CORRECTION_CUTOFF`), `L-03` (`claimDeadline` & treasury sweep), `L-04` (`dotenv` + Foundry keystore). Partly fixed: `H-01` (overstated total no longer locked forever; understated total / leaf accuracy still rely on the 48h review), `M-03` (cross-source duplicate key fixed; snapshot provenance off-chain), `M-04` (production bypass flags blocked; blocklist still a separate Safe batch), `M-05` (blocked long-lock warnings added; no on-chain reserve), `L-01` (contract-wallet warnings; Robinhood recipient validity not provable). Accepted: `H-02` (Decision #10). Inherent: `L-02` (external CAP tax). |
| **1/** | **Does the code satisfy `docs/migration_plan.md` (v3.4)?** | **Yes, with high fidelity for all on-chain mechanics.** Every v3.4 parameter, timestamp (`11-25`, `12-10 23:59:59`, `12-25 23:59:59`, `12-31`, `2027-03-01`, `2027-03-31 00:00:00`), vesting rule (20% + 60d linear for both depositors and long-locks), 4.20B deposit cap, 5B distributor ceiling, and two-step treasury sweep matches v3.4 to the exact second. **One newly found edge case (`NEW-01`)** would create a conflict if `extendDeadline()` were called past `2026-12-26 11:08:58 UTC`; the team has confirmed `extendDeadline()` will not be used. TWAP pricing, archive snapshot extraction, DEX sales, Across V5 bridging, and Uni v4 LP provisioning remain off-chain Safe execution steps. |
| **2/** | **Is security ensured?** | **Strong against unprivileged external attackers; conditionally safe under the trusted 404AI Labs Safe model.** Contracts are non-upgradeable, use `Ownable2Step` (renounce disabled), `ReentrancyGuard`, `SafeERC20`, balance-delta deposit accounting, double-hashed domain-bound Merkle leaves (`chainId` + `address(this)`), non-pausable exits, and permissionless timeout refunds. Residual risk sits in operational input accuracy and two subtle launch/extension timing edges (`NEW-01`, `NEW-02`). |
| **3/** | **Can funds be lost or hacked?** | **No permissionless exploit or unprivileged token-drain vector exists in the Solidity contracts.** Funds can only be lost or impaired via: (a) compromised/malicious Safe (accepted trust boundary after window close), (b) understated `totalAllocation` or corrupted Merkle tree committed on-chain, (c) user/contract-wallet registering an unusable recipient on Robinhood (`L-01`/`NEW-06`), (d) double-counting or dropping January long-lockers if `extendDeadline` is used carelessly (`NEW-01`), (e) users missing the `2027-03-31 00:00:00 UTC` hard claim expiry (by v3.4 design, swept to treasury), or (f) external swap/bridge slippage or third-party CAP tax activation (`L-02`). |
| **4/** | **Are there cases that revert?** | **Yes — extensively and intentionally.** Beyond standard access, window, and proof guards, the v3.4 code introduces three critical new revert conditions: `RatesFinal` (rate edits after `2026-12-10 23:59:59`), `DepositCapExceeded` (deposits pushing `totalDepositAllocation() > 4.20B`), and `ClaimsExpired` (any claim after `claimDeadline()`). Off-chain `build-claims.mjs` also reverts/aborts if `extendDeadline` pushes `depositDeadline` past any long-lock row's `lock_end_ts` (`NEW-01`). Full revert matrix in §5. |
| **5/** | **From the old reports, were real bugs found — and are there any new ones?** | **Yes.** The old reports found genuine code/tooling defects—most notably `M-01` (uncapped deposits), `M-02` (`extendDeadline` reopening rate changes), `M-03` (`(source, address, lock_end_ts)` allowing duplicate positions across source labels), `M-04` (bypass flags allowed on prod chains), `L-03` (permanent token lock on abandoned/overstated claims), and `L-04` (broken `$PRIVATE_KEY` shell expansion). All were confirmed real. `M-01`, `M-02`, `L-03` and `L-04` are fully fixed; for `M-03` and `M-04` the specific defect (cross-source key, prod bypass flags) is fixed while the off-chain residual remains (see §1). In addition, **this review identified 7 new findings/edge cases (`NEW-01` to `NEW-07`: 1 Medium, 4 Low, 2 Informational)** introduced or exposed by the v3.4 changes. |

---

## 1. Status of Previous Audit Findings (`0/` & `5/`)

| Prior ID | Summary of Prior Finding | Status in Current Code (v3.4) | Verification Details |
|---|---|---|---|
| **H-01** | `commitRoot` cannot sum all Merkle leaves on-chain; wrong `totalAllocation` or tree data underpays users (`AllocationExceeded`) or permanently locks AGENTOS. | **Partially Fixed** *(Permanent lock fixed; off-chain sum check remains)* | 1) Overstated `totalAllocation` no longer permanently locks tokens: after `claimDeadline()`, `outstanding()` drops to `0` (`MerkleVestingDistributor.sol:258`), returning the excess via `sweepExcess`.<br>2) Removed `vestingStart` from leaves; `tree-lib.mjs:73` & `verify-tree.mjs:44` strictly enforce 1 leaf per lowercase account.<br>3) `build-claims.mjs:178-181` exits *before* writing files if over budget.<br>4) Understated `totalAllocation` or wrong leaf values still require off-chain `verify-tree.mjs` + 48h review. |
| **H-02** *(Astra)* | Base `attestClaimRoot` does not cryptographically verify Robinhood state. | **Accepted by Design** | Settled in Plan v3.4 Decision #10 and inherited trusted-Safe model (`GUARDIAN = address(0)`, public attestation + 24h delay). |
| **M-01** | No on-chain deposit cap against the 5B AGENTOS budget. | **Fixed** *(see `NEW-02`, `NEW-03`)* | `MigrationVault.sol:78, 191-192` enforces `totalDepositAllocation() <= MAX_DEPOSIT_ALLOCATION` (`4.20B` AGENTOS) on every deposit once `ratesSet == true`, leaving `0.80B` headroom for long-locks (`~0.76B` indicative). |
| **M-02** | `extendDeadline()` shifted the rate-change cutoff (`depositDeadline - MIN_RATE_NOTICE`), allowing rate edits after `2026-12-10`. | **Fixed** | `MigrationVault.sol:76, 148, 273` adds immutable `RATE_CORRECTION_CUTOFF = p.depositDeadline - p.minRateNotice` (`1796947199` = `2026-12-10 23:59:59 UTC`) and reverts with `RatesFinal()` if `ratesSet && block.timestamp > RATE_CORRECTION_CUTOFF`. |
| **M-03** | Long-lock CSV trusted externally; duplicate key `(source, address, lock_end_ts)` allowed double-counting under different `source` labels. | **Partially Fixed** *(see `NEW-01`, `NEW-05`)* | `claims-lib.mjs:86-88` now deduplicates by `(address, lock_end_ts)` regardless of `source`, or `(source, position_id)` when `position_id` is supplied. Archive-node extraction at the `11-25 00:00` snapshot block remains an off-chain responsibility. |
| **M-04** | `ALLOW_EOA_OWNER` and `ALLOW_ANY_CHAIN` worked on production chains; blocklist applied post-deploy. | **Partially Fixed** *(Bypass flags fixed; see `NEW-04`)* | `DeployBase.s.sol:24-26, 49-54` explicitly reverts if either bypass flag is `true` on Base (`8453`) or Robinhood (`4663`). Blocklist Safe batches remain a mandatory pre-open operational step. |
| **M-05** | Blocked/manual-path entitlements excluded from Merkle tree without on-chain reserve; blocked long-locks lacked warnings. | **Partially Fixed** *(Warning fixed; treasury reserve operational)* | `claims-lib.mjs:147, 163, 209-217` sums both blocked depositors and blocked long-locks into `report.totals.excludedBlocked` and emits an explicit warning with exact wei owed so treasury retains that amount after `sweepExcess`. |
| **L-01** | Recipient usability on Robinhood not validated. | **Partially Mitigated** *(see `NEW-06`)* | `build-claims.mjs:129-143, 158-163` detects Base contracts (excluding EIP-7702 `0xef0100` delegations) that default to their own address and emits human-review warnings. Cross-chain control of `recipient` cannot be proven by Base contracts. |
| **L-02** | CAP third-party owner can flag vault as a taxed pool (1% fee-on-transfer). | **Acknowledged External Risk** | Balance-delta accounting in `MigrationVault.deposit` preserves vault solvency (`BaseFork.t.sol` passes against live Base CAP & DACKIE). Live Robinhood `AGENTOS` (`0x6eDA...bba3`) was verified in this review to be a standard non-taxed Clanker `ERC20Votes` token. |
| **L-03** | No expiry or treasury recovery for allocated but unclaimed AGENTOS. | **Fixed** | `MerkleVestingDistributor.sol:47, 107-108, 250-260` implements `claimDeadline() = claimStart + 60 days + 30 days`. After `2027-03-31 00:00:00 UTC`, `claim()` reverts with `ClaimsExpired`, `outstanding()` becomes `0`, and `sweepExcess(treasury)` recovers all unclaimed tokens. |
| **L-04** | `package.json` expanded `$PRIVATE_KEY` in parent shell before `dotenv` loaded `.env`. | **Fixed** | `package.json:21-22` removed `$PRIVATE_KEY`, runs inside single-quoted `sh -c '...'` after `dotenv`, and uses Foundry encrypted keystore `--account "${DEPLOYER_ACCOUNT:?...}"`. |

---

## 2. New Findings in Current Code (`v3.4`)

No Critical or High permissionless vulnerabilities were found. However, reviewing the v3.4 changes and cross-referencing them against `docs/migration_plan.md` and `docs/data/dackie-longlock-close-2026-12-25.csv` uncovered **1 Medium, 4 Low, and 2 Informational** findings.

| ID | Severity | Title |
|---|---|---|
| **NEW-01** | **Medium (conditional)** | `extendDeadline()` collides with the DACKIE long-lock snapshot cutoff, causing `build-claims.mjs` to abort and creating a double-counting vs. disenfranchisement trap |
| **NEW-02** | **Low** | Launch-day gap between `DEPOSIT_START` (`11-25 00:00 UTC`) and `setRates()` leaves `MAX_DEPOSIT_ALLOCATION` inactive and permits blind deposits |
| **NEW-03** | **Low** | Last-minute deposit-cap squatting (`MAX_DEPOSIT_ALLOCATION` griefing) cannot be mitigated by `extendDeadline()` once `depositDeadline` passes |
| **NEW-04** | **Low** | `BlocklistBatches.s.sol` does not reject duplicate addresses despite explicit NatSpec claim, risking inaccurate blocklist count verification |
| **NEW-05** | **Low** | `parseLongLockCsv` `position_id` mode allows duplicate positions across unvalidated `source` label spellings |
| **NEW-06** | **Informational** | Off-chain contract-recipient warning skips custom `recipient != account` addresses and does not check Robinhood (`4663`) bytecode |
| **NEW-07** | **Informational** | `postponeClaimStart()` shifts on-chain `claimDeadline()` away from static `claimStart` / `claimDeadline` fields in `tree.json` and `claims-report.json` |

---

### NEW-01 [Medium, conditional] — `extendDeadline()` Collides With DACKIE Long-Lock Snapshot Cutoff (Pipeline Abort & Double-Payment Trap)

**Status:** Applies only if `extendDeadline()` is called. The team-confirmed operating assumption is that it will not be used and the deposit deadline stays `2026-12-25 23:59:59 UTC`. Under that assumption, this finding does not occur.

**Locations:**  
- `projects/migration/src/MigrationVault.sol:286-295` (`extendDeadline`)  
- `projects/migration/offchain/build-claims.mjs:84` (`depositDeadline` read live from vault)  
- `projects/migration/offchain/claims-lib.mjs:153-155` (`if (l.lockEnd <= depositDeadline) throw ...`)  
- `docs/data/dackie-longlock-close-2026-12-25.csv` (draft long-lock list)  
- `docs/migration_plan.md` §4 & §9  

**Description:**  
Under Plan §4, DACKIE long-locks are defined at the `2026-11-25 00:00:00 UTC` snapshot as positions with `lockEnd > 2026-12-25 23:59:59 UTC` (`1798243199`), finalized in **Post #2 on `2026-12-10`**, and holders are instructed to do **"Nothing. Snapshot amount recorded."**  
The contract still allows `vault.extendDeadline(...)` up to `MAX_DEPOSIT_DEADLINE = 2027-01-31 23:59:59 UTC`, for example as a response to rate-arbitrage deposits crowding holders out of the `4.20B` cap.

However, `build-claims.mjs:84` reads the *current* (extended) `vault.depositDeadline()` from Base and passes it into `computeClaims()`, which enforces:

```js
if (l.lockEnd <= depositDeadline) {
  throw new Error(`long-lock ${l.address}: lock_end_ts ${l.lockEnd} is not after the deposit deadline ${depositDeadline}`);
}
```

Inspecting the draft long-lock list in the repository reveals **5 long-lock positions (4 in `DackiePool`, 1 in `DackieLPVault`) totaling ~`3.03M DACKIE` (~`56M AGENTOS` at indicative rates)** whose locks expire between `2026-12-26` and `2027-01-28`. The earliest expires at `2026-12-26 11:08:59 UTC`, about 11 hours after the deposit deadline.

**Impact:**  
1. **Immediate Settlement Script Failure:** Extending `depositDeadline` by even 12 hours (e.g., to `2026-12-26 23:59:59`) causes `build-claims.mjs` to hard-abort when run against the published Post #2 long-lock CSV.
2. **Double-Payment vs. Disenfranchisement Dilemma:** Once a position unlocks during an extended window while `MigrationVault` is still accepting deposits:
   - Deleting the row from the CSV breaks the Post #2 guarantee to passive long-lockers who were told to do nothing.
   - Conversely, relaxing `claims-lib.mjs` to check `lockEnd` against the *original* `2026-12-25` cutoff without additional guards would let a position that unlocks during the extension be counted both as a long-lock and as a vault deposit.

**Recommendation:**  
- Keep `depositDeadline` at `2026-12-25 23:59:59 UTC` (team-confirmed).
- Update `claims-lib.mjs` / `build-claims.mjs` to validate `lockEnd > INITIAL_DEPOSIT_DEADLINE` (`1798243199`), **and** if `vault.depositDeadline() > INITIAL_DEPOSIT_DEADLINE`, automatically flag or cap/deduct any long-lock row whose `lockEnd <= vault.depositDeadline()` if that position was withdrawn from `DackiePool`/`DackieLPVault` before `freezeBlock` (verifiable via archive `eth_call` on `DackiePool.userInfo(address)` at `freezeBlock`).

---

### NEW-02 [Low] — Pre-Rate Deposit Window Gap on Launch Day (`2026-11-25 00:00:00 UTC` vs `setRates()`)

**Status:** The team-confirmed operating assumption is that `setRates` is executed before `DEPOSIT_START`, so no deposit can be made before the rates are known and the cap applies from the first deposit. The finding applies only if that assumption is not met.

**Locations:**  
- `projects/migration/src/MigrationVault.sol:190-192, 268-281, 437-439`  
- `projects/migration/env.example:21` (`DEPOSIT_START=1795564800`)  
- `docs/migration_plan.md` §3 & §5  

**Description:**  
`DEPOSIT_START` is configured as `1795564800` (`2026-11-25 00:00:00 UTC`)—the exact second the 7-day baseline TWAP window closes (`11-18 → 11-25`). Computing the final 7-day TWAP after `00:00:00 UTC` and collecting multisig signatures on 404AI Labs's Safe Wallet on Base to execute `setRates(capRate, dackieRate)` takes non-zero operational time.

During the interval `[DEPOSIT_START, setRates tx timestamp)`:
1. `_depositsOpen()` is already `true`.
2. `ratesSet` is `false` (`capRate == 0`, `dackieRate == 0`), so `totalDepositAllocation()` returns `0`.
3. Consequently, **`MAX_DEPOSIT_ALLOCATION` (`4.20B`) is unenforced** until `setRates` lands, and early depositors deposit without on-chain rates (contrary to §5 *"so everyone knows the rate before depositing"*). If pre-rate deposits convert to `> 4.20B` once `setRates` is called (e.g., if TWAP rates are higher than indicative spot), `setRates` succeeds and halts *new* deposits, but cannot reduce already-credited deposits unless users voluntarily withdraw.

**Recommendation:**  
Either:
1. Have 404AI Labs's Safe Wallet on Base call `vault.pause()` immediately after deployment (before `2026-11-25 00:00:00 UTC`), then execute `MultiSend(vault.setRates(capRate, dackieRate), vault.unpause())` atomically in a single Safe transaction when publishing Post #1; **or**
2. Set `DEPOSIT_START` a few hours after the baseline TWAP cutoff (e.g., `2026-11-25 12:00:00 UTC`) so `setRates` is confirmed on-chain *before* `DEPOSIT_START` (`setRates` works while `Phase == Pending`).

---

### NEW-03 [Low] — Last-Minute Deposit-Cap Squatting (`MAX_DEPOSIT_ALLOCATION` Griefing)

**Locations:**  
- `projects/migration/src/MigrationVault.sol:191-192, 199-208, 286-295`  

**Description:**  
Deposits and withdrawals are untaxed on Base (`0%` fee) and open through `depositDeadline` (`2026-12-25 23:59:59 UTC`). A large holder or arbitrageur can deposit enough CAP/DACKIE to saturate `MAX_DEPOSIT_ALLOCATION` (`4.20B`), causing subsequent holders' deposits to revert with `DepositCapExceeded`, and then call `withdraw()` in the final block(s) at `timestamp == depositDeadline`. Once `block.timestamp > depositDeadline` (`2026-12-26 00:00:00 UTC`), `extendDeadline()` reverts with `LedgerFrozen()`, preventing the Safe from reacting after the window closes.

**Recommendation:**  
Publish `vault.totalDepositAllocation()` live and monitor top-depositor concentration, especially in the final 48 hours (`12-23 → 12-25`). Since `extendDeadline` will not be used (see `NEW-01`), the remaining on-chain fallback against a squat is `cancel` and redeploy.

---

### NEW-04 [Low] — `BlocklistBatches.s.sol` Does Not Reject Duplicate Addresses Despite NatSpec Claim

**Locations:**  
- `projects/migration/scripts/BlocklistBatches.s.sol:80-98`  

**Description:**  
Line 80 documents:
```solidity
/// @dev One address per line. Blank lines and lines starting with '#' are skipped.
///      Duplicates are rejected so the count matches the source list.
```
However, `_readAddresses()` never checks for duplicate addresses—every non-empty, non-comment line is appended to `buffer` and counted in `console2.log("Addresses:", list.length)`. On-chain, `MigrationVault.setBlocked` silently skips already-blocked addresses as a no-op (`if (isBlocked[account] != blocked_)`).

**Impact:**  
If the blocklist input file contains duplicate lines, the logged address count is higher than the number of unique addresses actually blocked on-chain, so a count-based check could pass while the blocklist is incomplete.

**Recommendation:**  
Add a duplicate check in `_readAddresses()` (or verify `sort -u` uniqueness and count exact `BlockedSet` events emitted on Base before opening deposits).

---

### NEW-05 [Low] — `parseLongLockCsv` `position_id` Mode Allows Duplicate Positions Across Unvalidated `source` Spellings

**Locations:**  
- `projects/migration/offchain/claims-lib.mjs:77-85`  
- `projects/migration/README.md:279-280`  

**Description:**  
When `position_id` is absent, `parseLongLockCsv` properly deduplicates on `(address, lock_end_ts)` ignoring `source`. However, when a `position_id` column is present, lines 78–85 switch completely to:
```js
const key = `${source.toLowerCase()}:${positionId}`;
if (seen.has(key)) throw new Error(`long-lock row ${row}: duplicate position_id ${positionId}`);
```
Because `source` is an unvalidated free-text column, two rows representing the exact same position with slightly different `source` labels (e.g., `DackieLPVault` vs `LPVault`, or `DackiePool` vs empty string) and identical `(position_id, address, lock_end_ts)` bypass deduplication and double-count the allocation.

**Recommendation:**  
Validate `source.toLowerCase()` against an explicit allowlist (`"dackiepool"` or `"dackielpvault"`) whenever `source` or `position_id` is used.

---

### NEW-06 [Informational] — Contract-Recipient Warning Skips Custom `recipient != account` Addresses and Robinhood Code Checks

**Locations:**  
- `projects/migration/offchain/build-claims.mjs:136, 159`  
- `projects/migration/offchain/claims-lib.mjs:188-197`  

**Description:**  
`collectWarnings()` warns when a Base contract depositor/long-locker leaves `recipient == account` (`d.isContract && d.recipient === d.account`). It does not inspect bytecode when `recipient !== account`, nor does it check Robinhood (`4663`) RPC. If an EOA or Base multisig mistakenly registers *another* Base-only contract/Safe address `R != account` that is undeployed on Robinhood, no warning is emitted. Furthermore, because `distributor.claim()` is permissionless, any third party can trigger `claim()` and send the vested AGENTOS to `R` on Robinhood before `claimDeadline()`.

**Recommendation:**  
During the 48-hour public review, check `eth_getCode(recipient)` on both Base (`8453`) and Robinhood (`4663`) for every leaf in `tree.csv`: any `recipient` that has contract code on Base but `0x` on Robinhood should be manually confirmed with the depositor before `commitRoot`.

---

### NEW-07 [Informational] — `postponeClaimStart()` Desynchronizes Static `claimStart` / `claimDeadline` in `tree.json`

**Locations:**  
- `projects/migration/src/MerkleVestingDistributor.sol:182-191, 250-253`  
- `projects/migration/offchain/build-tree.mjs:40-43`  
- `projects/migration/offchain/verify-tree.mjs:67-76`  

**Description:**  
`tree.json` and `claims-report.json` record `claimStart` and `claimDeadline` computed prior to `commitRoot`. Because leaves no longer contain `claimStart`, calling `distributor.postponeClaimStart(newClaimStart)` on-chain keeps `merkleRoot` and all proofs valid while advancing on-chain `claimStart()` and `claimDeadline()` by the postponed delta. Any claim UI or reminder bot must read `distributor.claimStart()` and `distributor.claimDeadline()` directly from Robinhood rather than trusting the static timestamps in `tree.json`.

---

## 3. Conformance With `docs/migration_plan.md` (Draft v3.4) (`1/`)

### Verified On-Chain & Tooling Alignment

Every timestamp and numerical rule in Draft v3.4 was cross-checked against `MigrationVault.sol`, `MerkleVestingDistributor.sol`, `env.example`, and `MigrationFlow.t.sol`:

| Plan v3.4 Requirement | Implementation & Value | Status |
|---|---|---|
| Base tokens: CAP (`0xbfa7...2649`), DACKIE (`0x7332...AaF4`) | Validated on live Base fork (`18` decimals, contract code check) | **Matches** |
| Robinhood token: AGENTOS (`0x6eDA...bba3`, chain `4663`) | Verified live on Robinhood RPC (`chainId = 4663`, `18` decimals, `100B` supply, Shanghai `PUSH0` supported) | **Matches** |
| Window: `2026-11-25 00:00:00` → `2026-12-25 23:59:59 UTC` | `DEPOSIT_START = 1795564800`, `DEPOSIT_DEADLINE = 1798243199` (inclusive) | **Matches** |
| Rate correction cutoff: `2026-12-10 23:59:59 UTC` (fixed, never reopened by `extendDeadline`) | `RATE_CORRECTION_CUTOFF = 1798243199 - 15 days = 1796947199` (`2026-12-10T23:59:59Z`) | **Matches** |
| Deposit cap: `4.20B AGENTOS` (Decision #9), withdrawals free room | `MAX_DEPOSIT_ALLOCATION = 4_200_000_000e18` enforced in `deposit()` once `ratesSet == true` | **Matches** *(note `NEW-02`)* |
| Settlement timeout refund if not released by `2027-01-08` | `settlementDeadline() = 1798243199 + 14 days = 1799452799` (`2027-01-08T23:59:59Z`) | **Matches** |
| Root attestation + 24h public delay before `release()`, no guardian (Decision #10) | `RELEASE_DELAY = 86400`, `GUARDIAN = address(0)` | **Matches** |
| Distributor ceiling: `5B AGENTOS` (5% supply), no minting | `MAX_TOTAL_ALLOCATION = 5_000_000_000e18`, `commitRoot` requires `balance >= totalAllocation` | **Matches** |
| Vesting: 20% at `claimStart`, 80% linear over 60 days; identical for long-locks; 1 combined claim per wallet (Decision #2) | `INITIAL_UNLOCK_BPS = 2_000`, `VESTING_DURATION = 60 days`; `claims-lib.mjs` sums deposit + long-lock per recipient into 1 leaf | **Matches** |
| Claims open `2026-12-31 00:00:00 UTC`, vesting ends `2027-03-01 00:00:00 UTC` | `CLAIM_START = 1798675200` → `+60d = 1803859200` (`2027-03-01T00:00:00Z`) | **Matches** |
| Claim deadline: `2027-03-31 00:00:00 UTC` (vesting end + 30d), fixed offset, shifts equally if `claimStart` postponed; unclaimed swept to treasury (Decision #8) | `CLAIM_GRACE = 30 days` → `claimDeadline() = 1806451200` (`2027-03-31T00:00:00Z` inclusive); `postponeClaimStart` shifts both equally; `sweepExcess` sweeps all remaining after `1806451200` | **Matches** |

### Responsibilities Remaining Off-Chain (Not Enforced by Bytecode)

As designed, the following Plan v3.4 items are operational responsibilities of 404AI Labs / 404AI Labs's Safe Wallet:
1. Pre-window admin actions (§8): setting `DackiePool.overdueFee = 0`, `adminWithdraw` on CAP Merkle airdrops `0x9edc…` and `0xee2a…`, keeping `CAPU.mintPaused`, and executing all Safe blocklist batches before `11-25`.
2. Computing accurate 7-day baseline TWAPs (`11-18 → 11-25`) with zero team trading/MM.
3. Extracting the authoritative `2026-11-25 00:00:00 UTC` Base snapshot for `DackiePool` and `DackieLPVault` (`lockedLiquidity` → DACKIE conversion without WETH compensation, Decision #3 & #6).
4. Funding `MerkleVestingDistributor` with the full `5B AGENTOS` *before* `11-25` (`commitRoot` only checks `balance >= totalAllocation` at commit time on `12-28`).
5. Retaining `report.totals.excludedBlocked` in treasury for manual verified claims.
6. Executing atomic private-RPC DEX sales on Base with `minAmountOut` guards, bridging ETH via Across V5, and adding single-sided ETH liquidity (`spot → −50%`) to the Robinhood AGENTOS/WETH Uni v4 pool *before* `claimStart` (calling `postponeClaimStart` if delayed).

---

## 4. Security & Fund-Loss Assessment (`2/` & `3/`)

### Core Defensive Properties Verified
- **Immutability & Minimal Attack Surface:** No proxies, `delegatecall`, `selfdestruct`, Hooks, or flash-loan callbacks. Fixed `solc = 0.8.28` (`evm_version = "shanghai"`, `via_ir = false`), OpenZeppelin `v5.4.0`.
- **Unconditional User Exit Guarantees:** `withdraw()` and `refund()` are **never** `whenNotPaused` and **never** blocked by `isBlocked` or `MAX_DEPOSIT_ALLOCATION`. While the window is open, or after `cancel()` / `settlementDeadline()` timeout, user funds cannot be trapped even if Safe keys are lost.
- **Strict Separation of Funds:** Before `release()`, the Safe cannot touch user deposits via `rescue()` (`excessOf` strictly protects `totalDeposited[token]`). On Robinhood, once `commitRoot` is called, the Safe cannot touch a single wei of `outstanding() = totalAllocation - totalClaimed` until `block.timestamp > claimDeadline()`, and `rescue()` explicitly forbids `address(TOKEN)`.
- **Domain-Bound, Second-Preimage-Safe Merkle Proofs:** `leafOf` double-hashes `abi.encode(block.chainid, address(this), account, allocation)`. Cross-chain replay, cross-deployment replay, and 64-byte internal-node second-preimage attacks are impossible. `commitRoot` validates a real sample leaf on-chain, preventing accidental commitment of a wrong-chain or wrong-address tree that would otherwise lock funds for 90 days.
- **Arithmetic & Rounding Safety:** All multiplication paths (`deposit * rate`, `allocation * 2_000`, `(allocation - initial) * elapsed`) are bounded decades of orders of magnitude below `uint256.max`. Per-user floor rounding satisfies $\sum_i \lfloor d_i \cdot r / 10^{18} \rfloor \le \lfloor (\sum_i d_i) \cdot r / 10^{18} \rfloor = \text{totalDepositAllocation}()$, so individual leaves can never sum to more than the vault's aggregate cap check.
- **Live Token Compatibility Verified:**
  - **Base (`8453`):** Live fork tests (`BaseFork.t.sol`) confirm `CAP` (`0xbfa7...2649`) and `DACKIE` (`0x7332...AaF4`) transfer 1:1 with `MigrationVault` today, and remain solvent under balance-delta accounting even if `CAP`'s external owner flags the vault as a 1%-taxed liquidity pool.
  - **Robinhood (`4663`):** Live RPC inspection confirms `AGENTOS` (`0x6eDA...bba3`, EIP-1167 proxy to Clanker token `0x3be8...c599`) has `18` decimals, `100,000,000,000e18` supply, no transfer tax, no pause function, and full Shanghai opcode (`PUSH0`) compatibility.

### Scenarios Where Funds Could Be Lost or Impaired

| Vector | Who Is Affected | Preconditions & Mitigation |
|---|---|---|
| **Compromised / Malicious 404AI Labs's Safe Wallet** | Depositors (after `depositDeadline`) & pre-commit treasury | Inherent to Plan Decision #10 (`GUARDIAN = address(0)`). Mitigated by ≥2-signer hardware-wallet Safe, public 24h `RELEASE_DELAY`, and pre-committing the immutable root on Robinhood first. |
| **Understated `totalAllocation` or Bad Leaf in `commitRoot`** | Late claimants (`AllocationExceeded`) or miscalculated user | Mitigated by deterministic `build-claims.mjs` → `build-tree.mjs` → mandatory `verify-tree.mjs` against on-chain `merkleRoot()` & `totalAllocation()`, plus 48h public review. |
| **`extendDeadline()` Overlaps Expiring Long-Locks (`NEW-01`)** | Treasury (2× payout) or January long-lockers | Mitigated by not extending past `2026-12-26 11:08:58` or reconciling `DackiePool` withdrawals at `freezeBlock`. |
| **Unusable Robinhood Recipient (`L-01` / `NEW-06`)** | Individual depositor / contract wallet | User error (naming an undeployed contract wallet on chain `4663`). Partially mitigated by `build-claims.mjs` contract warnings; verify custom recipients on Robinhood before `commitRoot`. |
| **Missed `2027-03-31 00:00:00 UTC` Claim Deadline** | Late claimant (including unclaimed 80% of partial claimants) | Intentional Plan v3.4 Decision #8: tokens sweep to treasury rather than burning. Permissionless `claim()` allows anyone (or a team keeper script) to push vested tokens to stragglers on `2027-03-30` before expiry! |
| **Third-Party CAP Pool-Tax Flag (`L-02`) or Swap MEV** | Depositors (1% exit tax if flagged) or ETH sale proceeds | Vault stays solvent. Check `CAP.isLiquidityPool(vault)` before settlement; execute swaps via private RPC with strict `minAmountOut`. |

---

## 5. Complete Revert & Failure Matrix (`4/`)

### 5.1 `MigrationVault` (Base)

| Function | Revert Conditions |
|---|---|
| `constructor` | `owner == 0` (`OwnableInvalidOwner`); `cap == 0` or `dackie == 0` (`ZeroAddress`); `cap == dackie` or either has no code (`InvalidConfig`); `minRateNotice` outside `[7d, 30d]`; `releaseDelay` outside `[12h, 7d]`; `settlementGrace` outside `[releaseDelay + 2d, 60d]`; `depositDeadline < max(depositStart, now) + max(14d, minRateNotice)`; `maxDepositDeadline < depositDeadline` or `> opening + 180d`; `guardian == owner`; `maxDepositAllocation == 0` (`InvalidConfig`). |
| `deposit` | Vault paused (`EnforcedPause`); token not CAP/DACKIE (`UnsupportedToken`); `cancelled` or `now < DEPOSIT_START` or `now > depositDeadline` (`DepositsNotOpen`); `amount == 0` (`ZeroAmount`); `recipient == 0` (`ZeroAddress`); `msg.sender` or `recipient` blocked (`AccountBlocked`); ERC-20 allowance/balance failure; 100% tax token (`NothingReceived`); **once `ratesSet == true`, `totalDepositAllocation() > MAX_DEPOSIT_ALLOCATION` (`DepositCapExceeded`)**. |
| `withdraw` | Unsupported token; `released` or (`!cancelled && now > depositDeadline && now <= settlementDeadline()`) (`WithdrawalsClosed`); `amount == 0` (`ZeroAmount`); `amount > depositOf[token][msg.sender]` (`InsufficientDeposit`); ERC-20 transfer failure. |
| `refund` | `released` or (`!cancelled && now <= settlementDeadline()`) (`NotRefunding`); both CAP and DACKIE balances for `account` are `0` (`ZeroAmount`); ERC-20 transfer failure (atomic across both tokens—if one token reverts, `account` can still call per-token `withdraw()`). |
| `registerRecipient` | `cancelled` (`MigrationCancelled`); `now > depositDeadline` (`LedgerFrozen`); `recipient == 0` (`ZeroAddress`); `msg.sender` or `recipient` blocked (`AccountBlocked`). |
| `setBlocked` | Non-owner (`OwnableUnauthorizedAccount`); block gas limit if batch array is excessively large (default `400` uses ~10M gas, well within Base's block gas limit). |
| `setRates` | Non-owner; `cancelled` (`MigrationCancelled`); either rate outside `[1e15, 1_000_000e18]` (`InvalidRate`); **`ratesSet && now > RATE_CORRECTION_CUTOFF` (`RatesFinal`)**; `now + MIN_RATE_NOTICE > depositDeadline` (`RateNoticeTooShort`). |
| `extendDeadline` | Non-owner; `cancelled` (`MigrationCancelled`); `now > depositDeadline` (`LedgerFrozen`); `newDeadline <= depositDeadline` or `newDeadline > MAX_DEPOSIT_DEADLINE` (`InvalidDeadline`). |
| `attestClaimRoot` | Non-owner; `cancelled` / `released` / `now <= depositDeadline` (`WindowStillOpen`) / `now > settlementDeadline()` (`SettlementWindowOver`); `!ratesSet` (`RatesNotSet`); `root == 0` (`InvalidRoot`); `totalAllocation == 0` (`ZeroAmount`); `distributor == 0` (`ZeroAddress`); `now + RELEASE_DELAY > settlementDeadline()` (`SettlementWindowOver`). |
| `release` | Non-owner; `cancelled` / `released` / `now <= depositDeadline` / `now > settlementDeadline()`; `claimRoot == 0` (`RootNotAttested`); `now < claimRootAttestedAt + RELEASE_DELAY` (`ReleaseDelayNotElapsed`); ERC-20 transfer failure. |
| `cancel` | `released` (`AlreadyReleased`); `cancelled` (`MigrationCancelled`); caller neither `owner()` nor `GUARDIAN` (`NotAuthorized`); if caller is `GUARDIAN`, reverts unless settling (`WindowStillOpen` / `SettlementWindowOver`) and `claimRoot != 0` (`RootNotAttested`). |
| `rescue` | Non-owner; `to == 0` (`ZeroAddress`); `amount == 0` (`ZeroAmount`); `amount > excessOf(token)` (`InsufficientExcess`). |
| `renounceOwnership` | Always reverts (`RenounceDisabled`). |
| ETH transfers | Always reverts (no `receive` or `fallback`). |

### 5.2 `MerkleVestingDistributor` (Robinhood)

| Function | Revert Conditions |
|---|---|
| `constructor` | `owner_ == 0` (`OwnableInvalidOwner`); `token_ == 0` (`ZeroAddress`); `token_` has no code or `maxTotalAllocation_ == 0` (`InvalidConfig`). |
| `commitRoot` | Non-owner; `merkleRoot != 0` (`RootAlreadyCommitted`); `root == 0` (`InvalidRoot`); `totalAllocation_ == 0` or `> MAX_TOTAL_ALLOCATION` (`InvalidAllocation`); `claimStart_ <= now` or `> now + 30 days` (`InvalidClaimStart`); `TOKEN.balanceOf(this) < totalAllocation_` (`Underfunded`); `sampleAccount == 0` or `sampleAllocation == 0` or `> totalAllocation_` or `sampleProof` fails `leafOf(sampleAccount, sampleAllocation)` (`InvalidSampleLeaf`). |
| `claim` | `merkleRoot == 0` (`RootNotCommitted`); `now < claimStart` (`ClaimsNotOpen`); **`now > claimDeadline()` (`ClaimsExpired`)**; invalid Merkle proof for `(chainId, address(this), account, allocation)` (`InvalidProof`); `vested <= claimedOf[leaf]` (`NothingToClaim`); `totalClaimed + amount > totalAllocation` (`AllocationExceeded`); AGENTOS transfer failure. |
| `postponeClaimStart` | Non-owner; `merkleRoot == 0` (`RootNotCommitted`); `now >= claimStart` (`ClaimsAlreadyOpen`); `newClaimStart <= claimStart` or `> latestClaimStart` (`InvalidClaimStart`). |
| `sweepExcess` | Non-owner; `to == 0` (`ZeroAddress`); `excess() == 0` (`NothingToSweep`)—which reverts if called for committed unclaimed funds at any `timestamp <= claimDeadline()`. |
| `rescue` | Non-owner; `token == address(TOKEN)` (`CannotRescueDistributedToken`); `to == 0` (`ZeroAddress`); `amount == 0` (`ZeroAmount`). |
| `renounceOwnership` | Always reverts (`RenounceDisabled`). |

### 5.3 Deployment Scripts & Off-Chain Pipeline Reverts/Aborts

- **`DeployVault.s.sol` / `DeployDistributor.s.sol`:** Revert on wrong chain ID, `ALLOW_EOA_OWNER=true` or `ALLOW_ANY_CHAIN=true` on Base (`8453`) or Robinhood (`4663`), `OWNER` without contract code or Safe `getThreshold() < 2` or `getOwners().length < threshold`, or non-18-decimal tokens. In the listed release revision, the scripts also reject `MAX_DEPOSIT_ALLOCATION` outside `[1M, 4.20B]` and any `MAX_TOTAL_ALLOCATION` other than 5B or above `AGENTOS.totalSupply()`.
- **`build-claims.mjs` / `build-tree.mjs` / `verify-tree.mjs`:** Abort non-zero (writing **no output files**) if the migration is cancelled, deposit window is still open, `ratesSet == false`, `--block` is not the exact first block after `depositDeadline`, discovered `Deposited` events do not sum to `vault.totalDeposited` (catches truncated RPC logs or wrong `--from-block`), computed allocation differs from `vault.allocationOf`, any long-lock row has `lock_end_ts <= depositDeadline` (`NEW-01`) or `misses_window != "yes"` or duplicate `(address, lock_end_ts)`, `--longlock-vesting` or legacy 3-column CSV is passed, duplicate accounts appear in `tree.csv`, `claimStart` is in milliseconds, or `totalAllocation > --max-total`.

---

## 6. Verification Evidence

All verification commands were executed fresh against the current working tree during this audit session:

1. **Solidity Unit, Integration & Default Fuzz/Invariant Suite:**
   - Command: `forge test -vv` (in `projects/migration`)
   - Result: **133 passed, 0 failed, 1 skipped** (`BaseForkTest` skipped when `BASE_RPC_URL` unset).
2. **Deep CI Fuzz & Invariant Campaign:**
   - Command: `FOUNDRY_PROFILE=ci forge test` (in `projects/migration`)
   - Result: **133 passed, 0 failed, 1 skipped** (`10,000` fuzz runs per property; `1,000` runs × `100` depth = `100,000` randomized calls per invariant across both `VaultInvariantTest` and `DistributorInvariantTest`).
3. **Off-Chain Claim Builder, Tree Verifier & Local Anvil E2E Rehearsal:**
   - Command: `pnpm run test:offchain` (in `projects/migration`)
   - Result: **30 passed, 0 failed** (including full `MigrationVault` → `build-claims.mjs` → `build-tree.mjs` → `verify-tree.mjs` → `MerkleVestingDistributor.commitRoot` → vesting claims → post-`2027-03-31` `ClaimsExpired` & treasury sweep rehearsal).
4. **Live Base Mainnet Fork Suite:**
   - Command: `BASE_RPC_URL=https://mainnet.base.org forge test --match-path 'test/fork/*' -vv`
   - Result: **4 passed, 0 failed** against live `CAP` (`0xbfa733702305280F066D470afDFA784fA70e2649`) and `DACKIE` (`0x73326b4d0225c429bed050c11C4422d91470AaF4`).
5. **Live Robinhood Mainnet (`4663`) Read-Only Inspection:**
   - Endpoint: `https://rpc.mainnet.chain.robinhood.com`
   - Verified `eth_chainId == 0x1237` (`4663`), Shanghai `PUSH0` (`0x5f`) execution support, and `AGENTOS` (`0x6eDA83Fc299C10d474068A7E69771c809Bcbbba3`) metadata (`name = "AgentOS"`, `symbol = "AGENTOS"`, `decimals = 18`, `totalSupply = 100,000,000,000e18`, standard non-taxed Clanker `ERC20Votes` implementation at `0x3be8b97fd0e713b5abe0649fa830223b6b4bc599`).

### Original Review File SHA-256 Fingerprints

```text
9f7a80f59334c0381c987f3e5b5060422f4a8c56536e9b23a34690c2789c072d  projects/migration/src/MigrationVault.sol
0ad920889a816f01917c3009db5aafe6e37dd2769e0ec73d74923e070fbd57a9  projects/migration/src/MerkleVestingDistributor.sol
7bc981938babc8eefff0aa4d6aecbabf6421866d389a38da474aa8c957999fd9  projects/migration/src/interfaces/IMigrationVault.sol
0e482cad8b0f94be6b04799df30db89959f02c8b23c1057720e998e5167dba31  projects/migration/src/interfaces/IMerkleVestingDistributor.sol
dc4dbe19c2d008d69eb27cff8995cf541f3f43c50dce36bb1626ebb48df76364  projects/migration/scripts/DeployBase.s.sol
0cc16f5ad433c1e7f7bacc2991ae30d88c00be13b379b4b6133b836f4a7958c4  projects/migration/scripts/DeployVault.s.sol
05d7b6098c057aa0daeecb712f1f478b9ccdcfdbd3db7dea2bfc86e6fa1353ee  projects/migration/scripts/DeployDistributor.s.sol
52b378af6936f2fac64c971c33380c2c6f3604a901505f2a92fdb937510b5815  projects/migration/scripts/BlocklistBatches.s.sol
ce4580dba4115ed80910dba81979267771547b6299635452dd7ab28338613c1f  projects/migration/offchain/claims-lib.mjs
907178928e812e6175c1d5b5cf859ff3d2349242713cffa19c2975d5e8a22b8f  projects/migration/offchain/build-claims.mjs
ccb929dc7fbccf56a66f0bfa4bd3d021e4a00dcde6f9f014efe28aa686a2e514  projects/migration/offchain/tree-lib.mjs
90aefe445681773de84a8a07959ab852f4e57dff8b0f6cf21becf1c7c20aa9dc  projects/migration/offchain/build-tree.mjs
7c9dc04164a1301873f9cbd7bd5f7fd5adf9a41090bc8cb6497b11372b9650fe  projects/migration/offchain/verify-tree.mjs
a5bbd0c370a6dc1eeebbe05dc1108bee1446cd2abdf7a8c4a372b55216459065  projects/migration/package.json
c3d0c1f42c6c232377497b46a2d137c6e34ad8933b22dff3cf3eaca6686596e2  docs/migration_plan.md
```
