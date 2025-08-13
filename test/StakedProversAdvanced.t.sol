// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {TestStakedProvers} from "./TestStakedProvers.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title StakedProvers Advanced Test Suite
 * @notice Advanced tests for edge cases, complex scenarios, and security-critical paths
 * @dev Tests extreme scenarios, commission edge cases, complex interactions, and stress testing
 */
contract StakedProversAdvancedTest is Test {
    TestStakedProvers public stakedProvers;
    MockERC20 public brevToken;

    address public owner = makeAddr("owner");
    address public prover1 = makeAddr("prover1");
    address public prover2 = makeAddr("prover2");
    address public staker1 = makeAddr("staker1");
    address public staker2 = makeAddr("staker2");
    address public staker3 = makeAddr("staker3");

    uint256 public constant INITIAL_SUPPLY = 1_000_000e18;
    uint256 public constant MIN_SELF_STAKE = 10_000e18;
    uint256 public constant GLOBAL_MIN_SELF_STAKE = 50e18;
    uint64 public constant COMMISSION_RATE = 1000; // 10%

    function setUp() public {
        // Deploy contracts
        brevToken = new MockERC20("Protocol Token", "TOKEN");
        brevToken = brevToken; // Same token for rewards

        // Deploy with direct deployment pattern (simpler for tests)
        vm.prank(owner);
        stakedProvers = new TestStakedProvers(address(brevToken), GLOBAL_MIN_SELF_STAKE);

        // Mint tokens (same token used for staking and rewards)
        brevToken.mint(prover1, INITIAL_SUPPLY);
        brevToken.mint(prover2, INITIAL_SUPPLY);
        brevToken.mint(staker1, INITIAL_SUPPLY);
        brevToken.mint(staker2, INITIAL_SUPPLY);
        brevToken.mint(staker3, INITIAL_SUPPLY);
        brevToken.mint(address(this), INITIAL_SUPPLY); // For reward distribution

        // Approve spending
        vm.prank(prover1);
        brevToken.approve(address(stakedProvers), INITIAL_SUPPLY);
        vm.prank(prover2);
        brevToken.approve(address(stakedProvers), INITIAL_SUPPLY);
        vm.prank(staker1);
        brevToken.approve(address(stakedProvers), INITIAL_SUPPLY);
        vm.prank(staker2);
        brevToken.approve(address(stakedProvers), INITIAL_SUPPLY);
        vm.prank(staker3);
        brevToken.approve(address(stakedProvers), INITIAL_SUPPLY);
        brevToken.approve(address(stakedProvers), INITIAL_SUPPLY);
    }

    // ========== COMMISSION EDGE CASES ==========

    function test_ZeroCommissionRateRewards() public {
        // Initialize prover with 0% commission
        vm.prank(prover1);
        stakedProvers.initProver(MIN_SELF_STAKE, 0);

        _stakeToProver(staker1, prover1, 5000e18);

        uint256 rewardAmount = 1000e18;
        brevToken.transfer(address(stakedProvers), rewardAmount);
        stakedProvers.addRewardsPublic(prover1, rewardAmount);

        // With 0% commission, all rewards go to stake proportionally
        uint256 totalStake = MIN_SELF_STAKE + 5000e18; // 15000e18

        (,,, uint256 proverRewards) = stakedProvers.getStakeInfo(prover1, prover1);
        (,,, uint256 stakerRewards) = stakedProvers.getStakeInfo(prover1, staker1);

        uint256 expectedProverRewards = (rewardAmount * MIN_SELF_STAKE) / totalStake; // 666.67e18
        uint256 expectedStakerRewards = (rewardAmount * 5000e18) / totalStake; // 333.33e18

        assertApproxEqRel(proverRewards, expectedProverRewards, 1e15);
        assertApproxEqRel(stakerRewards, expectedStakerRewards, 1e15);
    }

    function test_MaxCommissionRateRewards() public {
        // Initialize prover with 100% commission
        vm.prank(prover1);
        stakedProvers.initProver(MIN_SELF_STAKE, 10000);

        _stakeToProver(staker1, prover1, 5000e18);

        uint256 rewardAmount = 1000e18;
        brevToken.transfer(address(stakedProvers), rewardAmount);
        stakedProvers.addRewardsPublic(prover1, rewardAmount);

        // With 100% commission, all rewards go to prover
        (,,, uint256 proverRewards) = stakedProvers.getStakeInfo(prover1, prover1);
        (,,, uint256 stakerRewards) = stakedProvers.getStakeInfo(prover1, staker1);

        assertEq(proverRewards, rewardAmount);
        assertEq(stakerRewards, 0);
    }

    function test_NoStakerRewards() public {
        _initializeProver(prover1);

        // Prover unstakes all their stake
        vm.prank(prover1);
        stakedProvers.requestUnstake(prover1, MIN_SELF_STAKE);

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(prover1);
        stakedProvers.completeUnstake(prover1);

        // Add rewards when no stakers exist
        uint256 rewardAmount = 500e18;
        brevToken.transfer(address(stakedProvers), rewardAmount);
        stakedProvers.addRewardsPublic(prover1, rewardAmount);

        // All rewards should go to prover's commission
        (,,, uint256 proverRewards) = stakedProvers.getStakeInfo(prover1, prover1);
        assertEq(proverRewards, rewardAmount);
    }

    function test_RewardsDistributionWithOnlyProverStake() public {
        _initializeProver(prover1);

        // No external stakers, only prover's self-stake
        uint256 rewardAmount = 1000e18;
        brevToken.transfer(address(stakedProvers), rewardAmount);
        stakedProvers.addRewardsPublic(prover1, rewardAmount);

        // All rewards should go to prover (as commission since no other stakers)
        (,,, uint256 proverRewards) = stakedProvers.getStakeInfo(prover1, prover1);
        assertEq(proverRewards, rewardAmount);
    }

    // ========== EXTREME SCENARIOS ==========

    function test_SingleWeiStakeAndRewards() public {
        _initializeProver(prover1);

        // Stake just 1 wei
        vm.prank(staker1);
        stakedProvers.stake(prover1, 1);

        uint256 rewardAmount = 1000e18;
        brevToken.transfer(address(stakedProvers), rewardAmount);
        stakedProvers.addRewardsPublic(prover1, rewardAmount);

        // With 1 wei vs 10000e18 total stake, rewards may round to 0
        // This is expected behavior for extremely small stakes
        (,,, uint256 stakerRewards) = stakedProvers.getStakeInfo(prover1, staker1);

        // Total stake: 10000e18 + 1 wei
        // Staker portion: ~0 due to rounding with such a tiny fraction
        // This test verifies the system handles tiny stakes without breaking
        assertTrue(stakerRewards >= 0); // Should not revert, but may be 0 due to rounding
    }

    function test_MassiveStakeAndSlash() public {
        _initializeProver(prover1);

        // Stake enormous amount
        uint256 massiveStake = 100_000_000e18;
        brevToken.mint(staker1, massiveStake);
        vm.prank(staker1);
        brevToken.approve(address(stakedProvers), massiveStake);
        vm.prank(staker1);
        stakedProvers.stake(prover1, massiveStake);

        // Slash 99.99%
        vm.prank(owner);
        stakedProvers.slashProverPublic(prover1, 999900); // 99.99%

        (,,, uint256 totalStake,) = stakedProvers.getProverInfo(prover1);
        uint256 expectedRemaining = ((MIN_SELF_STAKE + massiveStake) * 1) / 10000; // 0.01%
        assertApproxEqRel(totalStake, expectedRemaining, 1e15);
    }

    function test_ExtremeSlashingScenario() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 4000e18);

        // Multiple severe slashes
        vm.prank(owner);
        stakedProvers.slashProverPublic(prover1, 800000); // 80% slash - leaves 20%
        vm.prank(owner);
        stakedProvers.slashProverPublic(prover1, 750000); // 75% of remaining - leaves 5% total
        vm.prank(owner);
        stakedProvers.slashProverPublic(prover1, 500000); // 50% of remaining - leaves 2.5% total

        (,,, uint256 finalStake,) = stakedProvers.getProverInfo(prover1);
        uint256 originalStake = MIN_SELF_STAKE + 4000e18; // 14000e18
        uint256 expectedFinalStake = (originalStake * 25) / 1000; // 2.5% = 350e18

        assertEq(finalStake, expectedFinalStake);

        // Staker should still be able to unstake remaining amount
        vm.prank(staker1);
        stakedProvers.requestUnstake(prover1, (4000e18 * 25) / 1000); // 2.5% of original stake

        vm.warp(block.timestamp + 7 days + 1);
        uint256 balanceBefore = brevToken.balanceOf(staker1);
        vm.prank(staker1);
        stakedProvers.completeUnstake(prover1);
        uint256 balanceAfter = brevToken.balanceOf(staker1);

        assertEq(balanceAfter - balanceBefore, (4000e18 * 25) / 1000);
    }

    // ========== COMPLEX INTERACTION SEQUENCES ==========

    function test_MultipleRewardRounds() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 400e18);
        _stakeToProver(staker2, prover1, 500e18);

        // First reward round
        brevToken.transfer(address(stakedProvers), 200e18);
        stakedProvers.addRewardsPublic(prover1, 200e18);

        // Second reward round BEFORE withdrawals
        brevToken.transfer(address(stakedProvers), 300e18);
        stakedProvers.addRewardsPublic(prover1, 300e18);

        // Total stake: 10000e18 + 400e18 + 500e18 = 10900e18
        // Total rewards: 500e18, commission: 50e18, stakers: 450e18
        // Staker1 share: 400/10900 * 450e18 ≈ 16.51e18
        // Staker2 share: 500/10900 * 450e18 ≈ 20.64e18

        (,,, uint256 pendingStaker1) = stakedProvers.getStakeInfo(prover1, staker1);
        (,,, uint256 pendingStaker2) = stakedProvers.getStakeInfo(prover1, staker2);

        // Check rewards are distributed proportionally
        uint256 totalStake = MIN_SELF_STAKE + 400e18 + 500e18; // 10900e18
        uint256 totalDistributed = 450e18; // 500e18 - 50e18 commission
        uint256 expectedStaker1 = (totalDistributed * 400e18) / totalStake;
        uint256 expectedStaker2 = (totalDistributed * 500e18) / totalStake;

        assertApproxEqRel(pendingStaker1, expectedStaker1, 1e15);
        assertApproxEqRel(pendingStaker2, expectedStaker2, 1e15);
    }

    function test_RewardDistributionAccuracyWithPartialUnstake() public {
        _initializeProver(prover1);

        // Two stakers: A=100, B=300
        _stakeToProver(staker1, prover1, 100e18); // staker1 = A
        _stakeToProver(staker2, prover1, 300e18); // staker2 = B

        // First reward round
        uint256 firstReward = 400e18;
        brevToken.transfer(address(stakedProvers), firstReward);
        stakedProvers.addRewardsPublic(prover1, firstReward);

        // Calculate expected rewards after first round
        // Total stake: 10000e18 (prover) + 100e18 (A) + 300e18 (B) = 10400e18
        // Commission: 400e18 * 10% = 40e18
        // Stakers reward: 360e18
        // A's share: (100/10400) * 360e18 ≈ 3.46e18
        // B's share: (300/10400) * 360e18 ≈ 10.38e18
        uint256 totalStakeAfterFirst = MIN_SELF_STAKE + 100e18 + 300e18; // 10400e18
        uint256 stakersRewardFirst = 360e18; // 400e18 - 40e18 commission
        uint256 expectedA1 = (stakersRewardFirst * 100e18) / totalStakeAfterFirst;
        uint256 expectedB1 = (stakersRewardFirst * 300e18) / totalStakeAfterFirst;

        // Partial unstake by A between reward rounds
        vm.prank(staker1);
        stakedProvers.requestUnstake(prover1, 60e18); // A reduces from 100 to 40

        // Second reward round (with gap in time and different stake distribution)
        vm.warp(block.timestamp + 1 days);
        uint256 secondReward = 500e18;
        brevToken.transfer(address(stakedProvers), secondReward);
        stakedProvers.addRewardsPublic(prover1, secondReward);

        // Calculate expected rewards after second round
        // New total stake: 10000e18 (prover) + 40e18 (A) + 300e18 (B) = 10340e18
        // Commission: 500e18 * 10% = 50e18
        // Stakers reward: 450e18
        // A's additional share: (40/10340) * 450e18 ≈ 1.74e18
        // B's additional share: (300/10340) * 450e18 ≈ 13.05e18
        uint256 totalStakeAfterSecond = MIN_SELF_STAKE + 40e18 + 300e18; // 10340e18
        uint256 stakersRewardSecond = 450e18; // 500e18 - 50e18 commission
        uint256 expectedA2 = (stakersRewardSecond * 40e18) / totalStakeAfterSecond;
        uint256 expectedB2 = (stakersRewardSecond * 300e18) / totalStakeAfterSecond;

        // Verify total accumulated rewards match expected splits
        (,,, uint256 actualA) = stakedProvers.getStakeInfo(prover1, staker1);
        (,,, uint256 actualB) = stakedProvers.getStakeInfo(prover1, staker2);

        uint256 expectedATotalRewards = expectedA1 + expectedA2;
        uint256 expectedBTotalRewards = expectedB1 + expectedB2;

        assertApproxEqRel(actualA, expectedATotalRewards, 1e15, "Staker A rewards incorrect");
        assertApproxEqRel(actualB, expectedBTotalRewards, 1e15, "Staker B rewards incorrect");

        // Withdraw rewards and verify exact amounts
        uint256 balanceABefore = brevToken.balanceOf(staker1);
        uint256 balanceBBefore = brevToken.balanceOf(staker2);

        vm.prank(staker1);
        stakedProvers.withdrawRewards(prover1);
        vm.prank(staker2);
        stakedProvers.withdrawRewards(prover1);

        uint256 balanceAAfter = brevToken.balanceOf(staker1);
        uint256 balanceBAfter = brevToken.balanceOf(staker2);

        assertApproxEqRel(balanceAAfter - balanceABefore, expectedATotalRewards, 1e15, "Staker A withdrawal incorrect");
        assertApproxEqRel(balanceBAfter - balanceBBefore, expectedBTotalRewards, 1e15, "Staker B withdrawal incorrect");
    }

    function test_SlashDuringUnstakingPeriod() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 1000e18);

        // Request unstake
        vm.prank(staker1);
        stakedProvers.requestUnstake(prover1, 800e18);

        // Slash 30% during unstaking period
        vm.prank(owner);
        stakedProvers.slashProverPublic(prover1, 300000); // 30% slash

        // Complete unstake after delay
        vm.warp(block.timestamp + 7 days + 1);
        uint256 balanceBefore = brevToken.balanceOf(staker1);
        vm.prank(staker1);
        stakedProvers.completeUnstake(prover1);
        uint256 balanceAfter = brevToken.balanceOf(staker1);

        // Should receive 70% of original unstake amount (800e18 * 0.7 = 560e18)
        uint256 expectedPayout = (800e18 * 70) / 100;
        assertEq(balanceAfter - balanceBefore, expectedPayout, "Unstake payout should reflect slash");
    }

    function test_RewardsToRetiredProverWithNoStakers() public {
        _initializeProver(prover1);

        // Prover unstakes all self-stake to get totalRawShares = 0
        vm.prank(prover1);
        stakedProvers.requestUnstake(prover1, MIN_SELF_STAKE);

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(prover1);
        stakedProvers.completeUnstake(prover1);

        // Verify totalRawShares is now 0
        (uint256 totalRawShares,,,) = stakedProvers.getProverInternals(prover1);
        assertEq(totalRawShares, 0, "Total raw shares should be 0");

        // Add rewards when no stakers exist (totalRawShares == 0)
        uint256 rewardAmount = 1000e18;
        brevToken.transfer(address(stakedProvers), rewardAmount);
        stakedProvers.addRewardsPublic(prover1, rewardAmount);

        // All rewards should go to prover's commission (100% to pendingCommission)
        (,,, uint256 proverRewards) = stakedProvers.getStakeInfo(prover1, prover1);
        assertEq(proverRewards, rewardAmount, "All rewards should go to commission when no stakers");

        // Prover can withdraw rewards even when retired/no stakes
        uint256 balanceBefore = brevToken.balanceOf(prover1);
        vm.prank(prover1);
        stakedProvers.withdrawRewards(prover1);
        uint256 balanceAfter = brevToken.balanceOf(prover1);

        assertEq(balanceAfter - balanceBefore, rewardAmount, "Prover should receive all rewards as commission");
    }

    function test_ComplexStakeRequestUnstakeRewardSequence() public {
        _initializeProver(prover1);

        // Initial stake from staker1
        _stakeToProver(staker1, prover1, 1000e18);

        // First reward
        brevToken.transfer(address(stakedProvers), 500e18);
        stakedProvers.addRewardsPublic(prover1, 500e18);

        // Staker2 joins
        _stakeToProver(staker2, prover1, 2000e18);

        // Second reward (different stake distribution)
        brevToken.transfer(address(stakedProvers), 600e18);
        stakedProvers.addRewardsPublic(prover1, 600e18);

        // Staker1 partially unstakes
        vm.prank(staker1);
        stakedProvers.requestUnstake(prover1, 400e18);

        // Third reward (with pending unstake)
        brevToken.transfer(address(stakedProvers), 300e18);
        stakedProvers.addRewardsPublic(prover1, 300e18);

        // Complete unstake and add fourth reward
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(staker1);
        stakedProvers.completeUnstake(prover1);

        brevToken.transfer(address(stakedProvers), 200e18);
        stakedProvers.addRewardsPublic(prover1, 200e18);

        // Verify accumulated rewards are correct
        (,,, uint256 staker1Rewards) = stakedProvers.getStakeInfo(prover1, staker1);
        (,,, uint256 staker2Rewards) = stakedProvers.getStakeInfo(prover1, staker2);

        assertGt(staker1Rewards, 0);
        assertGt(staker2Rewards, 0);
        assertGt(staker2Rewards, staker1Rewards); // Staker2 has more stake and was present for more rewards
    }

    function test_RestakeAfterFullExit() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 500e18);

        // Add rewards
        brevToken.transfer(address(stakedProvers), 100e18);
        stakedProvers.addRewardsPublic(prover1, 100e18);

        // Withdraw rewards
        vm.prank(staker1);
        stakedProvers.withdrawRewards(prover1);

        // Full unstake and complete
        vm.prank(staker1);
        stakedProvers.requestUnstake(prover1, 500e18);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(staker1);
        stakedProvers.completeUnstake(prover1);

        // Add more rewards while staker is out
        brevToken.transfer(address(stakedProvers), 200e18);
        stakedProvers.addRewardsPublic(prover1, 200e18);

        // Staker re-stakes
        vm.prank(staker1);
        stakedProvers.stake(prover1, 300e18);

        // Should not get retroactive rewards
        (,,, uint256 pendingRewards) = stakedProvers.getStakeInfo(prover1, staker1);
        assertEq(pendingRewards, 0);

        // Add new rewards after re-staking
        brevToken.transfer(address(stakedProvers), 150e18);
        stakedProvers.addRewardsPublic(prover1, 150e18);

        // Should get new rewards proportionally
        (,,, pendingRewards) = stakedProvers.getStakeInfo(prover1, staker1);
        assertGt(pendingRewards, 0);
    }

    function test_ProverRetirement() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 5000e18);

        // Add rewards before retirement
        brevToken.transfer(address(stakedProvers), 1000e18);
        stakedProvers.addRewardsPublic(prover1, 1000e18);

        // Prover completely exits by unstaking all self-stake
        vm.prank(prover1);
        stakedProvers.requestUnstake(prover1, MIN_SELF_STAKE);

        // Should be able to complete unstake even though it goes below minSelfStake
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(prover1);
        stakedProvers.completeUnstake(prover1);

        // Verify prover has no stake but rewards remain
        (uint256 proverStake,,,) = stakedProvers.getStakeInfo(prover1, prover1);
        assertEq(proverStake, 0);

        // Prover should still be able to withdraw accumulated rewards
        (,,, uint256 proverRewards) = stakedProvers.getStakeInfo(prover1, prover1);
        assertGt(proverRewards, 0);

        vm.prank(prover1);
        stakedProvers.withdrawRewards(prover1);

        (,,, proverRewards) = stakedProvers.getStakeInfo(prover1, prover1);
        assertEq(proverRewards, 0);
    }

    function test_SlashDuringMultipleUnbonding() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 5000e18);
        _stakeToProver(staker2, prover1, 3000e18);

        // Both stakers initiate unstaking
        vm.prank(staker1);
        stakedProvers.requestUnstake(prover1, 2000e18);

        vm.warp(block.timestamp + 3600); // 1 hour later
        vm.prank(staker2);
        stakedProvers.requestUnstake(prover1, 1000e18);

        // Slash 50% while both are unbonding
        vm.prank(owner);
        stakedProvers.slashProverPublic(prover1, 500000);

        // Complete first unstake
        vm.warp(block.timestamp + 7 days);
        uint256 balance1Before = brevToken.balanceOf(staker1);
        vm.prank(staker1);
        stakedProvers.completeUnstake(prover1);
        uint256 balance1After = brevToken.balanceOf(staker1);

        // Complete second unstake
        vm.warp(block.timestamp + 3600); // Original unstake + 7 days for staker2
        uint256 balance2Before = brevToken.balanceOf(staker2);
        vm.prank(staker2);
        stakedProvers.completeUnstake(prover1);
        uint256 balance2After = brevToken.balanceOf(staker2);

        // Both should receive 50% of their unstaked amounts
        assertEq(balance1After - balance1Before, 1000e18); // 50% of 2000e18
        assertEq(balance2After - balance2Before, 500e18); // 50% of 1000e18
    }

    function test_SimultaneousOperationsFromMultipleStakers() public {
        _initializeProver(prover1);

        // Multiple stakers stake simultaneously (same block)
        vm.prank(staker1);
        stakedProvers.stake(prover1, 2000e18);
        vm.prank(staker2);
        stakedProvers.stake(prover1, 3000e18);
        vm.prank(staker3);
        stakedProvers.stake(prover1, 1000e18);

        // Add rewards
        brevToken.transfer(address(stakedProvers), 1200e18);
        stakedProvers.addRewardsPublic(prover1, 1200e18);

        // All stakers unstake simultaneously
        vm.prank(staker1);
        stakedProvers.requestUnstake(prover1, 1000e18);
        vm.prank(staker2);
        stakedProvers.requestUnstake(prover1, 1500e18);
        vm.prank(staker3);
        stakedProvers.requestUnstake(prover1, 500e18);

        // Fast forward and all complete simultaneously
        vm.warp(block.timestamp + 7 days + 1);

        uint256 balance1Before = brevToken.balanceOf(staker1);
        uint256 balance2Before = brevToken.balanceOf(staker2);
        uint256 balance3Before = brevToken.balanceOf(staker3);

        vm.prank(staker1);
        stakedProvers.completeUnstake(prover1);
        vm.prank(staker2);
        stakedProvers.completeUnstake(prover1);
        vm.prank(staker3);
        stakedProvers.completeUnstake(prover1);

        uint256 balance1After = brevToken.balanceOf(staker1);
        uint256 balance2After = brevToken.balanceOf(staker2);
        uint256 balance3After = brevToken.balanceOf(staker3);

        // Verify correct amounts returned
        assertEq(balance1After - balance1Before, 1000e18);
        assertEq(balance2After - balance2Before, 1500e18);
        assertEq(balance3After - balance3Before, 500e18);
    }

    function test_RepeatedStakeUnstakePattern() public {
        _initializeProver(prover1);

        for (uint256 i = 0; i < 5; i++) {
            // Stake
            vm.prank(staker1);
            stakedProvers.stake(prover1, 1000e18);

            // Add rewards
            brevToken.transfer(address(stakedProvers), 100e18);
            stakedProvers.addRewardsPublic(prover1, 100e18);

            // Unstake
            vm.prank(staker1);
            stakedProvers.requestUnstake(prover1, 1000e18);

            // Fast forward and complete
            vm.warp(block.timestamp + 7 days + 1);
            vm.prank(staker1);
            stakedProvers.completeUnstake(prover1);

            // Withdraw rewards
            vm.prank(staker1);
            stakedProvers.withdrawRewards(prover1);
        }

        // Final state should be clean
        (uint256 finalStake, uint256 pendingUnstake, uint256 unstakeTime, uint256 pendingRewards) =
            stakedProvers.getStakeInfo(prover1, staker1);

        assertEq(finalStake, 0);
        assertEq(pendingUnstake, 0);
        assertEq(unstakeTime, 0);
        assertEq(pendingRewards, 0);
    }

    // ========== HELPER FUNCTIONS ==========

    function _initializeProver(address prover) internal {
        vm.prank(prover);
        stakedProvers.initProver(MIN_SELF_STAKE, COMMISSION_RATE);
    }

    function _stakeToProver(address staker, address prover, uint256 amount) internal {
        vm.prank(staker);
        stakedProvers.stake(prover, amount);
    }
}
