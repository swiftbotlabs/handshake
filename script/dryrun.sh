#!/usr/bin/env bash
# Reproduce one real Handshake loop WITHOUT SENDING ANYTHING (local forks in forge's in-memory EVM; no keys, no broadcast).
#   ./script/dryrun.sh <version> <bounty id> [proof tx]      e.g.  ./script/dryrun.sh v5 2      (Aave v3 Supply, stranger paid)
#                                                                  ./script/dryrun.sh v4 1 0x0f5ebe2d...  (front-runner: dropped)
# Picks the loop from evidence/triples.csv (rebuild it from chain with script/triples.py), re-reads every input from chain, then
# runs test/HandshakeReplay.t.sol: real escrow + origin logs -> local HandshakeReactive -> callback -> escrow on a Base Sepolia fork.
set -euo pipefail
cd "$(dirname "$0")/.."
VER=${1:?version, e.g. v5}; ID=${2:?bounty id}; PTX=${3:-}
[[ "$VER" =~ ^v[1-5]$ ]] || { echo "version must be v1..v5 (escrows on Base Sepolia)"; exit 2; }
[[ "$ID" =~ ^[0-9]{1,6}$ ]] || { echo "bounty id must be a number"; exit 2; }
[[ -z "$PTX" || "$PTX" =~ ^0x[0-9a-fA-F]{64}$ ]] || { echo "proof tx must be 0x + 64 hex"; exit 2; }
BASE=${BASE_SEP_RPC:-https://base-sepolia-rpc.publicnode.com}
ORIGIN=${ETH_SEP_RPC:-https://ethereum-sepolia-rpc.publicnode.com}
declare -A ESC=([v1]=0xb7B6a6E5Fc852FBcC5E62a0db92e0edb6429d769 [v2]=0x24F1134538a06a63AE49Ed9f3bFA47fabD67c802
  [v3]=0xf45D582Edbf7dB418b32C6cdA13D16ff57Cae7A2 [v4]=0x43eE856817a3Bac8EfcCaD54355b1de9C97aeAA5 [v5]=0x1cD6c715f1b5579161864361e275e250a11c8004)
row=$(python3 -I - "$VER" "$ID" "$PTX" <<'PY'
import csv, sys
ver, bid, ptx = sys.argv[1], sys.argv[2], sys.argv[3].lower()
rows = [r for r in csv.DictReader(open("evidence/triples.csv")) if r["version"] == ver and r["bounty"] == bid and r["proof_tx"]]
if ptx: rows = [r for r in rows if r["proof_tx"].lower() == ptx]
else: rows = [r for r in rows if r["outcome"] == "paid"] or rows
if not rows: sys.exit("no proof loop for that bounty in evidence/triples.csv")
r = rows[0]
print(r["outcome"], r["proof_tx"], r["post_tx"], r["callback_tx"] or "-")
PY
)
read -r OUTCOME PROOF POST CB <<<"$row"
[[ "$OUTCOME" == paid || "$OUTCOME" == ignored ]] || { echo "loop outcome '$OUTCOME' has no proof to replay"; exit 2; }
blk() { local i; for i in 1 2 3 4; do cast receipt --rpc-url "$1" "$2" blockNumber 2>/dev/null && return 0; sleep 2; done; return 1; }
POST_BLOCK=$(blk "$BASE" "$POST")
if [[ "$OUTCOME" == paid ]]; then FORK=$(( $(blk "$BASE" "$CB") - 1 )); EXPECT=true; else FORK=$POST_BLOCK; EXPECT=false; fi
# the proof transaction's logs + block time (public Sepolia nodes prune old state, so no origin fork; receipts are enough)
read -r PROOF_BLOCK PROOF_TS NLOGS PROOF_JSON < <(python3 -I - "$PROOF" "$ORIGIN" <<'PY'
import json, sys, time, urllib.request
tx, urls = sys.argv[1], [sys.argv[2], "https://1rpc.io/sepolia", "https://sepolia.gateway.tenderly.co"]
def call(m, p):
    for i in range(6):
        try:
            req = urllib.request.Request(urls[i % len(urls)], json.dumps({"jsonrpc": "2.0", "id": 1, "method": m, "params": p}).encode(),
                                         {"Content-Type": "application/json", "User-Agent": "handshake-dryrun"})
            r = json.loads(urllib.request.urlopen(req, timeout=30).read(8_000_000))
            if r.get("result"): return r["result"]
        except Exception: pass
        time.sleep(1 + i)
    sys.exit("could not read " + m)
rc = call("eth_getTransactionReceipt", [tx])
logs = [{"address": l["address"], "topics": l["topics"], "data": l["data"]} for l in rc["logs"]][:64]
ts = int(call("eth_getBlockByNumber", [rc["blockNumber"], False])["timestamp"], 16)
print(int(rc["blockNumber"], 16), ts, len(logs), json.dumps(logs, separators=(",", ":")))
PY
)
[[ "$NLOGS" =~ ^[0-9]+$ && "$NLOGS" -gt 0 ]] || { echo "proof transaction has no logs"; exit 3; }
echo "dry run $VER bounty $ID ($OUTCOME on chain): post block $POST_BLOCK, proof $PROOF (Sepolia block $PROOF_BLOCK), Base fork at $FORK"
echo "nothing is signed or sent: forge forks Base Sepolia in memory; the proof comes from its receipt"
HS_REPLAY=1 HS_ESCROW=${ESC[$VER]} HS_ID=$ID HS_PROOF_TX=$PROOF HS_ORIGIN_CHAIN=11155111 HS_PROOF_BLOCK=$PROOF_BLOCK \
HS_POST_BLOCK=$POST_BLOCK HS_FORK_BLOCK=$FORK HS_EXPECT_PAID=$EXPECT HS_BASE_RPC=$BASE \
HS_PROOF_TS=$PROOF_TS HS_PROOF_LOG_COUNT=$NLOGS HS_PROOF_LOGS_JSON=$PROOF_JSON \
  forge test --match-contract HandshakeReplay -vv
