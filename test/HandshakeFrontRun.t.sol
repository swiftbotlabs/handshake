// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Vm } from "forge-std/Test.sol";
import { HandshakeEscrow } from "../src/HandshakeEscrow.sol";
import { HandshakeReactive } from "../src/HandshakeReactive.sol";
import { HandshakeBase } from "./Handshake.t.sol";
import { KeeperJobsLike } from "./HandshakeMore.t.sol";

/// Front-running: a bot copies the claimant's job tx (same calldata, higher gas) and gets itself named in the proof log.
/// With an allowlist the bot is ignored by the watcher, refused again by the escrow, and the bounty stays open.
contract HandshakeFrontRunTest is HandshakeBase {
    address bot = address(0xB07);
    KeeperJobsLike open; // a proof source anyone may emit more than once (e.g. "deposit >= X")

    function _cond(address emitter, uint256 jobId) internal pure returns (HandshakeEscrow.Condition memory c) {
        c = HandshakeEscrow.Condition({
            chainId: JOBS_CHAIN, emitter: emitter, topic0: uint256(keccak256("JobRun(uint256,address,uint256)")),
            matchTopic1: true, topic1: jobId, winnerTopic: 2, minValue: 0
        });
    }

    function _postFor(address emitter, uint256 jobId, address who) internal returns (uint256 id) {
        address[] memory list = new address[](1);
        list[0] = who;
        vm.recordLogs();
        vm.prank(issuer);
        id = esc.postProofFor{ value: 1 ether }("run job", block.timestamp + 1 days, _cond(emitter, jobId), list);
        _pipe(vm.getRecordedLogs(), ESCROW_CHAIN);
    }

    function _st(uint256 id) internal view returns (HandshakeEscrow.Status st, address winner) {
        (,,, st,, winner,) = esc.bounties(id);
    }

    function setUp() public override {
        super.setUp();
        open = new KeeperJobsLike();
    }

    function test_allowlistIsEmittedBeforeTheCondition() public {
        address[] memory list = new address[](1);
        list[0] = keeper;
        vm.recordLogs();
        vm.prank(issuer);
        esc.postProofFor{ value: 1 ether }("x", block.timestamp + 1 days, _cond(address(jobs), 7), list);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 allowedAt = type(uint256).max;
        uint256 condAt;
        for (uint256 i; i < logs.length; ++i) {
            if (uint256(logs[i].topics[0]) == rx.ALLOWED_TOPIC_0()) allowedAt = i;
            if (uint256(logs[i].topics[0]) == rx.CONDITION_TOPIC_0()) condAt = i;
        }
        assertLt(allowedAt, condAt); // the watcher learns the allowlist before it subscribes to the proof event
    }

    function test_frontRunnerIsIgnoredAndClaimantStillPaid() public {
        uint256 id = _postFor(address(open), 7, keeper);
        vm.recordLogs();
        vm.prank(bot);
        open.run(7, 1); // the bot's copy lands first
        vm.prank(keeper);
        open.run(7, 1); // the claimant's own tx
        _pipe(vm.getRecordedLogs(), JOBS_CHAIN);
        assertEq(sys.payloadCount(), 1); // one callback, for the keeper only
        _deliverCallbacks();
        (HandshakeEscrow.Status st, address winner) = _st(id);
        assertEq(uint8(st), uint8(HandshakeEscrow.Status.Paid));
        assertEq(winner, keeper);
        assertEq(keeper.balance, 1 ether);
        assertEq(bot.balance, 0);
    }

    function test_frontRunOnceOnlyJobCannotStealOnlyRefund() public {
        uint256 id = _postFor(address(jobs), 7, keeper);
        vm.recordLogs();
        vm.prank(bot);
        jobs.run(7, 1); // the bot did the once-only job; the keeper's copy now reverts
        _pipe(vm.getRecordedLogs(), JOBS_CHAIN);
        assertEq(sys.payloadCount(), 0);
        vm.warp(block.timestamp + 1 days);
        _tick();
        _deliverCallbacks();
        (HandshakeEscrow.Status st,) = _st(id);
        assertEq(uint8(st), uint8(HandshakeEscrow.Status.Refunded)); // the issuer keeps the money, the bot gets nothing
        assertEq(bot.balance, 0);
    }

    function test_escrowRefusesNotAllowedEvenIfWatcherWereWrong() public {
        uint256 id = _postFor(address(open), 7, keeper);
        vm.prank(proxy);
        esc.settleProof(address(rx), id, bot, bytes32(0));
        (HandshakeEscrow.Status st,) = _st(id);
        assertEq(uint8(st), uint8(HandshakeEscrow.Status.Open));
        vm.prank(proxy);
        esc.settleProof(address(rx), id, keeper, bytes32(0));
        (st,) = _st(id);
        assertEq(uint8(st), uint8(HandshakeEscrow.Status.Paid));
    }

    function test_unrestrictedBountyStillPaysFirstProof() public {
        _postProof(7, 0, 1 ether, block.timestamp + 1 days);
        vm.recordLogs();
        vm.prank(bot);
        jobs.run(7, 1);
        _pipe(vm.getRecordedLogs(), JOBS_CHAIN);
        _deliverCallbacks();
        assertEq(bot.balance, 1 ether); // open bounties stay permissionless by design
    }

    function test_issuerCanRestrictLaterOthersCannot() public {
        uint256 id = _postProof(7, 0, 1 ether, block.timestamp + 1 days);
        address[] memory list = new address[](1);
        list[0] = keeper;
        vm.prank(bot);
        vm.expectRevert(HandshakeEscrow.NotIssuer.selector);
        esc.allow(id, list);
        vm.recordLogs();
        vm.prank(issuer);
        esc.allow(id, list);
        _pipe(vm.getRecordedLogs(), ESCROW_CHAIN);
        assertTrue(rx.restricted(id));
        assertTrue(rx.allowed(id, keeper));
        assertFalse(rx.allowed(id, bot));
    }

    function test_allowRejectsJudgedEmptyAndZero() public {
        vm.prank(issuer);
        uint256 j = esc.postJudged{ value: 1 ether }("j", block.timestamp + 1 days);
        address[] memory list = new address[](1);
        list[0] = keeper;
        vm.prank(issuer);
        vm.expectRevert(HandshakeEscrow.NotProof.selector);
        esc.allow(j, list);
        address[] memory none = new address[](0);
        vm.prank(issuer);
        vm.expectRevert(HandshakeEscrow.BadCondition.selector);
        esc.postProofFor{ value: 1 ether }("x", block.timestamp + 1 days, _cond(address(jobs), 7), none);
        list[0] = address(0);
        vm.prank(issuer);
        vm.expectRevert(HandshakeEscrow.BadCondition.selector);
        esc.postProofFor{ value: 1 ether }("x", block.timestamp + 1 days, _cond(address(jobs), 7), list);
    }

    function testFuzz_onlyAllowedAddressesEverGetPaid(address named, bool isKeeper) public {
        vm.assume(named != address(0) && named != keeper && named.code.length == 0 && uint160(named) > 0x100);
        uint256 id = _postFor(address(open), 9, keeper);
        address who = isKeeper ? keeper : named;
        vm.recordLogs();
        vm.prank(who);
        open.run(9, 1);
        _pipe(vm.getRecordedLogs(), JOBS_CHAIN);
        _deliverCallbacks();
        (HandshakeEscrow.Status st, address winner) = _st(id);
        if (isKeeper) assertEq(winner, keeper);
        else assertEq(uint8(st), uint8(HandshakeEscrow.Status.Open));
    }

    // ---- runway

    function test_fundedUntilFromBalanceAndMeasuredRate() public {
        assertEq(rx.fundedUntil(), type(uint256).max); // no rate set yet
        rx.setBurnRate(0.0112 ether, 1053);
        vm.deal(address(rx), 0.92 ether);
        assertEq(rx.fundedUntil(), block.timestamp + 82 * 1053); // 0.92 / 0.0112 = 82 ticks ~ 1 day
        vm.mockCall(address(sys), abi.encodeWithSignature("debt(address)", address(rx)), abi.encode(1 ether));
        assertEq(rx.fundedUntil(), block.timestamp); // in debt: nothing funded
    }

    function test_fundedUntilUnboundedWithCronOff() public {
        rx.setBurnRate(0.0112 ether, 1053);
        rx.setCron(false);
        assertEq(rx.fundedUntil(), type(uint256).max);
    }

    function test_anyoneCanTopUpAndOnlyOwnerSetsRate() public {
        vm.deal(hunter, 1 ether);
        vm.expectEmit(true, false, false, true, address(rx));
        emit HandshakeReactive.Funded(hunter, 0.5 ether);
        vm.prank(hunter);
        (bool ok,) = address(rx).call{ value: 0.5 ether }("");
        assertTrue(ok);
        vm.prank(hunter);
        vm.expectRevert(HandshakeReactive.NotOwner.selector);
        rx.setBurnRate(1, 1);
    }
}
