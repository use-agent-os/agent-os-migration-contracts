# CAP + DACKIE → AGENTOS Migration Plan — v1.0

> **v1.0 Release Specification — 2026-11-17.** Final release label for the specification previously identified as Draft v3.4 in the historical [audit reports](../audits); this relabeling does not represent a new audit. Open decisions 1–4, 6, 7 settled (§9). Rates published and set on-chain on 11-25 with Post #1. Includes **claim deadline 2027-03-31** (unclaimed AGENTOS returns to treasury, decision #8) and on-chain deposit cap (decision #9). On-chain numbers from 2026-11-15, indicative only. All dates UTC.

---

## 1. Summary

CAP and DACKIE (Base) merge into **AGENTOS** (Robinhood). One token for all three projects.

- **Migration window: Nov 25 → Dec 25, 2026 (1 month).** Deposit CAP / DACKIE into `MigrationVault` on Base. Withdraw any time before the deadline.
- **DACKIE long-lockers** (lock ends after Dec 25) don't deposit. Their locked amount at the snapshot is recorded.
- After the window, **404AI Labs's Safe Wallet** swaps the released CAP and DACKIE for ETH on Base, bridges the proceeds directly to the Safe on Robinhood, and adds AGENTOS/WETH liquidity (buy wall) **before** claims open.
- **Claims** on Robinhood at fixed rates. **Vesting: 20% at claim, 80% linear over 60 days.**
- **Claim by 2027-03-31 00:00 UTC** (30 days after vesting ends). After that, claims are closed and unclaimed AGENTOS goes back to treasury.
- **Budget: 5B AGENTOS (5% supply)** from treasury, refilled by team market buys. **No new AGENTOS minted.**

## 2. Contracts

| Item | Chain | Address |
|---|---|---|
| CAP | Base | `0xbfa733702305280F066D470afDFA784fA70e2649` |
| DACKIE | Base | `0x73326b4d0225c429bed050c11C4422d91470AaF4` |
| AGENTOS | Robinhood (4663) | `0x6eDA83Fc299C10d474068A7E69771c809Bcbbba3` |
| CAP/VIRTUAL Uni V2 (CAP sale route, LP locked to 2035) | Base | `0xC19fb7AF58B67a072Ce23362c2fb1d61ebE6d4CA` |
| DACKIE/WETH DackieSwap V3 1% (DACKIE sale route) | Base | `0x5D9C4aacF8Eba662BAf392b56ea6cE2A7D3584cE` |
| DACKIE/WETH DackieSwap V2 (DACKIE sale route) | Base | `0xf6f60d084D5D5D4dd448F18d094bc66669623310` |
| AGENTOS/WETH Uni v4 (ETH destination) | Robinhood | pool id `0x1299aa8c…401a` |
| sCAP ScapStaking (7d unbond) | Base | `0x92ee42A61CF55642949B4fE74bB4796978ddB47a` |
| stCAP (max 2 weeks) | Base | `0xff66dff30a8ddda7e1e11541d21e8eccac026973` |
| DackiePool (lock ≤365d) | Base | `0xF6C5b5Df9Bcee40cd474CCd6373f99b56dBCF5E5` |
| DackieFlexiblePool | Base | `0x5cB90378614631b3d1BAcEDDce6bC09E508B5b95` |
| DackieLPVault (LP lock ≤730d) | Base | `0x645D25cC63578096eDbE941CB9EE56D20dA5fC98` |

New (build + audit before Nov 25):
- **`MigrationVault`** (Base): `deposit(token, amount, robinhoodRecipient)`, withdraw until deadline, refund if cancelled or not released by 01-08. Tokens are released directly to the Base Safe for sale only after the claim root is committed on Robinhood, attested on Base, and 24h have passed since the attestation. Deposits stop once they would convert to more than approximately 4.20B AGENTOS (the remaining approximately 0.80B of the 5B budget is reserved for long-locks).
- **`MerkleVestingDistributor`** (Robinhood): holds AGENTOS, pays claims from a Merkle root with vesting. Funded with the full 5B **before the window opens**. Root is locked once committed. Claims close 30 days after vesting ends: until then nobody but the claimants can take committed AGENTOS, after it 404AI Labs's Safe Wallet returns the unclaimed rest to treasury.
- **404AI Labs's Safe Wallet** (multisig, both chains): owns both contracts and commits and attests the claim root. The Base Safe executes swaps and initiates the bridge; the Robinhood Safe receives the ETH directly, adds liquidity, and holds the LP position.

## 3. Timeline

