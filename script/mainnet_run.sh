#!/usr/bin/env bash
# Handshake on MAINNETS: reactive on Reactive mainnet (1597), escrow on Base (8453), one real bounty paid by a real protocol event:
# "first to supply USDC to Aave v3 on Base" (Supply.onBehalfOf = winner; ~6 USDC supplies/hour by strangers, measured 11-18).
#   script/mainnet_run.sh plan    : read-only checks + cost estimate (no key needed)
#   script/mainnet_run.sh deploy  : deploy + link + burn rate (needs HS_MAIN_KEY in /home/agent/agent/secrets/handshake_mainnet.env)
#   script/mainnet_run.sh bounty  : post the Aave bounty (value BOUNTY_ETH, default 0.0005) with a 6 h deadline, cron on
# Writes deployments-mainnet.json and appends hashes to demo_log.md. Prints addresses/hashes only, never the key.
set -euo pipefail
cd "$(dirname "$0")/.."
RN=https://mainnet-rpc.rnk.dev/; BASE=${BASE_RPC:-https://mainnet.base.org}
PROXY=0xCc780DdE33f56f55dE778D42c930959374a4a068          # Base callback proxy (dev.reactive.network/origins-and-destinations, 11-18)
POOL=0xA238Dd80C259a72e81d7e4664a9801593F98d1c5           # Aave v3 Pool on Base
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913           # USDC on Base
TS=$(cast keccak 'Supply(address,address,address,uint256,uint16)')
OUT=deployments-mainnet.json; [ -f $OUT ] || echo '{}' > $OUT
save() { python3 -I -c "import json,sys;d=json.load(open('$OUT'));d[sys.argv[1]]=sys.argv[2];json.dump(d,open('$OUT','w'),indent=1)" "$1" "$2"; echo "$1=$2"; }
get() { python3 -I -c "import json,sys;print(json.load(open('$OUT')).get(sys.argv[1],''))" "$1"; }
note() { echo "- $(date -u +%FT%TZ) MAINNET $*" | tee -a demo_log.md; }
case "${1:-plan}" in
plan)
  echo "Reactive mainnet block $(cast block-number --rpc-url $RN), gas price $(cast gas-price --rpc-url $RN) wei"
  echo "Base block $(cast block-number --rpc-url $BASE), gas price $(cast gas-price --rpc-url $BASE) wei; proxy code $(cast code --rpc-url $BASE $PROXY | head -c 12)..."
  echo "Aave pool provider $(cast call --rpc-url $BASE $POOL 'ADDRESSES_PROVIDER()(address)')"
  echo "Needs on the deployer: ~3 REACT on Reactive mainnet (deploy ~0.2 at 100 gwei, link ~0.02, then the contract's own float: 2 REACT"
  echo "  = ~2 days of idle cron + reactions) and ~0.002 ETH on Base (escrow deploy ~0.0001 at current gas + 0.0005 gas float + bounty)." ;;
deploy)
  set -a; . /home/agent/agent/secrets/handshake_mainnet.env; set +a
  ADDR=$(cast wallet address --private-key "$HS_MAIN_KEY"); echo "deployer $ADDR: $(cast balance --ether --rpc-url $RN $ADDR) REACT, $(cast balance --ether --rpc-url $BASE $ADDR) ETH on Base"
  [ -n "$(get reactive)" ] || save reactive "$(forge create --broadcast --rpc-url $RN --private-key "$HS_MAIN_KEY" --value ${RX_FUND:-2ether} --gas-price 100gwei --gas-limit 2400000 src/HandshakeReactive.sol:HandshakeReactive 2>&1 | awk '/Deployed to:/{print $3}')"
  [ -n "$(get escrow)" ] || save escrow "$(forge create --broadcast --rpc-url $BASE --private-key "$HS_MAIN_KEY" --value ${GAS_FLOOR:-500000000000000} src/HandshakeEscrow.sol:HandshakeEscrow --constructor-args $PROXY $(get reactive) ${MIN_BOUNTY:-100000000000000} ${POST_FEE:-20000000000000} 0x0000000000000000000000000000000000000000 ${GAS_FLOOR:-500000000000000} 2>&1 | awk '/Deployed to:/{print $3}')"
  if [ "$(cast call --rpc-url $RN $(get reactive) 'escrow()(address)')" = "0x0000000000000000000000000000000000000000" ]; then
    h=$(cast send --rpc-url $RN --private-key "$HS_MAIN_KEY" --gas-price 100gwei $(get reactive) 'linkEscrow(uint256,address)' 8453 $(get escrow) --json | python3 -I -c "import json,sys;print(json.load(sys.stdin)['transactionHash'])")
    note "linkEscrow (Reactive mainnet) $h"
    h=$(cast send --rpc-url $RN --private-key "$HS_MAIN_KEY" --gas-price 100gwei $(get reactive) 'setBurnRate(uint256,uint256,uint256)' 11200000000000000 1053 12500000000000000 --json | python3 -I -c "import json,sys;print(json.load(sys.stdin)['transactionHash'])")
    note "setBurnRate $h"
  fi
  note "deployed: reactive $(get reactive) (Reactive mainnet 1597), escrow $(get escrow) (Base 8453); fundedUntil $(cast call --rpc-url $RN $(get reactive) 'fundedUntil()(uint256)')" ;;
bounty)
  set -a; . /home/agent/agent/secrets/handshake_mainnet.env; set +a
  DL=$(( $(date +%s) + 6*3600 ))
  h=$(cast send --rpc-url $BASE --private-key "$HS_MAIN_KEY" $(get escrow) 'postProof(string,uint256,(uint256,address,uint256,bool,uint256,uint8,uint256))' \
      "First to supply USDC to Aave v3 on Base" $DL "(8453,$POOL,$TS,true,$(cast to-uint256 $USDC),2,0)" --value ${BOUNTY_ETH:-0.0005}ether --json \
      | python3 -I -c "import json,sys;r=json.load(sys.stdin);print(r['transactionHash'], r['status'])")
  note "postProof on Aave v3 Base (Supply reserve=USDC pinned, winner=onBehalfOf), ${BOUNTY_ETH:-0.0005} ETH incl. fee, deadline +6 h: $h" ;;
esac
