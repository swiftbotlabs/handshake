#!/usr/bin/env bash
# v5 runs, logged to demo_log.md (hashes; chain block times are recomputed by latency.sh / the README tables):
#  R) UNATTENDED REFUND: a judged bounty with a 20-min deadline, nobody touches it; the Cron1000 watcher refunds the issuer.
#  F) FEES -> REACT: posting fees above the gas floor go to Reactive's Base Sepolia faucet for the watcher (anyone can call).
#  P) REAL PROTOCOL: "first to supply WBTC to Aave v3 on Sepolia" - the winner is whichever stranger does it (Supply.onBehalfOf).
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . /home/agent/agent/secrets/reactive_testnet.env; set +a
BASE_SEP=${BASE_SEP_RPC:-https://sepolia.base.org}; LASNA=https://lasna-rpc.rnk.dev/
d() { python3 -I -c "import json,sys;print(json.load(open('deployments.json'))[sys.argv[1]])" "$1"; }
ESC=$(d escrow); RX=$(d reactive); LOG=demo_log.md
tx() { python3 -I -c "import json,sys;r=json.load(sys.stdin);print(r['transactionHash'], r['status'])"; }
note() { echo "- $(date -u +%FT%TZ) $*" | tee -a $LOG; }
grep -q "### v5 (escrow $ESC" $LOG || { echo "" >> $LOG; echo "### v5 (escrow $ESC, reactive $RX)" >> $LOG; }
case "${1:-all}" in all|R)
  h=$(cast send --rpc-url $BASE_SEP --private-key "$RX_TN_KEY" $ESC 'postJudged(string,uint256)' "Unattended refund test (v5): nobody will claim this" \
      $(( $(date +%s) + 1200 )) --value 0.00012ether --json | tx)
  note "v5 R1 postJudged, deadline +20 min, no claim, no cancel: expect BountyRefunded via=1 from the cron $h" ;;
esac
case "${1:-all}" in all|P)
  POOL=0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951; WBTC=0x29f2d40b0605204364af54ec677bd022da425d03
  TS=$(cast keccak 'Supply(address,address,address,uint256,uint16)')
  h=$(cast send --rpc-url $BASE_SEP --private-key "$RX_TN_KEY" $ESC 'postProof(string,uint256,(uint256,address,uint256,bool,uint256,uint8,uint256))' \
      "First to supply WBTC to Aave v3 on Sepolia" $(( $(date +%s) + 6*3600 )) "(11155111,$POOL,$TS,true,$(cast to-uint256 $WBTC),2,0)" \
      --value 0.00012ether --json | tx)
  note "v5 P1 postProof on Aave v3 (Sepolia Pool $POOL): Supply(reserve=WBTC pinned, onBehalfOf=winner) $h" ;;
esac
case "${1:-all}" in all|F)
  before=$(cast balance --rpc-url $LASNA $RX)
  h=$(cast send --rpc-url $BASE_SEP --private-key "$RX_TN_KEY" $ESC 'fundReactive()' --json | tx)
  note "v5 F1 fundReactive() (fees above the gas floor -> Reactive faucet -> watcher) $h; watcher balance before $before wei" ;;
esac
