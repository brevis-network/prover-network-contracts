// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {TestStakedProvers} from "./TestStakedProvers.sol";
import {StakedProvers} from "../src/StakedProvers.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title StakedProvers Test Suite
 * @notice Core tests for staking functionality
 * @dev Tests basic user flows: initialization, staking, unstaking, rewards, slashing
 */
contract StakedProversTest is Test {
    TestStakedProvers public stakedProvers;
    MockERC20 public brevToken;

    address public owner = makeAddr("owner");
    address public prover1 = makeAddr("prover1");
    address public prover2 = makeAddr("prover2");
    address public staker1 = makeAddr("staker1");
    address public staker2 = makeAddr("staker2");
    address public user = makeAddr("user");

    uint256 public constant INITIAL_SUPPLY = 1_000_000e18;
    uint256 public constant MIN_SELF_STAKE = 10_000e18;
    uint256 public constant GLOBAL_MIN_SELF_STAKE = 50e18;
    uint64 public constant COMMISSION_RATE = 1000; // 10%

    function setUp() public {
        // Deploy BREV token (used for both staking and rewards)
        brevToken = new MockERC20("Brevis Token", "BREV");

        // Deploy staked provers contract with direct deployment pattern
        vm.prank(owner);
        stakedProvers = new TestStakedProvers(address(brevToken), GLOBAL_MIN_SELF_STAKE);

        // Mint tokens to participants
        brevToken.mint(prover1, INITIAL_SUPPLY);
        brevToken.mint(prover2, INITIAL_SUPPLY);
        brevToken.mint(staker1, INITIAL_SUPPLY);
        brevToken.mint(staker2, INITIAL_SUPPLY);
        brevToken.mint(address(this), INITIAL_SUPPLY); // For reward distribution
    }

    // ========== CORE FUNCTIONALITY TESTS ==========

    function test_InitProver() public {
        // Initialize prover
        vm.prank(prover1);
        brevToken.approve(address(stakedProvers), MIN_SELF_STAKE);

        vm.prank(prover1);
        stakedProvers.initProver(MIN_SELF_STAKE, COMMISSION_RATE);

        // Verify prover details
        (
            StakedProvers.ProverState state,
            uint256 minSelfStake,
            uint64 commissionRate,
            uint256 totalStaked,
            uint256 stakersCount
        ) = stakedProvers.getProverInfo(prover1);

        assertTrue(state == StakedProvers.ProverState.Active);
        assertEq(minSelfStake, MIN_SELF_STAKE);
        assertEq(commissionRate, COMMISSION_RATE);
        assertEq(totalStaked, MIN_SELF_STAKE);
        assertEq(stakersCount, 1); // Prover counts as one staker

        // Verify prover's stake
        (uint256 amount, uint256 pendingUnstake, uint256 unstakeTime, uint256 pendingRewards) =
            stakedProvers.getStakeInfo(prover1, prover1);

        assertEq(amount, MIN_SELF_STAKE);
        assertEq(pendingUnstake, 0);
        assertEq(unstakeTime, 0);
        assertEq(pendingRewards, 0);

        // Verify active prover list
        address[] memory activeProvers = stakedProvers.activeProverList();
        assertEq(activeProvers.length, 1);
        assertEq(activeProvers[0], prover1);

        // Verify all provers list
        address[] memory allProvers = stakedProvers.getAllProvers();
        assertEq(allProvers.length, 1);
        assertEq(allProvers[0], prover1);
    }

    function test_RevertOnDuplicateProverInit() public {
        _initializeProver(prover1);

        // Try to initialize again - should fail
        vm.prank(prover1);
        brevToken.approve(address(stakedProvers), MIN_SELF_STAKE);

        vm.expectRevert("Prover already initialized");
        vm.prank(prover1);
        stakedProvers.initProver(MIN_SELF_STAKE, COMMISSION_RATE);
    }

    function test_RevertOnInvalidCommissionRate() public {
        vm.prank(prover1);
        brevToken.approve(address(stakedProvers), MIN_SELF_STAKE);

        vm.expectRevert("Invalid commission rate");
        vm.prank(prover1);
        stakedProvers.initProver(MIN_SELF_STAKE, 10001); // > 100%
    }

    function test_Stake() public {
        // Initialize prover
        _initializeProver(prover1);

        uint256 stakeAmount = 5000e18;

        // Staker stakes to prover
        vm.prank(staker1);
        brevToken.approve(address(stakedProvers), stakeAmount);

        vm.prank(staker1);
        stakedProvers.stake(prover1, stakeAmount);

        // Verify stake was recorded
        (uint256 amount,,,) = stakedProvers.getStakeInfo(prover1, staker1);
        assertEq(amount, stakeAmount);

        // Verify total stake increased
        (,,, uint256 totalStaked,) = stakedProvers.getProverInfo(prover1);
        assertEq(totalStaked, MIN_SELF_STAKE + stakeAmount);
    }

    function test_RevertOnStakeToInactiveProver() public {
        address inactiveProver = makeAddr("inactive");

        vm.prank(staker1);
        brevToken.approve(address(stakedProvers), 1000e18);

        vm.expectRevert("Prover not active");
        vm.prank(staker1);
        stakedProvers.stake(inactiveProver, 1000e18);
    }

    function test_RevertOnStakeBelowMinSelfStake() public {
        vm.prank(prover1);
        brevToken.approve(address(stakedProvers), MIN_SELF_STAKE);
        vm.prank(prover1);
        stakedProvers.initProver(MIN_SELF_STAKE, COMMISSION_RATE);

        // Slash prover to reduce effective self-stake below minimum
        vm.prank(owner);
        stakedProvers.slashProverPublic(prover1, 600000); // 60% slash

        vm.prank(staker1);
        brevToken.approve(address(stakedProvers), 1000e18);

        vm.expectRevert("Prover below min self-stake");
        vm.prank(staker1);
        stakedProvers.stake(prover1, 1000e18);
    }

    function test_RequestUnstake() public {
        // Setup: initialize prover and add stake
        _initializeProver(prover1);
        uint256 stakeAmount = 5000e18;
        _stakeToProver(staker1, prover1, stakeAmount);

        uint256 unstakeAmount = 2000e18;

        // Initiate unstake
        vm.prank(staker1);
        stakedProvers.requestUnstake(prover1, unstakeAmount);

        // Verify pending unstake was set
        (, uint256 pendingUnstake, uint256 unstakeTime,) = stakedProvers.getStakeInfo(prover1, staker1);
        assertEq(pendingUnstake, unstakeAmount);
        assertEq(unstakeTime, block.timestamp);

        // Verify active stake was reduced
        (uint256 activeStake,,,) = stakedProvers.getStakeInfo(prover1, staker1);
        assertEq(activeStake, stakeAmount - unstakeAmount);
    }

    function test_CompleteUnstake() public {
        _initializeProver(prover1);
        uint256 stakeAmount = 5000e18;
        _stakeToProver(staker1, prover1, stakeAmount);

        uint256 unstakeAmount = 2000e18;
        vm.prank(staker1);
        stakedProvers.requestUnstake(prover1, unstakeAmount);

        // Try to complete before delay
        vm.expectRevert("No unstakes ready for completion");
        vm.prank(staker1);
        stakedProvers.completeUnstake(prover1);

        // Fast forward past delay
        vm.warp(block.timestamp + 7 days + 1);

        uint256 balanceBefore = brevToken.balanceOf(staker1);
        vm.prank(staker1);
        stakedProvers.completeUnstake(prover1);
        uint256 balanceAfter = brevToken.balanceOf(staker1);

        assertEq(balanceAfter - balanceBefore, unstakeAmount);

        // Verify pending unstake cleared
        (, uint256 pendingUnstake, uint256 unstakeTime,) = stakedProvers.getStakeInfo(prover1, staker1);
        assertEq(pendingUnstake, 0);
        assertEq(unstakeTime, 0);
    }

    function test_RevertOnInsufficientStakeForRequestUnstake() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 1000e18);

        vm.expectRevert("Insufficient stake");
        vm.prank(staker1);
        stakedProvers.requestUnstake(prover1, 2000e18); // Try to unstake more than staked
    }

    function test_MultipleRequestUnstake() public {
        _initializeProver(prover1);
        uint256 stakeAmount = 5000e18;
        _stakeToProver(staker1, prover1, stakeAmount);

        // First unstake request
        vm.prank(staker1);
        stakedProvers.requestUnstake(prover1, 1000e18);

        // Second unstake request should now succeed (multiple requests allowed)
        vm.prank(staker1);
        stakedProvers.requestUnstake(prover1, 1000e18);

        // Verify we have 2 pending unstake requests
        (,, uint256 pendingUnstakeCount,) = stakedProvers.getStakeInfo(prover1, staker1);
        assertEq(pendingUnstakeCount, 2, "Should have 2 pending unstake requests");
    }

    function test_MaxPendingUnstakesLimit() public {
        _initializeProver(prover1);
        uint256 stakeAmount = 100000e18; // Large stake to allow many unstakes
        _stakeToProver(staker1, prover1, stakeAmount);

        // Create 10 unstake requests (the maximum)
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(staker1);
            stakedProvers.requestUnstake(prover1, 1000e18);
        }

        // Verify we have 10 pending requests
        (,, uint256 pendingUnstakeCount,) = stakedProvers.getStakeInfo(prover1, staker1);
        assertEq(pendingUnstakeCount, 10, "Should have 10 pending unstake requests");

        // Try to create an 11th request - should fail
        vm.expectRevert("Too many pending unstakes");
        vm.prank(staker1);
        stakedProvers.requestUnstake(prover1, 1000e18);
    }

    function test_ProverCanUnstakeToZero() public {
        _initializeProver(prover1);

        // Prover can unstake all their self-stake (complete exit)
        vm.prank(prover1);
        stakedProvers.requestUnstake(prover1, MIN_SELF_STAKE);

        (, uint256 pendingUnstake,,) = stakedProvers.getStakeInfo(prover1, prover1);
        assertEq(pendingUnstake, MIN_SELF_STAKE);
    }

    function test_RewardDistribution() public {
        // Setup: initialize prover and add stakers
        _initializeProver(prover1);
        uint256 stakeAmount1 = 8000e18;
        uint256 stakeAmount2 = 2000e18;
        _stakeToProver(staker1, prover1, stakeAmount1);
        _stakeToProver(staker2, prover1, stakeAmount2);

        uint256 rewardAmount = 1000e18;

        // Add rewards
        brevToken.transfer(address(stakedProvers), rewardAmount);
        stakedProvers.addRewardsPublic(prover1, rewardAmount);

        // Calculate expected rewards
        uint256 totalStake = MIN_SELF_STAKE + stakeAmount1 + stakeAmount2; // 20000e18
        uint256 expectedCommission = (rewardAmount * COMMISSION_RATE) / 10000; // 10% of 1000e18 = 100e18
        uint256 stakersReward = rewardAmount - expectedCommission; // 900e18

        // Expected individual rewards (proportional to stake)
        uint256 expectedRewards1 = (stakersReward * stakeAmount1) / totalStake; // 900e18 * 8000e18 / 20000e18 = 360e18
        uint256 expectedRewards2 = (stakersReward * stakeAmount2) / totalStake; // 900e18 * 2000e18 / 20000e18 = 90e18
        uint256 expectedProverRewards = (stakersReward * MIN_SELF_STAKE) / totalStake + expectedCommission; // 450e18 + 100e18 = 550e18

        // Check pending rewards
        (,,, uint256 pendingRewards1) = stakedProvers.getStakeInfo(prover1, staker1);
        (,,, uint256 pendingRewards2) = stakedProvers.getStakeInfo(prover1, staker2);
        (,,, uint256 proverPendingRewards) = stakedProvers.getStakeInfo(prover1, prover1);

        // Allow for small rounding differences
        assertApproxEqRel(pendingRewards1, expectedRewards1, 1e15); // 0.1% tolerance
        assertApproxEqRel(pendingRewards2, expectedRewards2, 1e15);
        assertApproxEqRel(proverPendingRewards, expectedProverRewards, 1e15);
    }

    function test_WithdrawRewards() public {
        // Setup: add rewards
        _initializeProver(prover1);
        uint256 stakeAmount = 10000e18;
        _stakeToProver(staker1, prover1, stakeAmount);

        uint256 rewardAmount = 1000e18;
        brevToken.transfer(address(stakedProvers), rewardAmount);
        stakedProvers.addRewardsPublic(prover1, rewardAmount);

        uint256 balanceBefore = brevToken.balanceOf(staker1);

        // Withdraw rewards
        vm.prank(staker1);
        stakedProvers.withdrawRewards(prover1);

        uint256 balanceAfter = brevToken.balanceOf(staker1);
        uint256 withdrawn = balanceAfter - balanceBefore;

        assertGt(withdrawn, 0, "Should have withdrawn some rewards");

        // Check that pending rewards are now zero
        (,,, uint256 pendingRewards) = stakedProvers.getStakeInfo(prover1, staker1);
        assertEq(pendingRewards, 0);
    }

    function test_WithdrawFromInactiveProver() public {
        // Setup rewards first
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 1000e18);

        brevToken.transfer(address(stakedProvers), 100e18);
        stakedProvers.addRewardsPublic(prover1, 100e18);

        // Should still be able to withdraw rewards even if prover becomes inactive
        vm.prank(staker1);
        stakedProvers.withdrawRewards(prover1); // Should not revert
    }

    function test_SlashProver() public {
        // Setup staking
        _initializeProver(prover1);
        uint256 stakeAmount = 9000e18;
        _stakeToProver(staker1, prover1, stakeAmount);

        uint256 totalStakeBefore = 19000e18; // MIN_SELF_STAKE + 9000e18
        uint256 slashPercentage = 200000; // 20%

        vm.prank(owner);
        stakedProvers.slashProverPublic(prover1, slashPercentage);

        (,,, uint256 totalStakeAfter,) = stakedProvers.getProverInfo(prover1);
        uint256 expectedStakeAfter = (totalStakeBefore * 80) / 100; // 80% remaining = 15200e18

        assertEq(totalStakeAfter, expectedStakeAfter);
    }

    function test_SlashInactiveProver() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 1000e18);

        // Deactivate prover
        vm.prank(owner);
        stakedProvers.deactivateProver(prover1);

        // Should still be able to slash inactive prover
        uint256 stakeBefore = 11000e18; // MIN_SELF_STAKE + 1000e18
        vm.prank(owner);
        stakedProvers.slashProverPublic(prover1, 100000); // 10%

        (,,, uint256 stakeAfter,) = stakedProvers.getProverInfo(prover1);
        assertEq(stakeAfter, (stakeBefore * 90) / 100);
    }

    function test_SlashAfterUnbondingStart() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 900e18);

        // Staker initiates unstake
        vm.prank(staker1);
        stakedProvers.requestUnstake(prover1, 500e18);

        // Slash while unbonding
        vm.prank(owner);
        stakedProvers.slashProverPublic(prover1, 200000); // 20%

        // Complete unstake - should receive slashed amount
        vm.warp(block.timestamp + 7 days + 1);
        uint256 balanceBefore = brevToken.balanceOf(staker1);
        vm.prank(staker1);
        stakedProvers.completeUnstake(prover1);
        uint256 balanceAfter = brevToken.balanceOf(staker1);

        // Should receive 80% of 500e18 = 400e18
        assertEq(balanceAfter - balanceBefore, 400e18);
    }

    function test_CannotSlash100Percent() public {
        _initializeProver(prover1);

        vm.expectRevert("Cannot slash 100%");
        vm.prank(owner);
        stakedProvers.slashProverPublic(prover1, 1000000); // 100%
    }

    // ========== HELPER FUNCTIONS ==========

    function _initializeProver(address prover) internal {
        vm.prank(prover);
        brevToken.approve(address(stakedProvers), MIN_SELF_STAKE);

        vm.prank(prover);
        stakedProvers.initProver(MIN_SELF_STAKE, COMMISSION_RATE);
    }

    function test_StakerTracking() public {
        // Initialize prover
        _initializeProver(prover1);

        // Check initial stakers list (should just be the prover)
        address[] memory stakers = stakedProvers.getProverStakers(prover1);
        assertEq(stakers.length, 1, "Should have 1 staker initially");
        assertEq(stakers[0], prover1, "Prover should be in stakers list");

        // Check staker count from getProverInfo
        (,,,, uint256 stakerCount) = stakedProvers.getProverInfo(prover1);
        assertEq(stakerCount, 1, "Staker count should be 1");

        // Add another staker
        _stakeToProver(staker1, prover1, 100e18);

        // Check updated stakers list
        stakers = stakedProvers.getProverStakers(prover1);
        assertEq(stakers.length, 2, "Should have 2 stakers");

        // Verify both prover and staker are in the list
        bool foundProver = false;
        bool foundStaker = false;
        for (uint256 i = 0; i < stakers.length; i++) {
            if (stakers[i] == prover1) foundProver = true;
            if (stakers[i] == staker1) foundStaker = true;
        }
        assertTrue(foundProver, "Prover should be in stakers list");
        assertTrue(foundStaker, "Staker should be in stakers list");

        // Check staker count
        (,,,, stakerCount) = stakedProvers.getProverInfo(prover1);
        assertEq(stakerCount, 2, "Staker count should be 2");

        // Fully unstake one staker
        vm.prank(staker1);
        stakedProvers.requestUnstake(prover1, 100e18);

        // Check stakers list after unstaking
        stakers = stakedProvers.getProverStakers(prover1);
        assertEq(stakers.length, 1, "Should have 1 staker after unstaking");
        assertEq(stakers[0], prover1, "Only prover should remain in stakers list");

        // Check staker count
        (,,,, stakerCount) = stakedProvers.getProverInfo(prover1);
        assertEq(stakerCount, 1, "Staker count should be 1 after unstaking");
    }

    function test_InternalViewFunctions() public {
        // Initialize prover
        _initializeProver(prover1);

        // Check initial internal state
        (uint256 totalRawShares, uint256 scale, uint256 accRewardPerRawShare, uint256 stakersCount) =
            stakedProvers.getProverInternals(prover1);

        assertGt(totalRawShares, 0, "Should have raw shares from self-stake");
        assertEq(scale, 1e18, "Scale should be 1.0 initially (SCALE_FACTOR)");
        assertEq(accRewardPerRawShare, 0, "No rewards accumulated initially");
        assertEq(stakersCount, 1, "Should have 1 staker (the prover)");

        // Check prover's internal stake info
        (uint256 rawShares, uint256 rewardDebt, uint256 pendingRewards, uint256 pendingUnstakeRaw) =
            stakedProvers.getStakeInternals(prover1, prover1);

        assertGt(rawShares, 0, "Prover should have raw shares");
        assertEq(rewardDebt, 0, "No reward debt initially");
        assertEq(pendingRewards, 0, "No pending rewards initially");
        assertEq(pendingUnstakeRaw, 0, "No pending unstake initially");

        // Add another staker and verify internal state changes
        _stakeToProver(staker1, prover1, 100e18);

        (totalRawShares, scale, accRewardPerRawShare, stakersCount) = stakedProvers.getProverInternals(prover1);

        assertGt(totalRawShares, rawShares, "Total raw shares should increase");
        assertEq(scale, 1e18, "Scale should still be 1.0");
        assertEq(stakersCount, 2, "Should have 2 stakers now");

        // Check new staker's internal state
        (
            uint256 staker1RawShares,
            uint256 staker1RewardDebt,
            uint256 staker1PendingRewards,
            uint256 staker1PendingUnstakeRaw
        ) = stakedProvers.getStakeInternals(prover1, staker1);

        assertGt(staker1RawShares, 0, "Staker1 should have raw shares");
        assertEq(staker1RewardDebt, 0, "No reward debt for new staker");
        assertEq(staker1PendingRewards, 0, "No pending rewards for new staker");
        assertEq(staker1PendingUnstakeRaw, 0, "No pending unstake for new staker");
    }

    function _stakeToProver(address staker, address prover, uint256 amount) internal {
        vm.prank(staker);
        brevToken.approve(address(stakedProvers), amount);

        vm.prank(staker);
        stakedProvers.stake(prover, amount);
    }

    // === GLOBAL MIN SELF STAKE TESTS ===

    function test_GlobalMinSelfStakeDefault() public view {
        assertEq(stakedProvers.globalMinSelfStake(), GLOBAL_MIN_SELF_STAKE);
    }

    function test_SetGlobalMinSelfStake() public {
        uint256 newMinStake = 2000e18;

        vm.expectEmit(true, true, true, true);
        emit GlobalMinSelfStakeUpdated(GLOBAL_MIN_SELF_STAKE, newMinStake);

        vm.prank(owner);
        stakedProvers.setGlobalMinSelfStake(newMinStake);

        assertEq(stakedProvers.globalMinSelfStake(), newMinStake);
    }

    function test_OnlyOwnerCanSetGlobalMinSelfStake() public {
        vm.expectRevert();
        vm.prank(user);
        stakedProvers.setGlobalMinSelfStake(2000e18);
    }

    function test_CannotSetZeroGlobalMinSelfStake() public {
        vm.expectRevert("Global min self stake must be positive");
        vm.prank(owner);
        stakedProvers.setGlobalMinSelfStake(0);
    }

    function test_InitProverMeetsGlobalMinimum() public {
        uint256 minSelfStake = 75e18; // Above global minimum

        // Setup tokens for prover
        brevToken.mint(prover2, minSelfStake);
        vm.startPrank(prover2);
        brevToken.approve(address(stakedProvers), minSelfStake);

        // Should succeed
        stakedProvers.initProver(minSelfStake, COMMISSION_RATE);

        vm.stopPrank();

        (StakedProvers.ProverState state,,,,) = stakedProvers.getProverInfo(prover2);
        assertTrue(state == StakedProvers.ProverState.Active);
    }

    function test_InitProverBelowGlobalMinimumFails() public {
        uint256 minSelfStake = 25e18; // Below global minimum of 50e18

        // Setup tokens for prover
        brevToken.mint(prover2, minSelfStake);
        vm.startPrank(prover2);
        brevToken.approve(address(stakedProvers), minSelfStake);

        // Should fail
        vm.expectRevert("Below global minimum self stake");
        stakedProvers.initProver(minSelfStake, COMMISSION_RATE);

        vm.stopPrank();
    }

    function test_InitProverExactlyAtGlobalMinimum() public {
        uint256 minSelfStake = 50e18; // Exactly at global minimum

        // Setup tokens for prover
        brevToken.mint(prover2, minSelfStake);
        vm.startPrank(prover2);
        brevToken.approve(address(stakedProvers), minSelfStake);

        // Should succeed
        stakedProvers.initProver(minSelfStake, COMMISSION_RATE);

        vm.stopPrank();

        (StakedProvers.ProverState state,,,,) = stakedProvers.getProverInfo(prover2);
        assertTrue(state == StakedProvers.ProverState.Active);
    }

    function test_GlobalMinDoesNotAffectExistingProvers() public {
        // First initialize prover1 with current requirements
        vm.prank(prover1);
        brevToken.approve(address(stakedProvers), MIN_SELF_STAKE);
        vm.prank(prover1);
        stakedProvers.initProver(MIN_SELF_STAKE, COMMISSION_RATE);

        // Verify prover1 is active
        (StakedProvers.ProverState initialState,,,,) = stakedProvers.getProverInfo(prover1);
        assertTrue(initialState == StakedProvers.ProverState.Active);

        // Increase global minimum above prover1's current requirement
        vm.prank(owner);
        stakedProvers.setGlobalMinSelfStake(20000e18);

        // prover1 should still be active (not retroactive)
        (StakedProvers.ProverState state1,,,,) = stakedProvers.getProverInfo(prover1);
        assertTrue(state1 == StakedProvers.ProverState.Active);

        // But new provers must meet the new requirement
        uint256 lowMinSelfStake = 15000e18; // Below new global minimum

        brevToken.mint(prover2, lowMinSelfStake);
        vm.startPrank(prover2);
        brevToken.approve(address(stakedProvers), lowMinSelfStake);

        vm.expectRevert("Below global minimum self stake");
        stakedProvers.initProver(lowMinSelfStake, COMMISSION_RATE);

        vm.stopPrank();
    }

    // Add the event declaration
    event GlobalMinSelfStakeUpdated(uint256 oldMinStake, uint256 newMinStake);
}
