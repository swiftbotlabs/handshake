// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { HandshakeEscrow } from "../src/HandshakeEscrow.sol";
import { HandshakeBase } from "./Handshake.t.sol";

/// Stand-in for Reactive's faucet contract (request(address) payable credits REACT to that address on Reactive Network).
contract MockReactFunder {
    mapping(address => uint256) public credited;
    bool public broken;
    function setBroken(bool b) external { broken = b; }
    function request(address to) external payable {
        require(!broken, "funder down");
        credited[to] += msg.value * 100; // 1 ETH = 100 REACT
    }
}

/// Fees -> REACT: posting fees above the escrow's gas floor buy REACT for the watcher, on chain, with nobody in the loop.
contract HandshakeFeesTest is HandshakeBase {
    MockReactFunder funder;
    HandshakeEscrow fe;
    uint256 constant FEE = 0.0002 ether;
    uint256 constant FLOOR = 0.001 ether;

    function setUp() public override {
        super.setUp();
        funder = new MockReactFunder();
        fe = new HandshakeEscrow{ value: FLOOR }(IPayable(payable(proxy)), address(rx), 0.001 ether, FEE, address(funder), FLOOR);
    }

    function _post(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            vm.prank(issuer);
            fe.postJudged{ value: 0.01 ether }("j", block.timestamp + 1 days);
        }
    }

    function test_feesAboveFloorFundTheReactiveContract() public {
        _post(3);
        uint256 sent = fe.fundReactive();
        assertEq(sent, 3 * FEE);
        assertEq(funder.credited(address(rx)), 3 * FEE * 100); // credited to the watcher, not to anyone else
        assertEq(address(fe).balance, FLOOR); // the callback gas float stays
        assertEq(fe.feesToReact(), 3 * FEE);
    }

    function test_autoFundsEveryTenFees() public {
        _post(9);
        assertEq(fe.feesToReact(), 0);
        _post(1); // the 10th fee crosses floor + 10 fees
        assertEq(fe.feesToReact(), 10 * FEE);
        assertEq(address(fe).balance, FLOOR);
    }

    function test_neverTouchesBountyMoney() public {
        _post(5);
        uint256 vaultBefore = address(fe.vault()).balance;
        fe.fundReactive();
        assertEq(address(fe.vault()).balance, vaultBefore);
        assertEq(address(fe.vault()).balance, fe.openTotal());
    }

    function test_belowFloorSendsNothing() public {
        vm.prank(proxy);
        fe.pay(0.0005 ether); // callback gas billed: balance under the floor now
        _post(2);
        assertEq(fe.fundReactive(), 0);
    }

    function test_brokenFunderNeverBlocksPostingOrPayouts() public {
        funder.setBroken(true);
        _post(12); // auto-fund fails quietly
        assertEq(fe.feesToReact(), 0);
        assertEq(address(fe).balance, FLOOR + 12 * FEE); // money stays as callback gas
        assertEq(fe.fundReactive(), 0);
    }

    function test_disabledWhenNoFunder() public {
        assertEq(esc.fundReactive(), 0); // the base escrow has no funder set
    }

    function testFuzz_feeBooksBalance(uint8 posts, uint8 billSeed) public {
        posts = uint8(bound(posts, 0, 40));
        _post(posts);
        uint256 bill = bound(billSeed, 0, address(fe).balance);
        vm.prank(proxy);
        fe.pay(bill);
        fe.fundReactive();
        assertEq(address(fe).balance + bill + fe.feesToReact(), FLOOR + uint256(posts) * FEE);
    }
}
