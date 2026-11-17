#!/usr/bin/env bash
# Recompute proof-to-payout latency from CHAIN block timestamps (not from any log file's wall clock).
#   ./script/latency.sh <job tx on the origin chain> <reactive tx on Lasna> <payout tx on Base Sepolia>
set -euo pipefail
ETH_SEP=${ETH_SEP_RPC:-https://ethereum-sepolia-rpc.publicnode.com}; LASNA=https://lasna-rpc.rnk.dev/; BASE_SEP=${BASE_SEP_RPC:-https://base-sepolia-rpc.publicnode.com}
ts() { local rpc=$1 tx=$2; local bn; bn=$(cast receipt --rpc-url "$rpc" "$tx" blockNumber); echo "$bn $(cast block --rpc-url "$rpc" "$bn" -f timestamp)"; }
read -r b1 t1 < <(ts "$ETH_SEP" "$1"); read -r b2 t2 < <(ts "$LASNA" "$2"); read -r b3 t3 < <(ts "$BASE_SEP" "$3")
printf '%-34s block %-10s %s UTC\n' "job tx (Ethereum Sepolia)" "$b1" "$(date -u -d @"$t1" +%FT%T)"
printf '%-34s block %-10s %s UTC (+%ss)\n' "react() / ProofSeen (Lasna)" "$b2" "$(date -u -d @"$t2" +%FT%T)" "$((t2-t1))"
printf '%-34s block %-10s %s UTC (+%ss)\n' "BountyPaid callback (Base Sepolia)" "$b3" "$(date -u -d @"$t3" +%FT%T)" "$((t3-t1))"
