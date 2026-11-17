// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Vm } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { HandshakeEscrow } from "../src/HandshakeEscrow.sol";
import { HandshakeBase } from "./Handshake.t.sol";

/// Minimal 6-decimal token like USDC. `feeBps` > 0 makes it a fee-on-transfer token.
contract MockUSDC {
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;
    uint256 public feeBps;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    constructor(uint256 feeBps_) { feeBps = feeBps_; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { _move(msg.sender, to, a); return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        require(allowance[f][msg.sender] >= a, "allowance");
        allowance[f][msg.sender] -= a;
        _move(f, to, a);
        return true;
    }
    function _move(address f, address to, uint256 a) internal {
        require(balanceOf[f] >= a, "balance");
        balanceOf[f] -= a;
        uint256 fee = a * feeBps / 10_000;
        balanceOf[to] += a - fee;
    }
}

contract HandshakeTokenTest is HandshakeBase {
    uint256 constant FEE = 0.0002 ether;
    HandshakeEscrow tEsc;
    MockUSDC usdc;

    function setUp() public override {
        super.setUp();
        usdc = new MockUSDC(0);
        usdc.mint(issuer, 1_000e6);
        vm.prank(issuer);
        usdc.approve(address(esc), type(uint256).max);
        tEsc = new HandshakeEscrow(IPayable(payable(proxy)), address(rx), 0.001 ether, FEE, address(0), 0);
        vm.prank(issuer);
        usdc.approve(address(tEsc), type(uint256).max);
    }

    function _cond(uint256 job) internal view returns (HandshakeEscrow.Condition memory) {
        return HandshakeEscrow.Condition({
            chainId: JOBS_CHAIN, emitter: address(jobs), topic0: uint256(keccak256("JobRun(uint256,address,uint256)")),
            matchTopic1: true, topic1: job, winnerTopic: 2, minValue: 0
        });
    }

    function test_usdcProofBountyPaysKeeperAcrossChains() public {
        vm.recordLogs();
        vm.prank(issuer);
        uint256 id = esc.postProofToken("run job 7 for 25 USDC", block.timestamp + 1 days, _cond(7), address(usdc), 25e6);
        _pipe(vm.getRecordedLogs(), ESCROW_CHAIN);
        assertEq(usdc.balanceOf(address(esc.vault())), 25e6);
        assertEq(esc.openTotalOf(address(usdc)), 25e6);
        vm.recordLogs();
        vm.prank(keeper);
        jobs.run(7, 1);
        _pipe(vm.getRecordedLogs(), JOBS_CHAIN);
        _deliverCallbacks();
        assertEq(usdc.balanceOf(keeper), 25e6);
        assertEq(esc.openTotalOf(address(usdc)), 0);
        (,,, HandshakeEscrow.Status st,,,) = esc.bounties(id);
        assertEq(uint8(st), uint8(HandshakeEscrow.Status.Paid));
    }

    function test_usdcJudgedBountyRefundsByCronExactly() public {
        vm.recordLogs();
        vm.prank(issuer);
        uint256 id = esc.postJudgedToken("translate the README", block.timestamp + 1 days, address(usdc), 40e6);
        _pipe(vm.getRecordedLogs(), ESCROW_CHAIN);
        vm.warp(block.timestamp + 1 days + 1);
        _tick();
        _deliverCallbacks();
        assertEq(usdc.balanceOf(issuer), 1_000e6);
        (,,, HandshakeEscrow.Status st,,,) = esc.bounties(id);
        assertEq(uint8(st), uint8(HandshakeEscrow.Status.Refunded));
    }

    function test_tokenPostNeedsExactFeeInEth() public {
        vm.deal(issuer, 1 ether);
        vm.startPrank(issuer);
        vm.expectRevert(abi.encodeWithSelector(HandshakeEscrow.WrongFee.selector, 0, FEE));
        tEsc.postJudgedToken("x", block.timestamp + 1 days, address(usdc), 1e6);
        vm.expectRevert(abi.encodeWithSelector(HandshakeEscrow.WrongFee.selector, FEE + 1, FEE));
        tEsc.postJudgedToken{ value: FEE + 1 }("x", block.timestamp + 1 days, address(usdc), 1e6);
        uint256 id = tEsc.postJudgedToken{ value: FEE }("x", block.timestamp + 1 days, address(usdc), 1e6);
        vm.stopPrank();
        assertEq(tEsc.tokenOf(id), address(usdc));
        assertEq(address(tEsc).balance, FEE); // the fee is the callback gas float
    }

    function test_tokenPostWithoutAllowanceReverts() public {
        vm.prank(issuer);
        usdc.approve(address(esc), 0);
        vm.prank(issuer);
        vm.expectRevert(HandshakeEscrow.TokenTransferFailed.selector);
        esc.postJudgedToken("x", block.timestamp + 1 days, address(usdc), 1e6);
    }

    function test_tokenPostRejectsEoaOrZeroToken() public {
        vm.startPrank(issuer);
        vm.expectRevert(HandshakeEscrow.BadAmount.selector);
        esc.postJudgedToken("x", block.timestamp + 1 days, address(0), 1e6);
        vm.expectRevert(HandshakeEscrow.BadAmount.selector);
        esc.postJudgedToken("x", block.timestamp + 1 days, address(0xBEEF), 1e6);
        vm.expectRevert(HandshakeEscrow.BadAmount.selector);
        esc.postJudgedToken("x", block.timestamp + 1 days, address(usdc), 0);
        vm.stopPrank();
    }

    function test_feeOnTransferTokenRecordsWhatArrived() public {
        MockUSDC fot = new MockUSDC(100); // 1 % fee on every transfer
        fot.mint(issuer, 100e6);
        vm.prank(issuer);
        fot.approve(address(esc), type(uint256).max);
        vm.prank(issuer);
        uint256 id = esc.postProofToken("x", block.timestamp + 1 days, _cond(7), address(fot), 10e6);
        (,,,, uint256 amount,,) = esc.bounties(id);
        assertEq(amount, 9.9e6);
        assertEq(fot.balanceOf(address(esc.vault())), 9.9e6);
        vm.prank(proxy);
        esc.settleProof(address(rx), id, keeper, bytes32(0));
        assertEq(fot.balanceOf(address(esc.vault())), 0); // the vault never owes more than it holds
    }

    function test_ethAndTokenBountiesKeepSeparateBooks() public {
        vm.startPrank(issuer);
        uint256 a = esc.postJudged{ value: 1 ether }("eth", block.timestamp + 1 days);
        uint256 b = esc.postJudgedToken("usdc", block.timestamp + 1 days, address(usdc), 5e6);
        vm.stopPrank();
        assertEq(esc.openTotal(), 1 ether);
        assertEq(esc.openTotalOf(address(usdc)), 5e6);
        vm.warp(block.timestamp + 1 days);
        esc.expire(b);
        assertEq(esc.openTotal(), 1 ether);
        assertEq(address(esc.vault()).balance, 1 ether);
        assertEq(esc.openTotalOf(address(usdc)), 0);
        a;
    }

    function testFuzz_tokenRefundIsExact(uint64 amount, uint16 feeBps) public {
        uint256 bps = bound(uint256(feeBps), 0, 500);
        uint256 amt = bound(uint256(amount), 1e6, 500e6);
        MockUSDC t = new MockUSDC(bps);
        t.mint(issuer, amt);
        vm.prank(issuer);
        t.approve(address(esc), amt);
        vm.prank(issuer);
        uint256 id = esc.postJudgedToken("x", block.timestamp + 1 days, address(t), amt);
        (,,,, uint256 received,,) = esc.bounties(id);
        assertEq(received, amt - amt * bps / 10_000);
        vm.warp(block.timestamp + 1 days);
        esc.expire(id);
        assertEq(t.balanceOf(address(esc.vault())), 0);
        assertEq(esc.openTotalOf(address(t)), 0);
    }
}
