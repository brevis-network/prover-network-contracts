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
    uint256 public constant GLOBAL_MIN_SELF_STAKE = 10_000e18; // Set equal to MIN_SELF_STAKE for compatibility
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

        (, uint256 totalStake,,) = proverStaking.getProverInfo(prover1);
        uint256 expectedRemaining = (MIN_SELF_STAKE + massiveStake) / 2; // 50%
        assertApproxEqRel(totalStake, expectedRemaining, 1e15);
    }

    function test_ExtremeSlashingScenario() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 4000e18);

        // Multiple maximum slashes to demonstrate auto-deactivation at 20% threshold
        proverStaking.slash(prover1, 500000); // 50% slash - leaves 50%

        // Verify still active after first slash
        (ProverStaking.ProverState state1,,,) = proverStaking.getProverInfo(prover1);
        assertEq(uint256(state1), uint256(ProverStaking.ProverState.Active));

        proverStaking.slash(prover1, 500000); // 50% of remaining - leaves 25% total

        // Verify still active after second slash (still above 20% threshold)
        (ProverStaking.ProverState state2,,,) = proverStaking.getProverInfo(prover1);
        assertEq(uint256(state2), uint256(ProverStaking.ProverState.Active));

        proverStaking.slash(prover1, 500000); // 50% of remaining - leaves 12.5% total

        // NOW should be auto-deactivated (below 20% threshold)
        (ProverStaking.ProverState finalState,,,) = proverStaking.getProverInfo(prover1);
        assertEq(uint256(finalState), uint256(ProverStaking.ProverState.Deactivated));

        (, uint256 finalStake,,) = proverStaking.getProverInfo(prover1);
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
        proverStaking.initProver(COMMISSION_RATE);

        // Stake additional funds from external staker
        vm.prank(staker1);
        brevToken.approve(address(proverStaking), 100e18);
        vm.prank(staker1);
        proverStaking.stake(prover1, 100e18);

        // Cannot retire with active stakes
        vm.expectRevert(TestErrors.ActiveStakesRemain.selector);
        vm.prank(prover1);
        proverStaking.retireProver(prover1);

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
        proverStaking.retireProver(prover1);

        // Verify prover is retired
        (ProverStaking.ProverState state,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(state == ProverStaking.ProverState.Retired, "Prover should be retired");
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
        proverStaking.initProver(COMMISSION_RATE);
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
        uint256 customMinSelfStake = GLOBAL_MIN_SELF_STAKE; // Use global minimum
        uint64 customCommissionRate = 500; // 5%

        vm.prank(prover1);
        brevToken.approve(address(proverStaking), customMinSelfStake);
        vm.prank(prover1);
        proverStaking.initProver(customCommissionRate);

        // Retire prover completely
        vm.prank(prover1);
        proverStaking.requestUnstake(prover1, customMinSelfStake);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(prover1);
        proverStaking.completeUnstake(prover1);
        vm.prank(owner);
        proverStaking.retireProver(prover1);

        // Self-stake while retired with higher amount
        uint256 unretireStake = GLOBAL_MIN_SELF_STAKE + 1000e18; // Higher than minimum
        vm.prank(prover1);
        brevToken.approve(address(proverStaking), unretireStake);
        vm.prank(prover1);
        proverStaking.stake(prover1, unretireStake);

        // Unretire (state change only)
        vm.prank(prover1);
        proverStaking.unretireProver();

        // Verify configuration is preserved
        (uint64 commissionRate,,) = proverRewards.getProverRewardInfo(prover1);
        assertEq(commissionRate, customCommissionRate, "Commission rate should be preserved");

        // Verify new stake amount
        (uint256 amount,,,) = proverStaking.getStakeInfo(prover1, prover1);
        assertEq(amount, unretireStake, "Should have new stake amount");
    }

    function test_UnretireWithSlashingHistory() public {
        // Initialize prover and add delegations
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 1000e18);

        // Slash the prover by 10% (keep scale above DEACTIVATION_SCALE of 20%)
        vm.prank(owner);
        proverStaking.slash(prover1, 100000); // 10%

        // Verify slash took effect
        (uint256 totalStaked1,,,) = proverStaking.getStakeInfo(prover1, prover1);
        assertEq(totalStaked1, MIN_SELF_STAKE * 9 / 10, "Self-stake should be reduced by 10% after slash");

        // Unstake completely and retire
        vm.prank(prover1);
        proverStaking.requestUnstake(prover1, totalStaked1);
        vm.prank(staker1);
        proverStaking.requestUnstake(prover1, 900e18); // 90% of original 1000e18

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(prover1);
        proverStaking.completeUnstake(prover1);
        vm.prank(staker1);
        proverStaking.completeUnstake(prover1);

        vm.prank(owner);
        proverStaking.retireProver(prover1);

        // Self-stake while retired - need to stake more to account for slashing
        // With 10% slash, scale is 0.9, so need to stake ~111% of MIN_SELF_STAKE to get effective MIN_SELF_STAKE
        uint256 stakeAmount = (MIN_SELF_STAKE * 10) / 9; // Slightly more than MIN_SELF_STAKE / 0.9
        vm.prank(prover1);
        brevToken.approve(address(proverStaking), stakeAmount);
        vm.prank(prover1);
        proverStaking.stake(prover1, stakeAmount);

        // Unretire after self-staking (should work since scale is 0.9 > 0.2)
        vm.prank(prover1);
        proverStaking.unretireProver();

        // Verify stake retains slashing history - effective amount should meet minimum
        (uint256 totalStaked2,,,) = proverStaking.getStakeInfo(prover1, prover1);
        assertGe(totalStaked2, MIN_SELF_STAKE, "Effective stake should meet minimum self-stake requirement");

        // Verify prover scale retains slashing history (0.9 from 10% slash)
        (, uint256 scale,) = proverStaking.getProverInternals(prover1);
        assertEq(scale, 0.9e18, "Scale should retain slashing history (0.9 from 10% slash)");
    }

    function test_MaxSlashFactorLimit() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 1000e18);

        // Try to slash more than 50% - should revert
        vm.expectRevert(TestErrors.SlashTooHigh.selector);
        proverStaking.slash(prover1, 500001); // 50.0001%

        // Slash exactly 50% - should work
        proverStaking.slash(prover1, 500000); // 50%

        // Verify prover is still active after 50% slash
        (ProverStaking.ProverState state,,,) = proverStaking.getProverInfo(prover1);
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
        (ProverStaking.ProverState state1,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(state1 == ProverStaking.ProverState.Active, "Prover should still be active after 1st slash");

        proverStaking.slash(prover1, 500000); // 2nd slash - 25% remaining
        (ProverStaking.ProverState state2,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(state2 == ProverStaking.ProverState.Active, "Prover should still be active after 2nd slash");

        // Check scale after 2 slashes
        (, uint256 scaleAfter2,) = proverStaking.getProverInternals(prover1);
        assertTrue(scaleAfter2 > 2e17, "Scale should still be above 20% minimum");

        // Third 50% slash should trigger auto-deactivation (scale drops to 12.5%)
        proverStaking.slash(prover1, 500000); // 3rd slash

        // Verify prover is now deactivated
        (ProverStaking.ProverState state,,,) = proverStaking.getProverInfo(prover1);
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

    // Event declarations
    event ProverRetired(address indexed prover);
    event ProverUnretired(address indexed prover);
    event ProverReactivated(address indexed prover);
    event MinSelfStakeUpdateRequested(address indexed prover, uint256 newMinSelfStake, uint256 requestTime);
    event MinSelfStakeUpdated(address indexed prover, uint256 newMinSelfStake);
}
