#!/usr/bin/env python3
"""Every loop, every hash: rebuild evidence/triples.csv and evidence/EVIDENCE.md from CHAIN DATA ONLY.

For every bounty on every Handshake deployment it reads
  - the escrow's logs on the settlement chain (BountyPosted, ProofCondition, ClaimantAllowed, BountyPaid, BountyRefunded,
    CallbackSkipped),
  - the reactive contract's logs on Reactive Lasna (ProofSeen, ProofIgnored, ExpiryRequested),
  - the proof transaction's receipt and block time on the origin chain,
and pairs each Reactive request with the callback that landed for it. A request with no landed callback is reported as
STUCK, a landed callback with no request as ORPHAN. Nothing is taken from our own log files.

Usage:  python3 -I -u script/triples.py            (stdlib + `cast` for keccak; public RPCs; read-only; no keys)
        python3 -I -u script/triples.py --no-cache (ignore evidence/.cache and re-read everything)
Exit code is non-zero if a known anchor transaction is missing from what was read (positive control against a blind
log scan), if any chunk failed, or if zero loops were found.
"""
import csv, hashlib, json, os, statistics, subprocess, sys, time, urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "evidence"
CACHE = OUT / ".cache"
MAX_BODY = 32 * 1024 * 1024  # cap any RPC response

CHAINS = {
    84532: {"name": "Base Sepolia", "rpc": os.environ.get("BASE_SEP_RPC", "https://base-sepolia-rpc.publicnode.com"),
            "tx": "https://sepolia.basescan.org/tx/", "span": 50_000},
    5318007: {"name": "Reactive Lasna", "rpc": "https://lasna-rpc.rnk.dev/", "tx": "https://lasna.reactscan.net/tx/", "span": 30_000},
    11155111: {"name": "Ethereum Sepolia", "rpc": os.environ.get("ETH_SEP_RPC", "https://ethereum-sepolia-rpc.publicnode.com"),
               "fallback": ["https://1rpc.io/sepolia", "https://sepolia.gateway.tenderly.co"],
               "tx": "https://sepolia.etherscan.io/tx/", "span": 10_000},
}
BASE, LASNA, SEP = 84532, 5318007, 11155111

# route, version, escrow (chain, address, first block), reactive on Lasna (address, first block)
DEPLOYMENTS = [
    ("base", "v1", BASE, "0xb7B6a6E5Fc852FBcC5E62a0db92e0edb6429d769", 60_110_000, "0xb7B6a6E5Fc852FBcC5E62a0db92e0edb6429d769"),
    ("base", "v2", BASE, "0x24F1134538a06a63AE49Ed9f3bFA47fabD67c802", 60_110_000, "0x24F1134538a06a63AE49Ed9f3bFA47fabD67c802"),
    ("base", "v3", BASE, "0xf45D582Edbf7dB418b32C6cdA13D16ff57Cae7A2", 60_110_000, "0xe3818074Ba24d7c64642D8a9607A86d514B770F1"),
    ("base", "v4", BASE, "0x43eE856817a3Bac8EfcCaD54355b1de9C97aeAA5", 60_110_000, "0x8907Bda54e22fDaC6A751e5f84DCAe95E6e4c579"),
    ("base", "v5", BASE, "0x1cD6c715f1b5579161864361e275e250a11c8004", 60_110_000, "0xD27824e127D8615e7e24218f3F9DF163901253D0"),
    ("lasna-dest", "L1", LASNA, "0x7DFef9aE4E43743890b3c64d4D2647e8801f2BE5", 8_590_000, "0xfd8DE2fd9fF6bD09bC623bD1FF79eEB0154EcF55"),
]
LASNA_FROM = 8_590_000
BASE_FROM = 60_110_000