| Date | Step |
|---|---|
| now → 11-24 | Build + audit contracts, set up Safe, fund distributor with 5B |
| 11-18 → 11-25 | **Baseline window** (7-day TWAP for rates). No team trading or MM on CAP / DACKIE / AGENTOS |
| **11-25** | **Post #1 + rates + window opens.** Rates computed from the baseline TWAP and set on-chain (`setRates`) the same day. Snapshot = first Base block at 11-25 00:00 (freezes DACKIE long-lock list, draft published) |
| 11-25 → 12-07 | Community feedback (deposits open, withdrawable). Rates can only be corrected for an error, never renegotiated |
| **12-10** | **Post #2**: final long-lock list, participation update. **Last moment the contract accepts a rate correction (23:59:59)**: after it, rates are fixed and depositors keep 15 days to withdraw |
| **12-25 23:59:59** | **Window closes** |
| 12-26 → 12-28 | Freeze → publish `tree.csv` (48h review) → commit root on Robinhood |
| 12-29 | Release to the Base Safe after the 24h attestation delay; Safe swaps CAP + DACKIE |
| 12-29 → 12-30 | Base Safe bridges ETH directly to the Robinhood Safe, which adds AGENTOS/WETH liquidity |
| **12-31** | **Claims open** |
| **2027-03-01** | Vesting ends (claims open + 60 days) |
| **2027-03-31 00:00** | **Claim deadline** (vesting end + 30 days). Claims close for good. Unclaimed AGENTOS, vested or not, returns to treasury |

If claims open later than 12-31, vesting end and the claim deadline move by the same number of days.

Staker deadlines: stCAP turn off auto-renew by **12-10**. sCAP `initiateUnstake` by **12-17** (locked sCAP: unstake CAPU by **12-16**). DackiePool locks ending ≤ 12-25 must withdraw and deposit (e.g. `0x8BA0…` 12-17, `0x2D2E…` 12-13, `0x4b4B…` 12-14, `0x4c24…` 12-17).

## 4. Who does what

**CAP** (no automatic recording, must deposit):

| Position | Steps |
|---|---|
| Wallet | Deposit |
| sCAP unlocked | `initiateUnstake` → 7d → `finalizeUnstake` → deposit |
| sCAP locked by CAPU | Unstake CAPU (1d) → `burnAndUnlockScap` → unstake sCAP (7d) → deposit |
| stCAP | Auto-renew off → maturity (≤2w) → withdraw → deposit |
| CAP/CAPU Aerodrome LP | Remove LP → deposit |
| CAP/VIRTUAL locked LP (2035) | Not eligible |

**DACKIE**:

| Position | Steps |
|---|---|
| Wallet / FlexiblePool / DackiePool unlocked or lock ≤ 12-25 | Withdraw → deposit |
| DackieLPVault unlocked / expired | Withdraw → deposit the DACKIE side (keep ETH) |
| **Long lock** (DackiePool or LPVault, `lockEnd` at snapshot > 12-25 23:59:59) | **Nothing.** Snapshot amount recorded |

Long-lock rules: amount = locked DackiePool position, or LPVault `lockedLiquidity` converted to DACKIE at snapshot price. Anything added / extended after the snapshot doesn't count. No compensation for the WETH side of LPVault positions. Long-lock AGENTOS is claimed in the same round as everyone else and vests the same way (from claim open), with the same claim deadline. A wallet that deposits and also has a long lock gets one combined claim. List is final in Post #2 (now ~36 wallets, ~40.9M DACKIE; draft: `docs/data/dackie-longlock-close-2026-12-25.csv`).

**Recipient**: EOAs receive at the same address on Robinhood. Contract wallets call `registerRecipient` on Base.

**Excluded / special**: unclaimed CAP in the Merkle airdrops `0x9edc…` (75.9M) and `0xee2a…` (11.5M) is **not eligible**: their owners withdraw it (`adminWithdraw`) before the window opens.

## 5. Rates and budget

- **Rate** = token TWAP / AGENTOS TWAP over the baseline window. **Pure TWAP, no premium.** Sources: CAP/VIRTUAL V2 × VIRTUAL/USD, DACKIE/WETH DackieSwap V3, AGENTOS/WETH v4.
- **Indicative** (11-15 spot): 1 CAP ≈ 25.5 AGENTOS, 1 DACKIE ≈ 18.5 AGENTOS. **Final rates published in Post #1 (11-25)** and set on-chain the same day, so everyone knows the rate before depositing. The contract allows a correction (wrong number, not a renegotiation) until 12-10 23:59:59, then locks them.
- **Vesting** (fixed): 20% at claim open + 80% linear over 60 days. Same schedule for long-lock claims.
- **Claim deadline** (fixed in the contract): vesting end + 30 days = 2027-03-31 00:00 UTC. Whatever is not claimed by then, including the remaining 80% of someone who only took the first 20%, returns to treasury.
- **Budget: 5B AGENTOS (5% supply)**, all funded into the distributor before the window opens.
- **Deposit cap: 4.20B AGENTOS**, enforced on new deposits once rates are set. First come, first served; a withdrawal frees room. This leaves 0.80B of headroom for long-locks (~0.76B at the indicative rate).- **Before opening deposits**, confirm the snapshot and published DACKIE rate leave enough room for long-locks plus a safety buffer. If not, keep deposits closed and use a lower immutable cap. Recheck against the final long-lock list and after any rate correction; a correction can put existing deposits above the cap. Before committing the root, verify the sum of the claim allocations is at most 5B.

