// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Vm } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { HandshakeEscrow, BountyVault } from "../src/HandshakeEscrow.sol";
import { HandshakeBase } from "./Handshake.t.sol";

/// Stand-in with the exact event of WETH9 (`Deposit(address indexed dst, uint wad)`), the third-party proof source used
/// in the testnet demo (WETH on Ethereum Sepolia). Handshake does not care who wrote the emitting contract.
contract MockWETH {
    event Deposit(address indexed dst, uint256 wad);
    function deposit() external payable {
        emit Deposit(msg.sender, msg.value);
    }
}

/// Posting rules, fees, judged flow edges and callback edges.
contract HandshakeRulesTest is HandshakeBase {
    uint256 constant MIN = 0.001 ether;
    uint256 constant FEE = 0.0002 ether;
    HandshakeEscrow feeEsc;

    function setUp() public override {
        super.setUp();
        feeEsc = new HandshakeEscrow(IPayable(payable(proxy)), address(rx), MIN, FEE);
    }

    function _cond() internal view returns (HandshakeEscrow.Condition memory c) {
        c = HandshakeEscrow.Condition({
            chainId: JOBS_CHAIN, emitter: address(jobs), topic0: uint256(keccak256("JobRun(uint256,address,uint256)")),
            matchTopic1: true, topic1: 7, winnerTopic: 2, minValue: 0
        });
    }

    function _status(HandshakeEscrow e, uint256 id) internal view returns (HandshakeEscrow.Status st) {
        (,,, st,,,) = e.bounties(id);
    }

    // ---- fees and minimum
    function test_feeStaysAsCallbackGasAndBountyGoesToVault() public {
        vm.prank(issuer);
        uint256 id = feeEsc.postJudged{ value: 0.01 ether }("x", block.timestamp + 1 days);
        (,,,, uint256 amount,,) = feeEsc.bounties(id);
        assertEq(amount, 0.01 ether - FEE);
        assertEq(address(feeEsc.vault()).balance, 0.01 ether - FEE);
        assertEq(address(feeEsc).balance, FEE);
        assertEq(feeEsc.feesCollected(), FEE);
    }

    function test_belowMinimumRejectedForBothKinds() public {
        vm.startPrank(issuer);
        vm.expectRevert(abi.encodeWithSelector(HandshakeEscrow.BelowMinimum.selector, MIN, MIN + FEE));
        feeEsc.postJudged{ value: MIN }("x", block.timestamp + 1 days);
        vm.expectRevert(abi.encodeWithSelector(HandshakeEscrow.BelowMinimum.selector, MIN + FEE - 1, MIN + FEE));
        feeEsc.postProof{ value: MIN + FEE - 1 }("x", block.timestamp + 1 days, _cond());
        vm.stopPrank();
    }

    function test_exactMinimumPlusFeeAccepted() public {
        vm.prank(issuer);
        uint256 id = feeEsc.postProof{ value: MIN + FEE }("x", block.timestamp + 1 days, _cond());
        (,,,, uint256 amount,,) = feeEsc.bounties(id);
        assertEq(amount, MIN);
    }

    function test_feesPayCallbackGasNotBounties() public {
        vm.startPrank(issuer);
        feeEsc.postJudged{ value: 0.01 ether }("a", block.timestamp + 1 days);
        feeEsc.postJudged{ value: 0.01 ether }("b", block.timestamp + 1 days);
        vm.stopPrank();
        vm.prank(proxy);
        feeEsc.pay(2 * FEE); // the proxy bills callback gas: exactly the two fees
        assertEq(address(feeEsc).balance, 0);
        assertEq(address(feeEsc.vault()).balance, 2 * (0.01 ether - FEE));
        vm.prank(proxy);
        vm.expectRevert(); // nothing left in the float; the vault can't be billed
        feeEsc.pay(1);
    }

    function test_refundReturnsAmountWithoutFee() public {
        vm.prank(issuer);
        uint256 id = feeEsc.postJudged{ value: 0.01 ether }("x", block.timestamp + 1 days);
        uint256 before = issuer.balance;
        vm.warp(block.timestamp + 1 days);
        feeEsc.expire(id);
        assertEq(issuer.balance - before, 0.01 ether - FEE);
    }

    // ---- condition shape
    function test_rejectsWinnerTopicZeroAndFour() public {
        HandshakeEscrow.Condition memory c = _cond();
        vm.startPrank(issuer);
        c.winnerTopic = 0;
        vm.expectRevert(HandshakeEscrow.BadCondition.selector);
        esc.postProof{ value: 1 ether }("x", block.timestamp + 1 days, c);
        c.winnerTopic = 4;
        vm.expectRevert(HandshakeEscrow.BadCondition.selector);
        esc.postProof{ value: 1 ether }("x", block.timestamp + 1 days, c);
        vm.stopPrank();
    }

    function test_rejectsPinnedTopicThatIsAlsoTheWinner() public {
        HandshakeEscrow.Condition memory c = _cond();
        c.winnerTopic = 1;
        vm.prank(issuer);
        vm.expectRevert(HandshakeEscrow.BadCondition.selector);
        esc.postProof{ value: 1 ether }("x", block.timestamp + 1 days, c);
    }

    function test_rejectsZeroChainEmitterOrTopic() public {
        vm.startPrank(issuer);
        HandshakeEscrow.Condition memory c = _cond();
        c.chainId = 0;
        vm.expectRevert(HandshakeEscrow.BadCondition.selector);
        esc.postProof{ value: 1 ether }("x", block.timestamp + 1 days, c);
        c = _cond();
        c.emitter = address(0);
        vm.expectRevert(HandshakeEscrow.BadCondition.selector);
        esc.postProof{ value: 1 ether }("x", block.timestamp + 1 days, c);
        c = _cond();
        c.topic0 = 0;
        vm.expectRevert(HandshakeEscrow.BadCondition.selector);
        esc.postProof{ value: 1 ether }("x", block.timestamp + 1 days, c);
        vm.stopPrank();
    }

    function test_rejectsDeadlineBeyondOneYear() public {
        vm.prank(issuer);
        vm.expectRevert(HandshakeEscrow.BadDeadline.selector);
        esc.postJudged{ value: 1 ether }("x", block.timestamp + 366 days);
    }

    // ---- judged flow edges
    function test_claimAfterDeadlineReverts() public {
        vm.prank(issuer);
        uint256 id = esc.postJudged{ value: 1 ether }("x", block.timestamp + 1 days);
        vm.warp(block.timestamp + 1 days);
        vm.prank(hunter);
        vm.expectRevert();
        esc.claim(id, "late");
    }

    function test_acceptUnknownClaimReverts() public {
        vm.prank(issuer);
        uint256 id = esc.postJudged{ value: 1 ether }("x", block.timestamp + 1 days);
        vm.prank(issuer);
        vm.expectRevert(HandshakeEscrow.UnknownClaim.selector);
        esc.accept(id, 0);
    }

    function test_onlyIssuerCanAcceptOrCancel() public {
        vm.prank(issuer);
        uint256 id = esc.postJudged{ value: 1 ether }("x", block.timestamp + 1 days);
        vm.prank(hunter);
        esc.claim(id, "mine");
        vm.startPrank(hunter);
        vm.expectRevert(HandshakeEscrow.NotIssuer.selector);
        esc.accept(id, 0);
        vm.expectRevert(HandshakeEscrow.NotIssuer.selector);
        esc.cancel(id);
        vm.stopPrank();
    }

    function test_cancelRefundsAndCronSendsNothingLater() public {
        vm.recordLogs();
        vm.prank(issuer);
        uint256 id = esc.postJudged{ value: 1 ether }("x", block.timestamp + 1 days);
        uint256 before = issuer.balance;
        vm.prank(issuer);
        esc.cancel(id);
        _pipe(vm.getRecordedLogs(), ESCROW_CHAIN);
        assertEq(issuer.balance - before, 1 ether);
        vm.warp(block.timestamp + 2 days);
        _tick();
        assertEq(sys.payloadCount(), 0);
        assertEq(rx.openCount(), 0);
    }

    function test_acceptTwiceReverts() public {
        vm.prank(issuer);
        uint256 id = esc.postJudged{ value: 1 ether }("x", block.timestamp + 1 days);
        vm.prank(hunter);
        esc.claim(id, "a");
        vm.startPrank(issuer);
        esc.accept(id, 0);
        vm.expectRevert();
        esc.accept(id, 0);
        vm.stopPrank();
    }

    // ---- callback edges (all no-ops, never reverts)
    function test_settleProofWithZeroWinnerIsSkipped() public {
        uint256 id = _postProof(7, 0, 1 ether, block.timestamp + 1 days);
        vm.prank(proxy);
        esc.settleProof(address(rx), id, address(0), bytes32(0));
        assertEq(uint8(_status(esc, id)), uint8(HandshakeEscrow.Status.Open));
    }

    function test_settleProofOnJudgedBountyIsSkipped() public {
        vm.prank(issuer);
        uint256 id = esc.postJudged{ value: 1 ether }("x", block.timestamp + 1 days);
        vm.prank(proxy);
        esc.settleProof(address(rx), id, hunter, bytes32(0));
        assertEq(hunter.balance, 0);
        assertEq(uint8(_status(esc, id)), uint8(HandshakeEscrow.Status.Open));
    }

    function test_expireByReactiveBeforeDeadlineIsSkipped() public {
        vm.prank(issuer);
        uint256 id = esc.postJudged{ value: 1 ether }("x", block.timestamp + 1 days);
        vm.prank(proxy);
        esc.expireByReactive(address(rx), id);
        assertEq(uint8(_status(esc, id)), uint8(HandshakeEscrow.Status.Open));
    }

    function test_expireAfterPayoutCannotRefund() public {
        uint256 id = _postProof(7, 0, 1 ether, block.timestamp + 1 days);
        vm.prank(proxy);
        esc.settleProof(address(rx), id, keeper, bytes32(0));
        vm.warp(block.timestamp + 2 days);
        vm.prank(proxy);
        esc.expireByReactive(address(rx), id); // skipped
        vm.expectRevert();
        esc.expire(id);
        assertEq(keeper.balance, 1 ether);
    }

    function test_vaultAcceptsMoneyOnlyFromEscrow() public {
        vm.deal(hunter, 1 ether);
        vm.prank(hunter);
        (bool ok,) = address(esc.vault()).call{ value: 1 }("");
        assertFalse(ok);
        BountyVault v = esc.vault();
        vm.prank(hunter);
        vm.expectRevert(BountyVault.OnlyEscrow.selector);
        v.release(payable(hunter), 0);
    }

    // ---- third-party proof source: pay whoever first wraps at least 0.5 ETH in a WETH9-style contract
    function test_thirdPartyEventPaysFirstQualifyingCaller() public {
        MockWETH weth = new MockWETH();
        HandshakeEscrow.Condition memory c = HandshakeEscrow.Condition({
            chainId: JOBS_CHAIN, emitter: address(weth), topic0: uint256(keccak256("Deposit(address,uint256)")),
            matchTopic1: false, topic1: 0, winnerTopic: 1, minValue: 0.5 ether
        });
        vm.recordLogs();
        vm.prank(issuer);
        uint256 id = esc.postProof{ value: 1 ether }("wrap >= 0.5 ETH", block.timestamp + 1 days, c);
        _pipe(vm.getRecordedLogs(), ESCROW_CHAIN);
        vm.deal(hunter, 1 ether);
        vm.deal(keeper, 1 ether);
        vm.recordLogs();
        vm.prank(hunter); weth.deposit{ value: 0.1 ether }(); // too small
        vm.prank(keeper); weth.deposit{ value: 0.6 ether }(); // first qualifying
        _pipe(vm.getRecordedLogs(), JOBS_CHAIN);
        _deliverCallbacks();
        assertEq(uint8(_status(esc, id)), uint8(HandshakeEscrow.Status.Paid));
        (,,,,, address winner,) = esc.bounties(id);
        assertEq(winner, keeper);
    }
}