# Positive control: transactions we know exist (from the 17 Nov run). If the scan misses any, the scan is blind: fail.
ANCHORS = {
    "0xa3d235420b2711ef47e4eb30c38174cd458b93e77c636957483ff49f6f4e0be5",  # v5 Aave payout (Base)
    "0xac93f7450f67f31ea4a61eceee3ad18096d7577099da2719d710d6c918c97468",  # v5 ProofSeen (Lasna)
    "0xd084bc716d15ef494d9e4dbb9b4ab888dd52669e36e2b5138405734c678cd383",  # v4 ProofIgnored bot (Lasna)
    "0x82b0a2ffec77e900abbfe88b4428b23f2c6b131b392d24925868996c7a99365b",  # v4 ProofIgnored stranger (Lasna)
    "0x04074579df25c7d9f0ccb63f27a5025e6947c9d89b1a2e7dcce4c2bcbdf28083",  # v5 cron refund (Base)
    "0x0208fa60ffb87c76d481a0ee9039122bb177549154eaf474126cfa946e857df8",  # v2 WETH9 stranger payout (Base)
    "0x1bf02decfc9892c9bea0ecd74ed5d31efaca5b6e375cc3c2f25180c5ee5a87c9",  # v3 USDC payout (Base)
}

SIG = {
    "posted": "BountyPosted(uint256,address,uint8,uint256,uint256,string)",
    "condition": "ProofCondition(uint256,uint256,address,uint256,bool,uint256,uint8,uint256)",
    "allowed": "ClaimantAllowed(uint256,address)",
    "token": "BountyToken(uint256,address)",
    "paid": "BountyPaid(uint256,address,uint256,uint8,bytes32)",
    "refunded": "BountyRefunded(uint256,address,uint256,uint8)",
    "skipped": "CallbackSkipped(uint256,string)",
    "seen": "ProofSeen(uint256,address,uint256)",
    "ignored": "ProofIgnored(uint256,address,uint256)",
    "expiry": "ExpiryRequested(uint256,uint256)",
}
SEL = {"cancel": "cancel(uint256)", "expire": "expire(uint256)"}
USDC = "0x036cbd53842c5426634e7929541ec2318f3dcf7e"


def keccak(s):
    return subprocess.run(["cast", "keccak", s], capture_output=True, text=True, check=True).stdout.strip().lower()


T = {k: keccak(v) for k, v in SIG.items()}
TR = {v: k for k, v in T.items()}
S = {k: keccak(v)[:10] for k, v in SEL.items()}
USE_CACHE = "--no-cache" not in sys.argv
FAILS = []


def _cache_path(key):
    return CACHE / (hashlib.sha256(key.encode()).hexdigest()[:32] + ".json")


def rpc(chain, method, params, cacheable=False, need=False):
    """need=True: a null result is treated as an error (load-balanced public nodes sometimes miss old receipts)."""
    key = json.dumps([chain, method, params], sort_keys=True)
    p = _cache_path(key)
    if cacheable and USE_CACHE and p.exists():
        return json.loads(p.read_text())
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    urls = [CHAINS[chain]["rpc"]] + CHAINS[chain].get("fallback", [])
    last = None
    for attempt in range(6):
        url = urls[attempt % len(urls)]
        req = urllib.request.Request(url, body, {"Content-Type": "application/json", "User-Agent": "handshake-evidence"})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                raw = r.read(MAX_BODY + 1)
            if len(raw) > MAX_BODY:
                raise RuntimeError("response over size cap")
            j = json.loads(raw)
            if "error" in j:
                raise RuntimeError(str(j["error"])[:200])
            res = j["result"]
            if need and res is None:
                raise RuntimeError("null result")
            if cacheable and res is not None:
                CACHE.mkdir(parents=True, exist_ok=True)
                p.write_text(json.dumps(res))
            return res
        except Exception as e:  # network or rate limit: back off and retry, then fail loudly
            last = e
            time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"{CHAINS[chain]['name']} {method} failed: {last}")


def get_logs(chain, addrs, start, end, latest):
    out, span = [], CHAINS[chain]["span"]
    n = 0
    for frm in range(start, end + 1, span):
        to = min(end, frm + span - 1)
        final = to < latest - 2000  # older chunks never change: safe to cache
        try:
            out += rpc(chain, "eth_getLogs", [{"address": addrs, "fromBlock": hex(frm), "toBlock": hex(to)}], cacheable=final)
        except Exception as e:
            FAILS.append(f"getLogs {CHAINS[chain]['name']} {frm}-{to}: {e}")
        n += 1
        if n % 10 == 0:
            print(f"  {CHAINS[chain]['name']}: {n} chunks, {len(out)} logs", flush=True)
    return out


