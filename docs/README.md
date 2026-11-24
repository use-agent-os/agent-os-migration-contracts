# Migration docs

Migration planning material, first copied from the `market-maker` working folder on 2026-11-16 (its
commit `6459ff3`). **This folder is now the source.** The plan here is v1.0 (formerly Draft v3.4; decisions settled, claim
deadline and deposit cap added); the copy in `market-maker` is v3.1 and out of date.

| File | What it is | Used by |
|---|---|---|
| [`migration_plan.md`](migration_plan.md) | The release plan, v1.0 (English). **The specification the contracts implement.** Historical audit reports refer to its prior Draft v3.4 label; the release relabeling is not a new audit. See [`audits/`](../audits). | everything in `projects/migration` |
| [`data/dackie-longlock-close-2026-12-25.csv`](data/dackie-longlock-close-2026-12-25.csv) | **Final** DACKIE long-lock baseline, read at Base block 61,702,314 (2026-11-24 14:33 UTC): 42 positions, 36 wallets, 41,167,439.84 DACKIE with `lockEnd` after 2026-12-25 | `offchain/build-claims.mjs --longlock`, `offchain/check-longlock.mjs` |
| [`data/capu-stakers-2026-11-24.csv`](data/capu-stakers-2026-11-24.csv) | **Final** CAPU staker baseline, read at Base block 61,702,826 (2026-11-24 14:35 UTC): every address with CAPU staked or in cooldown in the Capu contract (19 addresses, `totalStakedCapu` = 19.9153 CAPU), with its ScapStaking lock and whether it can unlock it all | decision #5, outreach |

## Re-checking the baseline

Both scripts are read-only and live in `projects/migration/offchain`. They need RPCs that serve logs and
historical state; `BASE_DRPC_URL` and `ROBINHOOD_DRPC_URL` in the repository `.env` work.

```sh
cd projects/migration
# long-lock list now vs the baseline csv: new / removed positions, changed lock ends, changed amounts
node offchain/check-longlock.mjs --rpc "$BASE_DRPC_URL" [--out current.csv]
# baseline TWAP rates (CAP -> AGENTOS, DACKIE -> AGENTOS) from 11-18 00:00 UTC to now, capped at 11-25 00:00
node offchain/twap-rates.mjs --base-rpc "$BASE_DRPC_URL" --rh-rpc "$ROBINHOOD_DRPC_URL" [--out-csv samples.csv]
```
