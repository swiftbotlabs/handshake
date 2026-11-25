// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Vm } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { HandshakeEscrow } from "../src/HandshakeEscrow.sol";
import { HandshakeReactive } from "../src/HandshakeReactive.sol";
import { HandshakeBase, MockSystem } from "./Handshake.t.sol";

interface IERC20Bal { function balanceOf(address) external view returns (uint256); }

/// DRY RUN of one real loop, sending nothing. Run it through `script/dryrun.sh <version> <bounty id> [proof tx]`.
///   1. Reads the bounty's real escrow logs (post block) from Base Sepolia, and every log of the real proof transaction on the origin chain.
///   2. Feeds them into a LOCAL copy of HandshakeReactive (the same source that is deployed on Lasna, verified on Sourcify) and checks
///      that it asks for exactly the callback the network delivered: same bounty, same winner, same proof tx (or, for an ignored
///      proof, that it sends nothing).
///   3. On a local fork of Base Sepolia one block before the real payout, delivers that callback as the real callback proxy would and
///      checks the escrow pays the same winner the same amount, as the real BountyPaid log says.
/// Everything happens in forge's in-memory EVM; no transaction is signed or broadcast. Skipped unless HS_REPLAY=1.
contract HandshakeReplay is HandshakeBase {
    bytes32 constant PAID = keccak256("BountyPaid(uint256,address,uint256,uint8,bytes32)");
    bytes32 constant CONDITION = keccak256("ProofCondition(uint256,uint256,address,uint256,bool,uint256,uint8,uint256)");
    bytes32 constant IGNORED = keccak256("ProofIgnored(uint256,address,uint256)");
    bytes32 constant SEEN = keccak256("ProofSeen(uint256,address,uint256)");

    function setUp() public override { } // no mock world: everything below comes from chain

    // inputs and intermediate results live in storage (keeps the stack small)
    address escrow;
    uint256 id;
    bytes32 proofTx;
    uint256 originChain;
    uint256 proofBlock;
    uint256 postBlock;
    uint256 forkBlock;
    bool expectPaid;
    uint256 baseFork;
    uint256 proofTs;
    uint256 forkTs;
    bytes payload;

    function test_replayOneLoop() public {
        if (!vm.envOr("HS_REPLAY", false)) {
            vm.skip(true, "dry run only: use script/dryrun.sh");
        }
        escrow = vm.envAddress("HS_ESCROW");
        id = vm.envUint("HS_ID");
        proofTx = vm.envBytes32("HS_PROOF_TX");
        originChain = vm.envUint("HS_ORIGIN_CHAIN");
        proofBlock = vm.envUint("HS_PROOF_BLOCK");
        postBlock = vm.envUint("HS_POST_BLOCK");
        forkBlock = vm.envUint("HS_FORK_BLOCK"); // payout block - 1 (or the post block for an ignored proof)
        expectPaid = vm.envBool("HS_EXPECT_PAID");
        Vm.EthGetLogs[] memory posted;
        Vm.EthGetLogs[] memory proofLogs;
        (posted, proofLogs) = _readChain();
        if (!_reactLocally(posted, proofLogs)) return;
        _settleOnFork();
    }

    /// 1. the real logs: the bounty's escrow logs from its post block, and the proof log from the origin chain
    function _readChain() internal returns (Vm.EthGetLogs[] memory posted, Vm.EthGetLogs[] memory proofLogs) {
        baseFork = vm.createSelectFork(vm.envString("HS_BASE_RPC"), forkBlock);
        forkTs = block.timestamp;
        posted = vm.eth_getLogs(postBlock, postBlock, escrow, new bytes32[](0));
        (uint256 cChain,,) = _condition(posted, id);
        require(cChain == originChain, "origin chain mismatch");
        emit log_named_uint("escrow logs for this bounty in its post block", _countFor(posted, id));
        // The origin chain's public nodes prune old state, so the proof transaction's receipt logs and block time come in as JSON
        // (fetched by script/dryrun.sh with eth_getTransactionReceipt). Every log of that transaction is delivered, as the network does.
        string memory j = vm.envString("HS_PROOF_LOGS_JSON");
        uint256 n = vm.envUint("HS_PROOF_LOG_COUNT");
        proofTs = vm.envUint("HS_PROOF_TS");
        proofLogs = new Vm.EthGetLogs[](n);
        for (uint256 i; i < n; ++i) {
            string memory k = string.concat("[", vm.toString(i), "]");
            proofLogs[i].emitter = vm.parseJsonAddress(j, string.concat(k, ".address"));
            proofLogs[i].topics = vm.parseJsonBytes32Array(j, string.concat(k, ".topics"));
            proofLogs[i].data = vm.parseJsonBytes(j, string.concat(k, ".data"));
            proofLogs[i].transactionHash = proofTx;
        }
    }

    /// 2. the reactive side, locally: same source as the deployed contract, fed the real logs
    function _reactLocally(Vm.EthGetLogs[] memory posted, Vm.EthGetLogs[] memory proofLogs) internal returns (bool paid) {
        vm.etch(SYS, address(new MockSystem()).code);
        sys = MockSystem(payable(SYS));
        rx = new HandshakeReactive();
        rx.linkEscrow(ESCROW_CHAIN, escrow);
        for (uint256 i; i < posted.length; ++i) {
            if (posted[i].topics.length > 1 && uint256(posted[i].topics[1]) == id) _react(posted[i], ESCROW_CHAIN);
        }
        vm.warp(proofTs);
        uint256 before = sys.payloadCount();
        vm.recordLogs();
        for (uint256 i; i < proofLogs.length; ++i) _react(proofLogs[i], originChain);
        Vm.Log[] memory rlogs = vm.getRecordedLogs();
        if (!expectPaid) {
            assertEq(sys.payloadCount(), before, "an ignored proof must not request a callback");
            assertTrue(_has(rlogs, IGNORED, id), "expected ProofIgnored");
            emit log("OK: the reactive contract dropped this proof (claimant not on the allowlist); no callback requested");
            return false;
        }
        assertEq(sys.payloadCount(), before + 1, "expected exactly one callback request");
        assertTrue(_has(rlogs, SEEN, id), "expected ProofSeen");
        payload = sys.payloadAt(before);
        return true;
    }

    /// 3. the settlement side, on a fork of Base Sepolia one block before the real payout
    function _settleOnFork() internal {
        vm.warp(forkTs);
        HandshakeEscrow esc_ = HandshakeEscrow(payable(escrow));
        bytes memory p = payload;
        address sender = esc_._CALLBACK_SENDER();
        assembly { mstore(add(p, 36), sender) } // the network fills the first argument with the reactive sender
        (,,,, uint256 amount,,) = esc_.bounties(id);
        address token; // v1-v2 escrows predate ERC-20 bounties and have no tokenOf()
        (bool hasTok, bytes memory tok) = escrow.staticcall(abi.encodeWithSignature("tokenOf(uint256)", id));
        if (hasTok && tok.length == 32) token = abi.decode(tok, (address));
        (, uint256 pid, address winner, bytes32 ptx) = abi.decode(_args(p), (address, uint256, address, bytes32));
        assertEq(pid, id);
        assertEq(ptx, proofTx);
        uint256 bal = _bal(token, winner);
        vm.prank(address(esc_._SERVICE_PROVIDER()));
        vm.recordLogs();
        (bool ok,) = escrow.call(p);
        require(ok, "callback reverted on the fork");
        assertTrue(_has(vm.getRecordedLogs(), PAID, id), "expected BountyPaid");
        uint256 got = _bal(token, winner) - bal;
        assertEq(got, amount, "winner did not receive the bounty");
        _compareWithChain(winner);
        emit log_named_address("winner (same as on chain)", winner);
        emit log_named_uint("amount paid on the fork (wei or token units)", got);
        emit log("OK: proof -> react() -> callback -> BountyPaid reproduced locally; nothing was sent");
    }

    function _compareWithChain(address winner) internal view {
        Vm.EthGetLogs[] memory real = vm.eth_getLogs(forkBlock + 1, forkBlock + 1, escrow, new bytes32[](0));
        bool same;
        for (uint256 i; i < real.length; ++i) {
            if (real[i].topics[0] == PAID && uint256(real[i].topics[1]) == id) {
                same = address(uint160(uint256(real[i].topics[2]))) == winner;
                (, bytes32 realProof) = abi.decode(real[i].data, (uint256, bytes32));
                assertEq(realProof, proofTx, "the real BountyPaid names a different proof");
            }
        }
        assertTrue(same, "the real BountyPaid (next block) names a different winner, or is missing");
    }

    function _bal(address token, address who) internal view returns (uint256) {
        return token == address(0) ? who.balance : IERC20Bal(token).balanceOf(who);
    }

    // ---------------------------------------------------------------- helpers

    function _react(Vm.EthGetLogs memory l, uint256 chainId) internal {
        IReactive.LogRecord memory r;
        r.chainId = chainId;
        r.contractAddress = l.emitter;
        r.opCode = l.topics.length;
        if (l.topics.length > 0) r.topic0 = uint256(l.topics[0]);
        if (l.topics.length > 1) r.topic1 = uint256(l.topics[1]);
        if (l.topics.length > 2) r.topic2 = uint256(l.topics[2]);
        if (l.topics.length > 3) r.topic3 = uint256(l.topics[3]);
        r.data = l.data;
        r.txHash = uint256(l.transactionHash);
        vm.prank(SYS);
        rx.react(r);
    }

    function _condition(Vm.EthGetLogs[] memory ls, uint256 id) internal pure returns (uint256 c, address e, uint256 t0) {
        for (uint256 i; i < ls.length; ++i) {
            if (ls[i].topics[0] == CONDITION && uint256(ls[i].topics[1]) == id) {
                (c, e, t0) = abi.decode(ls[i].data, (uint256, address, uint256));
                return (c, e, t0);
            }
        }
        revert("no ProofCondition for this bounty in its post block");
    }

    function _countFor(Vm.EthGetLogs[] memory ls, uint256 id) internal pure returns (uint256 n) {
        for (uint256 i; i < ls.length; ++i) if (ls[i].topics.length > 1 && uint256(ls[i].topics[1]) == id) ++n;
    }

    function _has(Vm.Log[] memory ls, bytes32 t0, uint256 id) internal pure returns (bool) {
        for (uint256 i; i < ls.length; ++i) {
            if (ls[i].topics.length > 1 && ls[i].topics[0] == t0 && uint256(ls[i].topics[1]) == id) return true;
        }
        return false;
    }

    function _args(bytes memory p) internal pure returns (bytes memory a) {
        a = new bytes(p.length - 4);
        for (uint256 i; i < a.length; ++i) a[i] = p[i + 4];
    }
}