_ts = {}


def block_ts(chain, bn):
    k = (chain, bn)
    if k not in _ts:
        b = rpc(chain, "eth_getBlockByNumber", [hex(bn), False], cacheable=True, need=True)
        _ts[k] = int(b["timestamp"], 16)
    return _ts[k]


def receipt(chain, tx):
    return rpc(chain, "eth_getTransactionReceipt", [tx], cacheable=True, need=True)


def txn(chain, tx):
    return rpc(chain, "eth_getTransactionByHash", [tx], cacheable=True, need=True)


def word(data, i):
    return int(data[2 + 64 * i: 2 + 64 * (i + 1)] or "0", 16)


def a(topic):
    return "0x" + topic[-40:]


def utc(t):
    return time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(t)) if t else ""


def title_of(data):
    try:
        off = word(data, 2)
        raw = bytes.fromhex(data[2:])
        n = int.from_bytes(raw[off:off + 32], "big")
        return raw[off + 32: off + 32 + min(n, 300)].decode("utf-8", "replace")
    except Exception:
        return ""


def skipped_reason(data):
    try:
        raw = bytes.fromhex(data[2:])
        off = int.from_bytes(raw[0:32], "big")
        n = int.from_bytes(raw[off:off + 32], "big")
        return raw[off + 32: off + 32 + min(n, 100)].decode("utf-8", "replace")
    except Exception:
        return "?"


def key(l):
    return (int(l["blockNumber"], 16), int(l["transactionIndex"], 16), int(l["logIndex"], 16))


