// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {TestStakedProvers} from "./TestStakedProvers.sol";
import {StakedProvers} from "../src/StakedProvers.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract ProverManagementTest is Test {
    TestStakedProvers stakedProvers;
    MockERC20 brevToken;

    address owner = address(this);
    address prover = address(0x1);
    address staker = address(0x2);
    uint256 constant INITIAL_BALANCE = 1000e18;
    uint256 constant GLOBAL_MIN_SELF_STAKE = 50e18;

    function setUp() public {
        brevToken = new MockERC20("Protocol Token", "TOKEN");
        brevToken = brevToken; // Same token for rewards

        // Deploy with direct deployment pattern (simpler for tests)
        stakedProvers = new TestStakedProvers(address(brevToken), GLOBAL_MIN_SELF_STAKE);

        brevToken.mint(prover, INITIAL_BALANCE);
        brevToken.mint(staker, INITIAL_BALANCE);
        brevToken.mint(address(this), INITIAL_BALANCE); // For reward distribution

        vm.prank(prover);
        brevToken.approve(address(stakedProvers), INITIAL_BALANCE);
        vm.prank(staker);
        brevToken.approve(address(stakedProvers), INITIAL_BALANCE);
        brevToken.approve(address(stakedProvers), INITIAL_BALANCE);
    }

    function test_DeactivateProver() public {
        // Initialize prover
        vm.prank(prover);
        stakedProvers.initProver(100e18, 1000);

        // Verify prover is active
        (StakedProvers.ProverState state1,,,,,,) = stakedProvers.getProverDetails(prover);
        assertTrue(state1 == StakedProvers.ProverState.Active, "Prover should be active");

        // Deactivate prover (admin action)
        vm.expectEmit(true, false, false, false);
        emit ProverDeactivated(prover);
        stakedProvers.deactivateProver(prover);

        // Verify prover is deactivated
        (StakedProvers.ProverState state2,,,,,,) = stakedProvers.getProverDetails(prover);
        assertTrue(state2 == StakedProvers.ProverState.Retired, "Prover should be deactivated");

        // Verify prover is removed from active list but remains in all provers list
        address[] memory activeProvers = stakedProvers.activeProverList();
        assertEq(activeProvers.length, 0, "Active provers list should be empty");

        address[] memory allProvers = stakedProvers.getAllProvers();
        assertEq(allProvers.length, 1, "All provers list should still contain the prover");
        assertEq(allProvers[0], prover, "All provers list should contain the deactivated prover");

        // Staking should now fail
        vm.prank(staker);
        vm.expectRevert("Prover not active");
        stakedProvers.stake(prover, 50e18);

        // But withdrawing rewards should still work
        vm.prank(prover);

        // Only withdraw if there are rewards available
        try stakedProvers.withdrawRewards(prover) {
            // Withdrawal succeeded
        } catch Error(string memory reason) {
            // Expected if no rewards available
            assertEq(reason, "No rewards available");
        }
    }

    function test_SelfRetireProver() public {
        // Initialize prover with lower min self stake to avoid unstaking issues
        vm.prank(prover);
        stakedProvers.initProver(50e18, 1000);

        // Stake additional funds
        vm.prank(staker);
        stakedProvers.stake(prover, 100e18);

        // Cannot retire with active stakes
        vm.prank(prover);
        vm.expectRevert("Active stakes remaining");
        stakedProvers.retireProver();

        // Prover first unstakes to zero (complete exit)
        vm.prank(prover);
        stakedProvers.requestUnstake(prover, 50e18); // Unstake all self-stake
        vm.prank(staker);
        stakedProvers.requestUnstake(prover, 100e18);

        // Wait for unbonding
        vm.warp(block.timestamp + 7 days + 1);

        // Complete unstaking
        vm.prank(prover);
        stakedProvers.completeUnstake(prover);
        vm.prank(staker);
        stakedProvers.completeUnstake(prover);

        // Add some commission then withdraw it
        brevToken.transfer(address(stakedProvers), 100e18);
        stakedProvers.addRewardsPublic(prover, 100e18);
        vm.prank(prover);
        stakedProvers.withdrawRewards(prover);

        // Now prover can retire
        vm.prank(prover);
        vm.expectEmit(true, false, false, false);
        emit ProverRetired(prover);
        stakedProvers.retireProver();

        // Verify prover is retired
        (StakedProvers.ProverState state,,,,,,) = stakedProvers.getProverDetails(prover);
        assertTrue(state == StakedProvers.ProverState.Retired, "Prover should be retired");
    }

    function test_AdminRetireProver() public {
        // Initialize prover with lower min self stake
        vm.prank(prover);
        stakedProvers.initProver(50e18, 1000);

        // Admin cannot retire with active stakes
        vm.expectRevert("Active stakes remaining");
        stakedProvers.retireProver(prover);

        // Unstake all funds
        vm.prank(prover);
        stakedProvers.requestUnstake(prover, 50e18);

        // Wait and complete
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(prover);
        stakedProvers.completeUnstake(prover);

        // Admin retire should work now
        vm.expectEmit(true, false, false, false);
        emit ProverRetired(prover);
        stakedProvers.retireProver(prover);

        // Verify retired
        (StakedProvers.ProverState state,,,,,,) = stakedProvers.getProverDetails(prover);
        assertTrue(state == StakedProvers.ProverState.Retired, "Prover should be retired");
    }

    function test_OnlyOwnerCanDeactivate() public {
        vm.prank(prover);
        stakedProvers.initProver(100e18, 1000);

        // Non-owner cannot deactivate
        vm.prank(prover);
        vm.expectRevert("Ownable: caller is not the owner");
        stakedProvers.deactivateProver(prover);
    }

    function test_OnlyOwnerCanAdminRetire() public {
        vm.prank(prover);
        stakedProvers.initProver(100e18, 1000);

        // Non-owner cannot admin retire
        vm.prank(prover);
        vm.expectRevert("Ownable: caller is not the owner");
        stakedProvers.retireProver(prover);
    }

    function test_CannotDeactivateInactiveProver() public {
        vm.prank(prover);
        stakedProvers.initProver(100e18, 1000);

        // Deactivate first
        stakedProvers.deactivateProver(prover);

        // Cannot deactivate again
        vm.expectRevert("Prover already inactive");
        stakedProvers.deactivateProver(prover);
    }

    function test_CannotRetireInactiveProver() public {
        vm.prank(prover);
        stakedProvers.initProver(100e18, 1000);

        // Deactivate first
        stakedProvers.deactivateProver(prover);

        // Cannot retire inactive prover
        vm.expectRevert("Already inactive");
        stakedProvers.retireProver(prover);

        vm.prank(prover);
        vm.expectRevert("Already inactive");
        stakedProvers.retireProver();
    }

    function test_DeactivatedProverCanStillWithdrawAndComplete() public {
        // Setup stakes and rewards
        vm.prank(prover);
        stakedProvers.initProver(100e18, 1000);

        vm.prank(staker);
        stakedProvers.stake(prover, 100e18);

        // Start unstaking
        vm.prank(staker);
        stakedProvers.requestUnstake(prover, 50e18);

        // Add rewards - transfer tokens to market first
        brevToken.transfer(address(stakedProvers), 100e18);
        stakedProvers.addRewardsPublic(prover, 100e18);

        // Deactivate prover
        stakedProvers.deactivateProver(prover);

        // Should still be able to withdraw rewards
        vm.prank(staker);
        stakedProvers.withdrawRewards(prover);

        vm.prank(prover);
        stakedProvers.withdrawRewards(prover);

        // Should still be able to complete unstaking
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(staker);
        stakedProvers.completeUnstake(prover);
    }

    function test_RequestUnstakeAfterDeactivation() public {
        // Setup stakes
        vm.prank(prover);
        stakedProvers.initProver(100e18, 1000);

        vm.prank(staker);
        stakedProvers.stake(prover, 100e18);

        // Deactivate prover FIRST
        stakedProvers.deactivateProver(prover);

        // Should still be able to request unstaking AFTER deactivation
        vm.prank(staker);
        stakedProvers.requestUnstake(prover, 50e18);

        // Should be able to complete unstaking
        vm.warp(block.timestamp + 7 days + 1);

        uint256 balanceBefore = brevToken.balanceOf(staker);
        vm.prank(staker);
        stakedProvers.completeUnstake(prover);
        uint256 balanceAfter = brevToken.balanceOf(staker);

        assertEq(balanceAfter - balanceBefore, 50e18, "Should receive requested unstake amount");
    }

    // Events for testing
    event ProverDeactivated(address indexed prover);
    event ProverRetired(address indexed prover);
}
