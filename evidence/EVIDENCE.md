# Every loop, every hash

**9 proofs seen, 7 paid, 2 ignored by design, 4 unattended refunds, 0 stuck; median 2 s proof to payout (max 2 s).**

Built from chain data only by `python3 -I -u script/triples.py` on 2026-11-25 12:34:38 UTC (Base Sepolia block 63441020, Lasna block 9217388). Machine-readable: [`triples.csv`](triples.csv), [`totals.json`](totals.json).
Each Reactive request (a `ProofSeen` or `ExpiryRequested` log of the reactive contract on Lasna) is paired with the callback that landed on the escrow; a request with no landed callback would be listed as **stuck**. Proof times are the origin block's timestamp, callback times the settlement block's. Reproduce any paid loop without sending anything: `script/dryrun.sh <version> <bounty id>`.

## Reproduce it yourself (read-only, sends nothing)

```
python3 -I -u script/triples.py      # rebuild this page, triples.csv and totals.json from public RPCs
./script/dryrun.sh v5 2              # replay the Aave v3 loop: real logs -> local HandshakeReactive -> callback on a Base Sepolia fork
./script/dryrun.sh v4 1 0x0f5ebe2d9ba48f2a8320fdd08d0be59235db137108850f6893cd8a3de49ce5a4   # the front-runner: dropped, no callback
./script/coverage.sh                 # forge coverage of src/
```

`dryrun.sh` needs only Foundry and public RPCs. It feeds the bounty's real escrow logs and every log of the real proof transaction into a local `HandshakeReactive`, checks it requests exactly the callback the network delivered, then delivers that callback as the callback proxy on a fork of Base Sepolia one block before the real payout and checks the same winner gets the same amount. It runs the current source; v1 and v2 were deployed from earlier commits, so for those it shows the current code reaches the same result from the same logs.

## Totals

| Route | Proofs seen | Paid | Ignored (allowlist) | Cron refunds | Callbacks refused by escrow | Stuck | Closed by issuer | Open | Median s | Max s |
|---|---|---|---|---|---|---|---|---|---|---|
| Base Sepolia escrow, v1-v5 | 9 | 7 | 2 | 4 | 0 | 0 | 1 | 1 | 2 | 2 |
| Experiment: escrow on Lasna itself (L1) | 1 | 0 | 0 | 0 | 0 | 1 | 1 | 1 | - | - |

## Test coverage of the contracts (`script/coverage.sh`, `forge coverage` over src/)

91 tests passed, 0 failed, 1 skipped (92 total tests).

| File                      | % Lines           | % Statements      | % Branches       | % Funcs         |
|---|---|---|---|---|
| src/HandshakeEscrow.sol   | 100.00% (188/188) | 99.59% (240/241)  | 98.08% (51/52)   | 100.00% (30/30) |
| src/HandshakeReactive.sol | 100.00% (142/142) | 100.00% (183/183) | 100.00% (47/47)  | 100.00% (20/20) |
| src/demo/KeeperJobs.sol   | 100.00% (4/4)     | 100.00% (3/3)     | 100.00% (2/2)    | 100.00% (1/1)   |
| Total                     | 100.00% (334/334) | 99.77% (426/427)  | 99.01% (100/101) | 100.00% (51/51) |

Not reached by any test:

- `branch src/HandshakeEscrow.sol:328  if (!ok) revert TransferFailed();`
  (the vault is a fixed contract that always accepts ETH from the escrow, so this revert cannot be triggered without changing deployed code)

## v1 (escrow on Base Sepolia)

