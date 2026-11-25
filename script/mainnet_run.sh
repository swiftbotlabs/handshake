#!/usr/bin/env bash
# Handshake on MAINNETS: reactive on Reactive mainnet (1597), escrow on Base (8453), one real bounty paid by a real protocol event:
# "first to supply USDC to Aave v3 on Base" (Supply.onBehalfOf = winner; ~6 USDC supplies/hour by strangers, measured 11-18).
#   script/mainnet_run.sh plan    : read-only checks + cost estimate (no key needed)
#   script/mainnet_run.sh deploy  : deploy + link + burn rate (needs HS_MAIN_KEY in /home/agent/agent/secrets/handshake_mainnet.env)
#   script/mainnet_run.sh bounty  : post the Aave bounty (value BOUNTY_ETH, default 0.0005) with a 6 h deadline, cron on
#   script/mainnet_run.sh bounty-usdc : the same bounty paid in USDC (BOUNTY_USDC_UNITS, default 1 USDC): the planned live mode
# Writes deployments-mainnet.json and appends hashes to demo_log.md. Prints addresses/hashes only, never the key.
set -euo pipefail
cd "$(dirname "$0")/.."
RN=https://mainnet-rpc.rnk.dev/; BASE=${BASE_RPC:-https://mainnet.base.org}
LOG=demo_log.md; OUT=deployments-mainnet.json
# Rehearsal on local forks (script/mainnet_rehearse.sh): both RPCs must be 127.0.0.1, the key comes from the caller (an anvil
# test key), and nothing touches deployments-mainnet.json or demo_log.md.
if [ "${HS_REHEARSAL:-0}" = 1 ]; then
  RN=${RN_RPC:?}; BASE=${BASE_RPC:?}
  case "$RN$BASE" in http://127.0.0.1:*http://127.0.0.1:*) ;; *) echo "rehearsal needs 127.0.0.1 RPCs"; exit 2;; esac
  [ "$(cast chain-id --rpc-url $RN)" = 1597 ] && [ "$(cast chain-id --rpc-url $BASE)" = 8453 ] || { echo "forks are not 1597/8453"; exit 2; }
  LOG=${REHEARSAL_LOG:?}; OUT=${REHEARSAL_OUT:?}
fi
loadkey() { if [ "${HS_REHEARSAL:-0}" = 1 ]; then : "${HS_MAIN_KEY:?}"; else set -a; . /home/agent/agent/secrets/handshake_mainnet.env; set +a; HS_MAIN_KEY=${HS_MAIN_KEY:-${HANDSHAKE_MAINNET_PK:?no mainnet key}}; fi; }
PROXY=0xCc780DdE33f56f55dE778D42c930959374a4a068          # Base callback proxy (dev.reactive.network/origins-and-destinations, 11-18)
POOL=0xA238Dd80C259a72e81d7e4664a9801593F98d1c5           # Aave v3 Pool on Base
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913           # USDC on Base
TS=$(cast keccak 'Supply(address,address,address,uint256,uint16)')
[ -f $OUT ] || echo '{}' > $OUT
save() { [[ "$2" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "STOP: $1 deploy failed (no address); nothing saved"; exit 3; }
  python3 -I -c "import json,sys;d=json.load(open('$OUT'));d[sys.argv[1]]=sys.argv[2];json.dump(d,open('$OUT','w'),indent=1)" "$1" "$2"; echo "$1=$2"; }
get() { python3 -I -c "import json,sys;print(json.load(open('$OUT')).get(sys.argv[1],''))" "$1"; }
note() { echo "- $(date -u +%FT%TZ) MAINNET${HS_REHEARSAL:+ REHEARSAL} $*" | tee -a "$LOG"; }
case "${1:-plan}" in
plan)
  echo "Reactive mainnet block $(cast block-number --rpc-url $RN), gas price $(cast gas-price --rpc-url $RN) wei"
  echo "Base block $(cast block-number --rpc-url $BASE), gas price $(cast gas-price --rpc-url $BASE) wei; proxy code $(cast code --rpc-url $BASE $PROXY | head -c 12)..."
  echo "Aave pool provider $(cast call --rpc-url $BASE $POOL 'ADDRESSES_PROVIDER()(address)')"
  echo "Needs on the deployer: ~3 REACT on Reactive mainnet (deploy ~0.2 at 100 gwei, link ~0.02, then the contract's own float: 2 REACT"
  echo "  = ~2 days of idle cron + reactions) and ~0.002 ETH on Base (escrow deploy ~0.0001 at current gas + 0.0005 gas float + bounty)." ;;
