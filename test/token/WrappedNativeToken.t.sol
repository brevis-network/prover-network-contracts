// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/token/WrappedNativeToken.sol";

contract WrappedNativeTokenTest is Test {
    WrappedNativeToken public token;
    address payable public alice;
    address payable public bob;

    function setUp() public {
        token = new WrappedNativeToken("Wrapped Native Token", "WNAT");
        alice = payable(makeAddr("alice"));
        bob = payable(makeAddr("bob"));
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function testDeposit() public {
        vm.prank(alice);
        token.deposit{value: 10 ether}();

        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(address(token).balance, 10 ether);
    }

    function testWithdraw() public {
        vm.startPrank(alice);
        token.deposit{value: 10 ether}();

        uint256 balanceBefore = alice.balance;
        token.withdraw(5 ether);

        assertEq(token.balanceOf(alice), 5 ether);
        assertEq(alice.balance, balanceBefore + 5 ether);
        assertEq(address(token).balance, 5 ether);
        vm.stopPrank();
    }

    function testReceive() public {
        vm.prank(alice);
        (bool success,) = address(token).call{value: 10 ether}("");
        assertTrue(success);

        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(address(token).balance, 10 ether);
    }

    function testTransfer() public {
        vm.prank(alice);
        token.deposit{value: 10 ether}();

        vm.prank(alice);
        token.transfer(bob, 3 ether);

        assertEq(token.balanceOf(alice), 7 ether);
        assertEq(token.balanceOf(bob), 3 ether);
    }

    function testWithdrawInsufficientBalance() public {
        vm.prank(alice);
        token.deposit{value: 5 ether}();

        vm.prank(alice);
        vm.expectRevert();
        token.withdraw(10 ether);
    }

    function testMultipleDepositsAndWithdrawals() public {
        vm.startPrank(alice);
        token.deposit{value: 10 ether}();
        token.deposit{value: 5 ether}();
        assertEq(token.balanceOf(alice), 15 ether);

        token.withdraw(3 ether);
        assertEq(token.balanceOf(alice), 12 ether);

        token.withdraw(7 ether);
        assertEq(token.balanceOf(alice), 5 ether);
        vm.stopPrank();
    }

    function testDepositEvent() public {
        vm.expectEmit(true, false, false, true);
        emit WrappedNativeToken.Deposit(alice, 10 ether);

        vm.prank(alice);
        token.deposit{value: 10 ether}();
    }

    function testWithdrawalEvent() public {
        vm.prank(alice);
        token.deposit{value: 10 ether}();

        vm.expectEmit(true, false, false, true);
        emit WrappedNativeToken.Withdrawal(alice, 5 ether);

        vm.prank(alice);
        token.withdraw(5 ether);
    }
}