/// Property tests: random amounts, deadlines, work values and callback orders.
contract HandshakeFuzzTest is HandshakeBase {
    function testFuzz_feeSplitIsExact(uint96 value, uint64 fee) public {
        uint256 f = uint256(fee) % 1 ether;
        uint256 v = bound(uint256(value), f + 1, 100 ether);
        HandshakeEscrow e = new HandshakeEscrow(IPayable(payable(proxy)), address(rx), 1, f);
        vm.deal(issuer, v);
        vm.prank(issuer);
        uint256 id = e.postJudged{ value: v }("x", block.timestamp + 1 days);
        (,,,, uint256 amount,,) = e.bounties(id);
        assertEq(amount + f, v);
        assertEq(address(e.vault()).balance, v - f);
        assertEq(e.openTotal(), v - f);
    }

    function testFuzz_refundOnlyFromDeadline(uint32 dt, uint32 at) public {
        uint256 d = bound(uint256(dt), 1, 365 days);
        uint256 t = bound(uint256(at), 0, 2 * 365 days);
        vm.prank(issuer);
        uint256 id = esc.postJudged{ value: 1 ether }("x", block.timestamp + d);
        uint256 deadline = block.timestamp + d;
        vm.warp(block.timestamp + t);
        if (block.timestamp < deadline) {
            vm.expectRevert();
            esc.expire(id);
        } else {
            uint256 before = issuer.balance;
            esc.expire(id);
            assertEq(issuer.balance - before, 1 ether);
        }
    }

    function testFuzz_paysIffWorkMeetsMinimum(uint64 minWork, uint64 work) public {
        uint256 id = _postProof(7, minWork, 1 ether, block.timestamp + 1 days);
        vm.recordLogs();
        vm.prank(keeper);
        jobs.run(7, work);
        _pipe(vm.getRecordedLogs(), JOBS_CHAIN);
        _deliverCallbacks();
        (,,, HandshakeEscrow.Status st,,,) = esc.bounties(id);
        if (work >= minWork) {
            assertEq(uint8(st), uint8(HandshakeEscrow.Status.Paid));
            assertEq(keeper.balance, 1 ether);
        } else {
            assertEq(uint8(st), uint8(HandshakeEscrow.Status.Open));
            assertEq(keeper.balance, 0);
        }
    }

    function testFuzz_duplicateCallbacksInAnyOrderPayOnce(address a, address b, uint8 n) public {
        vm.assume(a != address(0) && b != address(0) && a.code.length == 0 && b.code.length == 0);
        vm.assume(uint160(a) > 0xff && uint160(b) > 0xff && a != b);
        vm.assume(a != address(esc.vault()) && b != address(esc.vault()) && a != issuer && b != issuer);
        uint256 id = _postProof(7, 0, 1 ether, block.timestamp + 1 days);
        uint256 ba = a.balance;
        uint256 bb = b.balance;
        uint256 rounds = bound(uint256(n), 1, 12);
        for (uint256 i; i < rounds; ++i) {
            vm.prank(proxy);
            esc.settleProof(address(rx), id, i % 2 == 0 ? a : b, bytes32(i));
        }
        assertEq((a.balance - ba) + (b.balance - bb), 1 ether);
        assertEq(a.balance - ba, 1 ether); // the first call won
    }

    function testFuzz_sharedSubscriptionLivesUntilLastBountyCloses(uint8 count, uint8 payIdx) public {
        uint256 k = bound(uint256(count), 1, 8);
        uint256 t0 = uint256(keccak256("JobRun(uint256,address,uint256)"));
        uint256[] memory ids = new uint256[](k);
        for (uint256 i; i < k; ++i) ids[i] = _postProof(7, 0, 0.1 ether, block.timestamp + 1 days + i * 1 hours);
        assertTrue(sys.isLive(JOBS_CHAIN, address(jobs), t0, 7));
        // close all but one by cancelling
        uint256 keep = bound(uint256(payIdx), 0, k - 1);
        for (uint256 i; i < k; ++i) {
            if (i == keep) continue;
            vm.recordLogs();
            vm.prank(issuer);
            esc.cancel(ids[i]);
            _pipe(vm.getRecordedLogs(), ESCROW_CHAIN);
            assertTrue(sys.isLive(JOBS_CHAIN, address(jobs), t0, 7));
        }
        vm.recordLogs();
        vm.prank(keeper);
        jobs.run(7, 1);
        _pipe(vm.getRecordedLogs(), JOBS_CHAIN);
        _deliverCallbacks();
        assertFalse(sys.isLive(JOBS_CHAIN, address(jobs), t0, 7));
        assertEq(rx.openCount(), 0);
    }

    function testFuzz_lateProofNeverPays(uint32 late) public {
        uint256 d = 1 hours;
        uint256 id = _postProof(7, 0, 1 ether, block.timestamp + d);
        vm.warp(block.timestamp + d + bound(uint256(late), 0, 30 days));
        vm.prank(proxy);
        esc.settleProof(address(rx), id, keeper, bytes32(0));
        assertEq(keeper.balance, 0);
        (,,, HandshakeEscrow.Status st,,,) = esc.bounties(id);
        assertEq(uint8(st), uint8(HandshakeEscrow.Status.Open));
    }
}