| Group (100% participation, pre-change estimate; not achievable under the 5B ceiling) | Amount | AGENTOS |
|---|---|---|
| CAP external (wallets 153.9M + sCAP 69.3M + stCAP 23.3M) | 246.5M | 6.28B |
| DACKIE deposit path | 56.6M | 1.05B |
| DACKIE long-lock | 40.9M | 0.76B |
| **Total external** | | **8.09B** |
| **Budget** | | **5B (5% supply)** |

The old 100% participation estimate is not achievable under the 5B ceiling. The 4.20B deposit cap is first come, first served; the final tree must include deposits and long-locks within 5B. Funded from treasury (~30B liquid), refilled by disclosed team TWAP buys from Post #1 on (none in the baseline window). Unused AGENTOS goes back to treasury in two steps: the budget that was never allocated right after the root is committed (12-28), and the allocations nobody claimed after the claim deadline (2027-03-31).

## 6. Settlement

1. **Freeze** 12-25 23:59:59.
2. **Claim list** (deposits × rate + long-locks × rate) → public 48h → **commit root** on Robinhood. Before any token leaves the vault.
3. **Release and swap from the Base Safe.** Attest the Robinhood root and allocation on Base, then wait 24h before releasing CAP and DACKIE from the vault directly to the Base Safe. The Safe executes the swaps itself (one Safe tx per token, private RPC, min-output guard):
   - CAP → VIRTUAL (V2, 1% tax + 0.3% fee) → WETH (Aerodrome).
   - DACKIE → WETH (DackieSwap V3 1% + V2).
4. **Bridge ETH directly from the Base Safe to the Robinhood Safe** with **Across V5** (test this Safe-to-Safe route with a small amount first). No intermediary wallet receives the CAP, DACKIE, or ETH proceeds.
5. **Add liquidity from the Robinhood Safe**: single-sided ETH in AGENTOS/WETH, spot → −50% (buy wall). The Robinhood Safe holds the LP position.
6. **Open claims.** Publish every tx hash.
7. **Close claims** 2027-03-31 00:00 UTC. The Safe sweeps the unclaimed AGENTOS to treasury.

Expected ETH (11-15 reserves, may change when migration open; sale-proceeds scenarios retained from the market estimate, not claim-participation limits under the 5B budget):

| External participation | CAP sold | ETH from CAP | ETH from DACKIE |
|---|---|---|---|
| 25% | 89.9M | 2.66 | 0.30 |
| 50% | 151.5M | 3.73 | 0.45 |
| 75% | 213.1M | 4.49 | 0.53 |
| 100% | 274.8M | 5.06 | 0.59 |

CAP ceiling ~9.2 ETH (all VIRTUAL in the pool). After the sale, CAP falls ~66–81% and DACKIE ~77–90%.

## 7. For AGENTOS holders

- **More products, one token.** Capminal and DackieSwap now capture value for AGENTOS. Every product the team runs feeds the same token.
- **Liquidity first, tokens later.** ETH from the CAP and DACKIE sale is added as an AGENTOS buy wall **before** any claim opens.
- **Vesting.** Migrated AGENTOS unlocks 20% at claim, the remaining 80% linearly over 60 days.
- **No mint, fixed budget.** Payouts come from the existing treasury, max 5% of supply. Unused and unclaimed tokens go back to treasury (claims close 2027-03-31).
- **Team buys AGENTOS.** The treasury is refilled with public market buys: real buy pressure, disclosed tx by tx.
- **More holders.** The CAP and DACKIE communities join AGENTOS (raw count: ~1,250 CAP and ~420 DACKIE wallets with ≥1,000 tokens, vs ~1,450 AGENTOS holders today).
- **Full team focus.** Dev, marketing and liquidity go to one token on Robinhood instead of three.
- **Sale proceeds fund AGENTOS liquidity.** The Safe adds the ETH proceeds from swapping CAP and DACKIE. Existing locked LP positions, including CAP/VIRTUAL LP locked until 2035, are not moved or unlocked.

## 8. Admin before the window opens

