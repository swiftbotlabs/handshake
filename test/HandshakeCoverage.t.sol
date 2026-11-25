// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { HandshakeEscrow } from "../src/HandshakeEscrow.sol";
import { HandshakeBase } from "./Handshake.t.sol";
import { MockUSDC } from "./HandshakeToken.t.sol";

/// The paths the other suites did not reach: an allowlisted ERC-20 proof bounty, the claimants view, and debt cover on both sides.
contract HandshakeCoverageTest is HandshakeBase {
    MockUSDC usdc;

    function setUp() public override {
        super.setUp();
        usdc = new MockUSDC(0);
        usdc.mint(issuer, 1_000e6);
        vm.prank(issuer);
        usdc.approve(address(esc), type(uint256).max);
    }

    function _cond(uint256 job) internal view returns (HandshakeEscrow.Condition memory) {
        return HandshakeEscrow.Condition({
            chainId: JOBS_CHAIN, emitter: address(jobs), topic0: uint256(keccak256("JobRun(uint256,address,uint256)")),
            matchTopic1: true, topic1: job, winnerTopic: 2, minValue: 0
        });
    }

    function test_tokenProofForPaysOnlyTheAllowedClaimant() public {
        address[] memory only = new address[](1);
        only[0] = keeper;
        vm.recordLogs();
        vm.prank(issuer);
        HandshakeEscrow.Condition memory c = _cond(0);
        c.matchTopic1 = false; // any job on the board counts; only the keeper may be paid
        uint256 id = esc.postProofTokenFor("run any job for 10 USDC, keeper only", block.timestamp + 1 days, c, address(usdc), 10e6, only);
        _pipe(vm.getRecordedLogs(), ESCROW_CHAIN);
        assertTrue(esc.allowed(id, keeper));
        assertTrue(esc.restricted(id));

        // someone off the list runs a job first: dropped on Reactive, no callback, nothing paid
        uint256 before = sys.payloadCount();
        vm.recordLogs();
        vm.prank(hunter);
        jobs.run(10, 1);
        _pipe(vm.getRecordedLogs(), JOBS_CHAIN);
        assertEq(sys.payloadCount(), before);
        assertEq(usdc.balanceOf(hunter), 0);

        // the agreed keeper's proof pays
        vm.recordLogs();
        vm.prank(keeper);
        jobs.run(11, 1);
        _pipe(vm.getRecordedLogs(), JOBS_CHAIN);
        _deliverCallbacks();
        assertEq(usdc.balanceOf(keeper), 10e6);
        assertEq(esc.openTotalOf(address(usdc)), 0);
    }

    function test_tokenProofForNeedsAClaimant() public {
        address[] memory none = new address[](0);
        HandshakeEscrow.Condition memory c = _cond(9);
        vm.prank(issuer);
        vm.expectRevert(HandshakeEscrow.BadCondition.selector);
        esc.postProofTokenFor("x", block.timestamp + 1 days, c, address(usdc), 10e6, none);
    }

    function test_claimantsViewListsEveryClaim() public {
        vm.prank(issuer);
        uint256 id = esc.postJudged{ value: 0.001 ether }("write the docs", block.timestamp + 1 days);
        vm.prank(hunter);
        esc.claim(id, "ipfs://a");
        vm.prank(keeper);
        esc.claim(id, "ipfs://b");
        address[] memory cs = esc.claimants(id);
        assertEq(cs.length, 2);
        assertEq(cs[0], hunter);
        assertEq(cs[1], keeper);
    }

    function test_escrowCoverDebtPaysTheProxyExactly() public {
        vm.deal(address(esc), 1 ether);
        vm.mockCall(proxy, abi.encodeWithSelector(IPayable.debt.selector, address(esc)), abi.encode(uint256(0.003 ether)));
        uint256 before = proxy.balance;
        esc.coverDebt();
        assertEq(proxy.balance - before, 0.003 ether);
    }

    function test_reactiveCoverDebtPaysTheSystemContract() public {
        vm.deal(address(rx), 1 ether);
        vm.mockCall(SYS, abi.encodeWithSelector(IPayable.debt.selector, address(rx)), abi.encode(uint256(0.0125 ether)));
        uint256 before = SYS.balance;
        rx.coverDebt();
        assertEq(SYS.balance - before, 0.0125 ether);
        assertEq(address(rx).balance, 1 ether - 0.0125 ether);
    }
}
