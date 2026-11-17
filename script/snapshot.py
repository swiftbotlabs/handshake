#!/usr/bin/env python3
"""Write a no-JavaScript snapshot of every bounty (all escrow versions) into web/index.html, between
<!--SNAPSHOT--> and <!--/SNAPSHOT-->. Read straight from chain logs (BountyPosted / BountyToken / ClaimantAllowed /
BountyPaid / BountyRefunded), so fetchers and readers without JS see the same list the live script draws.
Usage: python3 -I script/snapshot.py   (stdlib only; public RPCs; no keys)"""
import html, json, sys, time, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RPC = "https://base-sepolia-rpc.publicnode.com"
LASNA = "https://lasna-rpc.rnk.dev/"
EXPLORER = "https://sepolia.basescan.org"
USDC = "0x036cbd53842c5426634e7929541ec2318f3dcf7e"
ESCROWS = [  # version, escrow, first block to scan, reactive
    ("v5", "0x1cD6c715f1b5579161864361e275e250a11c8004", 60157500, "0xD27824e127D8615e7e24218f3F9DF163901253D0"),
    ("v4", "0x43eE856817a3Bac8EfcCaD54355b1de9C97aeAA5", 60155400, "0x8907Bda54e22fDaC6A751e5f84DCAe95E6e4c579"),
    ("v3", "0xf45D582Edbf7dB418b32C6cdA13D16ff57Cae7A2", 60146500, "0xe3818074Ba24d7c64642D8a9607A86d514B770F1"),
    ("v2", "0x24F1134538a06a63AE49Ed9f3bFA47fabD67c802", 60125000, "0x24F1134538a06a63AE49Ed9f3bFA47fabD67c802"),
]

def keccak_topic(sig):
    import subprocess
    return subprocess.run(["cast", "keccak", sig], capture_output=True, text=True, check=True).stdout.strip()

T = {k: keccak_topic(v) for k, v in {
    "posted": "BountyPosted(uint256,address,uint8,uint256,uint256,string)",
    "token": "BountyToken(uint256,address)",
    "allowed": "ClaimantAllowed(uint256,address)",
    "paid": "BountyPaid(uint256,address,uint256,uint8,bytes32)",
    "refunded": "BountyRefunded(uint256,address,uint256,uint8)",
}.items()}

def rpc(url, method, params):
    req = urllib.request.Request(url, json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
                                 {"Content-Type": "application/json", "User-Agent": "handshake-snapshot"})
    for attempt in range(4):
        try:
            r = json.load(urllib.request.urlopen(req, timeout=30))
            if "error" in r: raise RuntimeError(r["error"])
            return r["result"]
        except Exception:
            if attempt == 3: raise
            time.sleep(2 * (attempt + 1))

def logs(addr, start, end):
    out = []
    for frm in range(start, end + 1, 50_000):
        out += rpc(RPC, "eth_getLogs", [{"address": addr, "fromBlock": hex(frm), "toBlock": hex(min(end, frm + 49_999))}])
    return out

def word(data, i): return int(data[2 + 64 * i: 2 + 64 * (i + 1)], 16)
def addr(topic): return "0x" + topic[-40:]
def short(a): return a[:6] + "…" + a[-4:]

def decode_title(data):
    off = word(data, 2); raw = bytes.fromhex(data[2:])
    n = int.from_bytes(raw[off:off + 32], "big")
    return raw[off + 32: off + 32 + n].decode("utf-8", "replace")

