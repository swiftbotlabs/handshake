# Handshake: bounties that settle themselves

Post a bounty and walk away. Handshake pays the winner the moment the chain proves the work was done, on whichever chain it
happened, and refunds you by itself if the deadline passes. No keeper bot, no server, no reminder in your calendar.

Built on [Reactive Network](https://reactive.network) for the Reactive Omni Buildathon (track: Set It and Forget It).

![How Handshake works](docs/diagram.png)

## Why

I post small bounties and I claim them. Two chores eat my time:

1. **Deadlines.** A bounty nobody wins has to be cancelled and refunded by hand. Miss the date and the money stays stuck.
2. **Provable jobs.** Many jobs are on-chain facts: "run job 7", "settle order 12", "relay this message". Someone still has to
   watch for the event, check who did it and send the payment.

Handshake turns both into event-driven logic on Reactive Network, so a bounty needs no attention after it is posted.

## How it works

| Contract | Chain | Role |
|---|---|---|
| `HandshakeEscrow` + `BountyVault` | Base Sepolia | Holds bounties. Pays or refunds only through checked callbacks, or `expire(id)` by anyone after the deadline. |
| `HandshakeReactive` | Reactive Lasna | Mirrors bounties from escrow events, subscribes on the fly to each proof condition, pays the first proof, refunds on Cron1000 ticks. |
| `KeeperJobs` | Ethereum Sepolia | Tiny demo job board whose `run(job, work)` emits the proof event. Any contract's event works. |

Two kinds of bounty:

- **Proof bounty.** The issuer names an event as the condition: chain, contract, topic0, an optional pinned topic1 (for example
  the job id), which topic holds the winner, and a minimum value. Example: `JobRun(jobId = 7, keeper, work >= 3)` on Ethereum
  Sepolia. The first matching log pays the address in the named topic, on Base Sepolia.
- **Judged bounty.** The issuer accepts a claim and it pays out at once. If nobody is accepted by the deadline, the issuer is
  refunded automatically.

Subscriptions are dynamic: bounties that share a condition share one subscription (reference counted), and the last one to close
unsubscribes.

## Safety

- **Anti-spam:** every bounty must be at least `minBounty`, and each post pays a flat `postFee` that stays in the escrow as the gas
  float the callback proxy bills. Spam pays for the callbacks it causes. (Testnet: 0.0001 ETH minimum, 0.00002 ETH fee.) The reactive
  side (REACT for each `react()`) is still funded by the operator; see Limits.

- Every callback is checked twice: the callback proxy (`onlyServiceProvider`) and our reactive contract as the sender.
- The escrow re-checks everything on its own chain: still open, right kind, before or after the deadline on this chain's clock.
  Late, duplicate or forged callbacks are no-ops that emit `CallbackSkipped`. They never revert, so a failing callback can't loop
  and burn fees.
- Bounty money sits in a separate `BountyVault`. Callback gas is billed to the escrow's own float, so a fee can never touch a bounty.
- First valid proof wins. A proof after the deadline pays nothing and the bounty is refunded instead.
- If Reactive ever stops, anyone can call `expire(id)` on a due bounty. Funds can only go back to the issuer.

## It runs (testnets, 17 Nov 2026)

Two deployments, both run end to end. Times are **block timestamps**; `./script/latency.sh <origin tx> <lasna tx> <payout tx>`
recomputes any row from public RPCs.

**v2 (current, with the minimum and the posting fee)**: reactive (Lasna) and escrow (Base Sepolia) `0x24F1134538a06a63AE49Ed9f3bFA47fabD67c802`
(same deployer nonce on both chains), job board (Eth Sepolia) `0xc964f01ed8087f51b6DD1F6434bd268176Fbf212`.

| Loop | Proof on the origin chain | Reactive (Lasna) | Settlement (Base Sepolia) | Latency |
|---|---|---|---|---|
| A. Our keeper runs job 1794948400 | [job tx](https://sepolia.etherscan.io/tx/0xb239357ab0ac233ddf8725033c4f794db1bc4c0bed82b93194bcec401a172824) 20:47:48 | [ProofSeen](https://lasna.reactscan.net/tx/0x36763649425b534222e2de5f99165a9ff984b1748665f59a059ed91b30ce644b) | [BountyPaid](https://sepolia.basescan.org/tx/0x8e32730b2326d68f22b3b131acf2ff3b09bb1d63b75b727f6660d77dd6f21e42) 20:47:50 | **2 s** |
| C. Third-party event: first to wrap ≥ 0.003 ETH in the public WETH9 | [a stranger's wrap](https://sepolia.etherscan.io/tx/0x8fe9b7ab8046db99e0d176d5a50e9c84df377911138cb6b957abcb1c9790d4c6) 20:57:24 | [ProofSeen](https://lasna.reactscan.net/tx/0xda9fa1b159fd63e2997e73d0adf413d3a2f1e47987193442698ca2b67873d64d) | [BountyPaid to 0x78fc1fa1…](https://sepolia.basescan.org/tx/0x0208fa60ffb87c76d481a0ee9039122bb177549154eaf474126cfa946e857df8) 20:57:26 | **2 s** |
| B. Judged bounty nobody won, deadline 21:07:51 | none | [cron tick, ExpiryRequested](https://lasna.reactscan.net/tx/0xfa378fffb04b678c88d00491d3e8252423aed778f4ec71372cfcb293bc02b09f) | [BountyRefunded](https://sepolia.basescan.org/tx/0x2bac5bea0382b20baa77302d1c1c55c6ff506a200959b798055f5166ad0bcbc6) 21:13:43 | next Cron1000 tick |

Loop C is the one that matters most: the proof came from a contract we don't own (WETH9 on Sepolia), and the winner was an
address we don't control (`0x78fc1fa18c55c42bca391bfee8b57b623e7d99aa`, which wrapped 0.0172 ETH). Nobody on our side did anything after posting.

**v3 (adds ERC-20)**: reactive `0xe3818074Ba24d7c64642D8a9607A86d514B770F1`, escrow `0xf45D582Edbf7dB418b32C6cdA13D16ff57Cae7A2`.

| Loop | Proof on the origin chain | Reactive (Lasna) | Settlement (Base Sepolia) | Latency |
|---|---|---|---|---|
| D. **5 USDC** bounty (Circle test USDC) for our keeper's job | [job tx](https://sepolia.etherscan.io/tx/0x3d368f8b9830dd38a0f509f4bfa04f7dd85222081114ef14fa8904b9beb07703) 21:45:36 | [ProofSeen](https://lasna.reactscan.net/tx/0xe7e69a803bca706b511db495481563c5ba0249a032a98b11de6b51def5acc369) | [5 USDC paid](https://sepolia.basescan.org/tx/0x1bf02decfc9892c9bea0ecd74ed5d31efaca5b6e375cc3c2f25180c5ee5a87c9) 21:45:37 | **1 s** |
| E. ETH bounty, same flow | [job tx](https://sepolia.etherscan.io/tx/0x8a575b3582899a66763c1d630ff3567a17deb4a997f0320bb6c902a7b3ff06cb) 21:44:24 | [ProofSeen](https://lasna.reactscan.net/tx/0x214e6efa1e90ed2a2ed1bf7ed9e5d5df05606068cdeba1e8749cffb952e587b0) | [BountyPaid](https://sepolia.basescan.org/tx/0xabd7d9637764a2485a051d1b8884da3d953853b2fbfd5b6397392c5b34b9337e) 21:44:26 | **2 s** |

**v1 (first run, no fee)**: reactive and escrow `0xb7B6a6E5Fc852FBcC5E62a0db92e0edb6429d769`. Proof loop: job
[0x0f250aa8…](https://sepolia.etherscan.io/tx/0x0f250aa8e33ce6de0f8319f2a6b357028c2121499b1cbaa36c769b3990105151) at 19:46:24, Lasna
[0xaf8f8513…](https://lasna.reactscan.net/tx/0xaf8f85131db7df89e3da27337dd4e78895ba28f67d99527e03a87530fb772c3b) at 19:46:24, payout
[0xdf482835…](https://sepolia.basescan.org/tx/0xdf48283586407fddb8e1c0c55aeab613dfa862a068bfaaa82f3e01ff56ce1fb7) at 19:46:26 (+2 s). Deadline refund
[0x0eec3c54…](https://sepolia.basescan.org/tx/0x0eec3c542ee34ae94c4062b80f43ddd73a9304a2bf2165880556ab4d4af60e3a). Its cron is switched off.
Every hash: `demo_log.md` (v2) and `demo_log-v1.md`. The times at the start of those log lines are when the line was written,
not chain time.

## Verified addresses

Every contract below is verified on [Sourcify](https://sourcify.dev) with an **exact match** (creation and runtime bytecode), including the
reactive contracts on Reactive Lasna.

| Version | Contract | Chain | Address | Source |
|---|---|---|---|---|
| v3 (ETH + ERC-20) | HandshakeReactive | Reactive Lasna (5318007) | `0xe3818074Ba24d7c64642D8a9607A86d514B770F1` | [Sourcify](https://repo.sourcify.dev/5318007/0xe3818074Ba24d7c64642D8a9607A86d514B770F1) |
| v3 | HandshakeEscrow | Base Sepolia (84532) | `0xf45D582Edbf7dB418b32C6cdA13D16ff57Cae7A2` | [Sourcify](https://repo.sourcify.dev/84532/0xf45D582Edbf7dB418b32C6cdA13D16ff57Cae7A2) |
| v3 | BountyVault | Base Sepolia | `0x82d2185BB25c9c1B0F602e5D495A2DE336D27848` | [Sourcify](https://repo.sourcify.dev/84532/0x82d2185BB25c9c1B0F602e5D495A2DE336D27848) |
| v2 (ETH, the run below) | HandshakeReactive | Reactive Lasna | `0x24F1134538a06a63AE49Ed9f3bFA47fabD67c802` | [Sourcify](https://repo.sourcify.dev/5318007/0x24F1134538a06a63AE49Ed9f3bFA47fabD67c802) |
| v2 | HandshakeEscrow | Base Sepolia | `0x24F1134538a06a63AE49Ed9f3bFA47fabD67c802` | [Sourcify](https://repo.sourcify.dev/84532/0x24F1134538a06a63AE49Ed9f3bFA47fabD67c802) |
| v2 | BountyVault | Base Sepolia | `0x6165C352deEdFf147B1F938763c70F0f88dBa2f0` | [Sourcify](https://repo.sourcify.dev/84532/0x6165C352deEdFf147B1F938763c70F0f88dBa2f0) |
| all | KeeperJobs (demo job board) | Ethereum Sepolia (11155111) | `0xc964f01ed8087f51b6DD1F6434bd268176Fbf212` | [Sourcify](https://repo.sourcify.dev/11155111/0xc964f01ed8087f51b6DD1F6434bd268176Fbf212) |

v3 adds ERC-20 bounties (`postJudgedToken`, `postProofToken`; USDC on Base Sepolia is `0x036CbD53842c5426634e7929541eC2318f3dCF7e`).
The ETH flow and the reactive contract are unchanged from v2.

## USDC bounties (v3)

Approve the escrow, then `postProofToken(title, deadline, condition, token, amount)` or `postJudgedToken(...)` with `msg.value == postFee`
(the fee stays in ETH because it pays callback gas). The vault records **what actually arrived**, so fee-on-transfer tokens can't leave it
owing more than it holds; ETH and each token keep separate books (`openTotal`, `openTotalOf[token]`). Payouts and refunds go back in the
same token. Tested with a 6-decimal USDC look-alike, including a 1 % fee-on-transfer variant under the invariant suite.

## Trust limits and REACT runway

What the operator (the deployer key) can do: link the escrow once (`linkEscrow`), switch the cron on or off (`setCron`), and top up REACT.
What nobody can do: move bounty money anywhere except to the proven winner, the accepted claimant, or back to the issuer. There is no
admin withdraw, no upgrade proxy, no pause on payouts.

What happens if things fail:
- **Reactive out of REACT or down:** no automatic payouts or refunds. Bounty money stays in the vault; anyone can call `expire(id)` after the
  deadline to refund the issuer. A proof that happens while Reactive is down is not paid later (the deadline refund still works).
- **A callback fails** (e.g. a token that refuses transfers): the payout reverts as a whole and the bounty stays open; the next cron tick
  retries expiry after `RETRY_AFTER` (3 h). Use well-known tokens.
- **The cron is off:** proofs still pay; refunds need `expire(id)`.

REACT runway: measured on Lasna, 17 Nov. An idle Cron1000 tick costs the reactive contract 0.0112 REACT (balance 0.868691 -> 0.857461 across
block 8602000); ticks come every 1000 blocks (about 17.6 min at 1.06 s per block), so an idle contract burns about **0.92 REACT a day**.
A whole bounty lifecycle (posted, condition, proof, close) is a handful of `react()` calls of about 0.011-0.013 REACT each. At the REACT
price of 17 Nov (0.0022 USD) that is about **0.2 cents a day** idle plus about 0.01 cents per bounty; 10 REACT keeps a contract running
for over a week. When nothing is open the operator can switch the cron off (`setCron(false)`): proofs still pay, refunds then need
`expire(id)`. On the testnets the v3 cron is off until the next faucet top-up; v2 runs with the cron on.

## Post one without writing code

`web/index.html` is a one-page template picker: "pay whoever first runs job N", "pay whoever first wraps X ETH", "any event"
(contract + event signature + winner topic), or "I judge it". It shows the exact proof condition and the fee before you sign, sends
one transaction from your browser wallet on Base Sepolia, and lists the latest bounties straight from the escrow.

## Run it yourself

```shell
forge test                                   # 48 tests + 6 invariants, see below
./script/mutants.sh                          # 10 planted bugs; the suite must kill every one
./script/fund.sh lreact 0.02                 # Sepolia ETH -> Lasna lREACT (Reactive's faucet contract)
./script/fund.sh base 0.01                   # Sepolia ETH -> Base Sepolia (L1StandardBridge)
RX_FUND=1.5ether ESC_FUND=0.002ether ./script/deploy.sh
./script/demo.sh                             # proof loop, a judged bounty that refunds itself, a WETH9 third-party bounty
./script/watch_events.sh <escrow> <from block> 3   # prints each BountyPaid / BountyRefunded as it lands
```

The scripts read a testnet key from an env file (`RX_TN_KEY`, `RX_TN_ADDR`; optionally a second key `RX_KEEPER_KEY` for the keeper).

Tests (`forge test`): **48 tests and 6 invariants**, all passing.
- `test/Handshake.t.sol` (10): the full cross-chain flows through a mocked system contract and callback proxy: proof payout, filters,
  deadline refund, accept stops expiry, late proof refunds, forged callbacks, duplicate callback, fee isolation, shared subscription.
- `test/HandshakeMore.t.sol` (30): posting rules and the fee (minimum, exact split, fees pay callback gas, refund without fee),
  condition shape, judged-flow edges, callback edges that must be no-ops, a WETH9-style third-party source, reactive-side behaviour
  (wrong emitter, in-flight dedupe, idle cron, public expire closes the mirror), and 6 fuzz tests (512 runs each): fee split,
  refund only from the deadline, pays iff work >= minimum, duplicate callbacks in any order pay once, shared subscription lifetime,
  late proofs never pay.
- `test/HandshakeToken.t.sol` (8): USDC proof payout across chains, USDC refund by cron, exact ETH fee for token posts, missing
  allowance, bad token addresses, fee-on-transfer tokens, separate ETH/token books, and a fuzz test over amounts and transfer fees.
- `test/HandshakeInvariant.t.sol` (6 invariants, 64 runs x 50 random calls: ETH and USDC posts, claims, accepts, cancels, time jumps,
  proof and expiry callbacks including duplicates and wrong ids, public expiry, gas bills): the vault always equals the open bounties;
  money is conserved; no bounty is closed twice or changes after closing; callback gas is billed only from fees; the token books balance
  even with a 1 % fee-on-transfer USDC.
- `script/mutants.sh`: 10 planted bugs (a missing balance update on payout or refund, no "still open" check, paying after the deadline,
  early expiry, the fee leaking into the vault, no minimum, token books, trusting the requested token amount, no exact fee). The suite
  kills all 10.

## Limits

- Testnets only. Native ETH bounties only (ERC-20 is next).
- The posting fee covers callback gas on the escrow chain; REACT for the reactive contract is topped up by the operator. A
  mainnet run costs cents in REACT (0.002 USD each at 17 Nov prices), but needs REACT bought and bridged first.
- A wildcard proof on a busy contract (like WETH9) runs `react()` for every matching log until it pays, so keep such deadlines short.
- The deadline refund fires on the first Cron1000 tick after the deadline (about every 17 minutes), not at the exact second.
- The issuer has to describe the proof event correctly; the escrow checks the shape, not the meaning.

## License

MIT
