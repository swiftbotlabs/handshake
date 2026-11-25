// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Vm } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { HandshakeEscrow, BountyVault } from "../src/HandshakeEscrow.sol";
import { HandshakeReactive } from "../src/HandshakeReactive.sol";
import { HandshakeBase } from "./Handshake.t.sol";

/// transfer() returns false; transferFrom works. Payouts in it must revert, never half-close a bounty.
contract FalseOnTransfer {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) { balanceOf[f] -= a; balanceOf[to] += a; return true; }
    function transfer(address, uint256) external pure returns (bool) { return false; }
}

/// transferFrom says yes but moves nothing.
contract NoopToken {
    function balanceOf(address) external pure returns (uint256) { return 0; }
    function transferFrom(address, address, uint256) external pure returns (bool) { return true; }
}

/// A contract with code but no ERC-20 interface.
contract NotAToken { }

/// A claimant that refuses ETH.
contract RefusesEth {
    function claimOn(HandshakeEscrow e, uint256 id) external { e.claim(id, "ipfs://x"); }
}

/// Every guard branch the happy-path suites skip: duplicate deliveries, malformed proof logs, retry spacing, refused transfers.
contract HandshakeGuardsTest is HandshakeBase {
    uint256 constant JOBRUN = uint256(keccak256("JobRun(uint256,address,uint256)"));

    function _proof(uint8 winnerTopic, bool pin, uint256 topic1, uint256 minValue) internal returns (uint256 id) {
        HandshakeEscrow.Condition memory c = HandshakeEscrow.Condition({
            chainId: JOBS_CHAIN, emitter: address(jobs), topic0: JOBRUN, matchTopic1: pin, topic1: topic1,
            winnerTopic: winnerTopic, minValue: minValue
        });
        vm.recordLogs();
        vm.prank(issuer);
        id = esc.postProof{ value: 0.01 ether }("guard", block.timestamp + 1 days, c);
        _pipe(vm.getRecordedLogs(), ESCROW_CHAIN);
    }

    function _log(uint256 opCode, uint256 t1, uint256 t2, uint256 t3, bytes memory data) internal {
        IReactive.LogRecord memory r;
        r.chainId = JOBS_CHAIN; r.contractAddress = address(jobs); r.topic0 = JOBRUN; r.opCode = opCode;
        r.topic1 = t1; r.topic2 = t2; r.topic3 = t3; r.data = data; r.txHash = 0xabc;
        vm.prank(SYS);
        rx.react(r);
    }

    // ---------------------------------------------------------------- reactive side

    function test_onlyOwnerAndLinkOnce() public {
        vm.prank(hunter);
        vm.expectRevert(HandshakeReactive.NotOwner.selector);
        rx.setCron(true);
        vm.expectRevert(HandshakeReactive.EscrowAlreadySet.selector);
        rx.linkEscrow(ESCROW_CHAIN, address(0xBEEF));
    }

    function test_duplicateDeliveryOfPostAndConditionIsIgnored() public {
        vm.recordLogs();
        vm.prank(issuer);
        esc.postProof{ value: 0.01 ether }("dup", block.timestamp + 1 days, HandshakeEscrow.Condition({
            chainId: JOBS_CHAIN, emitter: address(jobs), topic0: JOBRUN, matchTopic1: true, topic1: 5, winnerTopic: 2, minValue: 0
        }));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _pipe(logs, ESCROW_CHAIN);
        uint256 live = sys.liveCount();
        _pipe(logs, ESCROW_CHAIN); // the same escrow logs delivered again: no second subscription, no second watch
        assertEq(sys.liveCount(), live);
        assertEq(rx.openCount(), 1);
    }

    function test_closeOfUnknownOrClosedIdIsNoop() public {
        IReactive.LogRecord memory r;
        r.chainId = ESCROW_CHAIN; r.contractAddress = address(esc); r.topic0 = rx.PAID_TOPIC_0(); r.topic1 = 999; r.opCode = 4;
        vm.prank(SYS);
        rx.react(r); // never opened: returns quietly
        vm.prank(SYS);
        rx.react(r);
    }

    function test_malformedProofLogsSendNothing() public {
        _proof(2, true, 7, 0);
        uint256 n = sys.payloadCount();
        _log(2, 7, 0, 0, abi.encode(uint256(1)));            // no topic2: the winner topic is missing
        _log(3, 7, 0, 0, abi.encode(uint256(1)));            // winner is the zero address
        assertEq(sys.payloadCount(), n);
        _log(3, 7, uint256(uint160(keeper)), 0, "");        // well formed: pays
        assertEq(sys.payloadCount(), n + 1);
    }

    function test_winnerFromTopic1AndTopic3() public {
        _proof(1, false, 0, 0);
        uint256 n = sys.payloadCount();
        _log(2, uint256(uint160(keeper)), 0, 0, "");
        assertEq(sys.payloadCount(), n + 1);
        _proof(3, true, 8, 0);
        _log(4, 8, 0, uint256(uint160(hunter)), "");
        assertEq(sys.payloadCount(), n + 2);
    }

    function test_dataWordWinnerNeedsTheWord() public {
        _proof(6, true, 9, 0); // data word 2
        uint256 n = sys.payloadCount();
        _log(2, 9, 0, 0, abi.encode(uint256(1), uint256(2)));               // only 2 words
        assertEq(sys.payloadCount(), n);
        _log(2, 9, 0, 0, abi.encode(uint256(1), uint256(2), uint256(uint160(keeper))));
        assertEq(sys.payloadCount(), n + 1);
    }

    function test_minValueNeedsAValueWord() public {
        _proof(2, true, 10, 3);
        uint256 n = sys.payloadCount();
        _log(3, 10, uint256(uint160(keeper)), 0, "");                      // no value word
        _log(3, 10, uint256(uint160(keeper)), 0, abi.encode(uint256(2)));  // below minimum
        assertEq(sys.payloadCount(), n);
        _log(3, 10, uint256(uint160(keeper)), 0, abi.encode(uint256(3)));
        assertEq(sys.payloadCount(), n + 1);
    }

    function test_cronDoesNotResendWithinRetryWindow() public {
        vm.recordLogs();
        vm.prank(issuer);
        esc.postJudged{ value: 0.01 ether }("late", block.timestamp + 1 hours);
        _pipe(vm.getRecordedLogs(), ESCROW_CHAIN);
        vm.warp(block.timestamp + 2 hours);
        _tick();
        uint256 n = sys.payloadCount();
        _tick();                                     // the first request is still in flight
        assertEq(sys.payloadCount(), n);
        vm.warp(block.timestamp + 3 hours + 1);
        _tick();                                     // after RETRY_AFTER it asks again
        assertEq(sys.payloadCount(), n + 1);
    }

    // ---------------------------------------------------------------- escrow side

    function test_vaultOnlyTakesFromEscrow() public {
        BountyVault v = esc.vault();
        vm.deal(hunter, 1 ether);
        vm.prank(hunter);
        (bool ok,) = address(v).call{ value: 1 }("");
        assertFalse(ok);
        vm.expectRevert(BountyVault.OnlyEscrow.selector);
        v.releaseToken(address(0), hunter, 1);
    }

    function test_payoutToAContractThatRefusesEthReverts() public {
        vm.prank(issuer);
        uint256 id = esc.postJudged{ value: 0.01 ether }("x", block.timestamp + 1 days);
        RefusesEth r = new RefusesEth();
        r.claimOn(esc, id);
        vm.prank(issuer);
        vm.expectRevert(BountyVault.TransferFailed.selector);
        esc.accept(id, 0);
        (,,, HandshakeEscrow.Status st,,,) = esc.bounties(id);
        assertEq(uint8(st), uint8(HandshakeEscrow.Status.Open)); // nothing half-closed
    }

    function test_tokenPayoutThatReturnsFalseReverts() public {
        FalseOnTransfer t = new FalseOnTransfer();
        t.mint(issuer, 100);
        vm.prank(issuer);
        uint256 id = esc.postJudgedToken("x", block.timestamp + 1 days, address(t), 100);
        RefusesEth r = new RefusesEth();
        r.claimOn(esc, id);
        vm.prank(issuer);
        vm.expectRevert(BountyVault.TransferFailed.selector);
        esc.accept(id, 0);
    }

    function test_tokenPostGuards() public {
        NoopToken noop = new NoopToken();
        vm.startPrank(issuer);
        vm.expectRevert(HandshakeEscrow.BadAmount.selector);
        esc.postJudgedToken("x", block.timestamp + 1 days, address(noop), 100);      // nothing arrived
        NotAToken nat = new NotAToken();
        vm.expectRevert(HandshakeEscrow.TokenTransferFailed.selector);
        esc.postJudgedToken("x", block.timestamp + 1 days, address(nat), 100);       // no balanceOf
        vm.expectRevert(HandshakeEscrow.BadDeadline.selector);
        esc.postJudgedToken("x", block.timestamp, address(noop), 100);
        vm.stopPrank();
    }

    function test_allowGuards() public {
        uint256 id = _proof(2, true, 11, 0);
        address[] memory none = new address[](0);
        address[] memory twice = new address[](2);
        twice[0] = keeper; twice[1] = keeper;
        vm.startPrank(issuer);
        vm.expectRevert(HandshakeEscrow.BadCondition.selector);
        esc.allow(id, none);
        vm.recordLogs();
        esc.allow(id, twice);
        assertEq(vm.getRecordedLogs().length, 1); // one ClaimantAllowed, the duplicate is skipped
        esc.cancel(id);
        vm.expectRevert(abi.encodeWithSelector(HandshakeEscrow.NotOpen.selector, id, HandshakeEscrow.Status.Refunded));
        esc.allow(id, twice);
        vm.expectRevert(abi.encodeWithSelector(HandshakeEscrow.NotOpen.selector, id, HandshakeEscrow.Status.Refunded));
        esc.cancel(id);
        vm.stopPrank();
    }

    function test_claimOnlyOnOpenJudgedBounty() public {
        uint256 id = _proof(2, true, 12, 0);
        vm.prank(hunter);
        vm.expectRevert(abi.encodeWithSelector(HandshakeEscrow.NotOpen.selector, id, HandshakeEscrow.Status.Open));
        esc.claim(id, "ipfs://x");
    }

    function test_zeroMinimumDefaultsToOneWei() public {
        HandshakeEscrow e = new HandshakeEscrow(IPayable(payable(proxy)), address(rx), 0, 0, address(0), 0);
        assertEq(e.minBounty(), 1);
        HandshakeEscrow e5 = new HandshakeEscrow(IPayable(payable(proxy)), address(rx), 5, 0, address(0), 0);
        assertEq(e5.minBounty(), 5);
    }

    function test_jobRunsOnce() public {
        jobs.run(1, 1);
        vm.expectRevert(bytes("already run"));
        jobs.run(1, 1);
    }
}