| Action | Contract | Who |
|---|---|---|
| `overdueFee` = 0 | DackiePool `0xF6C5…` | `0xe158…` |
| Do **not** pause DackiePool / LPVault | — | team |
| `adminWithdraw` all unclaimed CAP | Airdrop `0x9edc…` | `0xd290…` (EOA) |
| `adminWithdraw` all unclaimed CAP | Airdrop `0xee2a…` | `0x81F7…` (EOA) |
| Optional `setAdminUnlocked(true)` | stCAP `0xff66…` | `0x81F7…` (to confirm) |
| Keep CAPU `mintPaused` | ScapStaking | `0x231c…` |

Comms: Post #1 (11-25, with rates **and the 2027-03-31 claim deadline**), Post #2 (12-10, final long-lock list), reminders 12-10 (stCAP) / 12-17 (sCAP) / 12-23 (48h left) / 12-26 (claim list) / 12-31 (claims open) / 2027-03-01 (vesting ended, 30 days left to claim) / 2027-03-24 (7 days left). Direct outreach to ~20 long-lockers >1,000 DACKIE and large stakers (e.g. `0x8BA0…`: 27.85M DACKIE + 8.12M sCAP).

## 9. Risks and open decisions

| Risk | Mitigation |
|---|---|
| **Build + audit + funding in 8 days** (window opens 11-25) | Reuse the Surplus repo design. If the audit isn't done, open late rather than unaudited |
| Rate arbitrage for 30 days: with the rate fixed on 11-25, anyone can buy CAP / DACKIE when it trades below rate × AGENTOS price and deposit it (~210M CAP sits in the CAP/VIRTUAL pool) | After rates are set, the vault refuses new deposits above 4.20B AGENTOS (decision #9). The cap is first come, first served: watch `vault.totalDepositAllocation()` daily; arbitrage deposits can crowd holders out |
| Rate set wrong on 11-25 | Correctable until 12-10 23:59:59, a date fixed in the contract: extending the deadline does not reopen it. Every signer checks the calldata against the published numbers |
| Holder misses the claim deadline (2027-03-31) | Date announced in Post #1 and at claim open, reminders on 03-01 and 03-24. Anyone can trigger a claim for any wallet (tokens go to that wallet). After the deadline only a manual treasury payment is possible |
| Cross-chain trust | Pre-fund the distributor, commit and lock the root before selling, attest on Base with a 24h release delay, and publish the Safe-executed settlement transaction hashes |
| Rate manipulation | Baseline window ends before announcement. No team trading / MM in it |
| Snapshot gaming | Snapshot in the past at announcement. `lockEnd` read at snapshot |
| **DACKIE sale takes WETH from long-lock LPs** (99.8% of the V3 pool is DackieLPVault, ~96% locked) | Accepted, no compensation (decision #3) |
| Holders sell before settlement | Clear comms. One atomic sale tx per token with min-output |
| MEV | Private RPC, min-output, one tx per token |
| AGENTOS sell pressure | Vesting + buy wall + team buys |
| Holiday window (Christmas) | Reminders, direct outreach to large holders |
| Leaked keys | Blocklist + manual path |
| **Locked sCAP without the CAPU to unlock it** (2026-11-16): 16 wallets, **~28.04M CAP** (top 3: 9.53M, 9.33M, 5.05M). They miss 62.6 CAPU, mint is paused, and only ~55.6 CAPU sit in pools (WETH/CAPU 36.6, CAPU/CAP 4.8, other 14.2). List: `docs/data/scap-locked-without-capu-2026-11-16.csv` | Contact. Optional ScapStaking upgrade (decision #5) |
| Contract bugs | Audit, invariant tests, fork rehearsal, refund path |

Decisions (2026-11-16):
1. Rate: **pure TWAP**, no premium.
2. Long-lock vesting: **from claim open**, same round and same schedule as every other claim. Long-lockers keep their locked DACKIE and receive AGENTOS from 12-31.
3. DackieLPVault long-lockers: **no WETH compensation**.
4. CAP Merkle airdrops `0x9edc…` / `0xee2a…`: **not eligible**. Owners `adminWithdraw` the unclaimed CAP before 11-25.
5. Locked sCAP without CAPU: **open**. 16 wallets, ~28.04M CAP (risk table above).
6. DACKIE emissions after snapshot: **no action**. They never count: long-lock amounts are read at the snapshot.
7. Bridge route: **Across V5** (ETH Base → Robinhood route live on 2026-11-16).

Decisions (2026-11-17):

8. Unclaimed AGENTOS: **returns to treasury after a claim deadline** = vesting end + 30 days (2027-03-31 00:00 UTC). Fixed in the contract, the team cannot bring it closer. Replaces "claimable for ever".
9. Budget protection: **on-chain deposit cap of 4.20B AGENTOS** in the vault, reserving approximately 0.80B of the 5B budget for long-locks instead of relying on daily monitoring and `pause()`.
10. Trust model: 404AI Labs's Safe Wallet is trusted. **No independent guardian**, no on-chain cross-chain proof (public attestation + 24h delay only).