def main():
    t0 = time.time()
    latest = {c: int(rpc(c, "eth_blockNumber", []), 16) for c in (BASE, LASNA)}
    print(f"latest: Base Sepolia {latest[BASE]}, Lasna {latest[LASNA]}", flush=True)

    # 1) all logs, both chains, one pass each (address arrays)
    lasna_addrs = sorted({d[5] for d in DEPLOYMENTS} | {d[3] for d in DEPLOYMENTS if d[2] == LASNA})
    base_addrs = sorted({d[3] for d in DEPLOYMENTS if d[2] == BASE})
    print(f"scanning Base Sepolia {BASE_FROM}..{latest[BASE]} for {len(base_addrs)} escrows", flush=True)
    base_logs = get_logs(BASE, base_addrs, BASE_FROM, latest[BASE], latest[BASE])
    print(f"scanning Lasna {LASNA_FROM}..{latest[LASNA]} for {len(lasna_addrs)} contracts", flush=True)
    lasna_logs = get_logs(LASNA, lasna_addrs, LASNA_FROM, latest[LASNA], latest[LASNA])
    if FAILS:
        for f in FAILS:
            print("FAIL", f)
        sys.exit(2)
    seen_tx = {l["transactionHash"].lower() for l in base_logs + lasna_logs}
    missing = sorted(ANCHORS - seen_tx)
    print(f"logs: Base {len(base_logs)}, Lasna {len(lasna_logs)}; anchors found {len(ANCHORS) - len(missing)}/{len(ANCHORS)}", flush=True)
    if missing:
        print("FAIL: anchor transactions missing from the scan (blind read):", missing)
        sys.exit(3)

    by_addr = {}
    for chain, logs in ((BASE, base_logs), (LASNA, lasna_logs)):
        for l in logs:
            by_addr.setdefault((chain, l["address"].lower()), []).append(l)
    for v in by_addr.values():
        v.sort(key=key)

    rows, requests_all, landed_all = [], [], []
    for route, ver, echain, esc, _, rx in DEPLOYMENTS:
        elogs = by_addr.get((echain, esc.lower()), [])
        rlogs = by_addr.get((LASNA, rx.lower()), [])
        if echain == LASNA and esc.lower() == rx.lower():
            raise SystemExit("same address on one chain: cannot split logs")
        B = {}
        landed = []  # (id, kind, ts, tx, extra)
        for l in elogs:
            t = TR.get(l["topics"][0].lower())
            if not t or len(l["topics"]) < 2:
                continue
            i = int(l["topics"][1], 16)
            b = B.setdefault(i, {"id": i, "allowed": [], "token": None, "cond": None, "title": "", "post": None})
            if t == "posted":
                b.update(post=l["transactionHash"], post_block=int(l["blockNumber"], 16), issuer=a(l["topics"][2]),
                         kind="proof" if int(l["topics"][3], 16) == 1 else "judged", amount=word(l["data"], 0),
                         deadline=word(l["data"], 1), title=title_of(l["data"]))
            elif t == "condition":
                b["cond"] = {"chain": word(l["data"], 0), "emitter": "0x" + l["data"][2 + 64 + 24: 2 + 128]}
            elif t == "allowed":
                b["allowed"].append(a(l["topics"][2]))
            elif t == "token":
                b["token"] = a(l["topics"][2])
            elif t in ("paid", "refunded", "skipped"):
                landed.append({"id": i, "t": t, "log": l, "via": int(l["topics"][3], 16) if t != "skipped" else 1,
                               "block": int(l["blockNumber"], 16)})
        reqs = []
        for l in rlogs:
            t = TR.get(l["topics"][0].lower())
            if t not in ("seen", "ignored", "expiry"):
                continue
            reqs.append({"id": int(l["topics"][1], 16), "t": t, "log": l, "block": int(l["blockNumber"], 16)})

        # timestamps (parallel, cached)
        with ThreadPoolExecutor(4) as ex:
            list(ex.map(lambda x: block_ts(echain, x["block"]), landed))
            list(ex.map(lambda x: block_ts(LASNA, x["block"]), reqs))
        for x in landed:
            x["ts"] = block_ts(echain, x["block"])
        for x in reqs:
            x["ts"] = block_ts(LASNA, x["block"])

        # proof transactions on the origin chain
        def origin_of(i):
            c = B.get(i, {}).get("cond")
            return c["chain"] if c else SEP

        proofs = {}
        for x in reqs:
            if x["t"] in ("seen", "ignored"):
                proofs[(origin_of(x["id"]), "0x%064x" % int(x["log"]["topics"][3], 16))] = None
        for x in landed:
            if x["t"] == "paid" and x["via"] == 1:
                proofs[(origin_of(x["id"]), "0x" + x["log"]["data"][2 + 64: 2 + 128])] = None

        def pts(k):
            ch, h = k
            if ch not in CHAINS:
                return k, None
            try:
                r = receipt(ch, h)
                return k, block_ts(ch, int(r["blockNumber"], 16))
            except Exception as e:
                FAILS.append(f"proof receipt {h} on {ch}: {e}")
                return k, None
        with ThreadPoolExecutor(4) as ex:
            for k, v in ex.map(pts, list(proofs)):
                proofs[k] = v

        # issuer refunds: cancel() or expire()?
        for x in landed:
            if x["t"] == "refunded" and x["via"] == 0:
                inp = txn(echain, x["log"]["transactionHash"]).get("input", "")[:10].lower()
                x["how"] = "expire() by anyone" if inp == S["expire"] else ("cancel() by issuer" if inp == S["cancel"] else "issuer call")

        # pair each Reactive request with the callback that landed for it (per bounty, in time order)
        used = set()
        for x in sorted(reqs, key=lambda r: (r["ts"], key(r["log"]))):
            if x["t"] == "ignored":
                continue
            ph = "0x%064x" % int(x["log"]["topics"][3], 16) if x["t"] == "seen" else None
            cands = [j for j, y in enumerate(landed) if j not in used and y["id"] == x["id"] and y["via"] == 1
                     and y["ts"] >= x["ts"] - 5]
            match = None
            for j in cands:  # exact match first
                y = landed[j]
                if x["t"] == "seen" and y["t"] == "paid" and "0x" + y["log"]["data"][2 + 64: 2 + 128] == ph:
                    match = j; break
                if x["t"] == "expiry" and y["t"] == "refunded":
                    match = j; break
            if match is None:
                sk = [j for j in cands if landed[j]["t"] == "skipped"]
                match = sk[0] if sk else None
            x["match"] = match
            if match is not None:
                used.add(match)

        def link_row(**kw):
            base = {"route": route, "version": ver, "bounty": "", "kind": "", "outcome": "", "title": "", "origin_chain": "",
                    "post_tx": "", "proof_tx": "", "proof_utc": "", "react_tx": "", "react_utc": "", "callback_tx": "",
                    "callback_utc": "", "seconds": "", "winner": "", "amount": "", "note": ""}
            base.update(kw)
            rows.append(base)

        def amount_s(b, amt):
            tok = (b.get("token") or "").lower()
            if tok == USDC:
                return f"{amt / 1e6:g} USDC"
            if tok:
                return f"{amt} units {tok}"
            return f"{amt / 1e18:.6f}".rstrip("0").rstrip(".") + (" lREACT" if echain == LASNA else " ETH")

        for x in sorted(reqs, key=lambda r: (r["ts"], key(r["log"]))):
            b = B.get(x["id"], {})
            oc = origin_of(x["id"])
            common = dict(bounty=x["id"], kind=b.get("kind", ""), title=b.get("title", ""), post_tx=b.get("post") or "",
                          react_tx=x["log"]["transactionHash"], react_utc=utc(x["ts"]))
            if x["t"] in ("seen", "ignored"):
                ph = "0x%064x" % int(x["log"]["topics"][3], 16)
                pt = proofs.get((oc, ph))
                common.update(origin_chain=CHAINS.get(oc, {}).get("name", str(oc)), proof_tx=ph, proof_utc=utc(pt),
                              winner=a(x["log"]["topics"][2]))
            if x["t"] == "ignored":
                link_row(**common, outcome="ignored", seconds=(x["ts"] - pt) if pt else "",
                         note="named address not on the bounty's allowlist: dropped on Reactive, no callback sent (by design)")
                continue
            m = x.get("match")
            if m is None:
                age = latest_ts - x["ts"]
                link_row(**common, outcome="stuck" if age > 1800 else "in flight",
                         note=f"Reactive requested a callback {('to ' + CHAINS[echain]['name'])}; nothing landed on the escrow "
                              f"({age // 60} min so far)")
                continue
            y = landed[m]
            cb = dict(callback_tx=y["log"]["transactionHash"], callback_utc=utc(y["ts"]))
            if y["t"] == "paid":
                link_row(**common, **cb, outcome="paid", seconds=(y["ts"] - pt) if pt else "",
                         amount=amount_s(b, word(y["log"]["data"], 0)),
                         note="proof -> react() -> callback paid the winner")
            elif y["t"] == "refunded":
                link_row(**common, **cb, outcome="refunded (cron)", seconds=y["ts"] - b.get("deadline", y["ts"]),
                         amount=amount_s(b, word(y["log"]["data"], 0)),
                         note=f"deadline {utc(b.get('deadline'))}; Cron1000 tick -> callback refunded the issuer; seconds = refund minus deadline")
            else:
                link_row(**common, **cb, outcome="skipped (no-op)",
                         note=f"callback landed and the escrow refused it: '{skipped_reason(y['log']['data'])}' (state re-checked on chain)")

        # escrow-side closes with no Reactive request: issuer actions
        for j, y in enumerate(landed):
            if j in used:
                continue
            b = B.get(y["id"], {})
            cb = dict(bounty=y["id"], kind=b.get("kind", ""), title=b.get("title", ""), post_tx=b.get("post") or "",
                      callback_tx=y["log"]["transactionHash"], callback_utc=utc(y["ts"]))
            if y["via"] == 0 and y["t"] == "paid":
                link_row(**cb, outcome="paid by issuer", winner=a(y["log"]["topics"][2]), amount=amount_s(b, word(y["log"]["data"], 0)),
                         note="judged bounty: the issuer accepted a claim (no Reactive leg)")
            elif y["via"] == 0 and y["t"] == "refunded":
                link_row(**cb, outcome="closed by issuer", amount=amount_s(b, word(y["log"]["data"], 0)), note=y.get("how", ""))
            else:
                link_row(**cb, outcome="orphan callback", note=f"{y['t']} via Reactive with no matching request found")
        closed = {y["id"] for y in landed if y["t"] in ("paid", "refunded")}
        for i, b in sorted(B.items()):
            if i not in closed and b.get("post"):
                due = b.get("deadline", 0) and b["deadline"] < latest_ts
                link_row(bounty=i, kind=b.get("kind", ""), title=b.get("title", ""), post_tx=b["post"],
                         outcome="open, past deadline" if due else "open",
                         note=f"deadline {utc(b.get('deadline'))}" + ("; no refund has landed on this escrow yet" if due else ""))
        for i, b in B.items():
            b["route"], b["ver"] = route, ver
        requests_all += reqs
        landed_all += landed

    # stable order
    order = {d[1]: n for n, d in enumerate(DEPLOYMENTS)}
    rows.sort(key=lambda r: (order[r["version"]], int(r["bounty"] or 0), r["react_utc"] or r["callback_utc"]))
    OUT.mkdir(exist_ok=True)
    fields = list(rows[0].keys())
    with open(OUT / "triples.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)

    def tot(route):
        rr = [r for r in rows if r["route"] == route]
        paid = [r for r in rr if r["outcome"] == "paid"]
        secs = [int(r["seconds"]) for r in paid if r["seconds"] != ""]
        return {
            "proofs": sum(1 for r in rr if r["outcome"] in ("paid", "ignored", "stuck", "in flight", "skipped (no-op)") and r["proof_tx"]),
            "paid": len(paid),
            "ignored": sum(1 for r in rr if r["outcome"] == "ignored"),
            "cron": sum(1 for r in rr if r["outcome"] == "refunded (cron)"),
            "skipped": sum(1 for r in rr if r["outcome"] == "skipped (no-op)"),
            "stuck": sum(1 for r in rr if r["outcome"] == "stuck"),
            "inflight": sum(1 for r in rr if r["outcome"] == "in flight"),
            "issuer": sum(1 for r in rr if r["outcome"] in ("paid by issuer", "closed by issuer")),
            "open": sum(1 for r in rr if r["outcome"].startswith("open")),
            "orphan": sum(1 for r in rr if r["outcome"] == "orphan callback"),
            "median": statistics.median(secs) if secs else None, "max": max(secs) if secs else None,
            "rows": len(rr),
        }
    tb, tl = tot("base"), tot("lasna-dest")
    totals = (f"{tb['proofs']} proofs seen, {tb['paid']} paid, {tb['ignored']} ignored by design, {tb['cron']} unattended refunds, "
              f"{tb['stuck']} stuck; median {tb['median']:g} s proof to payout (max {tb['max']} s)") if tb["median"] is not None else "no paid loops"
    json.dump({"generated_utc": utc(int(time.time())), "latest_blocks": latest, "base": tb, "lasna_dest": tl, "totals_line": totals,
               "rows": len(rows)}, open(OUT / "totals.json", "w"), indent=1)
    write_doc(rows, tb, tl, totals, latest)
    print("TOTALS (Base-settled v1-v5):", totals)
    print("lasna-dest experiment:", tl)
    print(f"wrote {OUT/'triples.csv'} ({len(rows)} rows), {OUT/'EVIDENCE.md'}, {OUT/'totals.json'} in {time.time() - t0:.0f} s")
    gaps = [r for r in rows if r["outcome"] in ("paid", "ignored") and r["seconds"] == ""]
    if FAILS or gaps:
        for f in FAILS:
            print("FAIL", f)
        print(f"FAIL: {len(gaps)} paid/ignored rows without a proof time")
        sys.exit(5)
    if tb["paid"] == 0:
        print("FAIL: zero paid loops found")
        sys.exit(4)


latest_ts = int(time.time())


def L(chain_name, h, label=None):
    if not h:
        return ""
    url = {"Base Sepolia": CHAINS[BASE]["tx"], "Reactive Lasna": CHAINS[LASNA]["tx"], "Ethereum Sepolia": CHAINS[SEP]["tx"]}[chain_name]
    return f"[{label or h[:10] + '…'}]({url}{h})"


def write_doc(rows, tb, tl, totals, latest):
    cov = OUT / "coverage.txt"
    cov_table, cov_misses, cov_tests = [], [], ""
    if cov.exists():
        for line in cov.read_text().splitlines():
            if line.startswith(("| src/", "| File", "| Total")):
                cov_table.append(line)
            elif line.startswith("MISS "):
                cov_misses.append(line[5:])
            elif "tests passed" in line:
                cov_tests = line.split(":", 1)[-1].strip()
    out = [
        "# Every loop, every hash",
        "",
        f"**{totals}.**",
        "",
        f"Built from chain data only by `python3 -I -u script/triples.py` on {utc(int(time.time()))} UTC (Base Sepolia block "
        f"{latest[BASE]}, Lasna block {latest[LASNA]}). Machine-readable: [`triples.csv`](triples.csv), [`totals.json`](totals.json).",
        "Each Reactive request (a `ProofSeen` or `ExpiryRequested` log of the reactive contract on Lasna) is paired with the callback that "
        "landed on the escrow; a request with no landed callback would be listed as **stuck**. Proof times are the origin block's timestamp, "
        "callback times the settlement block's. Reproduce any paid loop without sending anything: `script/dryrun.sh <version> <bounty id>`.",
        "",
        "## Reproduce it yourself (read-only, sends nothing)",
        "",
        "```",
        "python3 -I -u script/triples.py      # rebuild this page, triples.csv and totals.json from public RPCs",
        "./script/dryrun.sh v5 2              # replay the Aave v3 loop: real logs -> local HandshakeReactive -> callback on a Base Sepolia fork",
        "./script/dryrun.sh v4 1 0x0f5ebe2d9ba48f2a8320fdd08d0be59235db137108850f6893cd8a3de49ce5a4   # the front-runner: dropped, no callback",
        "./script/coverage.sh                 # forge coverage of src/",
        "```",
        "",
        "`dryrun.sh` needs only Foundry and public RPCs. It feeds the bounty's real escrow logs and every log of the real proof transaction "
        "into a local `HandshakeReactive`, checks it requests exactly the callback the network delivered, then delivers that callback as the "
        "callback proxy on a fork of Base Sepolia one block before the real payout and checks the same winner gets the same amount. "
        "It runs the current source; v1 and v2 were deployed from earlier commits, so for those it shows the current code reaches the same "
        "result from the same logs.",
        "",
        "## Totals",
        "",
        "| Route | Proofs seen | Paid | Ignored (allowlist) | Cron refunds | Callbacks refused by escrow | Stuck | Closed by issuer | Open | Median s | Max s |",
        "|---|---|---|---|---|---|---|---|---|---|---|",
        f"| Base Sepolia escrow, v1-v5 | {tb['proofs']} | {tb['paid']} | {tb['ignored']} | {tb['cron']} | {tb['skipped']} | {tb['stuck']} | "
        f"{tb['issuer']} | {tb['open']} | {tb['median'] if tb['median'] is not None else '-'} | {tb['max'] if tb['max'] is not None else '-'} |",
        f"| Experiment: escrow on Lasna itself (L1) | {tl['proofs']} | {tl['paid']} | {tl['ignored']} | {tl['cron']} | {tl['skipped']} | "
        f"{tl['stuck']} | {tl['issuer']} | {tl['open']} | - | - |",
        "",
    ]
    if cov_table:
        out += ["## Test coverage of the contracts (`script/coverage.sh`, `forge coverage` over src/)", "",
                f"{cov_tests}." if cov_tests else "", "", cov_table[0], "|---|---|---|---|---|"] + cov_table[1:] + [""]
        if cov_misses:
            out += ["Not reached by any test:", ""] + [f"- `{m}`" for m in cov_misses] + [
                "  (the vault is a fixed contract that always accepts ETH from the escrow, so this revert cannot be triggered without "
                "changing deployed code)" if len(cov_misses) == 1 and "HandshakeEscrow.sol:328" in cov_misses[0] else "", ""]
    for ver in [d[1] for d in DEPLOYMENTS]:
        rr = [r for r in rows if r["version"] == ver]
        if not rr:
            continue
        dest = "Reactive Lasna" if ver.startswith("L") else "Base Sepolia"
        head = "Experiment L1: escrow on Lasna (Lasna -> Lasna callbacks)" if ver.startswith("L") else f"{ver} (escrow on Base Sepolia)"
        out += [f"## {head}", "",
                "| # | Bounty | Outcome | Post | Proof (origin) | react() (Lasna) | Callback | s | Winner / note |",
                "|---|---|---|---|---|---|---|---|---|"]
        for r in rr:
            title = (r["title"] or "").replace("|", "/")[:60]
            note = r["winner"][:10] + "…" if r["winner"] else ""
            if r["outcome"] not in ("paid",):
                note = (note + " " if note else "") + r["note"].replace("|", "/")
            if r["amount"]:
                note = r["amount"] + (" · " + note if note else "")
            out.append(f"| {r['bounty']} | {title} | **{r['outcome']}** | {L(dest, r['post_tx'], 'post')} | "
                       f"{L(r['origin_chain'], r['proof_tx'], (r['proof_utc'][11:] or 'proof')) if r['proof_tx'] else ''} | "
                       f"{L('Reactive Lasna', r['react_tx'], r['react_utc'][11:] or 'react')} | "
                       f"{L(dest, r['callback_tx'], r['callback_utc'][11:] or 'tx')} | {r['seconds']} | {note} |")
        out.append("")
    out += [
        "## How to read it, and what it does not show",
        "",
        "- **paid**: a matching event on the origin chain, `ProofSeen` on Lasna, then `BountyPaid` on the escrow. Seconds = payout block "
        "time minus proof block time.",
        "- **ignored**: the event named an address outside the bounty's allowlist (front-run tests); Reactive emitted `ProofIgnored` and "
        "sent no callback. That is the guard working, not a failure.",
        "- **refunded (cron)**: nobody won by the deadline; a Cron1000 tick on Lasna requested the refund. Seconds = refund minus deadline "
        "(the tick runs about every 17 minutes).",
        "- **skipped (no-op)**: a callback landed but the escrow's own re-check refused it (already closed, past deadline). No money moved.",
        "- **closed by issuer**: the issuer cancelled, or someone called the public `expire()` fallback. No Reactive leg.",
        "- **stuck**: Reactive requested a callback and nothing landed within 30 minutes.",
        "- Experiment L1 put the escrow on Lasna itself (Reactive as the destination chain). Its callbacks were never relayed by the network, "
        "so those rows show as stuck; the reactive side worked. It is a separate rehearsal, not part of the Base totals.",
        "- Block clocks differ by about a second between chains, so a Lasna `react()` can carry a timestamp one second before the origin "
        "block it reacted to. Seconds are computed from block timestamps as they are, never adjusted.",
        "- Experiment L1, bounty 1 (Aave WBTC, deadline 23 Nov): its reactive contract was drained by per-event billing (see below) and "
        "its refund request never reached the escrow, so it is listed as open past its deadline. The issuer can still recover it with the "
        "public `expire()`.",
        "- **Billing lesson (22 Nov).** Reactive bills every matching event the contract reacts to, about 0.0125 lREACT each on Lasna, not "
        "only cron ticks. The L1 WETH9 bounty subscribed to every `Deposit` on Sepolia WETH9 and 155 reactions drained the contract in "
        "about 2.5 hours. `fundedUntil()` models cron ticks only, so it showed days of runway while events were draining it. Budget per "
        "matching event, and pin low-volume proofs (topic1-filtered) instead of an unfiltered busy event.",
        "- All of this is testnet (Ethereum Sepolia, Base Sepolia, Lasna). No mainnet run yet.",
        "",
    ]
    (OUT / "EVIDENCE.md").write_text("\n".join(out))


if __name__ == "__main__":
    main()
