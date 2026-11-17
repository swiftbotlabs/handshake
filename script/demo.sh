#!/usr/bin/env bash
# End-to-end proof on testnets, logged to demo_log.md (tx hashes for the submission):
#  A) PROOF bounty: post on Base Sepolia -> a keeper runs job N on Ethereum Sepolia -> Reactive pays the keeper on Base Sepolia.
#  B) DEADLINE: post a judged bounty with a 20-min deadline -> nobody accepts -> Cron1000 refunds the issuer by itself.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . /home/agent/agent/secrets/reactive_testnet.env; [ -f /home/agent/agent/secrets/reactive_keeper_testnet.env ] && . /home/agent/agent/secrets/reactive_keeper_testnet.env; set +a
BASE_SEP=${BASE_SEP_RPC:-https://sepolia.base.org}; ETH_SEP=${ETH_SEP_RPC:-https://ethereum-sepolia-rpc.publicnode.com}
d() { python3 -I -c "import json,sys;print(json.load(open('deployments.json'))[sys.argv[1]])" "$1"; }
ESC=$(d escrow); JOBS=$(d jobs); LOG=demo_log.md
tx() { python3 -I -c "import json,sys;r=json.load(sys.stdin);print(r['transactionHash'])"; }
note() { echo "- $(date -u +%FT%TZ) $*" | tee -a $LOG; }
JOB=${JOB:-$(date +%s)}
KEEPER=${RX_KEEPER_ADDR:-$RX_TN_ADDR}; KEEPER_KEY=${RX_KEEPER_KEY:-$RX_TN_KEY}
T0=$(cast keccak 'JobRun(uint256,address,uint256)')
DL=$(( $(date +%s) + 3600 ))
h=$(cast send --rpc-url $BASE_SEP --private-key "$RX_TN_KEY" $ESC 'postProof(string,uint256,(uint256,address,uint256,bool,uint256,uint8,uint256))' \
   "Run job $JOB on Sepolia" $DL "(11155111,$JOBS,$T0,true,$JOB,2,3)" --value 0.0005ether --json | tx)
note "A1 postProof job=$JOB (Base Sepolia) $h"
sleep 60
h=$(cast send --rpc-url $ETH_SEP --private-key "$KEEPER_KEY" $JOBS 'run(uint256,uint256)' $JOB 5 --json | tx)
note "A2 keeper $KEEPER (not the issuer) runs job $JOB (Ethereum Sepolia) $h"
note "A3 wait for BountyPaid on Base Sepolia (Reactive callback): check $ESC events"
DL2=$(( $(date +%s) + 1200 ))
h=$(cast send --rpc-url $BASE_SEP --private-key "$RX_TN_KEY" $ESC 'postJudged(string,uint256)' "Unclaimed demo bounty" $DL2 --value 0.0003ether --json | tx)
note "B1 postJudged, deadline +20 min (Base Sepolia) $h; expect BountyRefunded via=1 within ~40 min"
