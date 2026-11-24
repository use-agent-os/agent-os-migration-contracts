# CAP + DACKIE → AGENTOS migration contracts

Two contracts, two chains, one owner (404AI Labs's Safe Wallet on each chain). They implement
[the migration plan](../../docs/migration_plan.md).

| Contract | Chain | Job |
|---|---|---|
| `MigrationVault` | Base (8453) | Escrows CAP + DACKIE during the window. Hands them to the Safe for the sale only after the claim root is attested and a delay has passed. Refunds if cancelled or not settled in time. |
| `MerkleVestingDistributor` | Robinhood (4663) | Holds AGENTOS. Pays claims from a Merkle root: 20% at claim open, 80% linear over 60 days. Claims close 30 days after vesting ends, then the unclaimed rest goes back to treasury. |

Status: **v1.0 Release.** AI-assisted security reviews completed; see [`audits/`](../../audits) for four model-written review reports.
All prior findings are fixed or documented under "Known limits". The implementation (claim deadline, one vesting schedule per leaf,
fixed rate-correction cutoff, deposit cap, hardened off-chain tooling) has been reviewed in rounds. **Not a formal third-party audit.**
Operational checks and final configuration review required before deployment.

The budget change requires fresh deployments: do not reuse the existing immutable 10B/8.5B contracts. Deploy a new distributor with a 5B ceiling and a new vault with the 4.20B deposit cap, then use those new addresses when building and committing the Merkle tree.

## 1. Lifecycle

```
Base: MigrationVault
  Pending ──start──▶ Open ──deadline──▶ Closed ──attestClaimRoot──▶ RootAttested ──release──▶ Released
                      │                    │                             │
                      └────── cancel() ────┴──── or settlementDeadline ──┴──▶ Refunding

Robinhood: MerkleVestingDistributor
  Funded ──commitRoot (once)──▶ Committed ──claimStart──▶ Claiming ──claimDeadline──▶ Closed
                                                          (20% + 60 days)   (unclaimed → treasury)
```

| Plan date (UTC) | Call | Who |
|---|---|---|
| before 11-25 | deploy both (Safe is owner from block 0), fund distributor with 5B AGENTOS, `setBlocked` for the blocklist | deployer / Safe |
| 11-25 | `setRates(capRate, dackieRate)` with Post #1, right after the baseline TWAP ends. A correction is accepted until 12-10 23:59:59 (`RATE_CORRECTION_CUTOFF`), then the rates are fixed for good | Safe (Base) |
| 11-25 → 12-25 | `deposit(token, amount, recipient)`, `withdraw`, `registerRecipient` | holders |
| 12-26 → 12-28 | build `tree.csv`, publish 48h, `commitRoot(root, total, claimStart, sample leaf + proof)` | Safe (Robinhood) |
| 12-28 | `attestClaimRoot(root, total, distributor)`, starts the 24h release delay | Safe (Base) |
| 12-28 | `sweepExcess(treasury)`, unused budget back to treasury | Safe (Robinhood) |
| 12-29 | `release()`, then sell CAP and DACKIE (one Safe tx per token) | Safe (Base) |
| 12-31 | claims open: `claim(account, allocation, proof)` | anyone, pays `account` |
| 2027-03-01 | vesting ends, every leaf is fully claimable | — |
| 2027-03-31 00:00:00 | `claimDeadline()`: last second a claim is accepted | — |
| after it | `sweepExcess(treasury)`: everything that was not claimed goes back to treasury | Safe (Robinhood) |

## 2. `MigrationVault`

- `deposit(token, amount, recipient)`: CAP or DACKIE. `recipient` is the address that receives the
  account's AGENTOS on Robinhood. EOAs pass their own address. It applies to the whole account and
  the latest value wins.
- Deposit cap: once the rates are set, a deposit reverts (`DepositCapExceeded`) if
  `totalDepositAllocation()` would go above `MAX_DEPOSIT_ALLOCATION` (4.20B AGENTOS, immutable). The
  other approximately 0.80B of the 5B budget is left for the long-lock allocations. Withdrawals are never capped
  and free the room again.- `registerRecipient(recipient)`: sets the recipient without depositing. For contract wallets and
  for DACKIE long-lockers, who never deposit. Callable before the window opens, frozen at the deadline.
- `withdraw(token, amount)`: open until the deadline (inclusive). Never pausable.
- `refund(account)`: anyone can push a full refund to `account` once the vault is refunding.
- `setRates`: always at least `MIN_RATE_NOTICE` (15 days) before the deadline. A mistake (wrong unit,
  swapped arguments) can be corrected only until `RATE_CORRECTION_CUTOFF` = initial deadline −
  15 days = 12-10 23:59:59. That date is immutable: after it, rates that are set revert with
  `RatesFinal`, and `extendDeadline` does not reopen them. If the rates were never set and come
  late, the owner must `extendDeadline` first, which gives depositors the full notice; rates set
  that way are final at once. The deadline can only move later, only while the window is open, and
  never past `MAX_DEPOSIT_DEADLINE`. Rates must be within `[1e15, 1_000_000e18]`.
- `attestClaimRoot(root, totalAllocation, distributor)`: after the deadline, needs the rates. Publishes
  on Base what was committed on Robinhood and starts the `RELEASE_DELAY` (24h) clock. Attesting
  again restarts it.
- `release()`: sends all deposited CAP + DACKIE to `owner()` in one call.
- `cancel()`: by the owner any time before `release`. Irreversible. Opens refunds.
- Guardian (optional, `GUARDIAN`, off by default): an independent address that can call `cancel()`
  only while a root is attested and not released. It has no other power. See "Guardian" below.
- Timeout: if `release()` has not happened by `depositDeadline + SETTLEMENT_GRACE` (14 days),
  refunds open for good and `release` is no longer possible.
- `allocationOf(account)`: `deposit × rate / 1e18`, each token rounded down on its own. **The claim
  tree must use this formula.**

A plain token transfer to the vault is not a deposit. The owner can `rescue` it (only the amount
above what depositors are owed).

## 3. `MerkleVestingDistributor`

- Leaf: `keccak256(bytes.concat(keccak256(abi.encode(chainId, distributor, account, allocation))))`.
  Same layout as OpenZeppelin `StandardMerkleTree` with `["uint256", "address", "address", "uint256"]`.
- One schedule for every leaf (plan decision #2): 20% at `claimStart`, 80% linear over 60 days,
  long-locks included. There is no per-leaf vesting start.
- **One leaf per account.** `build-claims.mjs` sums everything a recipient is owed (deposits and
  long locks) into one row, and `build-tree.mjs` / `verify-tree.mjs` reject a second row for the
  same account: two identical leaves would share one counter.
- `commitRoot(root, totalAllocation, claimStart, sampleAccount, sampleAllocation, sampleProof)`:
  once. Reverts unless the contract already holds `totalAllocation`,
  `totalAllocation ≤ MAX_TOTAL_ALLOCATION` (5B), `now < claimStart ≤ now + 30 days`, and the sample
  leaf verifies against the root. The sample proves the tree was built for this chain and this
  address: without it, a root from the wrong domain would lock the committed AGENTOS until the
  claim deadline.
  `build-tree.mjs` writes a ready-to-use `sample` into `tree.json`.
- `postponeClaimStart`: only before claims open, only later, never past `commit time + 30 days`.
  For the case where the liquidity is not in place on 12-31. Vesting and the claim deadline move
  with it.
- `claimDeadline()` = `claimStart + VESTING_DURATION (60 days) + CLAIM_GRACE (30 days)`:
  2027-03-31 00:00:00 UTC with the plan dates. It is derived, not set: the owner cannot choose it or
  bring it closer. `claim` works up to that second (inclusive) and reverts with `ClaimsExpired`
  after it, for good.
- `sweepExcess(to)`: everything above `outstanding()`. Before the root is committed that is the
  whole balance. Until the claim deadline `outstanding()` is `totalAllocation − totalClaimed`, so
  only the unused budget can leave. After the deadline `outstanding()` is zero and the same call
  returns **everything that was not claimed** to treasury.
- No pause, no upgrade.

## 4. Security model

### What the owner (Safe) can and cannot do

| Phase | Owner can | Owner cannot |
|---|---|---|
| Window open | pause new deposits, block addresses, set the rates and correct them until the cutoff (12-10), extend the deadline (bounded), cancel | touch deposits, stop withdrawals, change rates after the cutoff, shorten the window, take deposits above the cap |
| Closed, before release | attest any root, wait 24h, `release()` everything to itself, or cancel | release without rates + attestation + delay, release after the settlement deadline |
| After release | nothing in the vault | — |
| Distributor, before commit | withdraw all AGENTOS, commit any root | commit more than it holds or more than 5B |
| Distributor, after commit | sweep the excess, postpone claim start (bounded), rescue other tokens | change the root, pause or redirect claims, take committed AGENTOS, move the claim deadline earlier |
| Distributor, after the claim deadline | sweep everything that was not claimed | pay or reopen a claim |

**After the deadline, depositors trust the Safe.** A malicious or compromised Safe can attest any
root (even one that exists nowhere), wait 24h, release and keep the tokens. It can also empty the
distributor before committing, commit a root that pays itself, or state a `totalAllocation` lower
than the real sum and sweep the difference. No contract can prevent that without a trustless
bridge: "released only after the root is committed" and "funded with 5B before the window" are
**publicly checkable, not enforced**. The optional guardian is the only on-chain check on it.
What the contracts guarantee:

1. Until the deadline every depositor can leave, whatever the owner does.
2. Rates are on-chain, after any change depositors have at least 15 days to withdraw, and rates that
   are set cannot change after `RATE_CORRECTION_CUTOFF` (12-10 23:59:59), deadline extended or not.
3. Tokens cannot leave the vault before a root is attested and 24 hours have passed.
4. If the Safe goes silent, depositors get their tokens back after the settlement deadline.
5. Once committed, the claim root, the committed total and the vesting terms cannot change, and
   until `claimDeadline()` AGENTOS up to the committed total cannot be withdrawn by anyone but the
   claimants. The deadline is at least 90 days after claims open and the owner cannot shorten it.
   (Whether the committed total equals the sum of the tree is checked off-chain, see below.)
6. Once the rates are set, a new deposit cannot put the ledger above `MAX_DEPOSIT_ALLOCATION`.
   Rate corrections and off-chain long-lock allocations still require separate budget checks.

### Cross-chain

Base cannot read Robinhood. `attestClaimRoot` is the owner's public statement. During the 24h delay
anyone can check, on chain 4663 at `vault.attestedDistributor()`:

- `merkleRoot() == vault.claimRoot()`
- `totalAllocation() == vault.attestedTotalAllocation()`
- `TOKEN.balanceOf(distributor) ≥ outstanding()`
- `verify-tree.mjs` passes for the published `tree.json` with those on-chain values

`verify-tree.mjs` checks the published tree against the chain. To check the tree against the vault
ledger itself, re-run `build-claims.mjs` with the published inputs and compare `tree.csv` byte for
byte (see section 6).

### Guardian (optional)

Without a guardian, the 24h delay is transparency only: depositors can watch but cannot leave. With
`GUARDIAN` set (a second multisig with different signers), a wrong attestation can be vetoed and
everyone is refunded. The cost: a compromised guardian can cancel a correct migration after the
root is committed on Robinhood, which is the "double benefit" case below at the team's expense.
Decide before deploying, it is immutable.

### Known limits (accepted)

- **Double benefit on a late cancel.** If the root is already committed on Robinhood and the vault
  is then cancelled or times out, depositors get their tokens back *and* keep their AGENTOS claim.
  Only the team loses. Do not commit the root unless you will release.
- **`totalAllocation` is not provable on-chain.** If the committed total is lower than the real sum
  of the leaves, the last claimants revert with `AllocationExceeded` (and the owner could have swept
  the difference). If it is higher, the difference is reserved until the claim deadline and goes
  back to treasury then. Always pass the verifier's exact `totalAllocation` to `commitRoot`, and
  everyone should re-run the verifier with `--total` read from the chain.
- **The deposit cap covers the deposit path, not the long locks.** Deposits stop at
  `MAX_DEPOSIT_ALLOCATION` (4.20B). The long-lock allocations (~0.76B at the indicative rate) come
  on top and are only known when the tree is built: if `deposits × rate + long-locks` still
  exceeds `MAX_TOTAL_ALLOCATION`, `commitRoot` reverts. The 0.80B headroom is not a separate
  on-chain reservation. With ~40.9M locked DACKIE, it is exhausted at about 19.56 AGENTOS per DACKIE.
  Keep deposits paused until the opening snapshot and rate have been checked, then recheck at
  final list publication and after any rate correction. If more headroom is needed before opening,
  use a lower cap on a fresh vault. A rate correction can put existing deposits above the cap:
  new deposits then stop until withdrawals free room.
- **The deposit cap is first come, first served.** The rate is public for 30 days, so buying CAP
  from the pool to deposit can pay off, and that fills the cap for everyone else. A depositor can
  also fill it and withdraw late. An extension does not increase the cap; do not extend the
  window to address cap saturation. Watch `vault.totalDepositAllocation()` from 11-25.
- **Unclaimed airdrop CAP is excluded by its owners, not by the vault.** The airdrop owners must
  `adminWithdraw` the unclaimed CAP before the window opens. CAP claimed from them before that is
  ordinary wallet CAP and is eligible.
- **Release delay is 24h over a holiday.** `RELEASE_DELAY` is a deploy parameter (12h to 7 days).
- **Signers must be available until `settlementDeadline()`** (01-08 with the defaults). A missed
  release means refunds, and a double benefit if the root is already committed.
- **CAP tax.** CAP is a Virtuals AgentToken: 1% tax on transfers to or from flagged pools. Plain
  deposits and withdrawals are untaxed today (fork test). If CAP's owner (a third party) flags the
  vault as a pool, the vault stays solvent (it credits what arrived) but users lose the tax on the
  way in and out, and the Safe receives 1% less than the ledger at `release` (fork test).
- **Blocklist is advisory against fresh wallets.** A thief who moves tokens out of a leaked wallet
  first can deposit from a clean address. The blocklist stops deposits *from* and recipients *at*
  leaked addresses. Blocked accounts with an older deposit can still withdraw. The tree builder must
  exclude any depositor or recipient blocked at the deadline (manual verified path).
- **Recipient is not validated.** A contract wallet that names itself may not exist on Robinhood.
  `build-claims.mjs` warns about every depositor and long-locker that is a contract on Base and
  receives at its own address. Anyone can call `claim` for any account, so a leaf with a wrong
  recipient can be pushed there by a third party.
- **Claims expire.** After `claimDeadline()` (2027-03-31 00:00:00 UTC) a claim cannot be made any
  more, vested or not, and the Safe sweeps the rest to treasury. A claimant who took the first 20%
  and never came back loses the other 80%. Late claimants can only be paid by the treasury, by
  hand. Announce the date with the claim opening.
- **Rates set late are final at once.** If `setRates` is first called after 12-10 (deadline
  extended), there is no correction window. A wrong number then means `cancel()`.

### Hardening

Not upgradeable. `Ownable2Step`, `renounceOwnership` disabled. `ReentrancyGuard` on every function
that moves tokens. Balance-delta accounting on deposit. Double-hashed leaves bound to chain id and
contract address. Only `block.timestamp` (on Orbit, `block.number` is the L1 block). Exact compiler
pin (0.8.28), no via-IR, OpenZeppelin 5.4.0.

## 5. Tests

```bash
pnpm install            # off-chain tree tooling
pnpm run test:offchain  # claim-building rules + full settlement rehearsal on anvil
pnpm run setup          # forge-std + OpenZeppelin into lib/ (only on a fresh clone)
forge test              # unit, fuzz, invariant, end-to-end, off-chain tree cross-check
BASE_RPC_URL=https://mainnet.base.org forge test --match-path 'test/fork/*' -vv   # real CAP + DACKIE
FOUNDRY_PROFILE=ci forge test                                                     # deep fuzz
```

| File | What it proves |
|---|---|
| `test/MigrationVault.t.sol` | every function, every guard, every time boundary, fee-on-transfer and re-entrant tokens |
| `test/MerkleVestingDistributor.t.sol` | vesting curve, forged leaves, replay across deployments and chains, sweep limits, the claim deadline to the second and the return of unclaimed AGENTOS |
| `test/invariant/VaultInvariant.t.sol` | ledger adds up, vault solvent until release, owner cannot reach deposits, release is exact and final, no deposit above the cap, no rate change after the cutoff |
| `test/invariant/DistributorInvariant.t.sol` | always solvent, conservation, per-leaf bounds, commitment frozen, committed AGENTOS untouchable until the claim deadline |
| `test/MigrationFlow.t.sol` | the whole plan on its real dates up to the 2027-03-31 sweep of unclaimed AGENTOS, and the "Safe goes silent" refund |
| `test/OffchainTree.t.sol` | proofs from `offchain/build-tree.mjs` pay out on-chain |
| `test/DeployGuards.t.sol` | deploy scripts refuse an owner that is not a ≥2-signer Safe, the wrong chain, and the dry-run bypass flags on Base / Robinhood |
| `test/fork/BaseFork.t.sol` | real CAP and DACKIE on Base: exact deposit, withdraw, release, refund, and CAP's owner taxing the vault |

Mutation check (2026-11-16): 39 security guards were removed one at a time and the suite re-run.
All 39 mutants were caught. Repeat it after any change to `src/`.

Mutation check (2026-11-17), new guards only: 28 mutants on the claim deadline, the rate-correction
cutoff, the deposit cap, the deploy bypass flags and the off-chain tooling (guard removed, or
boundary moved by one second). All 28 were caught. The 39 mutants of 2026-11-16 were **not** re-run
after these changes.

## 6. Claim tree

Three steps, each one re-runnable by anyone:

```bash
# 1. Frozen vault ledger (Base) + long-lock snapshot -> tree.csv + claims-report.json
node offchain/build-claims.mjs --rpc <Base archive RPC> --vault <vault> --from-block <vault deploy block> \
  --longlock ../../docs/data/dackie-longlock-close-2026-12-25.csv --exclude <exclusion file | none> \
  --claim-start 1798675200 \
  --max-total 5000000000000000000000000000 --out-csv tree.csv --out-report claims-report.json

# 2. tree.csv -> tree.json (root, total, proofs, sample leaf for commitRoot)
node offchain/build-tree.mjs --input tree.csv --chain-id 4663 --distributor <address> \
  --claim-start 1798675200 --max-total 5000000000000000000000000000 --out tree.json

# 3. Check a published tree.json. Every flag is mandatory and must be read from the chain.
node offchain/verify-tree.mjs --tree tree.json --chain-id 4663 --distributor <address> \
  --root <distributor.merkleRoot()> --total <distributor.totalAllocation()>
```

`build-claims.mjs`:

- Reads everything at **one block**: the first Base block after the deposit deadline. Deposits,
  recipients, the blocklist and the rates are `eth_call`s at that block. Events are only used to
  discover who deposited.
- Aborts unless the discovered deposits add up to `totalDeposited` for both tokens (a missed event
  cannot silently drop a depositor) and unless every computed allocation equals
  `vault.allocationOf(account)`.
- Long-lock allocation = `lockedDackie × dackieRate / 1e18`. The snapshot CSV needs `address`,
  `lock_end_ts` and `dackie_wei` (exact) or `dackie` (decimal). The file in `docs/data` is the
  final baseline read at Base block 61,702,314 (2026-11-24 14:33 UTC).
- One position, one row. Two rows with the same `(address, lock_end_ts)` are refused whatever their
  `source` says: the same lock listed under two labels would be paid twice. If two real positions
  share a lock end, add a `position_id` column (the id from the pool / LP vault): every row then
  needs one and ids must be unique.
- Every leaf vests from claim open (decision #2). AGENTOS goes to the recipient registered in the
  vault, else the same address, and everything a recipient is owed is summed: **a wallet that
  deposits and also has a long lock gets one leaf and one claim.** In `claims-report.json` the
  deposit and each lock stay separate rows, so a wallet's leaf is the sum of its rows there.
  `--longlock-vesting` was removed and is refused.
- No leaf for: addresses in `--exclude`, accounts blocked at the freeze, accounts whose
  recipient is blocked (manual verified path), accounts that withdrew everything.
- `claims-report.json` lists every depositor and long-lock row with its status and amounts, the
  excluded totals, `claimDeadline`, and warnings: contracts that receive at their own address
  (depositors and long-lockers), excluded addresses with nothing to exclude, and everything the
  blocklist kept out of the tree with the AGENTOS owed on the manual path
  (`totals.excludedBlocked`). That amount is not in the tree: keep it in treasury. Publish the
  report with the tree.
- With `--max-total` (5B for this deployment), an over-budget run exits with code 2 **before writing anything**.
- The output is deterministic: the same inputs give a byte-identical `tree.csv`.

Not covered: the long-lock snapshot itself (the CSV is an input, produced from DackiePool and
DackieLPVault at the snapshot block). There is no LP-vault WETH compensation (decision #3).

Tests: `pnpm run test:offchain` (unit tests of the rules, plus a full rehearsal on a local anvil:
real vault → `build-claims` → `build-tree` → `verify-tree` → real `commitRoot` → every leaf claimed).

## 7. Deploy

Copy `env.example` to `.env` in this folder and fill it in (the deploy scripts read
`projects/migration/.env`, with `BASE_RPC_URL` and `ROBINHOOD_RPC_URL`). The Safe is the owner from
the first block, the deployer key only pays gas.

The deployer key lives in a Foundry keystore, never in `.env` or on the command line.
`DEPLOYER_ACCOUNT` is the keystore name, and forge asks for its password:

```bash
cast wallet import migration-deployer --interactive   # once
```

`ALLOW_EOA_OWNER` and `ALLOW_ANY_CHAIN` are for testnet dry runs. The scripts revert if either is
`true` on Base or Robinhood.

```bash
pnpm run deploy:distributor:robinhood
pnpm run deploy:vault:base
pnpm run blocklist:batches      # writes Safe Transaction Builder files, the Safe executes them
```

Checklist before announcing an address:

1. `owner()` is the Safe on **that** chain, `pendingOwner()` is zero.
2. Vault: `CAP`, `DACKIE`, `GUARDIAN` (zero: no guardian), `DEPOSIT_START`, `depositDeadline`,
   `MAX_DEPOSIT_DEADLINE`, `MIN_RATE_NOTICE`, `RATE_CORRECTION_CUTOFF` (1796947199 = 12-10
   23:59:59), `MAX_DEPOSIT_ALLOCATION` (4.20B), `RELEASE_DELAY`, `SETTLEMENT_GRACE` match the plan.
3. Distributor: `TOKEN` is AGENTOS, `MAX_TOTAL_ALLOCATION` is 5B. Fund it only after 1 and this.
4. Source verified on both explorers.
5. Blocklisted addresses set (`isBlocked`), spot-check a few from each batch.

Settlement checklist (12-26 → 12-29):

1. `build-claims.mjs` then `build-tree.mjs`. Read the warnings in `claims-report.json`. Publish
   `tree.csv`, `tree.json` and `claims-report.json`. Wait 48h.
2. `totalAllocation ≤ 5B`. `distributor` balance ≥ `totalAllocation`.
3. 404AI Labs's Safe Wallet on Robinhood: `commitRoot(root, totalAllocation, claimStart, sample…)` with the values and the
   `sample` from `tree.json`.
4. `verify-tree.mjs` passes with `--root` and `--total` read from the distributor.
5. 404AI Labs's Safe Wallet on Base: `attestClaimRoot(root, totalAllocation, distributor)`.
6. Wait `RELEASE_DELAY`. 404AI Labs's Safe Wallet on Base: `release()` and the sale. **Must be done before
   `settlementDeadline()`**, or the vault refunds.
7. 404AI Labs's Safe Wallet on Robinhood: `sweepExcess(treasury)`.
8. If the liquidity is late: `postponeClaimStart` before claims open (limit: commit + 30 days).
   The claim deadline moves with it: read `distributor.claimDeadline()` and announce that date.
9. After `claimDeadline()` (2027-03-31 00:00:00 UTC): 404AI Labs's Safe Wallet on Robinhood `sweepExcess(treasury)` returns
   what nobody claimed. Keep `totals.excludedBlocked` available in treasury for the manual path.
