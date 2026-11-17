// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test, Vm } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { HandshakeEscrow, BountyVault } from "../src/HandshakeEscrow.sol";
import { HandshakeReactive } from "../src/HandshakeReactive.sol";
import { KeeperJobs } from "../src/demo/KeeperJobs.sol";

/// Stand-in for Reactive's system contract (0x8888...): records subscriptions and callback requests.
contract MockSystem {
    struct Sub { uint256 chainId; address c; uint256 t0; uint256 t1; uint256 t2; uint256 t3; bool live; }
    Sub[] public subs;
    bytes[] public payloads;
    address[] public recipients;

    function subscribe(uint256 a, address b, uint256 c, uint256 d, uint256 e, uint256 f) external {
        subs.push(Sub(a, b, c, d, e, f, true));
    }
    function unsubscribe(uint256 a, address b, uint256 c, uint256 d, uint256 e, uint256 f) external {
        for (uint256 i; i < subs.length; ++i) {
            Sub storage s = subs[i];
            if (s.live && s.chainId == a && s.c == b && s.t0 == c && s.t1 == d && s.t2 == e && s.t3 == f) { s.live = false; return; }
        }
        revert("no such subscription");
    }
    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory cfg) external {
        recipients.push(cfg.recipient);
        payloads.push(cfg.payload);
    }
    function liveCount() external view returns (uint256 n) { for (uint256 i; i < subs.length; ++i) if (subs[i].live) ++n; }
    function isLive(uint256 a, address b, uint256 c, uint256 d) external view returns (bool) {
        for (uint256 i; i < subs.length; ++i) { Sub storage s = subs[i]; if (s.live && s.chainId == a && s.c == b && s.t0 == c && s.t1 == d) return true; }
        return false;
    }
    function payloadCount() external view returns (uint256) { return payloads.length; }
    function payloadAt(uint256 i) external view returns (bytes memory) { return payloads[i]; }
    function debt(address) external pure returns (uint256) { return 0; }
    function depositTo(address) external payable {}
    receive() external payable {}
}

abstract contract HandshakeBase is Test {
    address constant SYS = 0x8888888888888888888888888888888888888888;
    address constant CRON_SRC = 0x0000000000000000000000000000000000fffFfF;
    uint256 constant CRON1000 = 0xe20b31294d84c3661ddc8f423abb9c70310d0cf172aa2714ead78029b325e3f4;
    uint256 constant ESCROW_CHAIN = 84532; // Base Sepolia
    uint256 constant JOBS_CHAIN = 11155111; // Ethereum Sepolia
    uint256 constant IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    MockSystem sys;
    HandshakeReactive rx;
    HandshakeEscrow esc;
    KeeperJobs jobs;
    address proxy = address(0xC0FFEE);
    address issuer = address(0x1551);
    address hunter = address(0xB0B);
    address keeper = address(0xCAFE);

    function setUp() public virtual {
        MockSystem impl = new MockSystem();
        vm.etch(SYS, address(impl).code);
        sys = MockSystem(payable(SYS));
        rx = new HandshakeReactive();
        esc = new HandshakeEscrow(IPayable(payable(proxy)), address(rx), 1, 0);
        jobs = new KeeperJobs();
        rx.linkEscrow(ESCROW_CHAIN, address(esc));
        vm.deal(issuer, 10 ether);
        vm.warp(1_800_000_000);
    }

    // ---- plumbing: carry escrow logs into react(), and run requested callbacks through the "proxy"
    function _pipe(Vm.Log[] memory logs, uint256 chainId) internal {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            IReactive.LogRecord memory r;
            r.chainId = chainId;
            r.contractAddress = l.emitter;
            r.opCode = l.topics.length;
            if (l.topics.length > 0) r.topic0 = uint256(l.topics[0]);
            if (l.topics.length > 1) r.topic1 = uint256(l.topics[1]);
            if (l.topics.length > 2) r.topic2 = uint256(l.topics[2]);
            if (l.topics.length > 3) r.topic3 = uint256(l.topics[3]);
            r.data = l.data;
            r.txHash = uint256(keccak256(abi.encode(i, l.data)));
            if (l.emitter == address(esc) && chainId != ESCROW_CHAIN) continue;
            vm.prank(SYS);
            rx.react(r);
        }
    }
    function _tick() internal {
        IReactive.LogRecord memory r;
        r.chainId = block.chainid; r.contractAddress = CRON_SRC; r.topic0 = CRON1000; r.opCode = 1;
        r.data = abi.encode(block.number);
        vm.prank(SYS);
        rx.react(r);
    }
    uint256 delivered;
    function _deliverCallbacks() internal {
        uint256 n = sys.payloadCount();
        for (; delivered < n; ++delivered) {
            bytes memory p = sys.payloadAt(delivered);
            // the network overwrites the first argument with the requesting reactive contract
            assembly { mstore(add(p, 36), sload(rx.slot)) }
            vm.recordLogs();
            vm.prank(proxy);
            (bool ok,) = address(esc).call(p);
            require(ok, "callback reverted");
            _pipe(vm.getRecordedLogs(), ESCROW_CHAIN);
        }
    }
    function _postProof(uint256 jobId, uint256 minWork, uint256 amount, uint256 deadline) internal returns (uint256 id) {
        HandshakeEscrow.Condition memory c = HandshakeEscrow.Condition({
            chainId: JOBS_CHAIN, emitter: address(jobs), topic0: uint256(keccak256("JobRun(uint256,address,uint256)")),
            matchTopic1: true, topic1: jobId, winnerTopic: 2, minValue: minWork
        });
        vm.recordLogs();
        vm.prank(issuer);
        id = esc.postProof{ value: amount }("run job", deadline, c);
        _pipe(vm.getRecordedLogs(), ESCROW_CHAIN);
    }

}

