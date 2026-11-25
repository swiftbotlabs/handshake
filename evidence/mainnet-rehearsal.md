# Mainnet rehearsal (local forks of Reactive mainnet 1597 and Base 8453)
Generated 2026-11-25 14:27:37Z by `script/mainnet_rehearse.sh`. Nothing was sent to a real chain (anvil forks on 127.0.0.1,
anvil's public test key). Same `script/mainnet_run.sh deploy` and `bounty` steps as the live run.

- Deployed on the forks: reactive `0x5FbDB2315678afecb367f032d93F642f64180aa3` (1597), escrow `0x52edA2728B274B7a307d4Cee7EaC3b0a89Db9E78` (8453); linked; cron on; `fundedUntil()` 1795804261 after deploy.
- Posted bounty #1 "First to supply USDC to Aave v3 on Base" (Supply, reserve = USDC pinned, winner = onBehalfOf).
- Played the callback the network sends for the latest REAL USDC supply on Base (0x556464783312e155a387520d7d4b6bc75ac5ee9f14c7a076ceb24dfd60784072, by 0x644adf02388551204005b6a313396186d59d8ed6): the escrow paid
  1.00 USDC to that address (a contract). A forged callback (not the proxy) was refused. The bounty is paid in USDC on
  purpose: many Aave suppliers on Base are contracts that refuse plain ETH, and an ETH payout to one reverts.
- Event rate the cap has to absorb: 5 USDC Supply logs on the Aave v3 Base pool in the last hour (cap: 10 per hour per subscription).
- Live prices: Reactive gas 100 gwei, Base gas 0.0060 gwei, ETH $1,637.03, REACT $0.001953 (CoinGecko).

| Item | Amount | USD |
|---|---|---|
| Reactive mainnet gas: deploy + linkEscrow + setBurnRate (measured on the fork) | 0.268775 REACT | $0.0005 |
| REACT float sent with the deploy (RX_FUND) | 2.000000 REACT | $0.0039 |
| Reactions for one bounty, 6 h (25 x 231066 gas) | 0.577665 REACT | $0.0011 |
| Base gas: escrow deploy + postProof (measured on the fork) | 0.000021 ETH | $0.0348 |
| Base value: escrow gas float + posting fee | 0.000520 ETH | $0.8513 |
| Base USDC: the bounty | 1.000000 USDC | $1.0000 |
| Base callback gas (payout callback, 2x margin) | 0.000005 ETH | $0.0079 |
| **Total to have on hand** | | **$1.90** |
| of which spent for good (gas, REACT float, posting fee, escrow gas float) | | $0.90 |
| the bounty itself (1.00 USDC): to the first USDC supplier on Aave Base, or back to us at the deadline | | $1.00 |

Not on the forks: the ReactVM (react() runs only on the real network), so per-reaction cost is the documented formula
(max(gas price, base fee) x (gas used + 100,000)) with the largest reaction measured on Lasna (131,066 gas). The REACT itself must be
bought (Base DEX) and bridged to native REACT (portal.reactive.network/swap); that route's fees are not included above.
