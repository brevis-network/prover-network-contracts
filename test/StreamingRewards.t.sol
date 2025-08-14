// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {TestProverStaking} from "./TestProverStaking.sol";
import {ProverStaking} from "../src/ProverStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title Streaming Rewards Test Suite
 * @notice Comprehensive tests for the global streaming rewards system
 * @dev Tests streaming emission, budget management, accumulator math, and edge cases
 */
contract StreamingRewardsTest is Test {
    TestProverStaking public proverStaking;
    MockERC20 public brevToken;

    address public owner = makeAddr("owner");
    address public prover1 = makeAddr("prover1");
    address public prover2 = makeAddr("prover2");
    address public staker1 = makeAddr("staker1");
    address public staker2 = makeAddr("staker2");
    address public funder = makeAddr("funder");

    uint256 public constant INITIAL_SUPPLY = 1_000_000e18;
    uint256 public constant MIN_SELF_STAKE = 10_000e18;
    uint256 public constant GLOBAL_MIN_SELF_STAKE = 50e18;
    uint64 public constant COMMISSION_RATE = 1000; // 10%
    uint256 public constant SCALE_FACTOR = 1e18;

    event StreamingRateUpdated(uint256 oldRate, uint256 newRate);
    event StreamingBudgetAdded(uint256 amount, uint256 newTotal);
    event StreamingRewardsSettled(address indexed prover, uint256 totalOwed, uint256 commission, uint256 distributed);

    function setUp() public {
        // Deploy BREV token
        brevToken = new MockERC20("Brevis Token", "BREV");

        // Deploy staking contract
        vm.startPrank(owner);
        proverStaking = new TestProverStaking(address(brevToken), GLOBAL_MIN_SELF_STAKE);
        proverStaking.grantRole(proverStaking.SLASHER_ROLE(), address(this));
        vm.stopPrank();

        // Mint tokens to participants
        brevToken.mint(prover1, INITIAL_SUPPLY);
        brevToken.mint(prover2, INITIAL_SUPPLY);
        brevToken.mint(staker1, INITIAL_SUPPLY);
        brevToken.mint(staker2, INITIAL_SUPPLY);
        brevToken.mint(funder, INITIAL_SUPPLY);
        brevToken.mint(owner, INITIAL_SUPPLY); // Owner needs tokens for streaming budget
        brevToken.mint(address(this), INITIAL_SUPPLY);

        // Approve tokens for testing
        brevToken.approve(address(proverStaking), INITIAL_SUPPLY);
        vm.prank(funder);
        brevToken.approve(address(proverStaking), INITIAL_SUPPLY);
        vm.prank(owner);
        brevToken.approve(address(proverStaking), INITIAL_SUPPLY);
        vm.prank(staker1);
        brevToken.approve(address(proverStaking), INITIAL_SUPPLY);
        vm.prank(staker2);
        brevToken.approve(address(proverStaking), INITIAL_SUPPLY);
        vm.prank(prover1);
        brevToken.approve(address(proverStaking), INITIAL_SUPPLY);
        vm.prank(prover2);
        brevToken.approve(address(proverStaking), INITIAL_SUPPLY);
    }

    // ========== HELPER FUNCTIONS ==========

    function _initializeProver(address prover) internal {
        _initializeProver(prover, MIN_SELF_STAKE, COMMISSION_RATE);
    }

    function _initializeProverWithStake(address prover, uint256 selfStake, uint64 commission) internal {
        vm.prank(prover);
        brevToken.approve(address(proverStaking), selfStake);
        vm.prank(prover);
        proverStaking.initProver(selfStake, commission);
    }

    function _stakeToProver(address staker, address prover, uint256 amount) internal {
        vm.prank(staker);
        brevToken.approve(address(proverStaking), amount);
        vm.prank(staker);
        proverStaking.stake(prover, amount);
    }

    function _setStreamingParameters(uint256 ratePerSec, uint256 budget) internal {
        vm.prank(owner);
        proverStaking.setGlobalRatePerSec(ratePerSec);
        vm.prank(funder);
        proverStaking.addStreamingBudget(budget);
    }

    function _getTotalEffectiveStake(address prover) internal view returns (uint256) {
        (,,, uint256 totalStaked,) = proverStaking.getProverInfo(prover);
        return totalStaked;
    }

    function _initializeProver(address prover, uint256 selfStake, uint64 commission) internal {
        vm.prank(prover);
        brevToken.approve(address(proverStaking), selfStake);
        vm.prank(prover);
        proverStaking.initProver(selfStake, commission);
    }

    function _stake(address staker, address prover, uint256 amount) internal {
        vm.prank(staker);
        brevToken.approve(address(proverStaking), amount);
        vm.prank(staker);
        proverStaking.stake(prover, amount);
    }

    function _fundGlobalBudget(uint256 amount) internal {
        vm.prank(funder);
        proverStaking.addStreamingBudget(amount);
    }

    function _setGlobalRate(uint256 ratePerSec) internal {
        vm.prank(owner);
        proverStaking.setGlobalRatePerSec(ratePerSec);
    }

    // ========== BASIC STREAMING FUNCTIONALITY TESTS ==========

    function test_SetGlobalRatePerSec() public {
        uint256 newRate = 1e18; // 1 token per second

        vm.expectEmit(true, true, false, true);
        emit StreamingRateUpdated(0, newRate);

        vm.prank(owner);
        proverStaking.setGlobalRatePerSec(newRate);

        (uint256 ratePerSec,,,,) = proverStaking.getStreamingInfo();
        assertEq(ratePerSec, newRate);
    }

    function test_RevertSetGlobalRateNotOwner() public {
        vm.expectRevert();
        vm.prank(staker1);
        proverStaking.setGlobalRatePerSec(1e18);
    }

    function test_AddStreamingBudget() public {
        uint256 budgetAmount = 1000e18;

        vm.expectEmit(true, true, false, true);
        emit StreamingBudgetAdded(budgetAmount, budgetAmount);

        vm.prank(funder);
        proverStaking.addStreamingBudget(budgetAmount);

        (, uint256 budgetBalance,,,) = proverStaking.getStreamingInfo();
        assertEq(budgetBalance, budgetAmount);
    }

    function test_RevertAddStreamingBudgetZero() public {
        vm.expectRevert("Amount must be positive");
        vm.prank(funder);
        proverStaking.addStreamingBudget(0);
    }

    function test_GetStreamingInfoInitialState() public view {
        (
            uint256 ratePerSec,
            uint256 budgetBalance,
            uint256 globalAccumulatorPerEff,
            uint256 totalEffStake,
            uint256 lastUpdate
        ) = proverStaking.getStreamingInfo();

        assertEq(ratePerSec, 0);
        assertEq(budgetBalance, 0);
        assertEq(globalAccumulatorPerEff, 0);
        assertEq(totalEffStake, 0);
        assertGt(lastUpdate, 0); // Should be initialized to deployment time
    }

    // ========== STREAMING ACCUMULATION TESTS ==========

    function test_StreamingWithSingleProver() public {
        // Setup: Initialize prover and set streaming
        _initializeProver(prover1, MIN_SELF_STAKE, COMMISSION_RATE);
        _setGlobalRate(1e18); // 1 token per second
        _fundGlobalBudget(100e18);

        // Verify initial state
        (, uint256 budgetBefore,, uint256 totalEffBefore,) = proverStaking.getStreamingInfo();
        assertEq(budgetBefore, 100e18);
        assertEq(totalEffBefore, MIN_SELF_STAKE);

        // Wait 10 seconds and trigger update
        vm.warp(block.timestamp + 10);
        proverStaking.updateGlobalStreaming();

        // Check global state
        (, uint256 budgetAfter, uint256 globalAcc,,) = proverStaking.getStreamingInfo();
        assertEq(budgetAfter, 90e18); // 100 - 10 tokens distributed
        assertEq(globalAcc, (10e18 * SCALE_FACTOR) / MIN_SELF_STAKE); // 10 tokens / stake

        // Settle prover to verify rewards
        proverStaking.settleProverStreaming(prover1);

        // Check prover received commission (10% of 10 tokens = 1 token)
        (,,,,, uint256 pendingCommission,) = proverStaking.getProverDetails(prover1);
        assertEq(pendingCommission, 1e18);

        // Check staker rewards (90% of 10 tokens = 9 tokens)
        uint256 pendingRewards = proverStaking.getPendingRewards(prover1, prover1);
        assertEq(pendingRewards, 10e18); // 1 commission + 9 staker rewards (prover is also staker)
    }

    function test_StreamingWithMultipleProvers() public {
        // Setup: Initialize two provers with different stakes
        _initializeProver(prover1, MIN_SELF_STAKE, COMMISSION_RATE); // 10k stake
        _initializeProver(prover2, MIN_SELF_STAKE * 2, COMMISSION_RATE * 2); // 20k stake, 20% commission

        _setGlobalRate(3e18); // 3 tokens per second
        _fundGlobalBudget(300e18);

        // Wait 10 seconds and trigger update
        vm.warp(block.timestamp + 10);
        proverStaking.updateGlobalStreaming();

        // Total distributed: 30 tokens over 30k total stake
        // Global accumulator: 30 * 1e18 / 30k = 1e15 per unit stake

        // Settle both provers
        proverStaking.settleProverStreaming(prover1);
        proverStaking.settleProverStreaming(prover2);

        // Prover 1: 10k stake * 1e15 = 10 tokens total
        // Commission (10%): 1 token, Stakers: 9 tokens
        (,,,,, uint256 commission1,) = proverStaking.getProverDetails(prover1);
        assertEq(commission1, 1e18);

        // Prover 2: 20k stake * 1e15 = 20 tokens total
        // Commission (20%): 4 tokens, Stakers: 16 tokens
        (,,,,, uint256 commission2,) = proverStaking.getProverDetails(prover2);
        assertEq(commission2, 4e18);

        // Verify budget deduction
        (, uint256 budgetAfter,,,) = proverStaking.getStreamingInfo();
        assertEq(budgetAfter, 270e18); // 300 - 30 tokens
    }

    function test_StreamingWithDelegatedStaking() public {
        // Setup: Prover with external stakers
        _initializeProver(prover1, MIN_SELF_STAKE, COMMISSION_RATE);
        _stake(staker1, prover1, MIN_SELF_STAKE); // Double the stake
        _stake(staker2, prover1, MIN_SELF_STAKE * 2); // Triple more

        // Total stake: 40k (10k self + 10k staker1 + 20k staker2)

        _setGlobalRate(4e18); // 4 tokens per second
        _fundGlobalBudget(400e18);

        // Wait 10 seconds
        vm.warp(block.timestamp + 10);
        proverStaking.settleProverStreaming(prover1);

        // Total rewards: 40 tokens
        // Commission (10%): 4 tokens to prover
        // Staker rewards (90%): 36 tokens distributed proportionally

        (,,,,, uint256 commission,) = proverStaking.getProverDetails(prover1);
        assertEq(commission, 4e18);

        // Prover as staker: 36 * 10k/40k = 9 tokens
        uint256 proverStakeRewards = proverStaking.getPendingRewards(prover1, prover1);
        assertEq(proverStakeRewards, 13e18); // 4 commission + 9 stake rewards

        // Staker1: 36 * 10k/40k = 9 tokens
        uint256 staker1Rewards = proverStaking.getPendingRewards(prover1, staker1);
        assertEq(staker1Rewards, 9e18);

        // Staker2: 36 * 20k/40k = 18 tokens
        uint256 staker2Rewards = proverStaking.getPendingRewards(prover1, staker2);
        assertEq(staker2Rewards, 18e18);
    }

    // ========== BUDGET CONSTRAINT TESTS ==========

    function test_StreamingCappedByBudget() public {
        _initializeProver(prover1, MIN_SELF_STAKE, COMMISSION_RATE);
        _setGlobalRate(10e18); // 10 tokens per second
        _fundGlobalBudget(50e18); // Only 50 tokens available

        // Wait 10 seconds (would be 100 tokens at rate, but only 50 available)
        vm.warp(block.timestamp + 10);
        proverStaking.updateGlobalStreaming();

        // Should only distribute available budget
        (, uint256 budgetAfter, uint256 globalAcc,,) = proverStaking.getStreamingInfo();
        assertEq(budgetAfter, 0); // All budget consumed
        assertEq(globalAcc, (50e18 * SCALE_FACTOR) / MIN_SELF_STAKE); // Only 50 tokens distributed
    }

    function test_StreamingStopsWhenBudgetExhausted() public {
        _initializeProver(prover1, MIN_SELF_STAKE, COMMISSION_RATE);
        _setGlobalRate(1e18);
        _fundGlobalBudget(5e18); // Only 5 tokens

        // Consume entire budget
        vm.warp(block.timestamp + 10); // Try to consume 10 tokens
        proverStaking.updateGlobalStreaming();

        uint256 globalAccAfterFirst;
        (,, globalAccAfterFirst,,) = proverStaking.getStreamingInfo();

        // Wait more time - should not accumulate further
        vm.warp(block.timestamp + 10);
        proverStaking.updateGlobalStreaming();

        (, uint256 finalBudget, uint256 finalGlobalAcc,,) = proverStaking.getStreamingInfo();
        assertEq(finalBudget, 0);
        assertEq(finalGlobalAcc, globalAccAfterFirst); // No additional accumulation
    }

    // ========== EDGE CASES AND ERROR CONDITIONS ==========

    function test_StreamingWithZeroRate() public {
        _initializeProver(prover1, MIN_SELF_STAKE, COMMISSION_RATE);
        _fundGlobalBudget(100e18);
        // Rate remains 0 (default)

        vm.warp(block.timestamp + 100);
        proverStaking.updateGlobalStreaming();

        // No rewards should be distributed
        (, uint256 budget, uint256 globalAcc,,) = proverStaking.getStreamingInfo();
        assertEq(budget, 100e18); // Budget unchanged
        assertEq(globalAcc, 0); // No accumulation
    }

    function test_StreamingWithZeroBudget() public {
        _initializeProver(prover1, MIN_SELF_STAKE, COMMISSION_RATE);
        _setGlobalRate(1e18);
        // No budget added

        vm.warp(block.timestamp + 100);
        proverStaking.updateGlobalStreaming();

        // No rewards should be distributed
        (, uint256 budget, uint256 globalAcc,,) = proverStaking.getStreamingInfo();
        assertEq(budget, 0);
        assertEq(globalAcc, 0);
    }

    function test_StreamingWithNoActiveProvers() public {
        _setGlobalRate(1e18);
        _fundGlobalBudget(100e18);
        // No provers initialized

        vm.warp(block.timestamp + 100);
        proverStaking.updateGlobalStreaming();

        // Budget should remain unchanged (no distribution target)
        (, uint256 budget, uint256 globalAcc, uint256 totalEff,) = proverStaking.getStreamingInfo();
        assertEq(budget, 100e18);
        assertEq(globalAcc, 0);
        assertEq(totalEff, 0);
    }

    function test_StreamingWithInactiveProver() public {
        // Initialize and then retire prover
        _initializeProver(prover1, MIN_SELF_STAKE, COMMISSION_RATE);

        // Unstake all funds first (required for retirement)
        vm.prank(prover1);
        proverStaking.requestUnstakeAll(prover1);

        // Complete unstake
        vm.warp(block.timestamp + 8 days); // Wait for unstake delay
        vm.prank(prover1);
        proverStaking.completeUnstake(prover1);

        // Withdraw any pending rewards to clear commission (if any)
        uint256 pendingRewards = proverStaking.getPendingRewards(prover1, prover1);
        if (pendingRewards > 0) {
            vm.prank(prover1);
            proverStaking.withdrawRewards(prover1);
        }

        // Now retire the prover
        vm.prank(prover1);
        proverStaking.retireProver();

        _setGlobalRate(1e18);
        _fundGlobalBudget(100e18);

        vm.warp(block.timestamp + 10);
        proverStaking.updateGlobalStreaming();

        // No distribution should occur
        (, uint256 budget,, uint256 totalEff,) = proverStaking.getStreamingInfo();
        assertEq(budget, 100e18);
        assertEq(totalEff, 0);
    }

    // ========== INTEGRATION WITH EXISTING SYSTEMS ==========

    function test_StreamingIntegrationWithProofRewards() public {
        _initializeProver(prover1, MIN_SELF_STAKE, COMMISSION_RATE);
        _setGlobalRate(1e18);
        _fundGlobalBudget(100e18);

        // Add traditional proof rewards
        proverStaking.addRewards(prover1, 50e18);

        // Wait and accumulate streaming rewards
        vm.warp(block.timestamp + 10);
        vm.prank(prover1);
        proverStaking.withdrawRewards(prover1); // Should trigger streaming settlement

        // Verify combined rewards
        uint256 proverBalance = brevToken.balanceOf(prover1);

        // Initial balance: 1,000,000e18 - 10,000e18 (staked) + 60e18 (rewards) = 990,060e18
        // Traditional rewards: 50 * 10% = 5 commission + 45 * 10k/10k = 45 stake rewards = 50 total
        // Streaming rewards: 10 * 10% = 1 commission + 9 * 10k/10k = 9 stake rewards = 10 total
        // Total: 60 tokens
        assertEq(proverBalance, 990_060e18);
    }

    function test_StreamingIntegrationWithStaking() public {
        _initializeProver(prover1, MIN_SELF_STAKE, COMMISSION_RATE);
        _setGlobalRate(2e18);
        _fundGlobalBudget(100e18);

        // Accumulate some streaming rewards
        vm.warp(block.timestamp + 5); // 10 tokens distributed

        // Add more stake - should trigger settlement
        _stake(staker1, prover1, MIN_SELF_STAKE);

        // Verify previous rewards were settled
        uint256 proverRewards = proverStaking.getPendingRewards(prover1, prover1);
        assertEq(proverRewards, 10e18); // All 10 tokens (1 commission + 9 stake)

        // New staker should start with 0 accumulated rewards
        uint256 stakerRewards = proverStaking.getPendingRewards(prover1, staker1);
        assertEq(stakerRewards, 0);
    }

    function test_StreamingIntegrationWithUnstaking() public {
        _initializeProver(prover1, MIN_SELF_STAKE, COMMISSION_RATE);
        _stake(staker1, prover1, MIN_SELF_STAKE);

        _setGlobalRate(2e18);
        _fundGlobalBudget(100e18);

        // Accumulate rewards
        vm.warp(block.timestamp + 5); // 10 tokens total

        // Unstake - should trigger settlement
        vm.prank(staker1);
        proverStaking.requestUnstake(prover1, MIN_SELF_STAKE);

        // Staker should receive their share of accumulated rewards
        uint256 stakerRewards = proverStaking.getPendingRewards(prover1, staker1);
        assertEq(stakerRewards, 4.5e18); // 9 tokens * 10k/20k = 4.5 tokens
    }

    function test_StreamingIntegrationWithSlashing() public {
        _initializeProver(prover1, MIN_SELF_STAKE, COMMISSION_RATE);
        _setGlobalRate(1e18);
        _fundGlobalBudget(100e18);

        // Accumulate rewards
        vm.warp(block.timestamp + 10); // 10 tokens

        // Slash prover 50%
        proverStaking.slash(prover1, 500000); // 50%

        // Settlement should still work with reduced stake
        proverStaking.settleProverStreaming(prover1);

        // Verify rewards were calculated on original stake
        (,,,,, uint256 commission,) = proverStaking.getProverDetails(prover1);
        assertEq(commission, 1e18); // 10% of 10 tokens

        // But effective stake is now reduced for future calculations
        (,,, uint256 totalEff,) = proverStaking.getStreamingInfo();
        assertEq(totalEff, MIN_SELF_STAKE / 2); // 50% of original
    }

    // ========== MATHEMATICAL PRECISION TESTS ==========

    function test_StreamingPrecisionWithSmallAmounts() public {
        // Test with minimal amounts to verify precision
        _initializeProver(prover1, GLOBAL_MIN_SELF_STAKE, COMMISSION_RATE); // Use global minimum
        _setGlobalRate(1); // 1 wei per second
        _fundGlobalBudget(1000);

        vm.warp(block.timestamp + 100); // 100 wei total
        proverStaking.settleProverStreaming(prover1);

        // Should handle small amounts without losing precision
        (,,,,, uint256 commission,) = proverStaking.getProverDetails(prover1);
        assertGt(commission, 0); // Should receive some commission even with tiny amounts
    }

    function test_StreamingPrecisionWithLargeAmounts() public {
        // Test with large amounts but keep them reasonable
        uint256 largeStake = 1e24; // Large but manageable stake
        brevToken.mint(prover1, largeStake); // Mint additional tokens
        vm.prank(prover1);
        brevToken.approve(address(proverStaking), largeStake);

        _initializeProver(prover1, largeStake, COMMISSION_RATE);
        _setGlobalRate(1e24); // Large rate

        brevToken.mint(funder, 1e30); // Mint budget tokens to funder
        vm.prank(funder);
        brevToken.approve(address(proverStaking), 1e30);
        _fundGlobalBudget(1e30);

        vm.warp(block.timestamp + 1);
        proverStaking.settleProverStreaming(prover1);

        // Should handle large amounts without overflow
        (,,,,, uint256 commission,) = proverStaking.getProverDetails(prover1);
        assertEq(commission, 1e23); // 10% of 1e24 tokens
    }

    // ========== WITHDRAWAL AND SETTLEMENT TESTS ==========

    function test_WithdrawStreamingRewards() public {
        _initializeProver(prover1, MIN_SELF_STAKE, COMMISSION_RATE);
        _setGlobalRate(1e18);
        _fundGlobalBudget(100e18);

        vm.warp(block.timestamp + 10);

        uint256 balanceBefore = brevToken.balanceOf(prover1);
        vm.prank(prover1);
        proverStaking.withdrawRewards(prover1);
        uint256 balanceAfter = brevToken.balanceOf(prover1);

        assertEq(balanceAfter - balanceBefore, 10e18); // All streaming rewards
    }

    function test_ManualSettlement() public {
        _initializeProver(prover1, MIN_SELF_STAKE, COMMISSION_RATE);
        _setGlobalRate(1e18);
        _fundGlobalBudget(100e18);

        vm.warp(block.timestamp + 5);

        // Manual settlement should work
        vm.expectEmit(true, false, false, true);
        emit StreamingRewardsSettled(prover1, 5e18, 0.5e18, 4.5e18);

        proverStaking.settleProverStreaming(prover1);
    }

    // ========== HELPER FUNCTION TESTS ==========

    function test_TopUpGlobalBudget() public {
        _fundGlobalBudget(100e18);

        // Add more budget from a different user to test anyone can fund
        vm.prank(staker1);
        proverStaking.addStreamingBudget(50e18);

        (, uint256 budget,,,) = proverStaking.getStreamingInfo();
        assertEq(budget, 150e18);
    }

    /**
     * @notice Test that anyone can add to the streaming budget (not just owner)
     * @dev Verifies the change from onlyOwner to public access for addStreamingBudget
     */
    function test_AnyoneCanAddStreamingBudget() public {
        // Test that different types of users can add to budget
        uint256 amount1 = 100e18;
        uint256 amount2 = 50e18;
        uint256 amount3 = 25e18;

        // Owner can fund
        vm.prank(owner);
        proverStaking.addStreamingBudget(amount1);

        // Staker can fund
        vm.prank(staker1);
        proverStaking.addStreamingBudget(amount2);

        // Prover can fund
        vm.prank(prover1);
        proverStaking.addStreamingBudget(amount3);

        (, uint256 totalBudget,,,) = proverStaking.getStreamingInfo();
        assertEq(totalBudget, amount1 + amount2 + amount3, "All users should be able to add to budget");
    }

    function test_UpdateGlobalStreamingManual() public {
        _initializeProver(prover1, MIN_SELF_STAKE, COMMISSION_RATE);
        _setGlobalRate(1e18);
        _fundGlobalBudget(100e18);

        uint256 timeBefore;
        (,,,, timeBefore) = proverStaking.getStreamingInfo();

        vm.warp(block.timestamp + 10);
        proverStaking.updateGlobalStreaming();

        uint256 timeAfter;
        (,,,, timeAfter) = proverStaking.getStreamingInfo();

        assertEq(timeAfter, block.timestamp);
        assertGt(timeAfter, timeBefore);
    }

    /**
     * @notice Test commission rate change affects only future rewards (Vector 5)
     * @dev Validates that commission changes apply to future accruals, not past ones
     */
    function test_CommissionChangeAffectsOnlyFuture() public {
        // Setup single prover
        _initializeProver(prover1);

        // Set streaming parameters
        _setStreamingParameters(100e18, 10000e18); // 100 tokens/sec, 10k budget

        // Wait 5 seconds and settle
        vm.warp(block.timestamp + 5);
        vm.prank(prover1);
        proverStaking.withdrawRewards(prover1);

        uint256 firstRewards = brevToken.balanceOf(prover1) - (INITIAL_SUPPLY - MIN_SELF_STAKE);
        // Expected: 500 * 0.1 = 50 commission + 500 * 0.9 = 450 staker rewards = 500 total
        assertEq(firstRewards, 500e18);

        // Change commission rate to 20%
        vm.prank(prover1);
        proverStaking.updateCommissionRate(2000); // 20%

        // Wait another 5 seconds and withdraw
        vm.warp(block.timestamp + 5);
        vm.prank(prover1);
        proverStaking.withdrawRewards(prover1);

        uint256 secondRewards = brevToken.balanceOf(prover1) - (INITIAL_SUPPLY - MIN_SELF_STAKE) - firstRewards;
        // Expected: 500 * 0.2 = 100 commission + 500 * 0.8 = 400 staker rewards = 500 total
        assertEq(secondRewards, 500e18);

        // Total should be 1000 tokens over 10 seconds
        assertEq(firstRewards + secondRewards, 1000e18);
    }

    /**
     * @notice Test rate change mid-period with multiple provers (Vector 12)
     * @dev Validates that rate changes affect future accruals for all provers proportionally
     */
    function test_RateChangeMidPeriodMultipleProvers() public {
        // Setup two provers with different stakes
        _initializeProver(prover1); // 10k stake
        _initializeProverWithStake(prover2, 20000e18, 0); // 20k stake, 0% commission

        // Set initial streaming rate
        _setStreamingParameters(90e18, 10000e18); // 90 tokens/sec

        // Wait 4 seconds and settle both
        vm.warp(block.timestamp + 4);
        vm.prank(prover1);
        proverStaking.withdrawRewards(prover1);
        vm.prank(prover2);
        proverStaking.withdrawRewards(prover2);

        uint256 p1FirstRewards = brevToken.balanceOf(prover1) - (INITIAL_SUPPLY - MIN_SELF_STAKE);
        uint256 p2FirstRewards = brevToken.balanceOf(prover2) - (INITIAL_SUPPLY - 20000e18);

        // Total distributed: 360 tokens over 4 seconds
        // P1 gets 1/3 (10k/30k), P2 gets 2/3 (20k/30k)
        assertEq(p1FirstRewards, 120e18); // 360 * 1/3
        assertEq(p2FirstRewards, 240e18); // 360 * 2/3

        // Change rate to 150 tokens/sec
        vm.prank(owner);
        proverStaking.setGlobalRatePerSec(150e18);

        // Wait another 4 seconds and withdraw
        vm.warp(block.timestamp + 4);
        vm.prank(prover1);
        proverStaking.withdrawRewards(prover1);
        vm.prank(prover2);
        proverStaking.withdrawRewards(prover2);

        uint256 p1SecondRewards = brevToken.balanceOf(prover1) - (INITIAL_SUPPLY - MIN_SELF_STAKE) - p1FirstRewards;
        uint256 p2SecondRewards = brevToken.balanceOf(prover2) - (INITIAL_SUPPLY - 20000e18) - p2FirstRewards;

        // Total distributed: 600 tokens over 4 seconds at new rate
        // Same proportions: P1 gets 1/3, P2 gets 2/3
        assertEq(p1SecondRewards, 200e18); // 600 * 1/3
        assertEq(p2SecondRewards, 400e18); // 600 * 2/3

        // Verify total rewards
        assertEq(p1FirstRewards + p1SecondRewards, 320e18); // 120 + 200
        assertEq(p2FirstRewards + p2SecondRewards, 640e18); // 240 + 400
    }

    /**
     * @notice Test mathematical invariants (Vector 15)
     * @dev Validates key system invariants hold after operations
     */
    function test_MathematicalInvariants() public {
        // Setup multiple provers and stakers
        _initializeProver(prover1);
        _initializeProverWithStake(prover2, 15000e18, 500); // 5% commission

        // Add delegated stakes
        _stakeToProver(staker1, prover1, 5000e18);
        _stakeToProver(staker2, prover2, 8000e18);

        // Set streaming parameters
        _setStreamingParameters(200e18, 50000e18);

        // Record initial state
        (, uint256 initialBudget, uint256 initialAcc,,) = proverStaking.getStreamingInfo();

        // Perform various operations over time
        vm.warp(block.timestamp + 10); // 2000 tokens distributed

        // Settle all provers
        proverStaking.settleProverStreaming(prover1);
        proverStaking.settleProverStreaming(prover2);

        // Check invariant 1: globalAccPerEff is non-decreasing
        (,, uint256 currentAcc,,) = proverStaking.getStreamingInfo();
        assertGe(currentAcc, initialAcc, "Global accumulator should be non-decreasing");

        // Check invariant 2: Total effective stake matches individual stakes
        uint256 p1EffectiveStake = _getTotalEffectiveStake(prover1);
        uint256 p2EffectiveStake = _getTotalEffectiveStake(prover2);
        (,,, uint256 totalEffectiveActive,) = proverStaking.getStreamingInfo();
        assertEq(totalEffectiveActive, p1EffectiveStake + p2EffectiveStake, "Total effective stake mismatch");

        // Check invariant 3: Budget decreases by distributed amount
        (, uint256 finalBudget,,,) = proverStaking.getStreamingInfo();
        uint256 expectedDistributed = 200e18 * 10; // rate * time
        assertEq(initialBudget - finalBudget, expectedDistributed, "Budget decrease should match distributed amount");
    }

    /**
     * @notice Test accrual neutrality (Vector 15 sub-test)
     * @dev Validates that settlement timing doesn't affect total rewards
     */
    function test_AccrualNeutrality() public {
        // Setup single prover scenario
        _initializeProver(prover1);
        _setStreamingParameters(100e18, 20000e18);

        // Get rewards with frequent settlement
        vm.warp(block.timestamp + 2);
        proverStaking.settleProverStreaming(prover1);
        vm.warp(block.timestamp + 3);
        proverStaking.settleProverStreaming(prover1);
        vm.warp(block.timestamp + 5);
        proverStaking.settleProverStreaming(prover1);

        uint256 frequentSettlementRewards = proverStaking.getPendingRewards(prover1, prover1);

        // Reset and test with single settlement
        vm.prank(prover1);
        proverStaking.withdrawRewards(prover1); // Clear pending rewards

        // Reset global state by setting rate to 0 and back
        vm.prank(owner);
        proverStaking.setGlobalRatePerSec(0);
        vm.prank(owner);
        proverStaking.setGlobalRatePerSec(100e18);

        // Single settlement over same total time (10 seconds)
        vm.warp(block.timestamp + 10);
        proverStaking.settleProverStreaming(prover1);

        uint256 singleSettlementRewards = proverStaking.getPendingRewards(prover1, prover1);

        // Should be approximately equal (allowing for minor rounding differences)
        assertApproxEqRel(frequentSettlementRewards, singleSettlementRewards, 1e15, "Accrual neutrality violated"); // 0.1% tolerance
    }

    /**
     * @notice Test that inactive periods don't leak rewards (baseline fix)
     */
    function test_InactivePeriodRewardIsolation() public {
        // Setup: Initialize prover and enable streaming
        _initializeProver(prover1, 1000e18, 1000); // 10% commission

        uint256 streamingRate = 100e18; // 100 tokens per second
        uint256 budget = 10000e18;

        vm.prank(owner);
        proverStaking.setGlobalRatePerSec(streamingRate);
        vm.prank(funder);
        proverStaking.addStreamingBudget(budget);

        // Phase 1: Active for 10 seconds
        vm.warp(block.timestamp + 10);
        proverStaking.settleProverStreaming(prover1);

        uint256 commission1;
        (,,,,, commission1,) = proverStaking.getProverDetails(prover1);
        console.log("Commission after 10s active:", commission1);

        // Phase 2: Deactivate prover
        vm.prank(owner);
        proverStaking.deactivateProver(prover1);

        uint256 commission2;
        (,,,,, commission2,) = proverStaking.getProverDetails(prover1);
        console.log("Commission after deactivation:", commission2);

        // Phase 3: Wait 20 seconds while inactive
        vm.warp(block.timestamp + 20);

        uint256 commission3;
        (,,,,, commission3,) = proverStaking.getProverDetails(prover1);
        console.log("Commission after 20s inactive:", commission3);
        assertEq(commission3, commission2, "Should not earn commission while inactive");

        // Phase 4: Reactivate prover
        vm.prank(owner);
        proverStaking.reactivateProver(prover1);

        uint256 commission4;
        (,,,,, commission4,) = proverStaking.getProverDetails(prover1);
        console.log("Commission after reactivation:", commission4);

        // Phase 5: Active for 5 seconds
        vm.warp(block.timestamp + 5);
        proverStaking.settleProverStreaming(prover1);

        uint256 commission5;
        (,,,,, commission5,) = proverStaking.getProverDetails(prover1);
        console.log("Commission after 5s more active:", commission5);

        // Should have earned commission for 10 + 5 = 15 seconds total
        uint256 expectedTotalCommission = 15 * streamingRate * 1000 / 10000; // 15 seconds * rate * 10% commission
        console.log("Expected total commission:", expectedTotalCommission);

        assertApproxEqRel(
            commission5,
            expectedTotalCommission,
            0.01e18, // 1% tolerance
            "Should only earn commission for active periods"
        );
    }

    /**
     * @notice Test that zero-payout unstake completion works after heavy slashing
     */
    function test_ZeroPayoutUnstakeCompletion() public {
        // Setup prover and staker
        _initializeProver(prover1, 1000e18, 1000);

        // Staker stakes
        vm.prank(staker1);
        brevToken.approve(address(proverStaking), 500e18);
        vm.prank(staker1);
        proverStaking.stake(prover1, 500e18);

        // Staker requests unstake
        vm.prank(staker1);
        proverStaking.requestUnstake(prover1, 500e18);

        // Wait for delay
        vm.warp(block.timestamp + proverStaking.UNSTAKE_DELAY() + 1);

        // Heavy slashing (multiple 50% slashes) - this should make effective amount near zero
        proverStaking.slash(prover1, 500000); // 50% slash
        proverStaking.slash(prover1, 500000); // Another 50% slash (of remaining 50%)

        // Should be able to complete unstake even with zero effective amount
        vm.prank(staker1);
        proverStaking.completeUnstake(prover1);

        // Verify no pending unstakes remain
        (,, uint256 pendingCount,) = proverStaking.getStakeInfo(prover1, staker1);
        assertEq(pendingCount, 0, "Should have cleared all pending unstakes");
    }

    /**
     * @notice Test that getPendingStreamingRewards correctly returns zero for inactive provers
     * @dev Verifies the fix for the confusion where the function would show hypothetical
     *      rewards for inactive provers that would never actually be earned
     */
    function test_GetPendingStreamingRewardsInactiveProvers() public {
        // Setup: Initialize and stake with prover using helper
        _initializeProver(prover1, MIN_SELF_STAKE, COMMISSION_RATE);

        // Setup streaming using helper functions
        _setGlobalRate(1e18); // 1 token/second
        _fundGlobalBudget(1000e18);

        // Active prover should show pending rewards after some time
        vm.warp(block.timestamp + 10);
        (uint256 activeTotal, uint256 activeCommission,) = proverStaking.getPendingStreamingRewards(prover1);
        assertGt(activeTotal, 0, "Active prover should have pending rewards");
        assertGt(activeCommission, 0, "Active prover should have pending commission");

        // Deactivate the prover
        vm.prank(owner);
        proverStaking.deactivateProver(prover1);

        // Advance time more
        vm.warp(block.timestamp + 10);

        // Deactivated prover should show zero pending rewards (fixed behavior)
        (uint256 deactivatedTotal, uint256 deactivatedCommission, uint256 deactivatedStakers) =
            proverStaking.getPendingStreamingRewards(prover1);
        assertEq(deactivatedTotal, 0, "Deactivated prover should have zero pending rewards");
        assertEq(deactivatedCommission, 0, "Deactivated prover should have zero pending commission");
        assertEq(deactivatedStakers, 0, "Deactivated prover should have zero pending staker rewards");

        // Check retired state by testing a different prover that we'll retire
        _initializeProver(prover2, MIN_SELF_STAKE, COMMISSION_RATE);

        // Let prover2 accrue some rewards
        vm.warp(block.timestamp + 5);

        // Retire prover2 (must clear stakes first)
        vm.prank(prover2);
        proverStaking.withdrawRewards(prover2);
        vm.prank(prover2);
        proverStaking.requestUnstakeAll(prover2);
        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(prover2);
        proverStaking.completeUnstake(prover2);
        vm.prank(owner);
        proverStaking.retireProver(prover2);

        // Advance time more
        vm.warp(block.timestamp + 10);

        // Retired prover should also show zero pending rewards
        (uint256 retiredTotal, uint256 retiredCommission, uint256 retiredStakers) =
            proverStaking.getPendingStreamingRewards(prover2);
        assertEq(retiredTotal, 0, "Retired prover should have zero pending rewards");
        assertEq(retiredCommission, 0, "Retired prover should have zero pending commission");
        assertEq(retiredStakers, 0, "Retired prover should have zero pending staker rewards");
    }

    // ========== STREAMING ACCOUNTING DRIFT DETECTION TESTS ==========

    /**
     * @notice Test that would catch stake-change drift bugs
     * @dev Measures rewards per time period before/after stake changes
     */
    function test_StakeChangeDriftDetection() public {
        // Initialize prover with small stake
        _initializeProver(prover1, MIN_SELF_STAKE, COMMISSION_RATE);

        // Setup streaming: 100 tokens/second
        _setGlobalRate(100e18);
        _fundGlobalBudget(10000e18);

        // === PHASE 1: Small stake for 10 seconds ===
        uint256 startTime = block.timestamp;
        vm.warp(startTime + 10);

        // Get rewards for 10 seconds with MIN_SELF_STAKE
        proverStaking.settleProverStreaming(prover1);
        uint256 rewardsPhase1 = proverStaking.getPendingRewards(prover1, prover1);

        // Expected: 10 seconds * 100 tokens/sec = 1000 tokens (all to prover since no other stakers)
        assertEq(rewardsPhase1, 1000e18, "Phase 1 rewards incorrect");

        // Withdraw to reset
        vm.prank(prover1);
        proverStaking.withdrawRewards(prover1);

        // === PHASE 2: Add more stake and run for another 10 seconds ===
        _stake(staker1, prover1, MIN_SELF_STAKE); // Double the stake

        uint256 stakeChangeTime = block.timestamp;
        vm.warp(stakeChangeTime + 10); // Another 10 seconds

        // Get rewards for 10 seconds with 2x stake
        proverStaking.settleProverStreaming(prover1);
        uint256 rewardsPhase2 = proverStaking.getPendingRewards(prover1, prover1);

        // Expected: 10 seconds * 100 tokens/sec = 1000 tokens total
        // Prover gets: commission (10% of 1000) + staking rewards (50% of 900) = 100 + 450 = 550
        assertEq(rewardsPhase2, 550e18, "Phase 2 rewards incorrect - possible drift bug!");

        // === CRITICAL TEST: Verify staker got correct rewards ===
        uint256 stakerRewards = proverStaking.getPendingRewards(prover1, staker1);
        // Staker should get: 50% of staking portion = 50% of 900 = 450
        assertEq(stakerRewards, 450e18, "Staker rewards incorrect - drift bug detected!");
    }

    /**
     * @notice Test that would catch unstake-change drift bugs
     */
    function test_UnstakeChangeDriftDetection() public {
        // Setup: Prover + Staker with equal stakes
        _initializeProver(prover1, MIN_SELF_STAKE, COMMISSION_RATE);
        _stake(staker1, prover1, MIN_SELF_STAKE);

        // Setup streaming: 100 tokens/second
        _setGlobalRate(100e18);
        _fundGlobalBudget(10000e18);

        // === PHASE 1: Full stake for 10 seconds ===
        vm.warp(block.timestamp + 10);

        proverStaking.settleProverStreaming(prover1);
        uint256 proverRewardsPhase1 = proverStaking.getPendingRewards(prover1, prover1);
        uint256 stakerRewardsPhase1 = proverStaking.getPendingRewards(prover1, staker1);

        // Expected: 1000 tokens total, 100 commission + 450 staking each
        assertEq(proverRewardsPhase1, 550e18, "Phase 1 prover rewards incorrect");
        assertEq(stakerRewardsPhase1, 450e18, "Phase 1 staker rewards incorrect");

        // Withdraw to reset
        vm.prank(prover1);
        proverStaking.withdrawRewards(prover1);
        vm.prank(staker1);
        proverStaking.withdrawRewards(prover1);

        // === PHASE 2: Staker unstakes, then run for another 10 seconds ===
        vm.prank(staker1);
        proverStaking.requestUnstake(prover1, MIN_SELF_STAKE); // Halve the total stake

        vm.warp(block.timestamp + 10); // Another 10 seconds

        proverStaking.settleProverStreaming(prover1);
        uint256 proverRewardsPhase2 = proverStaking.getPendingRewards(prover1, prover1);
        uint256 stakerRewardsPhase2 = proverStaking.getPendingRewards(prover1, staker1);

        // Expected: 1000 tokens total, but now prover gets it all since staker unstaked
        // Commission: 10% of 1000 = 100, Staking: 90% of 1000 = 900 (all to prover)
        assertEq(proverRewardsPhase2, 1000e18, "Phase 2 prover rewards incorrect - drift bug!");
        assertEq(stakerRewardsPhase2, 0, "Phase 2 staker should have 0 new rewards after unstaking");
    }

    /**
     * @notice Test that would catch slash-change drift bugs
     */
    function test_SlashChangeDriftDetection() public {
        // Setup: Single prover
        _initializeProver(prover1, MIN_SELF_STAKE, COMMISSION_RATE);

        // Setup streaming: 100 tokens/second
        _setGlobalRate(100e18);
        _fundGlobalBudget(10000e18);

        // === PHASE 1: Full stake for 10 seconds ===
        vm.warp(block.timestamp + 10);

        proverStaking.settleProverStreaming(prover1);
        uint256 rewardsPhase1 = proverStaking.getPendingRewards(prover1, prover1);

        // Expected: 1000 tokens (all to prover)
        assertEq(rewardsPhase1, 1000e18, "Phase 1 rewards incorrect");

        // Withdraw to reset
        vm.prank(prover1);
        proverStaking.withdrawRewards(prover1);

        // === PHASE 2: Slash 50%, then run for another 10 seconds ===
        proverStaking.slash(prover1, 500000); // 50% slash

        vm.warp(block.timestamp + 10); // Another 10 seconds

        proverStaking.settleProverStreaming(prover1);
        uint256 rewardsPhase2 = proverStaking.getPendingRewards(prover1, prover1);

        // Expected: Now only 5000e18 effective stake, so only 50% of streaming rate
        // 10 seconds * 100 tokens/sec * (5000e18 / 10000e18) = 500 tokens
        // BUT: totalEffectiveActive should also be 5000e18, so prover still gets 100% of the reduced pool
        // So: 10 seconds * 100 tokens/sec * (5000e18 / 5000e18) = 1000 tokens
        assertEq(rewardsPhase2, 1000e18, "Phase 2 rewards incorrect - slash drift bug!");
    }

    /**
     * @notice Test for precise time-based reward calculation
     * @dev This would catch any drift where rewards leak across time boundaries
     */
    function test_PreciseTimeBasedAccounting() public {
        // Setup
        _initializeProver(prover1, MIN_SELF_STAKE, COMMISSION_RATE);

        _setGlobalRate(1e18); // 1 token per second for precision
        _fundGlobalBudget(1000e18);

        uint256 baseTime = block.timestamp;

        // === Test: Measure rewards at exact time boundaries ===

        // 5 seconds with small stake
        vm.warp(baseTime + 5);
        proverStaking.settleProverStreaming(prover1);
        uint256 rewards5sec = proverStaking.getPendingRewards(prover1, prover1);
        assertEq(rewards5sec, 5e18, "5 second rewards incorrect");

        // Add staker (double stake)
        _stake(staker1, prover1, MIN_SELF_STAKE);

        // Withdraw existing rewards to reset
        vm.prank(prover1);
        proverStaking.withdrawRewards(prover1);

        // Another 5 seconds with double stake
        vm.warp(baseTime + 10);
        proverStaking.settleProverStreaming(prover1);
        uint256 rewardsNext5sec = proverStaking.getPendingRewards(prover1, prover1);

        // Should be: 1 token/sec * 5 sec = 5 tokens total
        // Prover gets: 10% commission + 50% of staking = 0.5 + 2.25 = 2.75 tokens
        assertEq(rewardsNext5sec, 2.75e18, "Next 5 second rewards incorrect - time drift detected!");

        // Verify staker got correct share
        uint256 stakerShare = proverStaking.getPendingRewards(prover1, staker1);
        assertEq(stakerShare, 2.25e18, "Staker share incorrect - time drift detected!");
    }

    function test_DustAccountingInTokenUnitsNotScaledUnits() public {
        _initializeProver(prover1);

        // Create a scenario that will generate dust
        uint256 stakeAmount = 333e18; // 333 tokens
        _stakeToProver(staker1, prover1, stakeAmount);

        uint256 rewardAmount = 1e18; // 1 token

        // Get prover data to calculate expected values
        (uint256 totalRawShares,,,) = proverStaking.getProverInternals(prover1);

        // Calculate what the dust should be using the CORRECTED method
        uint256 commission = (rewardAmount * COMMISSION_RATE) / 10000;
        uint256 stakersReward = rewardAmount - commission;

        // Corrected dust calculation (in token units)
        uint256 deltaAcc = (stakersReward * SCALE_FACTOR) / totalRawShares;
        uint256 distributed = (deltaAcc * totalRawShares) / SCALE_FACTOR;
        uint256 expectedDustTokens = stakersReward - distributed;

        // Calculate what the dust would be using the OLD INCORRECT method
        uint256 incorrectDustScaled = (stakersReward * SCALE_FACTOR) % totalRawShares;

        // Verify these are different (proving the bug existed)
        if (expectedDustTokens != incorrectDustScaled) {
            assertGt(incorrectDustScaled, expectedDustTokens, "Incorrect method should give inflated dust");
        }

        uint256 treasuryBefore = proverStaking.getTreasuryPool();

        // Add the rewards
        brevToken.mint(owner, rewardAmount);
        vm.startPrank(owner);
        brevToken.approve(address(proverStaking), rewardAmount);
        proverStaking.addRewards(prover1, rewardAmount);
        vm.stopPrank();

        uint256 treasuryAfter = proverStaking.getTreasuryPool();
        uint256 actualDust = treasuryAfter - treasuryBefore;

        // Verify the dust is calculated correctly (in token units)
        assertEq(actualDust, expectedDustTokens, "Dust should be in token units");

        // The dust should be small relative to the reward amount
        assertLt(actualDust, rewardAmount / 100, "Dust should be less than 1% of reward");
    }
}