def main():
    latest = int(rpc(RPC, "eth_blockNumber", []), 16)
    rows, stats = [], {"paid": 0, "refunded": 0, "open": 0}
    runway = {}
    for ver, esc, start, rx in ESCROWS:
        b, toks = {}, {}
        for l in sorted(logs(esc, start, latest), key=lambda l: (int(l["blockNumber"], 16), int(l["logIndex"], 16))):
            t0 = l["topics"][0]; i = int(l["topics"][1], 16) if len(l["topics"]) > 1 else None
            if t0 == T["posted"]:
                b[i] = {"id": i, "title": decode_title(l["data"]), "amount": word(l["data"], 0), "deadline": word(l["data"], 1),
                        "kind": int(l["topics"][3], 16), "status": "open", "token": None, "allowed": [], "tx": None, "winner": None}
            elif t0 == T["token"]: toks[i] = addr(l["topics"][2])  # emitted just before BountyPosted
            elif i in b and t0 == T["allowed"]: b[i]["allowed"].append(addr(l["topics"][2]))
            elif i in b and t0 == T["paid"]: b[i].update(status="paid", winner=addr(l["topics"][2]), tx=l["transactionHash"])
            elif i in b and t0 == T["refunded"]: b[i].update(status="refunded", tx=l["transactionHash"])
        for x in sorted(b.values(), key=lambda x: -x["id"]):
            x["ver"], x["esc"], x["token"] = ver, esc, toks.get(x["id"])
            rows.append(x); stats[x["status"]] += 1
        try:
            fu = int(rpc(LASNA, "eth_call", [{"to": rx, "data": "0x" + keccak_topic("fundedUntil()")[2:10]}, "latest"]), 16)
            bal = int(rpc(LASNA, "eth_getBalance", [rx, "latest"]), 16)
            runway[ver] = (fu, bal)
        except Exception:
            pass
    now = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime())
    out = [f'<p class="hint">Snapshot from chain logs, {now} (no JavaScript needed; the live list replaces it). '
           f'{stats["paid"]} paid · {stats["refunded"]} refunded · {stats["open"]} open, across escrow versions v2-v5.</p>']
    for x in rows:
        amt = x["amount"]
        reward = (f"{amt / 1e6:g} USDC" if x["token"] and x["token"].lower() == USDC else
                  f"{amt} units of {x['token']}" if x["token"] else f"{amt / 1e18:.5f}".rstrip("0").rstrip(".") + " ETH")
        dl = time.strftime("%Y-%m-%d %H:%M", time.gmtime(x["deadline"]))
        kind = "judged" if x["kind"] == 0 else "proof"
        meta = [f"{x['ver']} · {kind} · Reward {reward} · deadline {dl} UTC"]
        if x["allowed"]: meta.append("only for " + ", ".join(f'<span class="mono">{short(a)}</span>' for a in x["allowed"]))
        if x["winner"]: meta.append(f'<span class="mono">winner {x["winner"]}</span>')
        if x["tx"]: meta.append(f'<a href="{EXPLORER}/tx/{x["tx"]}">{"payout" if x["status"] == "paid" else "refund"} tx</a>')
        out.append(f'<div class="b"><span class="n">{x["ver"]}·{x["id"]}</span><span class="t">{html.escape(x["title"] or "(untitled)")}</span>'
                   f'<span class="pill {x["status"]}">{x["status"]}</span><span class="m">{" · ".join(meta)}</span></div>')
    if "v5" in runway:
        fu, bal = runway["v5"]
        txt = ("deadline cron off (refunds by the public expire() until it is switched on)" if fu >= 2**255
               else f"deadline cron funded until {time.strftime('%Y-%m-%d %H:%M UTC', time.gmtime(fu))}")
        out.append(f'<p class="hint">v5 watcher on Reactive Lasna: {bal / 1e18:.4f} lREACT, {txt} (fundedUntil()).</p>')
    snap = "\n".join(out)
    page = ROOT / "web" / "index.html"
    s = page.read_text()
    a, b_ = s.index("<!--SNAPSHOT-->"), s.index("<!--/SNAPSHOT-->")
    page.write_text(s[:a] + "<!--SNAPSHOT-->\n" + snap + "\n" + s[b_:])
    print(f"snapshot: {len(rows)} bounties ({stats}), runway {runway}")

if __name__ == "__main__":
    main()
