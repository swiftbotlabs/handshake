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
create() { # rpc, contract, value, args...
  local rpc=$1 c=$2 v=$3; shift 3
  forge create --broadcast --rpc-url "$rpc" --private-key "$RX_TN_KEY" --value "$v" "$c" ${1:+--constructor-args "$@"} --json | python3 -I -c "import json,sys;l=[x for x in sys.stdin.read().splitlines() if 'deployedTo' in x];print(json.loads(l[-1])['deployedTo'])"
}

[ -n "$(get reactive)" ] || save reactive "$(create $LASNA src/HandshakeReactive.sol:HandshakeReactive ${RX_FUND:-1ether})"
[ -n "$(get jobs)" ] || save jobs "$(create $ETH_SEP src/demo/KeeperJobs.sol:KeeperJobs 0)"
[ -n "$(get escrow)" ] || save escrow "$(create $BASE_SEP src/HandshakeEscrow.sol:HandshakeEscrow ${ESC_FUND:-0.002ether} $BASE_SEP_PROXY $(get reactive))"
if [ "$(cast call --rpc-url $LASNA $(get reactive) 'escrow()(address)')" = "0x0000000000000000000000000000000000000000" ]; then
  cast send --rpc-url $LASNA --private-key "$RX_TN_KEY" "$(get reactive)" 'linkEscrow(uint256,address)' 84532 "$(get escrow)" --json \
    | python3 -I -c "import json,sys;print('linkEscrow tx', json.load(sys.stdin)['transactionHash'])"
fi
echo "done: $(cat $OUT | tr -d '\n ')"
