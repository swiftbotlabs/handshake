#!/usr/bin/env bash
# Rehearse script/mainnet_run.sh on LOCAL FORKS of Reactive mainnet (1597) and Base (8453). Nothing is signed for a real chain:
# both forks run on 127.0.0.1 and the key is anvil's public test key #0. It runs the real deploy + bounty steps, then plays the
# callback a real Aave v3 USDC Supply on Base would trigger (impersonating Base's callback proxy) and checks the payout.
# It also measures what the live run will cost: gas used per step x live gas prices x live prices (CoinGecko) -> USD.
# Output: evidence/mainnet-rehearsal.md (+ .json). Exit 0 only if every step passed.
set -euo pipefail
cd "$(dirname "$0")/.."
RN_UP=https://mainnet-rpc.rnk.dev/; BASE_UP=${BASE_UP:-https://mainnet.base.org}; BASE_LOGS=${BASE_LOGS:-https://base-rpc.publicnode.com}  # logs: publicnode (recent ranges); fork: base.org (archive reads)
PROXY=0xCc780DdE33f56f55dE778D42c930959374a4a068
POOL=0xA238Dd80C259a72e81d7e4664a9801593F98d1c5
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
TS=$(cast keccak 'Supply(address,address,address,uint256,uint16)')
W=$(mktemp -d "${TMPDIR:-/tmp}/hs-reh.XXXXXX")
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$W"; }
trap cleanup EXIT
fail() { echo "REHEARSAL FAILED: $*"; exit 1; }

# live numbers first (read-only)
RN_GP=$(cast gas-price --rpc-url $RN_UP); BASE_GP=$(cast gas-price --rpc-url $BASE_UP)
PRICES=$(curl -fsS --max-time 20 'https://api.coingecko.com/api/v3/simple/price?ids=ethereum,reactive-network&vs_currencies=usd')
ETH_USD=$(python3 -I -c "import json,sys;print(json.loads(sys.argv[1])['ethereum']['usd'])" "$PRICES")
REACT_USD=$(python3 -I -c "import json,sys;print(json.loads(sys.argv[1])['reactive-network']['usd'])" "$PRICES")
# event rate the cap must absorb: USDC Supply logs on the Aave v3 Base pool over the last ~1 h (1800 blocks at 2 s)
BN=$(cast block-number --rpc-url $BASE_LOGS)
cast logs --rpc-url $BASE_LOGS --from-block $((BN-1800)) --to-block $BN --address $POOL "$TS" "$(cast to-uint256 $USDC)" --json > "$W/supply.json" \
  || fail "could not read Supply logs"
