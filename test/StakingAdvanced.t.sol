// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {TestProverStaking} from "./TestProverStaking.sol";
import {ProverStaking} from "../src/ProverStaking.sol";
import {ProverRewards} from "../src/ProverRewards.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TestErrors} from "./utils/TestErrors.sol";

/**
 * @title Staking Advanced Test Suite
 * @notice Advanced tests for complex scenarios and edge cases
 * @dev Tests multi-step operations, boundary conditions, and complex interactions
 */
contract StakingAdvancedTest is Test {
    TestProverStaking public proverStaking;
    ProverRewards public proverRewards;
    MockERC20 public brevToken;

    address public owner = makeAddr("owner");
    address public prover1 = makeAddr("prover1");
    address public prover2 = makeAddr("prover2");
    address public staker1 = makeAddr("staker1");
    address public staker2 = makeAddr("staker2");
    address public staker3 = makeAddr("staker3");
    address public user = makeAddr("user");

    uint256 public constant INITIAL_SUPPLY = 1_000_000e18;
    uint256 public constant MIN_SELF_STAKE = 10_000e18;
    uint256 public constant GLOBAL_MIN_SELF_STAKE = 50e18;
    uint64 public constant COMMISSION_RATE = 1000; // 10%

    function setUp() public {
        // Deploy contracts
        brevToken = new MockERC20("Protocol Token", "TOKEN");
        brevToken = brevToken; // Same token for rewards

        // Deploy with direct deployment pattern (simpler for tests)
        vm.startPrank(owner);
        proverStaking = new TestProverStaking(address(brevToken), GLOBAL_MIN_SELF_STAKE);

        // Deploy ProverRewards
        proverRewards = new ProverRewards(address(proverStaking), address(brevToken));

        // Set ProverRewards in ProverStaking
        proverStaking.setProverRewardsContract(address(proverRewards));

        // Grant slasher role to both this test contract and owner for testing
        proverStaking.grantRole(proverStaking.SLASHER_ROLE(), address(this));
        proverStaking.grantRole(proverStaking.SLASHER_ROLE(), owner);
        vm.stopPrank();

        // Mint tokens (same token used for staking and rewards)
        brevToken.mint(prover1, INITIAL_SUPPLY);
        brevToken.mint(prover2, INITIAL_SUPPLY);
        brevToken.mint(staker1, INITIAL_SUPPLY);
        brevToken.mint(staker2, INITIAL_SUPPLY);
        brevToken.mint(staker3, INITIAL_SUPPLY);
        brevToken.mint(address(this), INITIAL_SUPPLY); // For reward distribution

        // Approve spending
        vm.prank(prover1);
        brevToken.approve(address(proverStaking), INITIAL_SUPPLY);
        vm.prank(prover2);
        brevToken.approve(address(proverStaking), INITIAL_SUPPLY);
        vm.prank(staker1);
        brevToken.approve(address(proverStaking), INITIAL_SUPPLY);
        vm.prank(staker2);
        brevToken.approve(address(proverStaking), INITIAL_SUPPLY);
        vm.prank(staker3);
        brevToken.approve(address(proverStaking), INITIAL_SUPPLY);
        brevToken.approve(address(proverStaking), INITIAL_SUPPLY);
        brevToken.approve(address(proverRewards), INITIAL_SUPPLY);
    }

    // ========== COMMISSION EDGE CASES ==========

    function test_ZeroCommissionRateRewards() public {
        // Initialize prover with 0% commission
        vm.prank(prover1);
        proverStaking.initProver(MIN_SELF_STAKE, 0);

        _stakeToProver(staker1, prover1, 5000e18);

        uint256 rewardAmount = 1000e18;
        _addRewards(prover1, rewardAmount);

        // With 0% commission, all rewards go to stake proportionally
        uint256 totalStake = MIN_SELF_STAKE + 5000e18; // 15000e18

        (,,, uint256 proverRewardsAmount) = proverStaking.getStakeInfo(prover1, prover1);
        (,,, uint256 stakerRewards) = proverStaking.getStakeInfo(prover1, staker1);

        uint256 expectedProverRewards = (rewardAmount * MIN_SELF_STAKE) / totalStake; // 666.67e18
        uint256 expectedStakerRewards = (rewardAmount * 5000e18) / totalStake; // 333.33e18

        assertApproxEqRel(proverRewardsAmount, expectedProverRewards, 1e15);
        assertApproxEqRel(stakerRewards, expectedStakerRewards, 1e15);
    }

    function test_MaxCommissionRateRewards() public {
        // Initialize prover with 100% commission
        vm.prank(prover1);
        proverStaking.initProver(MIN_SELF_STAKE, 10000);

        _stakeToProver(staker1, prover1, 5000e18);

        uint256 rewardAmount = 1000e18;
        _addRewards(prover1, rewardAmount);

        // With 100% commission, all rewards go to prover
        (,,, uint256 proverRewardsAmount) = proverStaking.getStakeInfo(prover1, prover1);
        (,,, uint256 stakerRewards) = proverStaking.getStakeInfo(prover1, staker1);

        assertEq(proverRewardsAmount, rewardAmount);
        assertEq(stakerRewards, 0);
    }

    function test_RewardsDistributionWithOnlyProverStake() public {
        _initializeProver(prover1);

        // No external stakers, only prover's self-stake
        uint256 rewardAmount = 1000e18;
        _addRewards(prover1, rewardAmount);

        // All rewards should go to prover (as commission since no other stakers)
        (,,, uint256 proverRewardsAmount) = proverStaking.getStakeInfo(prover1, prover1);
        assertEq(proverRewardsAmount, rewardAmount);
    }

    function test_CommissionWithoutSelfStake() public {
        // Test commission calculation when prover has minimal self-stake
        vm.prank(prover1);
        brevToken.approve(address(proverStaking), MIN_SELF_STAKE);
        vm.prank(prover1);
        proverStaking.initProver(MIN_SELF_STAKE, 2000); // 20% commission

        // Add delegated stake
        vm.prank(staker1);
        brevToken.approve(address(proverStaking), 1000e18);
        vm.prank(staker1);
        proverStaking.stake(prover1, 1000e18);

        // Add rewards
        uint256 rewardAmount = 100e18;
        _addRewards(prover1, rewardAmount);

        // Check commission is correctly calculated
        uint256 expectedCommission = (rewardAmount * 2000) / 10000; // 20%
        (, uint256 actualCommission,) = proverRewards.getProverRewardInfo(prover1);
        assertEq(actualCommission, expectedCommission, "Commission should be 20% of rewards");
    }

    // ========== EXTREME SCENARIOS ==========

    function test_MassiveStakeAndSlash() public {
        _initializeProver(prover1);

        // Stake enormous amount
        uint256 massiveStake = 100_000_000e18;
        brevToken.mint(staker1, massiveStake);
        vm.prank(staker1);
        brevToken.approve(address(proverStaking), massiveStake);
        vm.prank(staker1);
        proverStaking.stake(prover1, massiveStake);

        // Slash maximum allowed (50%)
        vm.prank(owner);
        proverStaking.slash(prover1, 500000); // 50%

        (,, uint256 totalStake,,) = proverStaking.getProverInfo(prover1);
        uint256 expectedRemaining = (MIN_SELF_STAKE + massiveStake) / 2; // 50%
        assertApproxEqRel(totalStake, expectedRemaining, 1e15);
    }

    function test_ExtremeSlashingScenario() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 4000e18);

        // Multiple maximum slashes to demonstrate auto-deactivation at 20% threshold
        proverStaking.slash(prover1, 500000); // 50% slash - leaves 50%

        // Verify still active after first slash
        (ProverStaking.ProverState state1,,,,) = proverStaking.getProverInfo(prover1);
        assertEq(uint256(state1), uint256(ProverStaking.ProverState.Active));

        proverStaking.slash(prover1, 500000); // 50% of remaining - leaves 25% total

        // Verify still active after second slash (still above 20% threshold)
        (ProverStaking.ProverState state2,,,,) = proverStaking.getProverInfo(prover1);
        assertEq(uint256(state2), uint256(ProverStaking.ProverState.Active));

        proverStaking.slash(prover1, 500000); // 50% of remaining - leaves 12.5% total

        // NOW should be auto-deactivated (below 20% threshold)
        (ProverStaking.ProverState finalState,,,,) = proverStaking.getProverInfo(prover1);
        assertEq(uint256(finalState), uint256(ProverStaking.ProverState.Deactivated));

        (,, uint256 finalStake,,) = proverStaking.getProverInfo(prover1);
        uint256 originalStake = MIN_SELF_STAKE + 4000e18; // 14000e18
        // After 3 slashes of 50% each: 14000 * (0.5)^3 = 14000 * 0.125 = 1750e18
        uint256 expectedFinalStake = originalStake / 8; // 12.5% remaining

        assertEq(finalStake, expectedFinalStake);

        // Staker should still be able to unstake remaining amount
        // After 3 slashes of 50% each, the staker's stake is reduced by the same factor
        // Original staker stake: 4000e18, after slashes: 4000e18 * (0.5)^3 = 4000e18 * 0.125 = 500e18
        uint256 stakerRemainingStake = 4000e18 / 8; // 12.5% remaining

        vm.prank(staker1);
        proverStaking.requestUnstake(prover1, stakerRemainingStake);

        vm.warp(block.timestamp + 7 days + 1);
        uint256 balanceBefore = brevToken.balanceOf(staker1);
        vm.prank(staker1);
        proverStaking.completeUnstake(prover1);
        uint256 balanceAfter = brevToken.balanceOf(staker1);

        assertEq(balanceAfter - balanceBefore, stakerRemainingStake);
    }

    // ========== COMPLEX INTERACTION SEQUENCES ==========

    function test_MultipleRewardRounds() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 400e18);
        _stakeToProver(staker2, prover1, 500e18);

        // First reward round
        _addRewards(prover1, 200e18);

        // Second reward round BEFORE withdrawals
        _addRewards(prover1, 300e18);

        // Total stake: 10000e18 + 400e18 + 500e18 = 10900e18
        // Total rewards: 500e18, commission: 50e18, stakers: 450e18
        // Staker1 share: 400/10900 * 450e18 ≈ 16.51e18
        // Staker2 share: 500/10900 * 450e18 ≈ 20.64e18

        (,,, uint256 pendingStaker1) = proverStaking.getStakeInfo(prover1, staker1);
        (,,, uint256 pendingStaker2) = proverStaking.getStakeInfo(prover1, staker2);

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
        _addRewards(prover1, firstReward);

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
        proverStaking.requestUnstake(prover1, 60e18); // A reduces from 100 to 40

        // Second reward round (with gap in time and different stake distribution)
        vm.warp(block.timestamp + 1 days);
        uint256 secondReward = 500e18;
        _addRewards(prover1, secondReward);

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
        (,,, uint256 actualA) = proverStaking.getStakeInfo(prover1, staker1);
        (,,, uint256 actualB) = proverStaking.getStakeInfo(prover1, staker2);

        uint256 expectedATotalRewards = expectedA1 + expectedA2;
        uint256 expectedBTotalRewards = expectedB1 + expectedB2;

        assertApproxEqRel(actualA, expectedATotalRewards, 1e15, "Staker A rewards incorrect");
        assertApproxEqRel(actualB, expectedBTotalRewards, 1e15, "Staker B rewards incorrect");

        // Withdraw rewards and verify exact amounts
        uint256 balanceABefore = brevToken.balanceOf(staker1);
        uint256 balanceBBefore = brevToken.balanceOf(staker2);

        vm.prank(staker1);
        proverRewards.withdrawRewards(prover1);
        vm.prank(staker2);
        proverRewards.withdrawRewards(prover1);

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
        proverStaking.requestUnstake(prover1, 800e18);

        // Slash 30% during unstaking period
        vm.prank(owner);
        proverStaking.slash(prover1, 300000); // 30% slash

        // Complete unstake after delay
        vm.warp(block.timestamp + 7 days + 1);
        uint256 balanceBefore = brevToken.balanceOf(staker1);
        vm.prank(staker1);
        proverStaking.completeUnstake(prover1);
        uint256 balanceAfter = brevToken.balanceOf(staker1);

        // Should receive 70% of original unstake amount (800e18 * 0.7 = 560e18)
        uint256 expectedPayout = (800e18 * 70) / 100;
        assertEq(balanceAfter - balanceBefore, expectedPayout, "Unstake payout should reflect slash");
    }

    function test_RewardsToRetiredProverWithNoStakers() public {
        _initializeProver(prover1);

        // Prover unstakes all self-stake to get totalRawShares = 0
        vm.prank(prover1);
        proverStaking.requestUnstake(prover1, MIN_SELF_STAKE);

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(prover1);
        proverStaking.completeUnstake(prover1);

        // Verify totalRawShares is now 0
        (uint256 totalRawShares,,) = proverStaking.getProverInternals(prover1);
        assertEq(totalRawShares, 0, "Total raw shares should be 0");

        // Add rewards when no stakers exist (totalRawShares == 0)
        uint256 rewardAmount = 1000e18;
        _addRewards(prover1, rewardAmount);

        // All rewards should go to prover's commission (100% to pendingCommission)
        (,,, uint256 proverRewardsAmount) = proverStaking.getStakeInfo(prover1, prover1);
        assertEq(proverRewardsAmount, rewardAmount, "All rewards should go to commission when no stakers");

        // Prover can withdraw rewards even when retired/no stakes
        uint256 balanceBefore = brevToken.balanceOf(prover1);
        vm.prank(prover1);
        proverRewards.withdrawRewards(prover1);
        uint256 balanceAfter = brevToken.balanceOf(prover1);

        assertEq(balanceAfter - balanceBefore, rewardAmount, "Prover should receive all rewards as commission");
    }

    function test_ComplexStakeRequestUnstakeRewardSequence() public {
        _initializeProver(prover1);

        // Initial stake from staker1
        _stakeToProver(staker1, prover1, 1000e18);

        // First reward
        _addRewards(prover1, 500e18);

        // Staker2 joins
        _stakeToProver(staker2, prover1, 2000e18);

        // Second reward (different stake distribution)
        _addRewards(prover1, 600e18);

        // Staker1 partially unstakes
        vm.prank(staker1);
        proverStaking.requestUnstake(prover1, 400e18);

        // Third reward (with pending unstake)
        _addRewards(prover1, 300e18);

        // Complete unstake and add fourth reward
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(staker1);
        proverStaking.completeUnstake(prover1);

        _addRewards(prover1, 200e18);

        // Verify accumulated rewards are correct
        (,,, uint256 staker1Rewards) = proverStaking.getStakeInfo(prover1, staker1);
        (,,, uint256 staker2Rewards) = proverStaking.getStakeInfo(prover1, staker2);

        assertGt(staker1Rewards, 0);
        assertGt(staker2Rewards, 0);
        assertGt(staker2Rewards, staker1Rewards); // Staker2 has more stake and was present for more rewards
    }

    function test_RestakeAfterFullExit() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 500e18);

        // Add rewards
        _addRewards(prover1, 100e18);

        // Withdraw rewards
        vm.prank(staker1);
        proverRewards.withdrawRewards(prover1);

        // Full unstake and complete
        vm.prank(staker1);
        proverStaking.requestUnstake(prover1, 500e18);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(staker1);
        proverStaking.completeUnstake(prover1);

        // Add more rewards while staker is out
        _addRewards(prover1, 200e18);

        // Staker re-stakes
        vm.prank(staker1);
        proverStaking.stake(prover1, 300e18);

        // Should not get retroactive rewards
        (,,, uint256 pendingRewards) = proverStaking.getStakeInfo(prover1, staker1);
        assertEq(pendingRewards, 0);

        // Add new rewards after re-staking
        _addRewards(prover1, 150e18);

        // Should get new rewards proportionally
        (,,, pendingRewards) = proverStaking.getStakeInfo(prover1, staker1);
        assertGt(pendingRewards, 0);
    }

    function test_ProverRetirement() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 5000e18);

        // Add rewards before retirement
        _addRewards(prover1, 1000e18);

        // Prover completely exits by unstaking all self-stake
        vm.prank(prover1);
        proverStaking.requestUnstake(prover1, MIN_SELF_STAKE);

        // Should be able to complete unstake even though it goes below minSelfStake
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(prover1);
        proverStaking.completeUnstake(prover1);

        // Verify prover has no stake but rewards remain
        (uint256 proverStake,,,) = proverStaking.getStakeInfo(prover1, prover1);
        assertEq(proverStake, 0);

        // Prover should still be able to withdraw accumulated rewards
        (,,, uint256 proverRewardsAmount) = proverStaking.getStakeInfo(prover1, prover1);
        assertGt(proverRewardsAmount, 0);

        vm.prank(prover1);
        proverRewards.withdrawRewards(prover1);

        (,,, uint256 proverRewardsAfter) = proverStaking.getStakeInfo(prover1, prover1);
        assertEq(proverRewardsAfter, 0);
    }

    function test_SlashDuringMultipleUnbonding() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 5000e18);
        _stakeToProver(staker2, prover1, 3000e18);

        // Both stakers initiate unstaking
        vm.prank(staker1);
        proverStaking.requestUnstake(prover1, 2000e18);

        vm.warp(block.timestamp + 3600); // 1 hour later
        vm.prank(staker2);
        proverStaking.requestUnstake(prover1, 1000e18);

        // Slash 50% while both are unbonding
        vm.prank(owner);
        proverStaking.slash(prover1, 500000);

        // Complete first unstake
        vm.warp(block.timestamp + 7 days);
        uint256 balance1Before = brevToken.balanceOf(staker1);
        vm.prank(staker1);
        proverStaking.completeUnstake(prover1);
        uint256 balance1After = brevToken.balanceOf(staker1);

        // Complete second unstake
        vm.warp(block.timestamp + 3600); // Original unstake + 7 days for staker2
        uint256 balance2Before = brevToken.balanceOf(staker2);
        vm.prank(staker2);
        proverStaking.completeUnstake(prover1);
        uint256 balance2After = brevToken.balanceOf(staker2);

        // Both should receive 50% of their unstaked amounts
        assertEq(balance1After - balance1Before, 1000e18); // 50% of 2000e18
        assertEq(balance2After - balance2Before, 500e18); // 50% of 1000e18
    }

    function test_SimultaneousOperationsFromMultipleStakers() public {
        _initializeProver(prover1);

        // Multiple stakers stake simultaneously (same block)
        vm.prank(staker1);
        proverStaking.stake(prover1, 2000e18);
        vm.prank(staker2);
        proverStaking.stake(prover1, 3000e18);
        vm.prank(staker3);
        proverStaking.stake(prover1, 1000e18);

        // Add rewards
        _addRewards(prover1, 1200e18);

        // All stakers unstake simultaneously
        vm.prank(staker1);
        proverStaking.requestUnstake(prover1, 1000e18);
        vm.prank(staker2);
        proverStaking.requestUnstake(prover1, 1500e18);
        vm.prank(staker3);
        proverStaking.requestUnstake(prover1, 500e18);

        // Fast forward and all complete simultaneously
        vm.warp(block.timestamp + 7 days + 1);

        uint256 balance1Before = brevToken.balanceOf(staker1);
        uint256 balance2Before = brevToken.balanceOf(staker2);
        uint256 balance3Before = brevToken.balanceOf(staker3);

        vm.prank(staker1);
        proverStaking.completeUnstake(prover1);
        vm.prank(staker2);
        proverStaking.completeUnstake(prover1);
        vm.prank(staker3);
        proverStaking.completeUnstake(prover1);

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
            proverStaking.stake(prover1, 1000e18);

            // Add rewards
            _addRewards(prover1, 100e18);

            // Unstake
            vm.prank(staker1);
            proverStaking.requestUnstake(prover1, 1000e18);

            // Fast forward and complete
            vm.warp(block.timestamp + 7 days + 1);
            vm.prank(staker1);
            proverStaking.completeUnstake(prover1);

            // Withdraw rewards
            vm.prank(staker1);
            proverRewards.withdrawRewards(prover1);
        }

        // Final state should be clean
        (uint256 finalStake, uint256 pendingUnstake, uint256 unstakeTime, uint256 pendingRewards) =
            proverStaking.getStakeInfo(prover1, staker1);

        assertEq(finalStake, 0);
        assertEq(pendingUnstake, 0);
        assertEq(unstakeTime, 0);
        assertEq(pendingRewards, 0);
    }

    // ========== HELPER FUNCTIONS ==========

    // ========== ADVANCED PROVER MANAGEMENT ==========

    function test_SelfRetireProver() public {
        // Initialize prover with minimal stake
        vm.prank(prover1);
        brevToken.approve(address(proverStaking), GLOBAL_MIN_SELF_STAKE);
        vm.prank(prover1);
        proverStaking.initProver(GLOBAL_MIN_SELF_STAKE, COMMISSION_RATE);

        // Stake additional funds from external staker
        vm.prank(staker1);
        brevToken.approve(address(proverStaking), 100e18);
        vm.prank(staker1);
        proverStaking.stake(prover1, 100e18);

        // Cannot retire with active stakes
        vm.expectRevert(TestErrors.ActiveStakesRemain.selector);
        vm.prank(prover1);
        proverStaking.retireProver();

        // Staker unstakes
        vm.prank(staker1);
        proverStaking.requestUnstake(prover1, 100e18);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(staker1);
        proverStaking.completeUnstake(prover1);

        // Prover unstakes own stake
        vm.prank(prover1);
        proverStaking.requestUnstake(prover1, GLOBAL_MIN_SELF_STAKE);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(prover1);
        proverStaking.completeUnstake(prover1);

        // Now prover can retire
        vm.expectEmit(true, false, false, false);
        emit ProverRetired(prover1);
        vm.prank(prover1);
        proverStaking.retireProver();

        // Verify prover is retired
        (ProverStaking.ProverState state,,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(state == ProverStaking.ProverState.Retired, "Prover should be retired");
    }

    function test_OnlyOwnerCanAdminRetire() public {
        _initializeProver(prover1);

        vm.expectRevert();
        vm.prank(user);
        proverStaking.retireProver(prover1);
    }

    function test_CannotRetireInactiveProver() public {
        _initializeProver(prover1);

        // Unstake completely
        vm.prank(prover1);
        proverStaking.requestUnstake(prover1, MIN_SELF_STAKE);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(prover1);
        proverStaking.completeUnstake(prover1);

        // Retire once
        vm.prank(owner);
        proverStaking.retireProver(prover1);

        // Try to retire again
        vm.expectRevert(TestErrors.InvalidProverState.selector);
        vm.prank(owner);
        proverStaking.retireProver(prover1);
    }

    function test_DeactivatedProverCanStillWithdrawAndComplete() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 100e18);

        // Add rewards
        _addRewards(prover1, 50e18);

        // Deactivate prover
        vm.prank(owner);
        proverStaking.deactivateProver(prover1);

        // Prover can still withdraw rewards
        vm.prank(prover1);
        proverRewards.withdrawRewards(prover1);

        // Staker can request unstake after deactivation
        vm.prank(staker1);
        proverStaking.requestUnstake(prover1, 100e18);

        // Complete unstake after delay
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(staker1);
        proverStaking.completeUnstake(prover1);

        // Verify unstake completed
        (uint256 stakerStake,,,) = proverStaking.getStakeInfo(prover1, staker1);
        assertEq(stakerStake, 0, "Staker should have no remaining stake");
    }

    // ========== HELPER FUNCTIONS ==========

    function _initializeProver(address prover) internal {
        vm.prank(prover);
        proverStaking.initProver(MIN_SELF_STAKE, COMMISSION_RATE);
    }

    function _stakeToProver(address staker, address prover, uint256 amount) internal {
        vm.prank(staker);
        proverStaking.stake(prover, amount);
    }

    function _addRewards(address prover, uint256 amount) internal {
        proverRewards.addRewards(prover, amount);
    }

    function test_UnretirePreservesProverConfiguration() public {
        // Initialize prover with specific configuration
        uint256 customMinSelfStake = 2000e18;
        uint64 customCommissionRate = 500; // 5%

        vm.prank(prover1);
        brevToken.approve(address(proverStaking), customMinSelfStake);
        vm.prank(prover1);
        proverStaking.initProver(customMinSelfStake, customCommissionRate);

        // Retire prover completely
        vm.prank(prover1);
        proverStaking.requestUnstake(prover1, customMinSelfStake);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(prover1);
        proverStaking.completeUnstake(prover1);
        vm.prank(owner);
        proverStaking.retireProver(prover1);

        // Self-stake while retired with higher amount
        uint256 unretireStake = 3000e18;
        vm.prank(prover1);
        brevToken.approve(address(proverStaking), unretireStake);
        vm.prank(prover1);
        proverStaking.stake(prover1, unretireStake);

        // Unretire (state change only)
        vm.prank(prover1);
        proverStaking.unretireProver();

        // Verify configuration is preserved
        (, uint256 minSelfStake,,,) = proverStaking.getProverInfo(prover1);
        (uint64 commissionRate,,) = proverRewards.getProverRewardInfo(prover1);
        assertEq(minSelfStake, customMinSelfStake, "Min self-stake should be preserved");
        assertEq(commissionRate, customCommissionRate, "Commission rate should be preserved");

        // Verify new stake amount
        (uint256 amount,,,) = proverStaking.getStakeInfo(prover1, prover1);
        assertEq(amount, unretireStake, "Should have new stake amount");
    }

    function test_UnretireWithSlashingHistory() public {
        // Initialize prover and add delegations
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 1000e18);

        // Slash the prover by 50% (owner already has SLASHER_ROLE from setUp)
        vm.prank(owner);
        proverStaking.slash(prover1, 500000); // 50%

        // Verify slash took effect
        (uint256 totalStaked1,,,) = proverStaking.getStakeInfo(prover1, prover1);
        assertEq(totalStaked1, MIN_SELF_STAKE / 2, "Self-stake should be halved after slash");

        // Unstake completely and retire
        vm.prank(prover1);
        proverStaking.requestUnstake(prover1, totalStaked1);
        vm.prank(staker1);
        proverStaking.requestUnstake(prover1, 500e18); // Half of original 1000e18

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(prover1);
        proverStaking.completeUnstake(prover1);
        vm.prank(staker1);
        proverStaking.completeUnstake(prover1);

        vm.prank(owner);
        proverStaking.retireProver(prover1);

        // Self-stake while retired - slashing history should not affect new stakes
        vm.prank(prover1);
        brevToken.approve(address(proverStaking), MIN_SELF_STAKE);
        vm.prank(prover1);
        proverStaking.stake(prover1, MIN_SELF_STAKE);

        // Unretire after self-staking
        vm.prank(prover1);
        proverStaking.unretireProver();

        // Verify new stake is worth more than original due to scale reset (shares bought at discount)
        (uint256 totalStaked2,,,) = proverStaking.getStakeInfo(prover1, prover1);
        assertTrue(totalStaked2 > MIN_SELF_STAKE, "Stake should be worth more after scale reset");

        // Verify prover scale is reset to 1.0
        (, uint256 scale,) = proverStaking.getProverInternals(prover1);
        assertEq(scale, 1e18, "Scale should be reset to 1.0 for new prover session");
    }

    function test_UpdateMinSelfStakeIncrease() public {
        // Initialize prover
        _initializeProver(prover1);

        // Test immediate increase
        uint256 newMinStake = 15_000e18; // Increase from 10_000e18
        vm.prank(prover1);
        proverStaking.updateMinSelfStake(newMinStake);

        // Should be applied immediately (no pending update created for increases)
        (, uint256 currentMin,,,) = proverStaking.getProverInfo(prover1);
        assertEq(currentMin, newMinStake, "Increase should be applied immediately");

        (bool hasPending,,,) = proverStaking.getPendingMinSelfStakeUpdate(prover1);
        assertFalse(hasPending, "Should have no pending update after immediate increase");
    }

    function test_UpdateMinSelfStakeDecreaseRetired() public {
        // Initialize prover and retire
        _initializeProver(prover1);

        // Prover unstakes to retire
        vm.prank(prover1);
        proverStaking.requestUnstake(prover1, MIN_SELF_STAKE);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(prover1);
        proverStaking.completeUnstake(prover1);

        vm.prank(prover1);
        proverStaking.retireProver();

        // Test immediate decrease for retired prover
        uint256 newMinStake = 5_000e18; // Decrease from 10_000e18
        vm.prank(prover1);
        proverStaking.updateMinSelfStake(newMinStake);

        // Should be applied immediately for retired prover
        (, uint256 currentMin,,,) = proverStaking.getProverInfo(prover1);
        assertEq(currentMin, newMinStake, "Decrease should be applied immediately for retired prover");

        // Should have no pending update
        (bool hasPending,,,) = proverStaking.getPendingMinSelfStakeUpdate(prover1);
        assertFalse(hasPending, "Should have no pending update after immediate decrease for retired prover");
    }

    function test_UpdateMinSelfStakeDecreaseActiveDelayed() public {
        // Initialize prover
        _initializeProver(prover1);

        // Test delayed decrease for active prover
        uint256 newMinStake = 5_000e18; // Decrease from 10_000e18
        vm.prank(prover1);
        proverStaking.updateMinSelfStake(newMinStake);

        // Should not be applied immediately
        (, uint256 currentMin,,,) = proverStaking.getProverInfo(prover1);
        assertEq(currentMin, MIN_SELF_STAKE, "Decrease should not be applied immediately for active prover");

        // Should have pending update
        (bool hasPending, uint256 pendingAmount, uint256 updateTime,) =
            proverStaking.getPendingMinSelfStakeUpdate(prover1);
        assertTrue(hasPending, "Should have pending update for delayed decrease");
        assertEq(pendingAmount, newMinStake, "Pending amount should match requested amount");
        assertEq(updateTime, block.timestamp + 7 days, "Update time should be 7 days from now");

        // Complete the update after delay
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(prover1);
        proverStaking.completeMinSelfStakeUpdate();

        // Should be applied now
        (, currentMin,,,) = proverStaking.getProverInfo(prover1);
        assertEq(currentMin, newMinStake, "Decrease should be applied after delay");

        // Should have no pending update
        (hasPending,,,) = proverStaking.getPendingMinSelfStakeUpdate(prover1);
        assertFalse(hasPending, "Should have no pending update after completion");
    }

    function test_UpdateMinSelfStakeDecreaseDeactivatedDelayed() public {
        // Initialize prover and deactivate
        _initializeProver(prover1);

        vm.prank(owner);
        proverStaking.deactivateProver(prover1);

        // Test delayed decrease for deactivated prover
        uint256 newMinStake = 5_000e18; // Decrease from 10_000e18
        vm.prank(prover1);
        proverStaking.updateMinSelfStake(newMinStake);

        // Should not be applied immediately
        (, uint256 currentMin,,,) = proverStaking.getProverInfo(prover1);
        assertEq(currentMin, MIN_SELF_STAKE, "Decrease should not be applied immediately for deactivated prover");

        // Should have pending update
        (bool hasPending, uint256 pendingAmount, uint256 updateTime,) =
            proverStaking.getPendingMinSelfStakeUpdate(prover1);
        assertTrue(hasPending, "Should have pending update for delayed decrease");
        assertEq(pendingAmount, newMinStake, "Pending amount should match requested amount");
        assertEq(updateTime, block.timestamp + 7 days, "Update time should be 7 days from now");
    }

    function test_CannotUpdateMinSelfStakeBelowGlobal() public {
        // Set global min to 75 ether
        vm.prank(owner);
        proverStaking.setGlobalMinSelfStake(75 ether);

        // Initialize prover
        brevToken.mint(prover1, 100 ether);
        vm.prank(prover1);
        brevToken.approve(address(proverStaking), 100 ether);
        vm.prank(prover1);
        proverStaking.initProver(100 ether, COMMISSION_RATE);

        // Try to update below global minimum
        vm.prank(prover1);
        vm.expectRevert(TestErrors.GlobalMinSelfStakeNotMet.selector);
        proverStaking.updateMinSelfStake(50 ether);
    }

    function test_CannotCompleteMinSelfStakeUpdateTooEarly() public {
        // Initialize prover
        _initializeProver(prover1);

        // Request decrease
        vm.prank(prover1);
        proverStaking.updateMinSelfStake(5_000e18);

        // Try to complete before delay
        vm.prank(prover1);
        vm.expectRevert(TestErrors.MinStakeDelay.selector);
        proverStaking.completeMinSelfStakeUpdate();
    }

    function test_CannotCompleteMinSelfStakeUpdateWithoutPending() public {
        // Initialize prover
        _initializeProver(prover1);

        // Try to complete without pending update
        vm.prank(prover1);
        vm.expectRevert(TestErrors.NoPendingMinStakeUpdate.selector);
        proverStaking.completeMinSelfStakeUpdate();
    }

    function test_MinSelfStakeUpdateEvents() public {
        // Initialize prover
        _initializeProver(prover1);

        // Test increase (immediate)
        vm.prank(prover1);
        vm.expectEmit(true, false, false, true);
        emit MinSelfStakeUpdated(prover1, 15_000e18);
        proverStaking.updateMinSelfStake(15_000e18);

        // Test decrease (delayed)
        vm.prank(prover1);
        vm.expectEmit(true, false, false, true);
        emit MinSelfStakeUpdateRequested(prover1, 5_000e18, block.timestamp);
        proverStaking.updateMinSelfStake(5_000e18);

        // Complete the decrease
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(prover1);
        vm.expectEmit(true, false, false, true);
        emit MinSelfStakeUpdated(prover1, 5_000e18);
        proverStaking.completeMinSelfStakeUpdate();
    }

    function test_OnlyProverCanUpdateMinSelfStake() public {
        // Initialize prover
        _initializeProver(prover1);

        // Try to update from different address
        vm.prank(user);
        vm.expectRevert(TestErrors.ProverNotRegistered.selector);
        proverStaking.updateMinSelfStake(15_000e18);

        // Try to complete from different address
        vm.prank(prover1);
        proverStaking.updateMinSelfStake(5_000e18);

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(user);
        vm.expectRevert(TestErrors.ProverNotRegistered.selector);
        proverStaking.completeMinSelfStakeUpdate();
    }

    function test_MinSelfStakeDecreaseDelayConfigurable() public {
        // Initialize prover
        _initializeProver(prover1);

        // Change the delay to 14 days
        vm.prank(owner);
        proverStaking.setMinSelfStakeDecreaseDelay(14 days);

        // Request decrease
        vm.prank(prover1);
        proverStaking.updateMinSelfStake(5_000e18);

        // Should have pending update with new delay
        (bool hasPending, uint256 pendingAmount, uint256 updateTime,) =
            proverStaking.getPendingMinSelfStakeUpdate(prover1);
        assertTrue(hasPending, "Should have pending update");
        assertEq(pendingAmount, 5_000e18, "Pending amount should match");
        assertEq(updateTime, block.timestamp + 14 days, "Update time should use new delay");

        // Try to complete before new delay period
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(prover1);
        vm.expectRevert(TestErrors.MinStakeDelay.selector);
        proverStaking.completeMinSelfStakeUpdate();

        // Should work after new delay period
        vm.warp(block.timestamp + 7 days + 1); // Total 14 days + 1
        vm.prank(prover1);
        proverStaking.completeMinSelfStakeUpdate();

        // Should be applied now
        (, uint256 currentMin,,,) = proverStaking.getProverInfo(prover1);
        assertEq(currentMin, 5_000e18, "Decrease should be applied after new delay");
    }

    function test_PendingMinSelfStakeUpdateAffectedByDelayChange() public {
        // Initialize prover
        _initializeProver(prover1);

        // Request decrease with 7-day delay
        vm.prank(prover1);
        proverStaking.updateMinSelfStake(5_000e18);

        // Verify initial effective time (7 days from request)
        (bool hasPending1, uint256 pendingAmount1, uint256 updateTime1,) =
            proverStaking.getPendingMinSelfStakeUpdate(prover1);
        assertTrue(hasPending1, "Should have pending update");
        assertEq(pendingAmount1, 5_000e18, "Pending amount should match");
        assertEq(updateTime1, block.timestamp + 7 days, "Initial update time should be 7 days");

        // Admin changes delay to 3 days
        vm.prank(owner);
        proverStaking.setMinSelfStakeDecreaseDelay(3 days);

        // Verify effective time changed (3 days from request time, not current time)
        (bool hasPending2, uint256 pendingAmount2, uint256 updateTime2, bool isReady2) =
            proverStaking.getPendingMinSelfStakeUpdate(prover1);
        assertTrue(hasPending2, "Should still have pending update");
        assertEq(pendingAmount2, 5_000e18, "Pending amount should not change");
        assertEq(updateTime2, block.timestamp + 3 days, "Update time should reflect new delay");
        assertFalse(isReady2, "Should not be ready yet");

        // Fast forward 3 days + 1 second
        vm.warp(block.timestamp + 3 days + 1);

        // Should now be ready and completable
        (,,, bool isReady3) = proverStaking.getPendingMinSelfStakeUpdate(prover1);
        assertTrue(isReady3, "Should be ready after new delay");

        vm.prank(prover1);
        proverStaking.completeMinSelfStakeUpdate();

        // Should be applied
        (, uint256 currentMin,,,) = proverStaking.getProverInfo(prover1);
        assertEq(currentMin, 5_000e18, "Decrease should be applied");
    }

    function test_UpdateCommissionRate() public {
        // Initialize prover with default commission rate
        _initializeProver(prover1);

        // Verify initial commission rate
        (uint64 initialRate,,) = proverRewards.getProverRewardInfo(prover1);
        assertEq(initialRate, COMMISSION_RATE, "Initial commission rate should match");

        // Update commission rate to a new value
        uint64 newCommissionRate = 1500; // 15%
        vm.prank(prover1);
        vm.expectEmit(true, false, false, true);
        emit CommissionRateUpdated(prover1, COMMISSION_RATE, newCommissionRate);
        proverRewards.updateCommissionRate(newCommissionRate);

        // Verify commission rate was updated
        (uint64 updatedRate,,) = proverRewards.getProverRewardInfo(prover1);
        assertEq(updatedRate, newCommissionRate, "Commission rate should be updated");
    }

    function test_CannotUpdateCommissionRateInvalidRate() public {
        // Initialize prover
        _initializeProver(prover1);

        // Try to set commission rate above 100%
        vm.prank(prover1);
        vm.expectRevert(TestErrors.RewardsInvalidCommission.selector);
        proverRewards.updateCommissionRate(10001); // 100.01%
    }

    function test_CannotUpdateCommissionRateNotProver() public {
        // Try to update commission rate without being a prover
        vm.prank(user);
        vm.expectRevert(TestErrors.RewardsProverNotRegistered.selector);
        proverRewards.updateCommissionRate(1000);
    }

    function test_UpdateCommissionRateSameValueNoRevert() public {
        // Initialize prover
        _initializeProver(prover1);

        // Capture current rate
        (uint64 beforeRate,,) = proverRewards.getProverRewardInfo(prover1);
        assertEq(beforeRate, COMMISSION_RATE, "Precondition");

        // Update with same value should not revert and rate stays same
        vm.prank(prover1);
        proverRewards.updateCommissionRate(COMMISSION_RATE);

        (uint64 afterRate,,) = proverRewards.getProverRewardInfo(prover1);
        assertEq(afterRate, beforeRate, "Rate should remain unchanged");
    }

    function test_CommissionRateUpdateAffectsFutureRewards() public {
        // Initialize prover and add staker
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 1000e18);

        // Check initial commission rate
        (uint64 initialRate,,) = proverRewards.getProverRewardInfo(prover1);
        assertEq(initialRate, COMMISSION_RATE, "Initial rate should be 10%");

        // Update commission rate to 20%
        vm.prank(prover1);
        proverRewards.updateCommissionRate(2000);

        // Verify commission rate was updated
        (uint64 newRate,,) = proverRewards.getProverRewardInfo(prover1);
        assertEq(newRate, 2000, "Commission rate should be updated to 20%");

        // Add rewards after rate change - this should use the new rate
        uint256 balanceBefore = brevToken.balanceOf(prover1);
        _addRewards(prover1, 100e18);

        // Withdraw rewards
        vm.prank(prover1);
        proverRewards.withdrawRewards(prover1);
        uint256 balanceAfter = brevToken.balanceOf(prover1);

        // Verify prover received rewards (exact calculation is complex due to staking rewards)
        assertGt(balanceAfter, balanceBefore, "Prover should receive rewards");
    }

    function test_MaxSlashPercentageLimit() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 1000e18);

        // Try to slash more than 50% - should revert
        vm.expectRevert(TestErrors.SlashTooHigh.selector);
        proverStaking.slash(prover1, 500001); // 50.0001%

        // Slash exactly 50% - should work
        proverStaking.slash(prover1, 500000); // 50%

        // Verify prover is still active after 50% slash
        (ProverStaking.ProverState state,,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(state == ProverStaking.ProverState.Active, "Prover should still be active after 50% slash");
    }

    function test_AutoDeactivationOnMinScale() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 1000e18);

        // Get initial scale
        (, uint256 initialScale,) = proverStaking.getProverInternals(prover1);
        assertEq(initialScale, 1e18, "Initial scale should be 1e18");

        // Slash multiple times to approach minimum scale (20% threshold)
        // Each 50% slash reduces scale by half
        // After 1 slash: 1e18 * 0.5 = 5e17 (50%) - still above 20%
        // After 2 slashes: 1e18 * (0.5)^2 = 2.5e17 (25%) - still above 20%
        // After 3 slashes: 1e18 * (0.5)^3 = 1.25e17 (12.5%) - below 20% threshold

        proverStaking.slash(prover1, 500000); // 1st slash - 50%
        (ProverStaking.ProverState state1,,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(state1 == ProverStaking.ProverState.Active, "Prover should still be active after 1st slash");

        proverStaking.slash(prover1, 500000); // 2nd slash - 25% remaining
        (ProverStaking.ProverState state2,,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(state2 == ProverStaking.ProverState.Active, "Prover should still be active after 2nd slash");

        // Check scale after 2 slashes
        (, uint256 scaleAfter2,) = proverStaking.getProverInternals(prover1);
        assertTrue(scaleAfter2 > 2e17, "Scale should still be above 20% minimum");

        // Third 50% slash should trigger auto-deactivation (scale drops to 12.5%)
        proverStaking.slash(prover1, 500000); // 3rd slash

        // Verify prover is now deactivated
        (ProverStaking.ProverState state,,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(
            state == ProverStaking.ProverState.Deactivated,
            "Prover should be auto-deactivated after scale drops below 20%"
        );

        // Verify scale is below 20% minimum
        (, uint256 finalScale,) = proverStaking.getProverInternals(prover1);
        assertTrue(finalScale < 2e17, "Scale should be below 20% threshold");
    }

    function test_GlobalTreasuryPoolAccounting() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 1000e18);

        // Check initial treasury pool is empty
        uint256 initialTreasuryPool = proverStaking.treasuryPool();
        assertEq(initialTreasuryPool, 0, "Initial treasury pool should be empty");

        // Slash 50% - should move 50% of effective stake to treasury pool
        uint256 effectiveStakeBefore = 1000e18 + MIN_SELF_STAKE; // staker + prover self-stake
        proverStaking.slash(prover1, 500000); // 50%

        // Check treasury pool received the slashed amount
        uint256 treasuryPoolAfter1 = proverStaking.treasuryPool();
        uint256 expectedSlashed1 = effectiveStakeBefore / 2; // 50% slashed
        assertEq(treasuryPoolAfter1, expectedSlashed1, "Treasury pool should contain 50% of original stake");

        // Slash another 50% of remaining stake
        uint256 effectiveStakeAfter1 = effectiveStakeBefore / 2; // 50% remaining
        proverStaking.slash(prover1, 500000); // 50% of remaining

        // Check treasury pool accumulated more slashed tokens
        uint256 treasuryPoolAfter2 = proverStaking.treasuryPool();
        uint256 expectedSlashed2 = expectedSlashed1 + (effectiveStakeAfter1 / 2); // Previous + 25% more
        assertEq(treasuryPoolAfter2, expectedSlashed2, "Treasury pool should accumulate slashed tokens");

        // Test withdrawal by owner
        address treasury = makeAddr("treasury");
        uint256 withdrawAmount = expectedSlashed2 / 2;

        vm.prank(owner);
        proverStaking.withdrawFromTreasuryPool(treasury, withdrawAmount);

        // Check treasury pool decreased and treasury received tokens
        uint256 treasuryPoolAfterWithdraw = proverStaking.treasuryPool();
        assertEq(
            treasuryPoolAfterWithdraw,
            expectedSlashed2 - withdrawAmount,
            "Treasury pool should decrease after withdrawal"
        );
        assertEq(brevToken.balanceOf(treasury), withdrawAmount, "Treasury should receive withdrawn tokens");
    }

    function test_DustAccumulation_BasicScenario() public {
        _initializeProver(prover1);

        // Create scenario that will generate dust:
        // Stake amount that doesn't divide evenly when multiplied by SCALE_FACTOR
        _stakeToProver(staker1, prover1, 333e18); // 333 * 1e18 tokens

        uint256 initialTreasuryPool = proverRewards.treasuryPool();
        assertEq(initialTreasuryPool, 0, "Dust pool should start empty");

        // Add rewards that will create dust
        uint256 rewardAmount = 1e18; // 1 token reward

        // Give owner tokens to add as rewards
        brevToken.mint(owner, rewardAmount);
        vm.startPrank(owner);
        brevToken.approve(address(proverRewards), rewardAmount);
        proverRewards.addRewards(prover1, rewardAmount);
        vm.stopPrank();

        // Check if dust pool accumulated dust
        uint256 treasuryPoolAfter = proverRewards.treasuryPool();

        // Calculate expected dust manually using the corrected method
        uint256 commission = (rewardAmount * COMMISSION_RATE) / 10000; // 10% commission
        uint256 stakersReward = rewardAmount - commission;

        // Get total raw shares (prover + staker)
        (uint256 totalRawShares,,) = proverStaking.getProverInternals(prover1);

        // Use the corrected dust calculation (in token units, not scaled units)
        uint256 deltaAcc = (stakersReward * 1e18) / totalRawShares;
        uint256 distributed = (deltaAcc * totalRawShares) / 1e18; // tokens actually distributed
        uint256 expectedDust = stakersReward - distributed; // tokens

        if (expectedDust > 0) {
            assertEq(treasuryPoolAfter, expectedDust, "Dust pool should contain expected dust");
        } else {
            assertEq(treasuryPoolAfter, 0, "No dust should be generated in this case");
        }
    }

    function test_DustAccumulation_MultipleRewards() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 777e18); // Odd number to encourage dust

        uint256 initialTreasuryPool = proverRewards.treasuryPool();

        // Add multiple small rewards to accumulate dust
        uint256 smallReward = 1e15; // 0.001 tokens

        // Give owner tokens to add as rewards
        brevToken.mint(owner, smallReward * 10);
        vm.startPrank(owner);
        brevToken.approve(address(proverRewards), smallReward * 10);

        for (uint256 i = 0; i < 10; i++) {
            proverRewards.addRewards(prover1, smallReward);
        }
        vm.stopPrank();

        uint256 finalTreasuryPool = proverRewards.treasuryPool();

        // Dust pool should have accumulated some dust
        assertGt(finalTreasuryPool, initialTreasuryPool, "Dust pool should accumulate dust from multiple rewards");
    }

    function test_DustAccumulation_CombinedWithSlashing() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 555e18);

        // Add rewards to generate some dust
        brevToken.mint(owner, 1e18);
        vm.startPrank(owner);
        brevToken.approve(address(proverRewards), 1e18);
        proverRewards.addRewards(prover1, 1e18);

        uint256 treasuryAfterRewards = proverStaking.treasuryPool();

        // Now slash the prover - this should add slashed tokens to treasury pool
        // (owner already has SLASHER_ROLE from setUp)
        proverStaking.slash(prover1, 100000); // 10% slash
        vm.stopPrank();

        uint256 treasuryAfterSlash = proverStaking.treasuryPool();

        // Treasury pool should contain both dust from rewards AND slashed tokens
        assertGt(treasuryAfterSlash, treasuryAfterRewards, "Treasury pool should increase from slashing");

        // The increase should be meaningful (more than just dust)
        uint256 increase = treasuryAfterSlash - treasuryAfterRewards;
        assertGt(increase, 50e18, "Slashing should contribute significant amount to treasury");
    }

    // Event declarations
    event ProverRetired(address indexed prover);
    event ProverUnretired(address indexed prover);
    event ProverReactivated(address indexed prover);
    event MinSelfStakeUpdateRequested(address indexed prover, uint256 newMinSelfStake, uint256 requestTime);
    event MinSelfStakeUpdated(address indexed prover, uint256 newMinSelfStake);
    event CommissionRateUpdated(address indexed prover, uint64 oldCommissionRate, uint64 newCommissionRate);
}