deploy)
  loadkey
  ADDR=$(cast wallet address --private-key "$HS_MAIN_KEY"); echo "deployer $ADDR: $(cast balance --ether --rpc-url $RN $ADDR) REACT, $(cast balance --ether --rpc-url $BASE $ADDR) ETH on Base"
  [ -n "$(get reactive)" ] || save reactive "$(forge create --broadcast --rpc-url $RN --private-key "$HS_MAIN_KEY" --value ${RX_FUND:-5ether} --gas-price 100gwei --gas-limit 4000000 src/HandshakeReactive.sol:HandshakeReactive 2>&1 | awk '/Deployed to:/{print $3}')"
  [ -n "$(get escrow)" ] || save escrow "$(forge create --broadcast --rpc-url $BASE --private-key "$HS_MAIN_KEY" --value ${GAS_FLOOR:-500000000000000} src/HandshakeEscrow.sol:HandshakeEscrow --constructor-args $PROXY $(get reactive) ${MIN_BOUNTY:-100000000000000} ${POST_FEE:-20000000000000} 0x0000000000000000000000000000000000000000 ${GAS_FLOOR:-500000000000000} 2>&1 | awk '/Deployed to:/{print $3}')"
  if [ "$(cast call --rpc-url $RN $(get reactive) 'escrow()(address)')" = "0x0000000000000000000000000000000000000000" ]; then
    h=$(cast send --rpc-url $RN --private-key "$HS_MAIN_KEY" --gas-price 100gwei $(get reactive) 'linkEscrow(uint256,address)' 8453 $(get escrow) --json | python3 -I -c "import json,sys;print(json.load(sys.stdin)['transactionHash'])")
    note "linkEscrow (Reactive mainnet) $h"
    h=$(cast send --rpc-url $RN --private-key "$HS_MAIN_KEY" --gas-price 100gwei $(get reactive) 'setBurnRate(uint256,uint256,uint256)' ${COST_TICK:-21600000000000000} 1053 ${COST_EVENT:-23100000000000000} --json | python3 -I -c "import json,sys;print(json.load(sys.stdin)['transactionHash'])")
    note "setBurnRate $h"
  fi
  note "deployed: reactive $(get reactive) (Reactive mainnet 1597), escrow $(get escrow) (Base 8453); fundedUntil $(cast call --rpc-url $RN $(get reactive) 'fundedUntil()(uint256)')" ;;
bounty)
  loadkey
  DL=$(( $(date +%s) + 6*3600 ))
  h=$(cast send --rpc-url $BASE --private-key "$HS_MAIN_KEY" $(get escrow) 'postProof(string,uint256,(uint256,address,uint256,bool,uint256,uint8,uint256))' \
      "First to supply USDC to Aave v3 on Base" $DL "(8453,$POOL,$TS,true,$(cast to-uint256 $USDC),2,0)" --value ${BOUNTY_ETH:-0.0005}ether --json \
      | python3 -I -c "import json,sys;r=json.load(sys.stdin);print(r['transactionHash'], r['status'])")
  note "postProof on Aave v3 Base (Supply reserve=USDC pinned, winner=onBehalfOf), ${BOUNTY_ETH:-0.0005} ETH incl. fee, deadline +6 h: $h" ;;
bounty-usdc)
  # (mainnet burn rates above: Reactive's documented fee max(gas price, base fee) x (gas used + 100,000) at 100 gwei, i.e. a 116k-gas tick
  #  = 0.0216 REACT and a 131k-gas proof = 0.0231 REACT; Lasna billed less (0.0112 per tick), so these are the conservative side.)
  # The default for the live run: pay the bounty in USDC. Many Aave suppliers on Base are smart contracts (vaults, routers) that
  # refuse plain ETH, so an ETH payout to them reverts and the bounty waits; an ERC-20 transfer to a contract always lands.
  loadkey
  DL=$(( $(date +%s) + 6*3600 )); AMT=${BOUNTY_USDC_UNITS:-1000000}   # 1 USDC
  # runway gate: the watcher must stay funded past the deadline + 1 h even with this bounty's subscription at its full event cap
  python3 -I - "$(cast balance --rpc-url $RN $(get reactive))" "$(cast call --rpc-url $RN $(get reactive) 'burnPerPeriod()(uint256,uint256)' | awk '{print $1}' | tr '\n' ' ')" \
    "$(cast call --rpc-url $RN $(get reactive) 'maxEventsPerWindow()(uint256)' | awk '{print $1}')" "$(cast call --rpc-url $RN $(get reactive) 'costPerEvent()(uint256)' | awk '{print $1}')" \
    "$(cast call --rpc-url $RN $(get reactive) 'eventWindow()(uint256)' | awk '{print $1}')" "$DL" <<'PY' || { echo "STOP: watcher not funded past the deadline; top up REACT first"; exit 4; }
import sys, time
bal = int(sys.argv[1]); burn, period = map(int, sys.argv[2].split()); cap, ce, win, dl = map(int, sys.argv[3:7])
burn += (cap + 1) * ce * period // win
until = int(time.time()) + (bal // burn) * period
print(f"runway with this bounty open: until {time.strftime('%Y-%m-%d %H:%M:%SZ', time.gmtime(until))}, deadline {time.strftime('%Y-%m-%d %H:%M:%SZ', time.gmtime(dl))}")
sys.exit(0 if until > dl + 3600 else 1)
PY
  FEE=$(cast call --rpc-url $BASE $(get escrow) 'postFee()(uint256)' | awk '{print $1}')
  h=$(cast send --rpc-url $BASE --private-key "$HS_MAIN_KEY" $USDC 'approve(address,uint256)' $(get escrow) $AMT --json | python3 -I -c "import json,sys;r=json.load(sys.stdin);print(r['transactionHash'], r['status'])")
  note "USDC approve $AMT to the escrow: $h"
  h=$(cast send --rpc-url $BASE --private-key "$HS_MAIN_KEY" $(get escrow) 'postProofToken(string,uint256,(uint256,address,uint256,bool,uint256,uint8,uint256),address,uint256)' \
      "First to supply USDC to Aave v3 on Base" $DL "(8453,$POOL,$TS,true,$(cast to-uint256 $USDC),2,0)" $USDC $AMT --value $FEE --json \
      | python3 -I -c "import json,sys;r=json.load(sys.stdin);print(r['transactionHash'], r['status'])")
  note "postProofToken on Aave v3 Base (Supply reserve=USDC pinned, winner=onBehalfOf), $AMT USDC units, fee $FEE wei, deadline +6 h: $h" ;;
esac