read -r NSUP WINNER PROOFTX < <(python3 -I -c "
import json,sys
L=json.load(open(sys.argv[1]))
if not L: print(0,'-','-'); sys.exit()
l=L[-1]; print(len(L), '0x'+l['topics'][2][-40:], l['transactionHash'])" "$W/supply.json")
[ "$NSUP" -gt 0 ] || fail "no USDC Supply on Aave v3 Base in the last hour: cannot pick a real winner (and the bounty would wait)"
echo "live: Reactive gas $RN_GP wei, Base gas $BASE_GP wei, ETH \$$ETH_USD, REACT \$$REACT_USD; USDC supplies last hour: $NSUP (cap 10/h); latest $PROOFTX by $WINNER"

# forks (pinned to the current head)
anvil --silent --port 8561 --chain-id 1597 --fork-url $RN_UP >"$W/rn.log" 2>&1 & PIDS+=($!)
anvil --silent --port 8562 --chain-id 8453 --fork-url $BASE_UP >"$W/base.log" 2>&1 & PIDS+=($!)
for p in 8561 8562; do for i in $(seq 60); do cast chain-id --rpc-url http://127.0.0.1:$p >/dev/null 2>&1 && break; sleep 1; done; done
export HS_REHEARSAL=1 RN_RPC=http://127.0.0.1:8561 BASE_RPC=http://127.0.0.1:8562 REHEARSAL_LOG="$W/log.md" REHEARSAL_OUT="$W/dep.json"
export HS_MAIN_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # anvil test key #0 (public)
ME=$(cast wallet address --private-key $HS_MAIN_KEY)

./script/mainnet_run.sh deploy | tee "$W/deploy.out"
RX=$(python3 -I -c "import json,sys;print(json.load(open(sys.argv[1]))['reactive'])" "$W/dep.json")
ESC=$(python3 -I -c "import json,sys;print(json.load(open(sys.argv[1]))['escrow'])" "$W/dep.json")
[ ${#RX} = 42 ] && [ ${#ESC} = 42 ] || fail "deploy did not produce both addresses"
[ "$(cast call --rpc-url $RN_RPC $RX 'escrow()(address)')" = "$ESC" ] || fail "reactive not linked to the escrow"
[ "$(cast call --rpc-url $RN_RPC $RX 'cronOn()(bool)')" = true ] || fail "cron not on"
FU=$(cast call --rpc-url $RN_RPC $RX 'fundedUntil()(uint256)' | awk '{print $1}')
# give the test key 5 USDC on the fork (FiatToken v2.2: balances live in mapping slot 9), then post the USDC bounty
SLOT=$(cast index address $ME 9)
cast rpc --rpc-url $BASE_RPC anvil_setStorageAt $USDC $SLOT 0x$(printf '%064x' 5000000) >/dev/null
[ "$(cast call --rpc-url $BASE_RPC $USDC 'balanceOf(address)(uint256)' $ME | awk '{print $1}')" = 5000000 ] || fail "could not fund the test key with USDC"
./script/mainnet_run.sh bounty-usdc | tee "$W/bounty.out"
grep -qE ' (true|0x1)$' "$W/bounty.out" || fail "postProof did not succeed"
ID=$(( $(cast call --rpc-url $BASE_RPC $ESC 'nextId()(uint256)' | awk '{print $1}') - 1 ))
LIVEKEYS=$(cast call --rpc-url $RN_RPC $RX 'liveKeys()(uint256)' | awk '{print $1}')   # 0 on the fork: the RVM never runs here
FU2=$(cast call --rpc-url $RN_RPC $RX 'fundedUntil()(uint256)' | awk '{print $1}')

# the callback the network would deliver for that real Supply
cast rpc --rpc-url $BASE_RPC anvil_impersonateAccount $PROXY >/dev/null
cast rpc --rpc-url $BASE_RPC anvil_setBalance $PROXY 0xDE0B6B3A7640000 >/dev/null
bal() { cast call --rpc-url $BASE_RPC $USDC 'balanceOf(address)(uint256)' $1 | awk '{print $1}'; }
WCODE=$(cast code --rpc-url $BASE_RPC $WINNER | wc -c); WKIND=$([ "$WCODE" -gt 3 ] && echo contract || echo EOA)
BEFORE=$(bal $WINNER)
cast send --rpc-url $BASE_RPC --unlocked --from $PROXY $ESC 'settleProof(address,uint256,address,bytes32)' $RX $ID $WINNER $PROOFTX --json > "$W/settle.json"
AFTER=$(bal $WINNER)
PAID=$(python3 -I -c "print($AFTER-$BEFORE)")
ST=$(cast call --rpc-url $BASE_RPC $ESC 'bounties(uint256)(address,uint96,uint8,uint8,uint256,address,string)' $ID | sed -n 4p)
[ "$ST" = 2 ] && [ "$PAID" -gt 0 ] || fail "settleProof did not pay (status $ST, paid $PAID)"
# a forged callback (not the proxy) must not pay: positive control
if cast send --rpc-url $BASE_RPC --private-key $HS_MAIN_KEY $ESC 'settleProof(address,uint256,address,bytes32)' $RX $ID $ME $PROOFTX >/dev/null 2>&1; then
  fail "a callback from a non-proxy sender was accepted"; fi

# gas actually used per step, from the fork receipts
python3 -I - "$W" "$RN_GP" "$BASE_GP" "$ETH_USD" "$REACT_USD" "$RX" "$ESC" "$ID" "$PAID" "$WINNER" "$PROOFTX" "$NSUP" "$FU" "$FU2" "$LIVEKEYS" "$WKIND" <<'PY'
import json, subprocess, sys, re, datetime
w, rn_gp, base_gp, eth, react, rx, esc, bid, paid, winner, ptx, nsup, fu, fu2, lk, wkind = sys.argv[1:]
rn_gp, base_gp, eth, react = int(rn_gp), int(base_gp), float(eth), float(react)
def blocks(rpc):
    out = []
    n = int(subprocess.check_output(["cast", "block-number", "--rpc-url", rpc]).strip())
    return n
def rpcj(rpc, method, *params):
    return json.loads(subprocess.check_output(["cast", "rpc", "--rpc-url", rpc, method, *params]))
def gas_by_tx(rpc, frm):
    # every tx our test key sent on the fork (anvil mines one block per tx), with gasUsed from the receipt
    res = []
    head = int(rpcj(rpc, "eth_blockNumber"), 16)
    for b in range(head, max(head - 16, 0), -1):
        j = rpcj(rpc, "eth_getBlockByNumber", hex(b), "true")
        for t in j.get("transactions", []):
            if t["from"].lower() == frm.lower():
                r = rpcj(rpc, "eth_getTransactionReceipt", t["hash"])
                res.append((b, t["hash"], int(r["gasUsed"], 16), int(t.get("value", "0x0"), 16), t.get("to")))
    if not res: raise SystemExit("no transactions found on " + rpc + ": cost table would be blind")
    return sorted(res)
me = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
rn = gas_by_tx("http://127.0.0.1:8561", me)
bs = gas_by_tx("http://127.0.0.1:8562", me)
rn_gas = sum(g for _, _, g, _, _ in rn); base_gas = sum(g for _, _, g, _, _ in bs)
rx_fund = sum(v for _, _, _, v, to in rn if to is None)
base_val = sum(v for _, _, _, v, _ in bs)
# live fee on Reactive: fee = max(gasprice, basefee) x (gas_used + 100000 extra) per reaction (dev.reactive.network/economy)
REACTION_GAS = 131066 + 100000   # largest measured reaction on Lasna (Aave proof + callback request), plus the extra-gas surcharge
reactions = {"setup (BountyPosted, ProofCondition)": 2, "proof + callback request": 1, "close (BountyPaid)": 1, "cron ticks, 6 h deadline": 21}
react_ops = sum(reactions.values()) * REACTION_GAS * rn_gp / 1e18
row = lambda k, v_native, unit, usd: f"| {k} | {v_native:.6f} {unit} | ${usd:.4f} |"
deploy_react = rn_gas * rn_gp / 1e18
base_gas_eth = base_gas * base_gp / 1e18
callback_eth = 400000 * base_gp / 1e18 * 2          # one payout callback at the 400k limit, x2 margin
rows = [
  row("Reactive mainnet gas: deploy + linkEscrow + setBurnRate (measured on the fork)", deploy_react, "REACT", deploy_react * react),
  row("REACT float sent with the deploy (RX_FUND)", rx_fund / 1e18, "REACT", rx_fund / 1e18 * react),
  row(f"Reactions for one bounty, 6 h ({sum(reactions.values())} x {REACTION_GAS} gas)", react_ops, "REACT", react_ops * react),
  row("Base gas: escrow deploy + postProof (measured on the fork)", base_gas_eth, "ETH", base_gas_eth * eth),
  row("Base value: escrow gas float + posting fee", base_val / 1e18, "ETH", base_val / 1e18 * eth),
  row("Base USDC: the bounty", int(paid) / 1e6, "USDC", int(paid) / 1e6),
  row("Base callback gas (payout callback, 2x margin)", callback_eth, "ETH", callback_eth * eth),
]
total_usd = int(paid) / 1e6 + deploy_react * react + rx_fund / 1e18 * react + react_ops * react + base_gas_eth * eth + base_val / 1e18 * eth + callback_eth * eth
bounty_usd = int(paid) / 1e6   # USDC, 6 decimals
# gone for good: all gas, the REACT float (it only pays reactions), the posting fee, and the escrow's gas float (no admin withdraw;
# it pays callbacks, fees above it go to REACT). Only the bounty is not ours to keep either way: winner or refund.
spent_usd = (deploy_react + rx_fund / 1e18 + react_ops) * react + (base_gas_eth + callback_eth + base_val / 1e18) * eth
md = f"""# Mainnet rehearsal (local forks of Reactive mainnet 1597 and Base 8453)
Generated {datetime.datetime.now(datetime.timezone.utc):%Y-%m-%d %H:%M:%SZ} by `script/mainnet_rehearse.sh`. Nothing was sent to a real chain (anvil forks on 127.0.0.1,
anvil's public test key). Same `script/mainnet_run.sh deploy` and `bounty` steps as the live run.

- Deployed on the forks: reactive `{rx}` (1597), escrow `{esc}` (8453); linked; cron on; `fundedUntil()` {fu} after deploy.
- Posted bounty #{bid} "First to supply USDC to Aave v3 on Base" (Supply, reserve = USDC pinned, winner = onBehalfOf).
- Played the callback the network sends for the latest REAL USDC supply on Base ({ptx}, by {winner}): the escrow paid
  {int(paid)/1e6:.2f} USDC to that address (a {wkind}). A forged callback (not the proxy) was refused. The bounty is paid in USDC on
  purpose: many Aave suppliers on Base are contracts that refuse plain ETH, and an ETH payout to one reverts.
- Event rate the cap has to absorb: {nsup} USDC Supply logs on the Aave v3 Base pool in the last hour (cap: 10 per hour per subscription).
- Live prices: Reactive gas {rn_gp/1e9:.0f} gwei, Base gas {base_gp/1e9:.4f} gwei, ETH ${eth:,.2f}, REACT ${react:.6f} (CoinGecko).

| Item | Amount | USD |
|---|---|---|
""" + "\n".join(rows) + f"""
| **Total to have on hand** | | **${total_usd:.2f}** |
| of which spent for good (gas, REACT float, posting fee, escrow gas float) | | ${spent_usd:.2f} |
| the bounty itself ({bounty_usd:.2f} USDC): to the first USDC supplier on Aave Base, or back to us at the deadline | | ${bounty_usd:.2f} |

Not on the forks: the ReactVM (react() runs only on the real network), so per-reaction cost is the documented formula
(max(gas price, base fee) x (gas used + 100,000)) with the largest reaction measured on Lasna (131,066 gas). The REACT itself must be
bought (Base DEX) and bridged to native REACT (portal.reactive.network/swap); that route's fees are not included above.
"""
open("evidence/mainnet-rehearsal.md", "w").write(md)
json.dump({"total_usd": round(total_usd, 4), "spent_usd": round(spent_usd, 4), "bounty_usd": round(bounty_usd, 4), "winner_kind": wkind, "rn_gas": rn_gas, "base_gas": base_gas,
           "rx_fund_wei": rx_fund, "base_value_wei": base_val, "react_ops": react_ops, "eth_usd": eth, "react_usd": react,
           "supplies_last_hour": int(nsup)}, open("evidence/mainnet-rehearsal.json", "w"), indent=1)
print(md)
PY
echo "REHEARSAL OK"
