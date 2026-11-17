#!/usr/bin/env bash
# Turn Sepolia ETH (from a free faucet) into the two testnet gases Handshake needs. Testnet key only; prints tx hashes.
#   ./fund.sh lreact 0.02   -> Lasna lREACT via Reactive's faucet contract on Ethereum Sepolia (1 ETH = 100 lREACT)
#   ./fund.sh base 0.01     -> Base Sepolia ETH via Base's L1StandardBridge on Ethereum Sepolia (arrives in ~1-3 min)
set -euo pipefail
set -a; . /home/agent/agent/secrets/reactive_testnet.env; set +a
ETH_SEP=${ETH_SEP_RPC:-https://ethereum-sepolia-rpc.publicnode.com}
REACT_FAUCET=0x9b9BB25f1A81078C544C829c5EB7822d747Cf434   # dev.reactive.network/reactive-mainnet (read 2026-11-17)
BASE_L1_BRIDGE=0xfd0Bf71F60660E2f608ed56e1659C450eB113120 # docs.base.org base-contracts, Sepolia L1StandardBridge (read 2026-11-17)
amt=${2:?amount in ETH}
case "$1" in
  lreact) cast send --rpc-url "$ETH_SEP" --private-key "$RX_TN_KEY" $REACT_FAUCET 'request(address)' "$RX_TN_ADDR" --value "${amt}ether" --json ;;
  base)   cast send --rpc-url "$ETH_SEP" --private-key "$RX_TN_KEY" $BASE_L1_BRIDGE 'depositETH(uint32,bytes)' 200000 0x --value "${amt}ether" --json ;;
  *) echo "usage: fund.sh lreact|base <eth>"; exit 2 ;;
esac | python3 -I -c "import json,sys;r=json.load(sys.stdin);print(r['transactionHash'], 'status', r['status'])"
