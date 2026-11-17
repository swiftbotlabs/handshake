#!/usr/bin/env bash
# Poll the escrow's BountyPaid / BountyRefunded logs on Base Sepolia from a start block; print each once. Read-only.
#   ./script/watch_events.sh <escrow> <from block> <expected count> [max minutes]
ESC=$1; FROM=$2; WANT=$3; MAXM=${4:-60}; R=${BASE_SEP_RPC:-https://base-sepolia-rpc.publicnode.com}
P=$(cast keccak 'BountyPaid(uint256,address,uint256,uint8,bytes32)'); F=$(cast keccak 'BountyRefunded(uint256,address,uint256,uint8)')
seen=""; n=0; end=$(( $(date +%s) + MAXM*60 )); cur=$FROM
while [ "$(date +%s)" -lt "$end" ]; do
  N=$(cast block-number --rpc-url $R 2>/dev/null) || { sleep 20; continue; }
  while [ "$cur" -le "$N" ]; do
    to=$(( cur+199 < N ? cur+199 : N ))
    out=$(cast rpc --rpc-url $R eth_getLogs "{\"address\":\"$ESC\",\"topics\":[[\"$P\",\"$F\"]],\"fromBlock\":\"$(printf '0x%x' $cur)\",\"toBlock\":\"$(printf '0x%x' $to)\"}" 2>/dev/null) || break
    while read -r line; do
      [ -z "$line" ] && continue; case " $seen " in *" $line "*) continue;; esac
      seen="$seen $line"; n=$((n+1)); echo "$(date -u +%T) $line"
    done < <(echo "$out" | python3 -c "
import json,sys
P='$P';F='$F'
for l in json.load(sys.stdin):
    kind='PAID' if l['topics'][0]==P else 'REFUNDED'
    print(kind+'|id='+str(int(l['topics'][1],16))+'|to=0x'+l['topics'][2][-40:]+'|block='+str(int(l['blockNumber'],16))+'|tx='+l['transactionHash'])")
    cur=$((to+1))
  done
  [ "$n" -ge "$WANT" ] && exit 0
  sleep 20
done
echo "TIMEOUT after $MAXM min with $n of $WANT events"
