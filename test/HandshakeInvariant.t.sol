// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { HandshakeEscrow } from "../src/HandshakeEscrow.sol";
import { MockUSDC } from "./HandshakeToken.t.sol";

/// Drives the escrow with random sequences: posts of both kinds, claims, accepts, cancels, time jumps, proof and expiry
/// callbacks from the proxy (duplicates, wrong ids and late ones included), public expire(), and callback-gas bills.
contract EscrowHandler is Test {
    HandshakeEscrow public esc;
    address public proxy;
    address public rx;
    address[] public actors;
    MockUSDC public usdc;          // a 1 %-fee-on-transfer USDC look-alike, the nastiest common token shape
    uint256 public ghostTokenPosted;
    uint256 public ghostTokenReleased;
    uint256 public ghostPosted;    // all bounty amounts ever posted (fee excluded)
    uint256 public ghostReleased;  // all amounts paid or refunded
    uint256 public ghostFees;
    uint256 public ghostBilled;
    mapping(uint256 => uint256) public closeCount; // how many times each bounty left Open (must stay <= 1)
    uint256 public maxCloseCount;
    bool public closedBountyChanged; // a Paid/Refunded bounty must never change status again
    bool public paidNotAllowed; // a restricted bounty paid an address off its allowlist

    constructor(HandshakeEscrow esc_, address proxy_, address rx_) {
        esc = esc_;
        proxy = proxy_;
        rx = rx_;
        for (uint256 i; i < 4; ++i) actors.push(address(uint160(0xA000 + i)));
        usdc = new MockUSDC(100);
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    function _status(uint256 id) internal view returns (HandshakeEscrow.Status st, uint256 amount) {
        (,,, st, amount,,) = esc.bounties(id);
    }

    function _id(uint256 s) internal view returns (uint256) {
        uint256 n = esc.nextId();
        return n == 1 ? 1 : 1 + (s % (n - 1));
    }

    // track a transition Open -> closed around any call
    modifier tracked(uint256 id) {
        (HandshakeEscrow.Status a, uint256 amt) = _status(id);
        _;
        (HandshakeEscrow.Status b,) = _status(id);
        if (a == HandshakeEscrow.Status.Open && b != HandshakeEscrow.Status.Open) {
            if (esc.tokenOf(id) == address(0)) ghostReleased += amt;
            else ghostTokenReleased += amt;
            if (++closeCount[id] > maxCloseCount) maxCloseCount = closeCount[id];
        }
        if (a != HandshakeEscrow.Status.Open && a != HandshakeEscrow.Status.None && b != a) closedBountyChanged = true;
        if (a == HandshakeEscrow.Status.Open && b == HandshakeEscrow.Status.Paid && esc.restricted(id)) {
            (,,,,, address w,) = esc.bounties(id);
            if (!esc.allowed(id, w)) paidNotAllowed = true;
        }
    }

    function postJudged(uint256 who, uint256 value, uint256 dt) external {
        address a = _actor(who);
        value = bound(value, esc.minBounty() + esc.postFee(), 5 ether);
        dt = bound(dt, 1, 30 days);
        uint256 deadline = block.timestamp + dt;
        vm.deal(a, value);
        vm.prank(a);
        esc.postJudged{ value: value }("j", deadline);
        ghostPosted += value - esc.postFee();
        ghostFees += esc.postFee();
    }

    function postProof(uint256 who, uint256 value, uint256 dt, uint256 job) external {
        address a = _actor(who);
        value = bound(value, esc.minBounty() + esc.postFee(), 5 ether);
        dt = bound(dt, 1, 30 days);
        HandshakeEscrow.Condition memory c = HandshakeEscrow.Condition({
            chainId: 11155111, emitter: address(0x1234), topic0: 1, matchTopic1: true, topic1: job % 5, winnerTopic: 2, minValue: 0
        });
        vm.deal(a, value);
        vm.prank(a);
        esc.postProof{ value: value }("p", block.timestamp + dt, c);
        ghostPosted += value - esc.postFee();
        ghostFees += esc.postFee();
    }

    /// A restricted PROOF bounty: only actor 0 may be paid; proof callbacks name random actors (front-runners included).
    function postProofRestricted(uint256 who, uint256 value, uint256 dt) external {
        address a = _actor(who);
        value = bound(value, esc.minBounty() + esc.postFee(), 5 ether);
        dt = bound(dt, 1, 30 days);
        HandshakeEscrow.Condition memory c = HandshakeEscrow.Condition({
            chainId: 11155111, emitter: address(0x1234), topic0: 1, matchTopic1: true, topic1: 4, winnerTopic: 2, minValue: 0
        });
        address[] memory list = new address[](1);
        list[0] = actors[0];
        uint256 deadline = block.timestamp + dt;
        vm.deal(a, value);
        vm.prank(a);
        esc.postProofFor{ value: value }("r", deadline, c, list);
        ghostPosted += value - esc.postFee();
        ghostFees += esc.postFee();
    }

    function postToken(uint256 who, uint256 amount, uint256 dt, bool proof) external {
        address a = _actor(who);
        amount = bound(amount, 1e6, 1_000e6);
        dt = bound(dt, 1, 30 days);
        uint256 deadline = block.timestamp + dt;
        uint256 fee = esc.postFee();
        HandshakeEscrow.Condition memory c = HandshakeEscrow.Condition({
            chainId: 11155111, emitter: address(0x1234), topic0: 1, matchTopic1: true, topic1: 3, winnerTopic: 2, minValue: 0
        });
        usdc.mint(a, amount);
        vm.deal(a, fee);
        vm.startPrank(a);
        usdc.approve(address(esc), amount);
        uint256 id = proof
            ? esc.postProofToken{ value: fee }("t", deadline, c, address(usdc), amount)
            : esc.postJudgedToken{ value: fee }("t", deadline, address(usdc), amount);
        vm.stopPrank();
        (,,,, uint256 received,,) = esc.bounties(id);
        ghostTokenPosted += received;
        ghostFees += fee;
    }

    function claimAndAccept(uint256 s, uint256 who) external tracked(_id(s)) {
        uint256 id = _id(s);
        (HandshakeEscrow.Status st,) = _status(id);
        (address payable issuer, uint96 deadline, HandshakeEscrow.Kind kind,,,,) = esc.bounties(id);
        if (st != HandshakeEscrow.Status.Open || kind != HandshakeEscrow.Kind.Judged || block.timestamp >= deadline) return;
        address claimer = _actor(who);
        vm.prank(claimer);
        uint256 claimId = esc.claim(id, "c");
        vm.prank(issuer);
        esc.accept(id, claimId);
    }

    function cancel(uint256 s) external tracked(_id(s)) {
        uint256 id = _id(s);
        (HandshakeEscrow.Status st,) = _status(id);
        if (st != HandshakeEscrow.Status.Open) return;
        (address payable issuer,,,,,,) = esc.bounties(id);
        vm.prank(issuer);
        esc.cancel(id);
    }

    function proofCallback(uint256 s, uint256 who) external tracked(_id(s)) {
        uint256 id = _id(s);
        address w = _actor(who);
        vm.prank(proxy);
        esc.settleProof(rx, id, w, bytes32(s)); // duplicates, judged ids, late ones: all must be safe
    }

    function expiryCallback(uint256 s) external tracked(_id(s)) {
        uint256 id = _id(s);
        vm.prank(proxy);
        esc.expireByReactive(rx, id);
    }

    function publicExpire(uint256 s) external tracked(_id(s)) {
        uint256 id = _id(s);
        (HandshakeEscrow.Status st,) = _status(id);
        (, uint96 deadline,,,,,) = esc.bounties(id);
        if (st != HandshakeEscrow.Status.Open || block.timestamp < deadline) return;
        esc.expire(id);
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 10 days));
    }

    function billCallbackGas(uint256 amount) external {
        uint256 avail = address(esc).balance;
        if (avail == 0) return;
        amount = bound(amount, 1, avail);
        vm.prank(proxy); // after bound(): bound() logs through an external call that would consume the prank
        esc.pay(amount);
        ghostBilled += amount;
    }
}