contract HandshakeTest is HandshakeBase {
    function test_proofBountyPaysFirstKeeperAcrossChains() public {
        uint256 id = _postProof(7, 3, 1 ether, block.timestamp + 2 days);
        assertTrue(sys.isLive(JOBS_CHAIN, address(jobs), uint256(keccak256("JobRun(uint256,address,uint256)")), 7));
        vm.recordLogs();
        vm.prank(keeper);
        jobs.run(7, 5);
        _pipe(vm.getRecordedLogs(), JOBS_CHAIN);
        _deliverCallbacks();
        (,,, HandshakeEscrow.Status st,, address winner,) = esc.bounties(id);
        assertEq(uint8(st), uint8(HandshakeEscrow.Status.Paid));
        assertEq(winner, keeper);
        assertEq(keeper.balance, 1 ether);
        // the paid bounty closed in the mirror and the condition subscription was dropped
        assertFalse(sys.isLive(JOBS_CHAIN, address(jobs), uint256(keccak256("JobRun(uint256,address,uint256)")), 7));
        assertEq(rx.openCount(), 0);
    }

    function test_proofIgnoresWrongJobAndTooLittleWork() public {
        uint256 id = _postProof(7, 3, 1 ether, block.timestamp + 2 days);
        vm.recordLogs();
        vm.prank(keeper); jobs.run(8, 9);  // other job
        vm.prank(hunter); jobs.run(7, 2);  // right job, too little work
        _pipe(vm.getRecordedLogs(), JOBS_CHAIN);
        assertEq(sys.payloadCount(), 0);
        (,,, HandshakeEscrow.Status st,,,) = esc.bounties(id);
        assertEq(uint8(st), uint8(HandshakeEscrow.Status.Open));
    }

    function test_postingRulesFailClosed() public {
        vm.startPrank(issuer);
        vm.expectRevert(HandshakeEscrow.BadAmount.selector);
        esc.postJudged("no money", block.timestamp + 1 days);
        vm.expectRevert(HandshakeEscrow.BadDeadline.selector);
        esc.postJudged{ value: 1 }("past", block.timestamp);
        HandshakeEscrow.Condition memory c;
        vm.expectRevert(HandshakeEscrow.BadCondition.selector);
        esc.postProof{ value: 1 }("empty condition", block.timestamp + 1 days, c);
        vm.stopPrank();
        // nobody can refund early, anyone can refund a due bounty (fallback if Reactive is down)
        vm.prank(issuer);
        uint256 id = esc.postJudged{ value: 1 ether }("x", block.timestamp + 1 days);
        vm.expectRevert();
        esc.expire(id);
        vm.warp(block.timestamp + 1 days);
        uint256 before = issuer.balance;
        vm.prank(hunter);
        esc.expire(id);
        assertEq(issuer.balance - before, 1 ether);
    }

    function test_judgedBountyRefundsExactAmount() public {
        vm.recordLogs();
        vm.prank(issuer);
        uint256 id = esc.postJudged{ value: 0.5 ether }("logo for the zine", block.timestamp + 1 days);
        _pipe(vm.getRecordedLogs(), ESCROW_CHAIN);
        uint256 before = issuer.balance;
        vm.warp(block.timestamp + 1 days + 1);
        _tick();
        _deliverCallbacks();
        (,,, HandshakeEscrow.Status st,,,) = esc.bounties(id);
        assertEq(uint8(st), uint8(HandshakeEscrow.Status.Refunded));
        assertEq(issuer.balance - before, 0.5 ether);
        assertEq(rx.openCount(), 0);
        _tick(); // closed: no second request
        assertEq(sys.payloadCount(), 1);
    }

    function test_judgedAcceptPaysClaimantAndStopsExpiry() public {
        vm.recordLogs();
        vm.prank(issuer);
        uint256 id = esc.postJudged{ value: 0.2 ether }("translate README", block.timestamp + 1 days);
        vm.prank(hunter);
        esc.claim(id, "ipfs://draft");
        vm.prank(issuer);
        esc.accept(id, 0);
        _pipe(vm.getRecordedLogs(), ESCROW_CHAIN);
        assertEq(hunter.balance, 0.2 ether);
        vm.warp(block.timestamp + 2 days);
        _tick();
        assertEq(sys.payloadCount(), 0);
    }

    function test_lateProofDoesNotPayAndDeadlineStillRefunds() public {
        uint256 id = _postProof(7, 0, 1 ether, block.timestamp + 1 hours);
        vm.warp(block.timestamp + 2 hours);
        vm.recordLogs();
        vm.prank(keeper); jobs.run(7, 1);
        _pipe(vm.getRecordedLogs(), JOBS_CHAIN);
        assertEq(sys.payloadCount(), 0); // reactive side already sees it is too late
        uint256 before = issuer.balance;
        _tick();
        _deliverCallbacks();
        assertEq(issuer.balance - before, 1 ether);
        assertEq(keeper.balance, 0);
        (,,, HandshakeEscrow.Status st,,,) = esc.bounties(id);
        assertEq(uint8(st), uint8(HandshakeEscrow.Status.Refunded));
    }

    function test_forgedCallbacksAreRejected() public {
        uint256 id = _postProof(7, 0, 1 ether, block.timestamp + 1 days);
        // not the proxy
        vm.expectRevert();
        esc.settleProof(address(rx), id, hunter, bytes32(0));
        // the proxy, but another reactive contract
        vm.prank(proxy);
        vm.expectRevert();
        esc.settleProof(address(0xBAD), id, hunter, bytes32(0));
        // react() only from the system contract
        IReactive.LogRecord memory r;
        vm.expectRevert();
        rx.react(r);
    }

    function test_duplicateCallbackCannotPayTwice() public {
        uint256 id = _postProof(7, 0, 1 ether, block.timestamp + 1 days);
        vm.prank(proxy);
        esc.settleProof(address(rx), id, keeper, bytes32(0));
        vm.prank(proxy);
        esc.settleProof(address(rx), id, hunter, bytes32(0)); // skipped, no revert
        assertEq(keeper.balance, 1 ether);
        assertEq(hunter.balance, 0);
    }

    function test_callbackFeesNeverTouchBountyMoney() public {
        uint256 id = _postProof(7, 0, 1 ether, block.timestamp + 1 days);
        vm.deal(address(esc), 0.01 ether); // gas float for callback fees
        vm.prank(proxy);
        vm.expectRevert(); // asking for more than the gas float fails; the bounty sits in the vault
        esc.pay(0.02 ether);
        assertEq(address(esc.vault()).balance, 1 ether);
        id;
    }

    function test_sharedConditionKeepsSubscriptionUntilLastCloses() public {
        uint256 a = _postProof(7, 0, 0.1 ether, block.timestamp + 1 days);
        uint256 b = _postProof(7, 0, 0.1 ether, block.timestamp + 3 days);
        uint256 t0 = uint256(keccak256("JobRun(uint256,address,uint256)"));
        vm.warp(block.timestamp + 1 days + 1);
        _tick();
        _deliverCallbacks(); // a refunds
        assertTrue(sys.isLive(JOBS_CHAIN, address(jobs), t0, 7)); // b still needs it
        vm.recordLogs();
        vm.prank(keeper); jobs.run(7, 1);
        _pipe(vm.getRecordedLogs(), JOBS_CHAIN);
        _deliverCallbacks(); // b pays
        assertFalse(sys.isLive(JOBS_CHAIN, address(jobs), t0, 7));
        assertEq(keeper.balance, 0.1 ether);
        a; b;
    }
}
