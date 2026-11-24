# Sourced by the deploy commands: env.example defaults, then the repository .env, then the names the scripts expect.
set -a; . ./env.example; . ../../.env; set +a
export OWNER="$SAFE_OWNER" ROBINHOOD_RPC_URL="$ROBINHOOD_DRPC_URL"
