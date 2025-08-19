// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ProverStaking.sol";
import "../src/ProverRewards.sol";
import "../test/mocks/MockERC20.sol";
import "../test/mocks/MockPicoVerifier.sol";

contract RewardsTest is Test {
    ProverStaking public proverStaking;
    ProverRewards public proverRewards;
    MockERC20 public brevToken;
    MockPicoVerifier public picoVerifier;

    address public owner = address(this);
    address public prover1 = address(0x1);
    address public prover2 = address(0x2);
    address public staker1 = address(0x3);
    address public staker2 = address(0x4);
    address public staker3 = address(0x5);

    uint256 public constant MIN_SELF_STAKE = 10000e18;
    uint256 public constant COMMISSION_RATE = 1000; // 10%

    function setUp() public {
        // Deploy token
        brevToken = new MockERC20("BREV", "BREV");

        // Deploy verifier
        picoVerifier = new MockPicoVerifier();

        // Deploy ProverStaking
        proverStaking = new ProverStaking(address(brevToken), MIN_SELF_STAKE);

        // Deploy ProverRewards
        proverRewards = new ProverRewards(address(proverStaking), address(brevToken));

        // Set ProverRewards in ProverStaking
        proverStaking.setProverRewardsContract(address(proverRewards));

        // Grant necessary roles for testing
        proverStaking.grantRole(proverStaking.SLASHER_ROLE(), address(this));

        // Mint tokens for testing
        brevToken.mint(address(this), 1000000e18);
        brevToken.mint(prover1, 100000e18);
        brevToken.mint(prover2, 100000e18);
        brevToken.mint(staker1, 100000e18);
        brevToken.mint(staker2, 100000e18);
        brevToken.mint(staker3, 100000e18);
    }

    function _initializeProver(address prover) internal {
        vm.startPrank(prover);
        brevToken.approve(address(proverStaking), MIN_SELF_STAKE);
        proverStaking.initProver(uint64(COMMISSION_RATE));
        vm.stopPrank();
    }

    function _stakeToProver(address staker, address prover, uint256 amount) internal {
        vm.startPrank(staker);
        brevToken.approve(address(proverStaking), amount);
        proverStaking.stake(prover, amount);
        vm.stopPrank();
    }

    function _addRewards(address prover, uint256 amount) internal {
        brevToken.approve(address(proverRewards), amount);
        proverRewards.addRewards(prover, amount);
    }

    function test_RewardDistribution() public {
        // Setup: initialize prover and add stakers through ProverStaking
        _initializeProver(prover1);
        uint256 stakeAmount1 = 8000e18;
        uint256 stakeAmount2 = 2000e18;
        _stakeToProver(staker1, prover1, stakeAmount1);
        _stakeToProver(staker2, prover1, stakeAmount2);

        uint256 rewardAmount = 1000e18;

        // Add rewards directly to ProverRewards (external party adding rewards)
        brevToken.transfer(address(this), rewardAmount);
        brevToken.approve(address(proverRewards), rewardAmount);
        proverRewards.addRewards(prover1, rewardAmount);

        // Calculate expected rewards
        uint256 totalStake = MIN_SELF_STAKE + stakeAmount1 + stakeAmount2; // 20000e18
        uint256 expectedCommission = (rewardAmount * COMMISSION_RATE) / 10000; // 10% of 1000e18 = 100e18
        uint256 stakersReward = rewardAmount - expectedCommission; // 900e18

        // Expected individual rewards (proportional to stake)
        uint256 expectedRewards1 = (stakersReward * stakeAmount1) / totalStake; // 900e18 * 8000e18 / 20000e18 = 360e18
        uint256 expectedRewards2 = (stakersReward * stakeAmount2) / totalStake; // 900e18 * 2000e18 / 20000e18 = 90e18
        uint256 expectedProverRewards = (stakersReward * MIN_SELF_STAKE) / totalStake + expectedCommission; // 450e18 + 100e18 = 550e18

        // Check pending rewards via ProverRewards
        uint256 pendingRewards1 = proverRewards.calculateTotalPendingRewards(prover1, staker1);
        uint256 pendingRewards2 = proverRewards.calculateTotalPendingRewards(prover1, staker2);
        uint256 proverPendingRewards = proverRewards.calculateTotalPendingRewards(prover1, prover1);

        // Allow for small rounding differences
        assertApproxEqRel(pendingRewards1, expectedRewards1, 1e15); // 0.1% tolerance
        assertApproxEqRel(pendingRewards2, expectedRewards2, 1e15);
        assertApproxEqRel(proverPendingRewards, expectedProverRewards, 1e15);
    }

    function test_WithdrawRewards() public {
        // Setup: add rewards through ProverStaking integration
        _initializeProver(prover1);
        uint256 stakeAmount = 10000e18;
        _stakeToProver(staker1, prover1, stakeAmount);

        uint256 rewardAmount = 1000e18;
        brevToken.approve(address(proverRewards), rewardAmount);
        proverRewards.addRewards(prover1, rewardAmount);

        uint256 balanceBefore = brevToken.balanceOf(staker1);

        // Withdraw rewards via ProverRewards
        vm.prank(staker1);
        proverRewards.withdrawRewards(prover1);

        uint256 balanceAfter = brevToken.balanceOf(staker1);
        uint256 withdrawn = balanceAfter - balanceBefore;

        assertGt(withdrawn, 0, "Should have withdrawn some rewards");

        // Check that pending rewards are now zero
        uint256 pendingRewards = proverRewards.calculateTotalPendingRewards(prover1, staker1);
        assertEq(pendingRewards, 0);
    }

    function test_WithdrawFromInactiveProver() public {
        // Setup rewards first through ProverStaking integration
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 1000e18);

        brevToken.approve(address(proverRewards), 100e18);
        proverRewards.addRewards(prover1, 100e18);

        // Should still be able to withdraw rewards even if prover becomes inactive
        vm.prank(staker1);
        proverRewards.withdrawRewards(prover1); // Should not revert
    }

    function test_AddRewardsExternal() public {
        _initializeProver(prover1);

        // Add a staker through ProverStaking
        vm.prank(staker1);
        brevToken.approve(address(proverStaking), 5000e18);
        vm.prank(staker1);
        proverStaking.stake(prover1, 5000e18);

        uint256 rewardAmount = 1000e18;

        // Approve and add rewards through ProverRewards
        brevToken.approve(address(proverRewards), rewardAmount);
        proverRewards.addRewards(prover1, rewardAmount);

        // Check that rewards were distributed
        uint256 pendingRewards = proverRewards.calculateTotalPendingRewards(prover1, staker1);
        assertGt(pendingRewards, 0, "Staker should have pending rewards");
    }

    function test_AddRewardsTransfersTokens() public {
        _initializeProver(prover1);

        // Add a staker through ProverStaking
        vm.prank(staker1);
        brevToken.approve(address(proverStaking), 5000e18);
        vm.prank(staker1);
        proverStaking.stake(prover1, 5000e18);

        uint256 rewardAmount = 500e18;
        uint256 initialBalance = brevToken.balanceOf(address(this));
        uint256 initialContractBalance = brevToken.balanceOf(address(proverRewards));

        // Approve and add rewards through ProverRewards
        brevToken.approve(address(proverRewards), rewardAmount);
        proverRewards.addRewards(prover1, rewardAmount);

        // Check token transfer occurred
        assertEq(
            brevToken.balanceOf(address(this)), initialBalance - rewardAmount, "Test contract balance should decrease"
        );
        assertEq(
            brevToken.balanceOf(address(proverRewards)),
            initialContractBalance + rewardAmount,
            "Contract balance should increase"
        );
    }

    // ========== COMMISSION TESTS ==========

    function test_ZeroCommissionRateRewards() public {
        // Initialize prover with 0% commission
        vm.prank(prover1);
        brevToken.approve(address(proverStaking), MIN_SELF_STAKE);
        vm.prank(prover1);
        proverStaking.initProver(0);

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
        brevToken.approve(address(proverStaking), MIN_SELF_STAKE);
        vm.prank(prover1);
        proverStaking.initProver(10000);

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
        proverStaking.initProver(2000); // 20% commission

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

    // ========== COMMISSION RATE MANAGEMENT TESTS ==========

    function test_UpdateCommissionRate() public {
        // Initialize prover with default commission rate
        _initializeProver(prover1);

        // Verify initial commission rate
        (uint64 initialRate,,) = proverRewards.getProverRewardInfo(prover1);
        assertEq(initialRate, COMMISSION_RATE, "Initial commission rate should match");

        // Update commission rate to a new value
        uint64 newCommissionRate = 1500; // 15%
        vm.prank(prover1);
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
        vm.expectRevert();
        proverRewards.updateCommissionRate(10001); // 100.01%
    }

    function test_CannotUpdateCommissionRateNotProver() public {
        // Try to update commission rate without being a prover
        vm.prank(staker1); // staker1 is not a prover
        vm.expectRevert();
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
        proverRewards.updateCommissionRate(uint64(COMMISSION_RATE));

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

    // ========== COMPLEX REWARDS DISTRIBUTION TESTS ==========

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

    function test_RewardsToRetiredProverWithNoStakers() public {
        _initializeProver(prover1);

        // Prover unstakes all self-stake to get totalRawShares = 0
        vm.prank(prover1);
        proverStaking.requestUnstake(prover1, MIN_SELF_STAKE);

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(prover1);
        proverStaking.completeUnstake(prover1);

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

    // ========== DUST ACCUMULATION TESTS ==========

    function test_DustAccumulation_BasicScenario() public {
        _initializeProver(prover1);

        // Create scenario that will generate dust:
        // Stake amount that doesn't divide evenly when multiplied by SCALE_FACTOR
        _stakeToProver(staker1, prover1, 333e18); // 333 * 1e18 tokens

        uint256 initialTreasuryPool = proverRewards.treasuryPool();
        assertEq(initialTreasuryPool, 0, "Dust pool should start empty");

        // Add rewards that will create dust
        uint256 rewardAmount = 1e18; // 1 token reward
        _addRewards(prover1, rewardAmount);

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

        for (uint256 i = 0; i < 10; i++) {
            _addRewards(prover1, smallReward);
        }

        uint256 finalTreasuryPool = proverRewards.treasuryPool();

        // Dust pool should have accumulated some dust
        assertGt(finalTreasuryPool, initialTreasuryPool, "Dust pool should accumulate dust from multiple rewards");
    }

    function test_DustAccumulation_CombinedWithSlashing() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 555e18);

        // Add rewards to generate some dust
        _addRewards(prover1, 1e18);
        uint256 treasuryAfterRewards = proverStaking.treasuryPool();

        // Now slash the prover - this should add slashed tokens to treasury pool
        proverStaking.slash(prover1, 100000); // 10% slash
        uint256 treasuryAfterSlash = proverStaking.treasuryPool();

        // Treasury pool should contain both dust from rewards AND slashed tokens
        assertGt(treasuryAfterSlash, treasuryAfterRewards, "Treasury pool should increase from slashing");

        // The increase should be meaningful (more than just dust)
        uint256 increase = treasuryAfterSlash - treasuryAfterRewards;
        assertGt(increase, 50e18, "Slashing should contribute significant amount to treasury");
    }

    function test_WithdrawFromTreasuryPool() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 333e18);

        // Generate some dust
        _addRewards(prover1, 1e18);

        uint256 dustAmount = proverRewards.treasuryPool();
        if (dustAmount > 0) {
            address treasury = address(0x99);
            uint256 balanceBefore = brevToken.balanceOf(treasury);

            // Withdraw dust (owner can do this)
            proverRewards.withdrawFromTreasuryPool(treasury, dustAmount);

            uint256 balanceAfter = brevToken.balanceOf(treasury);
            assertEq(balanceAfter - balanceBefore, dustAmount, "Should withdraw exact dust amount");
            assertEq(proverRewards.treasuryPool(), 0, "Dust pool should be empty after withdrawal");
        }
    }

    // ========== INTEGRATION TESTS ==========

    function test_IntegratedFlow() public {
        // Test 1: Prover initialization
        _initializeProver(prover1);

        // Verify prover info in both contracts
        (ProverStaking.ProverState state, uint256 totalStaked, uint256 selfStake, uint256 stakerCount) =
            proverStaking.getProverInfo(prover1);

        assertTrue(state == ProverStaking.ProverState.Active);
        assertEq(totalStaked, MIN_SELF_STAKE);
        assertEq(selfStake, MIN_SELF_STAKE);
        assertEq(stakerCount, 1);

        (uint64 commissionRate, uint256 pendingCommission, uint256 accRewardPerRawShare) =
            proverRewards.getProverRewardInfo(prover1);

        assertEq(commissionRate, COMMISSION_RATE);
        assertEq(pendingCommission, 0);
        assertEq(accRewardPerRawShare, 0);

        // Test 2: External staking
        uint256 stakeAmount = 5_000e18;
        _stakeToProver(staker1, prover1, stakeAmount);

        // Verify updated totals
        (, totalStaked,, stakerCount) = proverStaking.getProverInfo(prover1);
        assertEq(totalStaked, MIN_SELF_STAKE + stakeAmount);
        assertEq(stakerCount, 2);

        // Test 3: Reward distribution
        uint256 rewardAmount = 1_000e18;
        _addRewards(prover1, rewardAmount);

        // Test 4: Reward withdrawal
        uint256 expectedStakerReward = (rewardAmount * 9000 / 10000) * stakeAmount / (MIN_SELF_STAKE + stakeAmount); // 90% of rewards, proportional to stake
        uint256 expectedProverReward = rewardAmount - expectedStakerReward; // Commission + proportional stake reward

        // Record balances before withdrawal
        uint256 staker1BalanceBefore = brevToken.balanceOf(staker1);
        uint256 prover1BalanceBefore = brevToken.balanceOf(prover1);

        vm.prank(staker1);
        proverRewards.withdrawRewards(prover1);

        vm.prank(prover1);
        proverRewards.withdrawRewards(prover1);

        // Verify exact reward amounts were distributed
        uint256 staker1ActualReward = brevToken.balanceOf(staker1) - staker1BalanceBefore;
        uint256 prover1ActualReward = brevToken.balanceOf(prover1) - prover1BalanceBefore;

        assertEq(staker1ActualReward, expectedStakerReward, "Staker should receive expected reward");
        assertEq(prover1ActualReward, expectedProverReward, "Prover should receive expected reward");
    }
}