contract HandshakeInvariantTest is Test {
    HandshakeEscrow esc;
    EscrowHandler h;
    address proxy = address(0xC0FFEE);
    address rx = address(0x5EAC);

    function setUp() public {
        vm.warp(1_800_000_000);
        esc = new HandshakeEscrow(IPayable(payable(proxy)), rx, 0.001 ether, 0.0002 ether);
        h = new EscrowHandler(esc, proxy, rx);
        targetContract(address(h));
    }

    /// The vault holds exactly the open bounties: never less (insolvent), never more (stuck money).
    function invariant_vaultEqualsOpenBounties() public view {
        assertEq(address(esc.vault()).balance, esc.openTotal());
    }

    /// openTotal is the true sum of OPEN bounty amounts; closed bounties carry no amount.
    function invariant_openTotalMatchesStorage() public view {
        uint256 sum;
        for (uint256 id = 1; id < esc.nextId(); ++id) {
            (,,, HandshakeEscrow.Status st, uint256 amount,,) = esc.bounties(id);
            if (st == HandshakeEscrow.Status.Open) {
                if (esc.tokenOf(id) == address(0)) sum += amount;
            } else {
                assertEq(amount, 0);
            }
        }
        assertEq(sum, esc.openTotal());
    }

    /// Money is conserved: everything posted is either still open or was released exactly once.
    function invariant_conservation() public view {
        assertEq(h.ghostPosted(), esc.openTotal() + h.ghostReleased());
    }

    /// No bounty is ever paid or refunded twice.
    function invariant_neverClosedTwice() public view {
        assertLe(h.maxCloseCount(), 1);
        assertFalse(h.closedBountyChanged());
    }

    /// A restricted bounty never pays anyone off its allowlist, whatever the callbacks claim.
    function invariant_restrictedPaysOnlyAllowed() public view {
        assertFalse(h.paidNotAllowed());
    }

    /// ERC-20 books: the vault's token balance always equals the open token bounties, and token money is conserved
    /// even for a fee-on-transfer token (bounties record what actually arrived).
    function invariant_tokenBooks() public view {
        assertEq(h.usdc().balanceOf(address(esc.vault())), esc.openTotalOf(address(h.usdc())));
        assertEq(h.ghostTokenPosted(), esc.openTotalOf(address(h.usdc())) + h.ghostTokenReleased());
    }

    /// Callback gas is billed only from fees, never from bounty money.
    function invariant_feesFundGasOnly() public view {
        assertEq(address(esc).balance, h.ghostFees() - h.ghostBilled());
        assertEq(esc.feesCollected(), h.ghostFees());
    }
}
