# Handshake testnet run, 17 Nov 2026
Times at the start of each line are when the script or I WROTE the line (wall clock of the logging machine, sometimes minutes later),
not chain time. For latency use block timestamps: `./script/latency.sh <job tx> <lasna tx> <payout tx>`.
Proof loop by block timestamp: job tx Sepolia block 12156559 at 19:46:24 UTC -> ProofSeen Lasna block 8595062 at 19:46:24 UTC ->
BountyPaid Base Sepolia block 60114588 at 19:46:26 UTC (+2 s). Deadline loop: refund Base Sepolia block 60124851 at 20:20:39 UTC.

- 2026-11-17T19:45:18Z A1 postProof job=1794944716 (Base Sepolia) 0x87db67d67cc1c734ef95ba0e005505c04b195e3b5328c88e5f3a3a320f2636fc
- 2026-11-17T19:46:25Z A2 keeper 0x950B75A737993033108015974dDcDdC39185BBf3 (not the issuer) runs job 1794944716 (Ethereum Sepolia) 0x0f250aa8e33ce6de0f8319f2a6b357028c2121499b1cbaa36c769b3990105151
- 2026-11-17T19:46:25Z A3 wait for BountyPaid on Base Sepolia (Reactive callback): check 0xb7B6a6E5Fc852FBcC5E62a0db92e0edb6429d769 events
- 2026-11-17T19:46:28Z B1 postJudged, deadline +20 min (Base Sepolia) 0x0c6c628781eb04f706d5a9d8ac89264f45052872db07c1b7f112c94655c0b7f8; expect BountyRefunded via=1 within ~40 min
- 2026-11-17T19:47:04Z A3 PAID: BountyPaid id=1 winner=0x950B75A737993033108015974dDcDdC39185BBf3 via=1 (reactive callback) Base Sepolia block 60114588 tx 0xdf48283586407fddb8e1c0c55aeab613dfa862a068bfaaa82f3e01ff56ce1fb7; job run block ts 1794944784 -> paid block ts 1794944786 = 2 s
- 2026-11-17T19:47:32Z Lasna (reactive): Watching id=1 tx 0xe94253aec7eac2701f3fc456db274ed490765904eb897d14f2fdee777a369375; ProofSeen id=1 winner 0x950B...BBf3 tx 0xaf8f85131db7df89e3da27337dd4e78895ba28f67d99527e03a87530fb772c3b (block 8595062); Closed id=1 tx 0x0082686cd29af2460724d7aec744e4642d0fc1379229d3caa4c199cd20e605f5; Watching id=2 tx 0x367efb9eee3715cc2b041f45d95639fad0f84b2ef3a728f82bb04cb0b9bab118
- 2026-11-17T20:21:21Z B2 Cron1000 tick on Lasna requests the refund: ExpiryRequested id=2 tx 0x061766960451b97af39abfb6d9e5d5759e4357e92db34296a0b10831f2ad8f03 (block 8597001); B3 REFUNDED on Base Sepolia: BountyRefunded id=2 0.0003 ETH to the issuer, via=1 (reactive), tx 0x0eec3c542ee34ae94c4062b80f43ddd73a9304a2bf2165880556ab4d4af60e3a (block 60124851, ts 1794946839); Closed id=2 on Lasna tx 0x12e03e2ea74f28e1f505d2fa57b1cde909efd1779dbef68fdb34d91edde0a50e