| # | Bounty | Outcome | Post | Proof (origin) | react() (Lasna) | Callback | s | Winner / note |
|---|---|---|---|---|---|---|---|---|
| 1 | Run job 1794944716 on Sepolia | **paid** | [post](https://sepolia.basescan.org/tx/0x87db67d67cc1c734ef95ba0e005505c04b195e3b5328c88e5f3a3a320f2636fc) | [19:46:24](https://sepolia.etherscan.io/tx/0x0f250aa8e33ce6de0f8319f2a6b357028c2121499b1cbaa36c769b3990105151) | [19:46:24](https://lasna.reactscan.net/tx/0xaf8f85131db7df89e3da27337dd4e78895ba28f67d99527e03a87530fb772c3b) | [19:46:26](https://sepolia.basescan.org/tx/0xdf48283586407fddb8e1c0c55aeab613dfa862a068bfaaa82f3e01ff56ce1fb7) | 2 | 0.0005 ETH · 0x950b75a7… |
| 2 | Unclaimed demo bounty | **refunded (cron)** | [post](https://sepolia.basescan.org/tx/0x0c6c628781eb04f706d5a9d8ac89264f45052872db07c1b7f112c94655c0b7f8) |  | [20:20:37](https://lasna.reactscan.net/tx/0x061766960451b97af39abfb6d9e5d5759e4357e92db34296a0b10831f2ad8f03) | [20:20:39](https://sepolia.basescan.org/tx/0x0eec3c542ee34ae94c4062b80f43ddd73a9304a2bf2165880556ab4d4af60e3a) | 854 | 0.0003 ETH · deadline 2026-11-17 20:06:25; Cron1000 tick -> callback refunded the issuer; seconds = refund minus deadline |

## v2 (escrow on Base Sepolia)

| # | Bounty | Outcome | Post | Proof (origin) | react() (Lasna) | Callback | s | Winner / note |
|---|---|---|---|---|---|---|---|---|
| 1 | Run job 1794948400 on Sepolia | **paid** | [post](https://sepolia.basescan.org/tx/0x3d86c6db43d09edcd9d3b7e8374c3a5d22603610f6fe1c100932f0b81c339be8) | [20:47:48](https://sepolia.etherscan.io/tx/0xb239357ab0ac233ddf8725033c4f794db1bc4c0bed82b93194bcec401a172824) | [20:47:48](https://lasna.reactscan.net/tx/0x36763649425b534222e2de5f99165a9ff984b1748665f59a059ed91b30ce644b) | [20:47:50](https://sepolia.basescan.org/tx/0x8e32730b2326d68f22b3b131acf2ff3b09bb1d63b75b727f6660d77dd6f21e42) | 2 | 0.00048 ETH · 0x950b75a7… |
| 2 | Unclaimed demo bounty | **refunded (cron)** | [post](https://sepolia.basescan.org/tx/0x36f7207e1a64ea85d167429ea50f74719bc6244226de0cea88da9a8d2f3988e3) |  | [21:13:40](https://lasna.reactscan.net/tx/0xfa378fffb04b678c88d00491d3e8252423aed778f4ec71372cfcb293bc02b09f) | [21:13:43](https://sepolia.basescan.org/tx/0x2bac5bea0382b20baa77302d1c1c55c6ff506a200959b798055f5166ad0bcbc6) | 354 | 0.00028 ETH · deadline 2026-11-17 21:07:49; Cron1000 tick -> callback refunded the issuer; seconds = refund minus deadline |
| 3 | First to wrap 0.003 ETH on Sepolia WETH | **paid** | [post](https://sepolia.basescan.org/tx/0x15dca0d75ef79fc639f67ab717b3439e70974ea2962a5b3938f92b0ed3077ce0) | [20:57:24](https://sepolia.etherscan.io/tx/0x8fe9b7ab8046db99e0d176d5a50e9c84df377911138cb6b957abcb1c9790d4c6) | [20:57:23](https://lasna.reactscan.net/tx/0xda9fa1b159fd63e2997e73d0adf413d3a2f1e47987193442698ca2b67873d64d) | [20:57:26](https://sepolia.basescan.org/tx/0x0208fa60ffb87c76d481a0ee9039122bb177549154eaf474126cfa946e857df8) | 2 | 0.00015 ETH · 0x78fc1fa1… |

## v3 (escrow on Base Sepolia)

| # | Bounty | Outcome | Post | Proof (origin) | react() (Lasna) | Callback | s | Winner / note |
|---|---|---|---|---|---|---|---|---|
| 1 | Run job 1794951801 on Sepolia (v3) | **paid** | [post](https://sepolia.basescan.org/tx/0x0283301499c66b428077497a3a033abf79ab298152d435cdf3f547458ca42d44) | [21:44:24](https://sepolia.etherscan.io/tx/0x8a575b3582899a66763c1d630ff3567a17deb4a997f0320bb6c902a7b3ff06cb) | [21:44:24](https://lasna.reactscan.net/tx/0x214e6efa1e90ed2a2ed1bf7ed9e5d5df05606068cdeba1e8749cffb952e587b0) | [21:44:26](https://sepolia.basescan.org/tx/0xabd7d9637764a2485a051d1b8884da3d953853b2fbfd5b6397392c5b34b9337e) | 2 | 0.0003 ETH · 0x950b75a7… |
| 2 | Run job 1794951884 on Sepolia for 5 USDC | **paid** | [post](https://sepolia.basescan.org/tx/0xde9732e1e600181885309d2304d473cc6adca3b322f62fcf9e4893716388f2a6) | [21:45:36](https://sepolia.etherscan.io/tx/0x3d368f8b9830dd38a0f509f4bfa04f7dd85222081114ef14fa8904b9beb07703) | [21:45:35](https://lasna.reactscan.net/tx/0xe7e69a803bca706b511db495481563c5ba0249a032a98b11de6b51def5acc369) | [21:45:37](https://sepolia.basescan.org/tx/0x1bf02decfc9892c9bea0ecd74ed5d31efaca5b6e375cc3c2f25180c5ee5a87c9) | 1 | 5 USDC · 0x950b75a7… |

## v4 (escrow on Base Sepolia)

| # | Bounty | Outcome | Post | Proof (origin) | react() (Lasna) | Callback | s | Winner / note |
|---|---|---|---|---|---|---|---|---|
| 1 | Wrap >= 0.00005 ETH on Sepolia WETH (keeper only) | **ignored** | [post](https://sepolia.basescan.org/tx/0xdbcc68de8b2ec2c07941fe3934e336cbe46ea2bae0bc838dc09a22a6b99a2177) | [22:04:00](https://sepolia.etherscan.io/tx/0x0f5ebe2d9ba48f2a8320fdd08d0be59235db137108850f6893cd8a3de49ce5a4) | [22:03:59](https://lasna.reactscan.net/tx/0xd084bc716d15ef494d9e4dbb9b4ab888dd52669e36e2b5138405734c678cd383) |  | -1 | 0x285c41ec… named address not on the bounty's allowlist: dropped on Reactive, no callback sent (by design) |
| 1 | Wrap >= 0.00005 ETH on Sepolia WETH (keeper only) | **ignored** | [post](https://sepolia.basescan.org/tx/0xdbcc68de8b2ec2c07941fe3934e336cbe46ea2bae0bc838dc09a22a6b99a2177) | [22:04:12](https://sepolia.etherscan.io/tx/0xfc895a7d50fc1444097118d9d4b2fcbdd65ed9ec60f877a4bd1104cabe5c844d) | [22:04:12](https://lasna.reactscan.net/tx/0x82b0a2ffec77e900abbfe88b4428b23f2c6b131b392d24925868996c7a99365b) |  | 0 | 0x6acf89a6… named address not on the bounty's allowlist: dropped on Reactive, no callback sent (by design) |
| 1 | Wrap >= 0.00005 ETH on Sepolia WETH (keeper only) | **paid** | [post](https://sepolia.basescan.org/tx/0xdbcc68de8b2ec2c07941fe3934e336cbe46ea2bae0bc838dc09a22a6b99a2177) | [22:05:00](https://sepolia.etherscan.io/tx/0x5d0ccd5452d280711cbf50fd42e1566221e72ea24ae5591380b56ce6a30d11bc) | [22:05:00](https://lasna.reactscan.net/tx/0x3354c621e25ea847eac885d1ad697d38c58bcb3804d2df140e5cde854a8a05f4) | [22:05:02](https://sepolia.basescan.org/tx/0xaa5cd34e52fed32ed235e9ef8e35a051550bed39786d00cffea7bd89459ab1f3) | 2 | 0.0001 ETH · 0x950b75a7… |
| 2 | Open to anyone: run job 4242 on the Sepolia job board | **closed by issuer** | [post](https://sepolia.basescan.org/tx/0x841a88dc30e58ab4b9105a38af3c8e282eba1e875b3973b575d48aca40944f7a) |  |  | [23:20:58](https://sepolia.basescan.org/tx/0x41339e1819ac9e14470040cd67582dade86a60c483af5dae668cca2a9a7e385f) |  | 0.0005 ETH · cancel() by issuer |

## v5 (escrow on Base Sepolia)

| # | Bounty | Outcome | Post | Proof (origin) | react() (Lasna) | Callback | s | Winner / note |
|---|---|---|---|---|---|---|---|---|
| 1 | Unattended refund test (v5): nobody will claim this | **refunded (cron)** | [post](https://sepolia.basescan.org/tx/0xb8027e8616f444aec981a5fae8e6dc5f0dbfeeeb66887ea909139e9875f4b1da) |  | [23:17:11](https://lasna.reactscan.net/tx/0xe451e8f1b7053a141395f964aeafaf2a0332231c63849ee520afcba6f1563d39) | [23:17:14](https://sepolia.basescan.org/tx/0x04074579df25c7d9f0ccb63f27a5025e6947c9d89b1a2e7dcce4c2bcbdf28083) | 433 | 0.0001 ETH · deadline 2026-11-17 23:10:01; Cron1000 tick -> callback refunded the issuer; seconds = refund minus deadline |
| 2 | First to supply WBTC to Aave v3 on Sepolia | **paid** | [post](https://sepolia.basescan.org/tx/0xba9887d779252df7ba4d589d48772b0c3ddd41a003fc85822db64cbc5ce28b44) | [22:50:36](https://sepolia.etherscan.io/tx/0xfed5365395b7a5cc2d0a1d027eb7f268ee9ca912901526644302c9cc6a48e725) | [22:50:36](https://lasna.reactscan.net/tx/0xac93f7450f67f31ea4a61eceee3ad18096d7577099da2719d710d6c918c97468) | [22:50:38](https://sepolia.basescan.org/tx/0xa3d235420b2711ef47e4eb30c38174cd458b93e77c636957483ff49f6f4e0be5) | 2 | 0.0001 ETH · 0x7a3db09c… |
| 3 | Open to anyone: run job 4243 on the Sepolia job board | **refunded (cron)** | [post](https://sepolia.basescan.org/tx/0x9c9a9831eb452c0f7b21612d54dc305c046825ea2a7fd6850f69a15b0c3aa1a8) |  | [23:29:51](https://lasna.reactscan.net/tx/0x72cf69b7681aa5cb3d8c2eee3d037512181ff1d9b553036f0355942515e07fd7) | [23:29:53](https://sepolia.basescan.org/tx/0x2aba3b7145fe5931aaed5f797cdf826c9482145e60015af4a8026e2be984b02f) | 535 | 0.0005 ETH · deadline 2026-11-24 23:20:58; Cron1000 tick -> callback refunded the issuer; seconds = refund minus deadline |
| 4 | Open to anyone: run job 4244 on the Sepolia job board | **open** | [post](https://sepolia.basescan.org/tx/0x5446ff9417ee3faefde82f1db038209b60ba5962ad41d6b6b553639472cde4ce) |  |  |  |  | deadline 2026-12-07 21:00:00 |

## Experiment L1: escrow on Lasna (Lasna -> Lasna callbacks)

| # | Bounty | Outcome | Post | Proof (origin) | react() (Lasna) | Callback | s | Winner / note |
|---|---|---|---|---|---|---|---|---|
| 1 | First to supply WBTC to Aave v3 on Sepolia (paid in lREACT o | **open, past deadline** | [post](https://lasna.reactscan.net/tx/0xc774cd354d3aee788443b9f0931ddf0a0cbf0cef31ddec42f6b6a3c994dd2114) |  |  |  |  | deadline 2026-11-23 04:57:59; no refund has landed on this escrow yet |
| 2 | First to wrap 0.003 ETH on Sepolia WETH (paid in lREACT on L | **stuck** | [post](https://lasna.reactscan.net/tx/0xfcd551a3b330af5fcd246994a70f835c37d0ddd0154a4aa16f8212c01099c3be) | [04:58:24](https://sepolia.etherscan.io/tx/0xbc4b80d9e190d6bade27989f1911efce1770f07b283b76a7a8a4ef4ecfcab37a) | [04:58:24](https://lasna.reactscan.net/tx/0x90cfc79086a821695ee301a125db7af9ff472b455e611bc766bad6bde6e3d657) |  |  | 0xb97f6998… Reactive requested a callback to Reactive Lasna; nothing landed on the escrow (4776 min so far) |
| 2 | First to wrap 0.003 ETH on Sepolia WETH (paid in lREACT on L | **closed by issuer** | [post](https://lasna.reactscan.net/tx/0xfcd551a3b330af5fcd246994a70f835c37d0ddd0154a4aa16f8212c01099c3be) |  |  | [11:40:20](https://lasna.reactscan.net/tx/0x898698f60c921c35ac9375054d0074feede8d3bbe1421e11fafa0a6ef56fd3c6) |  | 0.19 lREACT · expire() by anyone |

## How to read it, and what it does not show

- **paid**: a matching event on the origin chain, `ProofSeen` on Lasna, then `BountyPaid` on the escrow. Seconds = payout block time minus proof block time.
- **ignored**: the event named an address outside the bounty's allowlist (front-run tests); Reactive emitted `ProofIgnored` and sent no callback. That is the guard working, not a failure.
- **refunded (cron)**: nobody won by the deadline; a Cron1000 tick on Lasna requested the refund. Seconds = refund minus deadline (the tick runs about every 17 minutes).
- **skipped (no-op)**: a callback landed but the escrow's own re-check refused it (already closed, past deadline). No money moved.
- **closed by issuer**: the issuer cancelled, or someone called the public `expire()` fallback. No Reactive leg.
- **stuck**: Reactive requested a callback and nothing landed within 30 minutes.
- Experiment L1 put the escrow on Lasna itself (Reactive as the destination chain). Its callbacks were never relayed by the network, so those rows show as stuck; the reactive side worked. It is a separate rehearsal, not part of the Base totals.
- Block clocks differ by about a second between chains, so a Lasna `react()` can carry a timestamp one second before the origin block it reacted to. Seconds are computed from block timestamps as they are, never adjusted.
- Experiment L1, bounty 1 (Aave WBTC, deadline 23 Nov): its reactive contract was drained by per-event billing (see below) and its refund request never reached the escrow, so it is listed as open past its deadline. The issuer can still recover it with the public `expire()`.
- **Billing lesson (22 Nov).** Reactive bills every matching event the contract reacts to, about 0.0125 lREACT each on Lasna, not only cron ticks. The L1 WETH9 bounty subscribed to every `Deposit` on Sepolia WETH9 and 155 reactions drained the contract in about 2.5 hours. `fundedUntil()` models cron ticks only, so it showed days of runway while events were draining it. Budget per matching event, and pin low-volume proofs (topic1-filtered) instead of an unfiltered busy event.
- All of this is testnet (Ethereum Sepolia, Base Sepolia, Lasna). No mainnet run yet.
