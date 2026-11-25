#!/usr/bin/env bash
# Deploy Handshake on testnets: reactive on Lasna, escrow on Base Sepolia, demo job board on Ethereum Sepolia.
# Reads the testnet-only key from secrets/reactive_testnet.env; prints addresses only. Writes deployments.json as it goes.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . /home/agent/agent/secrets/reactive_testnet.env; set +a
LASNA=https://lasna-rpc.rnk.dev/
BASE_SEP=${BASE_SEP_RPC:-https://sepolia.base.org}
ETH_SEP=${ETH_SEP_RPC:-https://ethereum-sepolia-rpc.publicnode.com}
BASE_SEP_PROXY=0x476F44b11F5C942c58f4c8E3d0300E5710743585
OUT=deployments.json
[ -f "$OUT" ] || echo '{}' > "$OUT"
save() { python3 -I -c "import json,sys;d=json.load(open('$OUT'));d[sys.argv[1]]=sys.argv[2];json.dump(d,open('$OUT','w'),indent=1)" "$1" "$2"; echo "$1=$2"; }
get() { python3 -I -c "import json,sys;print(json.load(open('$OUT')).get(sys.argv[1],''))" "$1"; }
create() { # rpc, contract, value (wei or Nether), args...  (plain output; the --json shape changed between forge versions)
  local rpc=$1 c=$2 v=$3; shift 3
  local gp=""; [ "$rpc" = "$LASNA" ] && gp="--gas-price 100gwei --gas-limit 2300000"
  forge create --broadcast --rpc-url "$rpc" --private-key "$RX_TN_KEY" --value "$v" $gp "$c" ${1:+--constructor-args "$@"} 2>&1 | awk '/Deployed to:/{print $3}'
}

[ -n "$(get reactive)" ] || save reactive "$(create $LASNA src/HandshakeReactive.sol:HandshakeReactive ${RX_FUND:-1ether})"
[ -n "$(get jobs)" ] || save jobs "$(create $ETH_SEP src/demo/KeeperJobs.sol:KeeperJobs 0)"
# Fees -> REACT: Reactive's faucet contract on Base Sepolia (dev.reactive.network/reactive-mainnet, read 2026-11-17) credits lREACT to
# the reactive contract; GAS_FLOOR (wei) is the callback-gas float the escrow keeps (= ESC_FUND, so only fees are ever swept).
REACT_FUNDER=${REACT_FUNDER:-0x2afaFD298b23b62760711756088F75B7409f5967}
GAS_FLOOR=${GAS_FLOOR:-1000000000000000}
[ -n "$(get escrow)" ] || save escrow "$(create $BASE_SEP src/HandshakeEscrow.sol:HandshakeEscrow ${GAS_FLOOR} $BASE_SEP_PROXY $(get reactive) ${MIN_BOUNTY:-100000000000000} ${POST_FEE:-20000000000000} $REACT_FUNDER $GAS_FLOOR)"
if [ "$(cast call --rpc-url $LASNA $(get reactive) 'escrow()(address)')" = "0x0000000000000000000000000000000000000000" ]; then
  cast send --rpc-url $LASNA --private-key "$RX_TN_KEY" --gas-price 100gwei "$(get reactive)" 'linkEscrow(uint256,address)' 84532 "$(get escrow)" --json \
    | python3 -I -c "import json,sys;print('linkEscrow tx', json.load(sys.stdin)['transactionHash'])"
fi
[ "$(cast call --rpc-url $LASNA $(get reactive) 'costPerTick()(uint256)')" != 0 ] || \
  cast send --rpc-url $LASNA --private-key "$RX_TN_KEY" --gas-price 100gwei "$(get reactive)" 'setBurnRate(uint256,uint256,uint256)' 11200000000000000 1053 12500000000000000 --json \
    | python3 -I -c "import json,sys;print('setBurnRate tx', json.load(sys.stdin)['transactionHash'])"
echo "done: $(cat $OUT | tr -d '\n ')"
