#!/usr/bin/env bash
# Post ONE open proof bounty on the v5 escrow (Base Sepolia TESTNET only) for any outside claimant:
#   "Open to anyone: run job <JOB> on the Sepolia job board" - paid to whoever runs KeeperJobs.run(<JOB>, work>=1) on Ethereum Sepolia.
# The proof is pinned to one job id (topic1), so it matches at most one event: no per-event REACT drain (see evidence/EVIDENCE.md).
#   ./script/open_bounty.sh --check      read-only: all pre-flight checks + an eth_call simulation of the post; sends nothing
#   ./script/open_bounty.sh --send       the same checks, then one cast send (needs secrets/reactive_testnet.env), then read-back
# Env overrides: JOB (default 4244), DEADLINE (unix, default 1796677200 = 2026-12-07 21:00Z), REWARD_WEI (default 0.0005 ETH).
set -euo pipefail
cd "$(dirname "$0")/.."
MODE=${1:-}; [[ "$MODE" == --check || "$MODE" == --send ]] || { sed -n 2,8p "$0"; exit 2; }
BASE=${BASE_SEP_RPC:-https://base-sepolia-rpc.publicnode.com}; LASNA=https://lasna-rpc.rnk.dev/
SEP=${ETH_SEP_RPC:-https://1rpc.io/sepolia}
ESC=0x1cD6c715f1b5579161864361e275e250a11c8004; RX=0xD27824e127D8615e7e24218f3F9DF163901253D0
JOBS=0xc964f01ed8087f51b6DD1F6434bd268176Fbf212; SYS=0x0000000000000000000000000000000000fffFfF
JOB=${JOB:-4244}; DEADLINE=${DEADLINE:-1796677200}; REWARD_WEI=${REWARD_WEI:-500000000000000}
MIN_DEADLINE=1796504400 # 2026-12-05 21:00Z: the bounty must still be open when the buildathon closes (12-05 20:00Z)
fail() { echo "CHECK FAILED: $*"; exit 3; }
[[ "$JOB" =~ ^[0-9]{1,12}$ && "$DEADLINE" =~ ^[0-9]{10}$ && "$REWARD_WEI" =~ ^[0-9]{1,24}$ ]] || fail "bad JOB/DEADLINE/REWARD_WEI"

# 1. right chains, right contracts (testnet only)
[[ $(cast chain-id --rpc-url "$BASE") == 84532 ]] || fail "settlement RPC is not Base Sepolia (84532)"
[[ $(cast chain-id --rpc-url "$LASNA") == 5318007 ]] || fail "Reactive RPC is not Lasna (5318007)"
[[ $(cast chain-id --rpc-url "$SEP") == 11155111 ]] || fail "origin RPC is not Ethereum Sepolia"
[[ $(python3 -I -c "import json;print(json.load(open('deployments.json'))['escrow'].lower())") == "${ESC,,}" ]] || fail "deployments.json escrow is not v5"
[[ $(cast call --rpc-url "$BASE" $ESC "_CALLBACK_SENDER()(address)") == "$RX" ]] || fail "escrow is not linked to the v5 reactive contract"
# 2. deadline after the close, and inside the escrow's 365-day window
NOW=$(date -u +%s)
(( DEADLINE > MIN_DEADLINE )) || fail "deadline $(date -u -d @"$DEADLINE" +%FT%TZ) is not after 2026-12-05 21:00Z"
(( DEADLINE < NOW + 30*86400 )) || fail "deadline more than 30 days out"
# 3. the job is still free on the Sepolia job board (else anyone could not win it)
[[ $(cast call --rpc-url "$SEP" $JOBS "done(uint256)(bool)" "$JOB") == false ]] || fail "job $JOB already run"
# 4. cron funded check: the watcher must stay funded past the deadline, cron on, no debt
FU=$(cast call --rpc-url "$LASNA" $RX "fundedUntil()(uint256)" | awk '{print $1}')
[[ ${#FU} -lt 20 ]] || fail "cron is OFF (fundedUntil = max): refunds would need the public expire()"
(( FU > DEADLINE + 86400 )) || fail "watcher funded only until $(date -u -d @"$FU" +%FT%TZ), need deadline + 1 day; top up REACT first"
DEBT=$(cast call --rpc-url "$LASNA" $SYS "debt(address)(uint256)" $RX | awk '{print $1}')
[[ "$DEBT" == 0 ]] || fail "reactive contract has debt $DEBT wei: coverDebt() first"
RXBAL=$(cast balance --rpc-url "$LASNA" $RX --ether)
FEE=$(cast call --rpc-url "$BASE" $ESC "postFee()(uint256)" | awk '{print $1}')
VALUE=$(( REWARD_WEI + FEE ))
TOPIC0=$(cast keccak 'JobRun(uint256,address,uint256)')
TITLE="Open to anyone: run job $JOB on the Sepolia job board"
COND="(11155111,$JOBS,$TOPIC0,true,$JOB,2,1)" # chain, emitter, JobRun, pin topic1 = job, winner = topic2 (keeper), work >= 1
SIG='postProof(string,uint256,(uint256,address,uint256,bool,uint256,uint8,uint256))'
echo "checks OK: job $JOB free; deadline $(date -u -d @"$DEADLINE" +%FT%TZ); watcher $RXBAL lREACT, funded until $(date -u -d @"$FU" +%FT%TZ), debt 0"
echo "post: '$TITLE', reward $REWARD_WEI wei + fee $FEE wei = value $VALUE wei, condition $COND"

set -a; . /home/agent/agent/secrets/reactive_testnet.env; set +a
[[ "$RX_TN_ADDR" =~ ^0x[0-9a-fA-F]{40}$ ]] || fail "no issuer address"
BAL=$(cast balance --rpc-url "$BASE" "$RX_TN_ADDR")
(( BAL > VALUE + 20000000000000 )) || fail "issuer has $BAL wei on Base Sepolia, not enough for value + gas"
# 5. simulate the exact call (eth_call, nothing sent): returns the new bounty id
SIM=$(cast call --rpc-url "$BASE" --from "$RX_TN_ADDR" --value "$VALUE" $ESC "${SIG}(uint256)" "$TITLE" "$DEADLINE" "$COND" | awk '{print $1}')
NEXT=$(cast call --rpc-url "$BASE" $ESC "nextId()(uint256)" | awk '{print $1}')
[[ "$SIM" == "$NEXT" ]] || fail "simulation returned id $SIM, expected nextId $NEXT"
echo "simulation OK: the post would create v5 bounty #$SIM"
[[ "$MODE" == --send ]] || { echo "--check only: nothing sent"; exit 0; }

# 6. send once, then read back from chain (no retries: on any error read the state before doing anything else)
OUT=$(cast send --rpc-url "$BASE" --private-key "$RX_TN_KEY" --value "$VALUE" $ESC "$SIG" "$TITLE" "$DEADLINE" "$COND" --json)
read -r TX ST < <(python3 -I -c "import json,sys;r=json.load(sys.stdin);print(r['transactionHash'],r['status'])" <<<"$OUT")
echo "- $(date -u +%FT%TZ) v5 O3 OPEN bounty for an outside claimant: postProof '$TITLE' (pinned topic1, work>=1), $REWARD_WEI wei, deadline $(date -u -d @"$DEADLINE" +%FT%TZ), Base Sepolia $TX $ST" | tee -a demo_log.md
[[ "$ST" == 0x1 ]] || fail "post tx status $ST: read the escrow state before anything else"
B=$(cast call --rpc-url "$BASE" $ESC "bounties(uint256)(address,uint96,uint8,uint8,uint256,address,string)" "$SIM")
echo "read-back escrow bounty #$SIM: $(echo "$B" | tr '\n' ' ')"
for i in $(seq 1 20); do  # the watcher mirrors it within a block or two
  W=$(cast call --rpc-url "$LASNA" $RX "watches(uint256)(uint256,uint256,bool,bool)" "$SIM" 2>/dev/null | tr '\n' ' ' || true)
  [[ "$W" == *true* ]] && { echo "read-back Lasna watcher: watches($SIM) = $W"; break; }
  sleep 15
done
[[ "${W:-}" == *true* ]] || echo "WARNING: Lasna watcher has not mirrored bounty #$SIM after 5 min; check reactscan before anything else"
