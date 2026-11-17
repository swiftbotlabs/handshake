#!/usr/bin/env bash
# After a Sepolia ETH drip to the testnet deployer: Sepolia ETH -> lREACT (Reactive faucet), then top up the v4 reactive contract.
# Keeps 0.0005 Sepolia ETH and 0.01 lREACT on the deployer for gas. Testnet key only; prints hashes and balances only.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . /home/agent/agent/secrets/reactive_testnet.env; set +a
E=${ETH_SEP_RPC:-https://ethereum-sepolia-rpc.publicnode.com}; L=https://lasna-rpc.rnk.dev/
RX=$(python3 -I -c "import json;print(json.load(open('deployments.json'))['reactive'])")
wei() { cast balance --rpc-url "$1" "$2"; }
sep=$(wei $E $RX_TN_ADDR); keep=500000000000000
if [ "$sep" -gt $((keep + 1000000000000000)) ]; then
  amt=$((sep - keep))
  cast send --rpc-url $E --private-key "$RX_TN_KEY" 0x9b9BB25f1A81078C544C829c5EB7822d747Cf434 'request(address)' $RX_TN_ADDR --value $amt --json \
    | python3 -I -c "import json,sys;r=json.load(sys.stdin);print('faucet', r['transactionHash'], r['status'])"
  for i in $(seq 1 30); do [ "$(wei $L $RX_TN_ADDR)" -gt 50000000000000000 ] && break; sleep 5; done
fi
lr=$(wei $L $RX_TN_ADDR); send=$((lr - 10000000000000000))
[ "$send" -gt 0 ] || { echo "nothing to send (deployer lREACT $lr)"; exit 1; }
cast send --rpc-url $L --private-key "$RX_TN_KEY" --gas-price 100gwei $RX --value $send --json \
  | python3 -I -c "import json,sys;r=json.load(sys.stdin);print('topup', r['transactionHash'], r['status'])"
echo "v4 reactive $RX balance $(cast balance --ether --rpc-url $L $RX) lREACT"