/// Reactive-side behaviour of the mirror contract.
contract HandshakeReactiveTest is HandshakeBase {
    function test_logFromAnotherEmitterRequestsNothing() public {
        _postProof(7, 0, 1 ether, block.timestamp + 1 days);
        KeeperJobsLike other = new KeeperJobsLike();
        vm.recordLogs();
        vm.prank(keeper);
        other.run(7, 9); // same event, same job id, wrong contract
        _pipe(vm.getRecordedLogs(), JOBS_CHAIN);
        assertEq(sys.payloadCount(), 0);
    }

    function test_secondMatchingLogWhileFirstInFlightRequestsOnce() public {
        _postProof(7, 0, 1 ether, block.timestamp + 1 days);
        _postProof(8, 0, 1 ether, block.timestamp + 1 days);
        vm.recordLogs();
        vm.prank(keeper);
        jobs.run(7, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _pipe(logs, JOBS_CHAIN);
        _pipe(logs, JOBS_CHAIN); // the same log delivered twice before the callback lands
        assertEq(sys.payloadCount(), 1);
    }

    function test_cronTickWithNothingDueRequestsNothing() public {
        _postProof(7, 0, 1 ether, block.timestamp + 1 days);
        vm.recordLogs();
        vm.prank(issuer);
        esc.postJudged{ value: 1 ether }("x", block.timestamp + 2 days);
        _pipe(vm.getRecordedLogs(), ESCROW_CHAIN);
        _tick();
        assertEq(sys.payloadCount(), 0);
        assertEq(rx.openCount(), 2);
    }

    function test_publicExpireClosesTheMirrorToo() public {
        vm.recordLogs();
        vm.prank(issuer);
        uint256 id = esc.postJudged{ value: 1 ether }("x", block.timestamp + 1 days);
        _pipe(vm.getRecordedLogs(), ESCROW_CHAIN);
        assertEq(rx.openCount(), 1);
        vm.warp(block.timestamp + 1 days);
        vm.recordLogs();
        vm.prank(hunter);
        esc.expire(id); // Reactive was "down": anyone refunds
        _pipe(vm.getRecordedLogs(), ESCROW_CHAIN);
        assertEq(rx.openCount(), 0);
        _tick();
        assertEq(sys.payloadCount(), 0); // nothing left to expire
    }
}

contract KeeperJobsLike {
    event JobRun(uint256 indexed jobId, address indexed keeper, uint256 work);
    function run(uint256 jobId_, uint256 work_) external {
        emit JobRun(jobId_, msg.sender, work_);
    }
}
