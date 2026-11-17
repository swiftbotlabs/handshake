#!/usr/bin/env bash
# D) FRONT-RUN on chain: a restricted PROOF bounty pays only the allowed keeper. A second wallet ("bot", a fresh
#    testnet key we hold only for this test) does the same qualifying action first; the watcher logs ProofIgnored,
#    sends no callback, and the keeper's own action is paid. Proof source: the public WETH9 on Ethereum Sepolia.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . /home/agent/agent/secrets/reactive_testnet.env; . /home/agent/agent/secrets/reactive_keeper_testnet.env
. /home/agent/agent/secrets/reactive_bot_testnet.env; set +a
BASE_SEP=${BASE_SEP_RPC:-https://sepolia.base.org}; ETH_SEP=${ETH_SEP_RPC:-https://ethereum-sepolia-rpc.publicnode.com}
LASNA=https://lasna-rpc.rnk.dev/
d() { python3 -I -c "import json,sys;print(json.load(open('deployments.json'))[sys.argv[1]])" "$1"; }
ESC=$(d escrow); RX=$(d reactive); LOG=demo_log.md
tx() { python3 -I -c "import json,sys;r=json.load(sys.stdin);print(r['transactionHash'], r['status'])"; }
note() { echo "- $(date -u +%FT%TZ) $*" | tee -a $LOG; }
WETH=0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14
TD=$(cast keccak 'Deposit(address,uint256)')
MIN=${MIN:-50000000000000}      # 0.00005 ETH
AMT=${AMT:-0.00006ether}
DL=$(( $(date +%s) + 7200 ))
echo "" >> $LOG; echo "### v4 D) front-run test (escrow $ESC, reactive $RX)" >> $LOG
h=$(cast send --rpc-url $BASE_SEP --private-key "$RX_TN_KEY" $ESC \
  'postProofFor(string,uint256,(uint256,address,uint256,bool,uint256,uint8,uint256),address[])' \
  "Wrap >= 0.00005 ETH on Sepolia WETH (keeper only)" $DL "(11155111,$WETH,$TD,false,0,1,$MIN)" "[$RX_KEEPER_ADDR]" \
  --value 0.00012ether --json | tx)
note "v4 D1 postProofFor, allowlist = keeper $RX_KEEPER_ADDR (Base Sepolia) $h"
# wait until the watcher mirrored the allowlist and subscribed
for i in $(seq 1 40); do
  id=$(( $(cast call --rpc-url $BASE_SEP $ESC 'nextId()(uint256)') - 1 ))
  [ "$(cast call --rpc-url $LASNA $RX 'allowed(uint256,address)(bool)' $id $RX_KEEPER_ADDR)" = true ] && \
  [ "$(cast call --rpc-url $LASNA $RX 'keyRefs(bytes32)(uint256)' $(cast keccak $(cast abi-encode 'f(uint256,address,uint256,bool,uint256)' 11155111 $WETH $TD false 0)) )" != 0 ] && break
  sleep 6
done
note "v4 D2 watcher ready: Lasna allowed(id=$id, keeper)=true, WETH subscription live"
h=$(cast send --rpc-url $ETH_SEP --private-key "$RX_BOT_KEY" $WETH 'deposit()' --value $AMT --json | tx)
note "v4 D3 FRONT-RUNNER $RX_BOT_ADDR wraps first (Ethereum Sepolia) $h"
sleep ${GAP:-45}
h=$(cast send --rpc-url $ETH_SEP --private-key "$RX_KEEPER_KEY" $WETH 'deposit()' --value $AMT --json | tx)
note "v4 D4 keeper $RX_KEEPER_ADDR wraps (Ethereum Sepolia) $h"
echo "id=$id"
