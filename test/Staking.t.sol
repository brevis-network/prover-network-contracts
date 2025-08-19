// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {TestErrors} from "./utils/TestErrors.sol";
import {TestProverStaking} from "./TestProverStaking.sol";
import {ProverStaking} from "../src/ProverStaking.sol";
import {ProverRewards} from "../src/ProverRewards.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title Staking Test Suite
 * @notice Core tests for staking functionality
 * @dev Tests basic user flows: initialization, staking, unstaking, rewards, slashing
 */
contract StakingTest is Test {
    TestProverStaking public proverStaking;
    ProverRewards public proverRewards;
    MockERC20 public brevToken;

    address public owner = makeAddr("owner");
    address public prover1 = makeAddr("prover1");
    address public prover2 = makeAddr("prover2");
    address public staker1 = makeAddr("staker1");
    address public staker2 = makeAddr("staker2");
    address public user = makeAddr("user");

    uint256 public constant INITIAL_SUPPLY = 1_000_000e18;
    uint256 public constant MIN_SELF_STAKE = 10_000e18;
    uint256 public constant GLOBAL_MIN_SELF_STAKE = 10_000e18; // Set equal to MIN_SELF_STAKE for compatibility
    uint64 public constant COMMISSION_RATE = 1000; // 10%

    function setUp() public {
        // Deploy BREV token (used for both staking and rewards)
        brevToken = new MockERC20("Brevis Token", "BREV");

        // Deploy staked provers contract with direct deployment pattern
        vm.startPrank(owner);
        proverStaking = new TestProverStaking(address(brevToken), GLOBAL_MIN_SELF_STAKE);

        // Deploy prover rewards contract
        proverRewards = new ProverRewards(address(proverStaking), address(brevToken));

        // Link the contracts
        proverStaking.setProverRewardsContract(address(proverRewards));

        // Grant slasher role to both this test contract and owner for testing
        proverStaking.grantRole(proverStaking.SLASHER_ROLE(), address(this));
        proverStaking.grantRole(proverStaking.SLASHER_ROLE(), owner);
        vm.stopPrank();

        // Mint tokens to participants
        brevToken.mint(prover1, INITIAL_SUPPLY);
        brevToken.mint(prover2, INITIAL_SUPPLY);
        brevToken.mint(staker1, INITIAL_SUPPLY);
        brevToken.mint(staker2, INITIAL_SUPPLY);
        brevToken.mint(address(this), INITIAL_SUPPLY); // For reward distribution

        // Approve tokens for the test contract to distribute rewards
        brevToken.approve(address(proverStaking), INITIAL_SUPPLY);
    }

    // ========== CORE FUNCTIONALITY TESTS ==========

    function test_InitProver() public {
        // Initialize prover
        vm.prank(prover1);
        brevToken.approve(address(proverStaking), GLOBAL_MIN_SELF_STAKE);

        vm.prank(prover1);
        proverStaking.initProver(COMMISSION_RATE);

        // Verify prover details
        (ProverStaking.ProverState state, uint256 totalStaked, uint256 selfEffectiveStake, uint256 stakersCount) =
            proverStaking.getProverInfo(prover1);

        assertTrue(state == ProverStaking.ProverState.Active);
        assertEq(totalStaked, GLOBAL_MIN_SELF_STAKE);
        assertEq(selfEffectiveStake, GLOBAL_MIN_SELF_STAKE);
        assertEq(stakersCount, 1); // Prover counts as one staker

        // Verify prover's stake
        (uint256 amount, uint256 pendingUnstake, uint256 pendingUnstakeCount, uint256 pendingRewards) =
            proverStaking.getStakeInfo(prover1, prover1);

        assertEq(amount, GLOBAL_MIN_SELF_STAKE);
        assertEq(pendingUnstake, 0);
        assertEq(pendingUnstakeCount, 0);
        assertEq(pendingRewards, 0);

        // Verify active prover list
        address[] memory activeProvers = proverStaking.activeProverList();
        assertEq(activeProvers.length, 1);
        assertEq(activeProvers[0], prover1);

        // Verify all provers list
        address[] memory allProvers = proverStaking.getAllProvers();
        assertEq(allProvers.length, 1);
        assertEq(allProvers[0], prover1);
    }

    function test_RevertOnDuplicateProverInit() public {
        _initializeProver(prover1);

        // Try to initialize again - should fail
        vm.prank(prover1);
        brevToken.approve(address(proverStaking), GLOBAL_MIN_SELF_STAKE);

        vm.expectRevert(TestErrors.InvalidProverState.selector);
        vm.prank(prover1);
        proverStaking.initProver(COMMISSION_RATE);
    }

    function test_RevertOnInvalidCommissionRate() public {
        vm.prank(prover1);
        brevToken.approve(address(proverStaking), GLOBAL_MIN_SELF_STAKE);

        vm.expectRevert(TestErrors.InvalidCommission.selector);
        vm.prank(prover1);
        proverStaking.initProver(10001); // > 100%
    }

    function test_Stake() public {
        // Initialize prover
        _initializeProver(prover1);

        uint256 stakeAmount = 5000e18;

        // Staker stakes to prover
        vm.prank(staker1);
        brevToken.approve(address(proverStaking), stakeAmount);

        vm.prank(staker1);
        proverStaking.stake(prover1, stakeAmount);

        // Verify stake was recorded
        (uint256 amount,,,) = proverStaking.getStakeInfo(prover1, staker1);
        assertEq(amount, stakeAmount);

        // Verify total stake increased
        (, uint256 totalStaked,,) = proverStaking.getProverInfo(prover1);
        assertEq(totalStaked, GLOBAL_MIN_SELF_STAKE + stakeAmount);
    }

    function test_RevertOnStakeToInactiveProver() public {
        address inactiveProver = makeAddr("inactive");

        vm.prank(staker1);
        brevToken.approve(address(proverStaking), 1000e18);

        vm.expectRevert(TestErrors.ProverNotRegistered.selector);
        vm.prank(staker1);
        proverStaking.stake(inactiveProver, 1000e18);
    }

    function test_RevertOnStakeBelowMinSelfStake() public {
        vm.prank(prover1);
        brevToken.approve(address(proverStaking), GLOBAL_MIN_SELF_STAKE);
        vm.prank(prover1);
        proverStaking.initProver(COMMISSION_RATE);

        // Slash prover to reduce effective self-stake below minimum
        vm.prank(owner);
        proverStaking.slash(prover1, 500000); // 50% slash

        vm.prank(staker1);
        brevToken.approve(address(proverStaking), 1000e18);

        vm.expectRevert(TestErrors.MinSelfStakeNotMet.selector);
        vm.prank(staker1);
        proverStaking.stake(prover1, 1000e18);
    }

    function test_RequestUnstake() public {
        // Setup: initialize prover and add stake
        _initializeProver(prover1);
        uint256 stakeAmount = 5000e18;
        _stakeToProver(staker1, prover1, stakeAmount);

        uint256 unstakeAmount = 2000e18;

        // Initiate unstake
        vm.prank(staker1);
        proverStaking.requestUnstake(prover1, unstakeAmount);

        // Verify pending unstake was set
        (, uint256 pendingUnstake, uint256 unstakeTime,) = proverStaking.getStakeInfo(prover1, staker1);
        assertEq(pendingUnstake, unstakeAmount);
        assertEq(unstakeTime, block.timestamp);

        // Verify active stake was reduced
        (uint256 activeStake,,,) = proverStaking.getStakeInfo(prover1, staker1);
        assertEq(activeStake, stakeAmount - unstakeAmount);
    }

    function test_CompleteUnstake() public {
        _initializeProver(prover1);
        uint256 stakeAmount = 5000e18;
        _stakeToProver(staker1, prover1, stakeAmount);

        uint256 unstakeAmount = 2000e18;
        vm.prank(staker1);
        proverStaking.requestUnstake(prover1, unstakeAmount);

        // Try to complete before delay
        vm.expectRevert(TestErrors.NoReadyUnstakes.selector);
        vm.prank(staker1);
        proverStaking.completeUnstake(prover1);

        // Fast forward past delay
        vm.warp(block.timestamp + 7 days + 1);

        uint256 balanceBefore = brevToken.balanceOf(staker1);
        vm.prank(staker1);
        proverStaking.completeUnstake(prover1);
        uint256 balanceAfter = brevToken.balanceOf(staker1);

        assertEq(balanceAfter - balanceBefore, unstakeAmount);

        // Verify pending unstake cleared
        (, uint256 pendingUnstake, uint256 unstakeTime,) = proverStaking.getStakeInfo(prover1, staker1);
        assertEq(pendingUnstake, 0);
        assertEq(unstakeTime, 0);
    }

    function test_RevertOnInsufficientStakeForRequestUnstake() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 1000e18);

        vm.expectRevert(TestErrors.InsufficientStake.selector);
        vm.prank(staker1);
        proverStaking.requestUnstake(prover1, 2000e18); // Try to unstake more than staked
    }

    function test_MultipleRequestUnstake() public {
        _initializeProver(prover1);
        uint256 stakeAmount = 5000e18;
        _stakeToProver(staker1, prover1, stakeAmount);

        // First unstake request
        vm.prank(staker1);
        proverStaking.requestUnstake(prover1, 1000e18);

        // Second unstake request should now succeed (multiple requests allowed)
        vm.prank(staker1);
        proverStaking.requestUnstake(prover1, 1000e18);

        // Verify we have 2 pending unstake requests
        (,, uint256 pendingUnstakeCount,) = proverStaking.getStakeInfo(prover1, staker1);
        assertEq(pendingUnstakeCount, 2, "Should have 2 pending unstake requests");
    }

    function test_MaxPendingUnstakesLimit() public {
        _initializeProver(prover1);
        uint256 stakeAmount = 100000e18; // Large stake to allow many unstakes
        _stakeToProver(staker1, prover1, stakeAmount);

        // Create 10 unstake requests (the maximum)
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(staker1);
            proverStaking.requestUnstake(prover1, 1000e18);
        }

        // Verify we have 10 pending requests
        (,, uint256 pendingUnstakeCount,) = proverStaking.getStakeInfo(prover1, staker1);
        assertEq(pendingUnstakeCount, 10, "Should have 10 pending unstake requests");

        // Try to create an 11th request - should fail
        vm.expectRevert(TestErrors.TooManyPendingUnstakes.selector);
        vm.prank(staker1);
        proverStaking.requestUnstake(prover1, 1000e18);
    }

    function test_ProverCanUnstakeToZero() public {
        _initializeProver(prover1);

        // Prover can unstake all their self-stake (complete exit)
        vm.prank(prover1);
        proverStaking.requestUnstake(prover1, MIN_SELF_STAKE);

        (, uint256 pendingUnstake,,) = proverStaking.getStakeInfo(prover1, prover1);
        assertEq(pendingUnstake, MIN_SELF_STAKE);
    }

    function test_SlashProver() public {
        // Setup staking
        _initializeProver(prover1);
        uint256 stakeAmount = 9000e18;
        _stakeToProver(staker1, prover1, stakeAmount);

        uint256 totalStakeBefore = 19000e18; // MIN_SELF_STAKE + 9000e18
        uint256 slashPercentage = 200000; // 20%

        vm.prank(owner);
        proverStaking.slash(prover1, slashPercentage);

        (, uint256 totalStakeAfter,,) = proverStaking.getProverInfo(prover1);
        uint256 expectedStakeAfter = (totalStakeBefore * 80) / 100; // 80% remaining = 15200e18

        assertEq(totalStakeAfter, expectedStakeAfter);
    }

    function test_SlashInactiveProver() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 1000e18);

        // Deactivate prover
        vm.prank(owner);
        proverStaking.deactivateProver(prover1);

        // Should still be able to slash inactive prover
        uint256 stakeBefore = 11000e18; // MIN_SELF_STAKE + 1000e18
        vm.prank(owner);
        proverStaking.slash(prover1, 100000); // 10%

        (, uint256 stakeAfter,,) = proverStaking.getProverInfo(prover1);
        assertEq(stakeAfter, (stakeBefore * 90) / 100);
    }

    function test_SlashAfterUnbondingStart() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 900e18);

        // Staker initiates unstake
        vm.prank(staker1);
        proverStaking.requestUnstake(prover1, 500e18);

        // Slash while unbonding
        vm.prank(owner);
        proverStaking.slash(prover1, 200000); // 20%

        // Complete unstake - should receive slashed amount
        vm.warp(block.timestamp + 7 days + 1);
        uint256 balanceBefore = brevToken.balanceOf(staker1);
        vm.prank(staker1);
        proverStaking.completeUnstake(prover1);
        uint256 balanceAfter = brevToken.balanceOf(staker1);

        // Should receive 80% of 500e18 = 400e18
        assertEq(balanceAfter - balanceBefore, 400e18);
    }

    function test_CannotSlashAboveMax() public {
        _initializeProver(prover1);

        // 100% slash now falls under generic SlashTooHigh (exceeds MAX_SLASH_PERCENTAGE = 50%)
        vm.expectRevert(TestErrors.SlashTooHigh.selector);
        vm.prank(owner);
        proverStaking.slash(prover1, 1_000_000); // 100%
    }

    // ========== HELPER FUNCTIONS ==========

    function _initializeProver(address prover) internal {
        vm.prank(prover);
        brevToken.approve(address(proverStaking), GLOBAL_MIN_SELF_STAKE);

        vm.prank(prover);
        proverStaking.initProver(COMMISSION_RATE);
    }

    function test_StakerTracking() public {
        // Initialize prover
        _initializeProver(prover1);

        // Check initial stakers list (should just be the prover)
        address[] memory stakers = proverStaking.getProverStakers(prover1);
        assertEq(stakers.length, 1, "Should have 1 staker initially");
        assertEq(stakers[0], prover1, "Prover should be in stakers list");

        // Check staker count from getProverInfo
        (,,, uint256 stakerCount) = proverStaking.getProverInfo(prover1);
        assertEq(stakerCount, 1, "Staker count should be 1");

        // Add another staker
        _stakeToProver(staker1, prover1, 100e18);

        // Check updated stakers list
        stakers = proverStaking.getProverStakers(prover1);
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
        (,,, stakerCount) = proverStaking.getProverInfo(prover1);
        assertEq(stakerCount, 2, "Staker count should be 2");

        // Fully unstake one staker
        vm.prank(staker1);
        proverStaking.requestUnstake(prover1, 100e18);

        // Check stakers list after unstaking
        stakers = proverStaking.getProverStakers(prover1);
        assertEq(stakers.length, 1, "Should have 1 staker after unstaking");
        assertEq(stakers[0], prover1, "Only prover should remain in stakers list");

        // Check staker count
        (,,, stakerCount) = proverStaking.getProverInfo(prover1);
        assertEq(stakerCount, 1, "Staker count should be 1 after unstaking");
    }

    function _stakeToProver(address staker, address prover, uint256 amount) internal {
        vm.prank(staker);
        brevToken.approve(address(proverStaking), amount);

        vm.prank(staker);
        proverStaking.stake(prover, amount);
    }

    // === GLOBAL MIN SELF STAKE TESTS ===

    function test_SetMinSelfStake() public {
        uint256 newGlobalMin = 75e18;

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit GlobalParamUpdated(ProverStaking.ParamName.MinSelfStake, newGlobalMin);
        proverStaking.setGlobalParam(ProverStaking.ParamName.MinSelfStake, newGlobalMin);

        assertEq(
            proverStaking.globalParams(ProverStaking.ParamName.MinSelfStake),
            newGlobalMin,
            "Global min self stake should be updated"
        );
    }

    function test_SetMaxSlashFactor() public {
        uint256 newMaxSlash = 300000; // 30% (300,000 parts per million)

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit GlobalParamUpdated(ProverStaking.ParamName.MaxSlashFactor, newMaxSlash);
        proverStaking.setGlobalParam(ProverStaking.ParamName.MaxSlashFactor, newMaxSlash);

        assertEq(
            proverStaking.globalParams(ProverStaking.ParamName.MaxSlashFactor),
            newMaxSlash,
            "Max slash percentage should be updated"
        );
    }

    function test_OnlyOwnerCanSetMinSelfStake() public {
        vm.expectRevert();
        vm.prank(user);
        proverStaking.setGlobalParam(ProverStaking.ParamName.MinSelfStake, 2000e18);
    }

    function test_InitProverMeetsGlobalMinimum() public {
        uint256 minSelfStake = GLOBAL_MIN_SELF_STAKE; // Exactly the global minimum

        // Setup tokens for prover
        brevToken.mint(prover2, minSelfStake);
        vm.startPrank(prover2);
        brevToken.approve(address(proverStaking), minSelfStake);

        // Should succeed
        proverStaking.initProver(COMMISSION_RATE);

        vm.stopPrank();

        (ProverStaking.ProverState state,,,) = proverStaking.getProverInfo(prover2);
        assertTrue(state == ProverStaking.ProverState.Active);
    }

    function test_InitProverBelowGlobalMinimumFails() public {
        uint256 insufficientAmount = 25e18; // Below global minimum of 50e18

        // Setup tokens for prover (insufficient amount)
        brevToken.mint(prover2, insufficientAmount);
        vm.startPrank(prover2);
        brevToken.approve(address(proverStaking), insufficientAmount);

        // Should fail due to insufficient balance (ERC20 transfer will fail)
        vm.expectRevert(); // Generic revert from ERC20 transfer
        proverStaking.initProver(COMMISSION_RATE);

        vm.stopPrank();
    }

    function test_GlobalMinDoesNotAffectExistingProvers() public {
        // First initialize prover1 with current requirements
        vm.prank(prover1);
        brevToken.approve(address(proverStaking), GLOBAL_MIN_SELF_STAKE);
        vm.prank(prover1);
        proverStaking.initProver(COMMISSION_RATE);

        // Verify prover1 is active
        (ProverStaking.ProverState initialState,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(initialState == ProverStaking.ProverState.Active);

        // Increase global minimum above prover1's current requirement
        vm.prank(owner);
        proverStaking.setGlobalParam(ProverStaking.ParamName.MinSelfStake, 20000e18);

        // prover1 should still be active (not retroactive)
        (ProverStaking.ProverState state1,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(state1 == ProverStaking.ProverState.Active);

        // But new provers must meet the global minimum (which is enforced in initProver)
        brevToken.mint(prover2, 30e18); // Below global minimum of 50e18
        vm.startPrank(prover2);
        brevToken.approve(address(proverStaking), 30e18);

        vm.expectRevert(); // Should fail due to insufficient balance for global minimum
        proverStaking.initProver(COMMISSION_RATE);

        vm.stopPrank();
    }

    function test_ProverEligibilityChecks() public {
        address prover = makeAddr("prover");
        brevToken.mint(prover, 10000e18);
        vm.prank(prover);
        brevToken.approve(address(proverStaking), 10000e18);

        // Test 1: Non-existent prover should not be eligible
        (bool eligible, uint256 totalStake) = proverStaking.isProverEligible(prover, 1000e18);
        assertFalse(eligible, "Non-existent prover should not be eligible");
        assertEq(totalStake, 0, "Non-existent prover should have 0 total stake");

        // Test 2: Initialize prover with proper self-stake above global minimum
        vm.prank(prover);
        proverStaking.initProver(1000); // 10% commission rate

        // Test 3: Eligible prover with sufficient stake (use global minimum)
        (eligible, totalStake) = proverStaking.isProverEligible(prover, 8000e18); // Less than global minimum
        assertTrue(eligible, "Properly initialized prover should be eligible");
        assertEq(totalStake, GLOBAL_MIN_SELF_STAKE, "Total stake should match global minimum self-stake");

        // Test 4: Prover with insufficient total stake
        (eligible, totalStake) = proverStaking.isProverEligible(prover, 15000e18); // More than what prover has
        assertFalse(eligible, "Prover with insufficient total stake should not be eligible");
        assertEq(totalStake, GLOBAL_MIN_SELF_STAKE, "Should still return current total stake");

        // Test 5: Deactivated prover should not be eligible
        vm.prank(owner);
        proverStaking.deactivateProver(prover);
        (eligible, totalStake) = proverStaking.isProverEligible(prover, 8000e18);
        assertFalse(eligible, "Deactivated prover should not be eligible");
        assertEq(totalStake, GLOBAL_MIN_SELF_STAKE, "Deactivated prover should still return actual total stake");

        // Test 6: Prover below global minimum (through global minimum change)
        address prover3 = makeAddr("prover3");
        brevToken.mint(prover3, 20000e18);
        vm.prank(prover3);
        brevToken.approve(address(proverStaking), 20000e18);

        // Initialize with current global minimum
        vm.prank(prover3);
        proverStaking.initProver(1000); // 10% commission rate

        // Increase global minimum
        vm.prank(owner);
        proverStaking.setGlobalParam(ProverStaking.ParamName.MinSelfStake, 15000e18);

        (eligible, totalStake) = proverStaking.isProverEligible(prover3, 8000e18);
        assertFalse(eligible, "Prover below new global minimum should not be eligible");
        assertEq(totalStake, 10000e18, "Should return actual total stake");

        // Test 7: Prover with insufficient actual self-stake due to slashing
        address prover4 = makeAddr("prover4");
        brevToken.mint(prover4, 20000e18);
        vm.prank(prover4);
        brevToken.approve(address(proverStaking), 20000e18);

        vm.prank(prover4);
        proverStaking.initProver(1000); // 10% commission rate

        // Slash the prover by 50%
        vm.prank(owner);
        proverStaking.slash(prover4, 500000);

        (eligible, totalStake) = proverStaking.isProverEligible(prover4, 8000e18); // More than 7500e18 (slashed amount)
        assertFalse(eligible, "Slashed prover below required amount should not be eligible");
        assertEq(totalStake, 7500e18, "Should return slashed total stake"); // 15000e18 * 0.5 = 7500e18
    }

    function test_SlashExternalWithRole() public {
        _initializeProver(prover1);

        // Add a staker
        vm.prank(staker1);
        brevToken.approve(address(proverStaking), 5000e18);
        vm.prank(staker1);
        proverStaking.stake(prover1, 5000e18);

        uint256 slashPercentage = 100000; // 10%

        // Get initial stake
        (uint256 initialStake,,,) = proverStaking.getStakeInfo(prover1, staker1);

        // Slash as this test contract (has slasher role)
        proverStaking.slash(prover1, slashPercentage);

        // Check that stake was reduced
        (uint256 finalStake,,,) = proverStaking.getStakeInfo(prover1, staker1);
        assertLt(finalStake, initialStake, "Stake should be reduced after slashing");

        // Check approximately 10% slash (90% remaining)
        uint256 expectedStake = (initialStake * 9) / 10;
        assertApproxEqRel(finalStake, expectedStake, 0.01e18, "Should be approximately 10% slashed");
    }

    function test_OnlySlasherRoleCanSlash() public {
        _initializeProver(prover1);

        // Owner has slasher role from setup, so this should work
        vm.prank(owner);
        proverStaking.slash(prover1, 50000); // 5%

        // But user without role should fail
        vm.expectRevert("unauthorized role");
        vm.prank(user);
        proverStaking.slash(prover1, 100000); // 10%
    }

    // ========== PROVER MANAGEMENT TESTS ==========

    function test_DeactivateProver() public {
        // Initialize prover
        _initializeProver(prover1);

        // Verify prover is active
        (ProverStaking.ProverState state1,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(state1 == ProverStaking.ProverState.Active, "Prover should be active");

        // Deactivate prover (admin action)
        vm.expectEmit(true, false, false, false);
        emit ProverDeactivated(prover1);
        vm.prank(owner);
        proverStaking.deactivateProver(prover1);

        // Verify prover is deactivated after deactivation
        (ProverStaking.ProverState state2,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(state2 == ProverStaking.ProverState.Deactivated, "Prover should be deactivated");
    }

    function test_OnlyOwnerCanDeactivate() public {
        _initializeProver(prover1);

        vm.expectRevert();
        vm.prank(user);
        proverStaking.deactivateProver(prover1);
    }

    function test_CannotDeactivateInactiveProver() public {
        _initializeProver(prover1);

        // Deactivate once
        vm.prank(owner);
        proverStaking.deactivateProver(prover1);

        // Try to deactivate again
        vm.expectRevert(TestErrors.InvalidProverState.selector);
        vm.prank(owner);
        proverStaking.deactivateProver(prover1);
    }

    function test_RetireProver() public {
        // Initialize prover with minimal stake
        vm.prank(prover1);
        brevToken.approve(address(proverStaking), GLOBAL_MIN_SELF_STAKE);
        vm.prank(prover1);
        proverStaking.initProver(COMMISSION_RATE);

        // Cannot retire with active stakes
        vm.expectRevert(TestErrors.ActiveStakesRemain.selector);
        vm.prank(owner);
        proverStaking.retireProver(prover1);

        // Unstake all funds
        vm.prank(prover1);
        proverStaking.requestUnstake(prover1, GLOBAL_MIN_SELF_STAKE);

        // Wait and complete
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(prover1);
        proverStaking.completeUnstake(prover1);

        // Now anyone can retire the prover (using owner here but could be anyone)
        vm.expectEmit(true, false, false, false);
        emit ProverRetired(prover1);
        vm.prank(owner);
        proverStaking.retireProver(prover1);

        // Verify prover is retired
        (ProverStaking.ProverState state,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(state == ProverStaking.ProverState.Retired, "Prover should be retired");
    }

    function test_AnyoneCanRetireProver() public {
        // Initialize prover with minimal stake
        vm.prank(prover2);
        brevToken.approve(address(proverStaking), GLOBAL_MIN_SELF_STAKE);
        vm.prank(prover2);
        proverStaking.initProver(COMMISSION_RATE);

        // Unstake all funds
        vm.prank(prover2);
        proverStaking.requestUnstake(prover2, GLOBAL_MIN_SELF_STAKE);

        // Wait and complete
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(prover2);
        proverStaking.completeUnstake(prover2);

        // Any address can retire the prover (using staker1 as example)
        vm.expectEmit(true, false, false, false);
        emit ProverRetired(prover2);
        vm.prank(staker1); // Random user retiring the prover
        proverStaking.retireProver(prover2);

        // Verify prover is retired
        (ProverStaking.ProverState retiredState,,,) = proverStaking.getProverInfo(prover2);
        assertTrue(retiredState == ProverStaking.ProverState.Retired, "Prover should be retired");
    }

    function test_UnretireRetiredProver() public {
        // Initialize and fully exit prover
        _initializeProver(prover1);

        // Unstake completely to retire
        vm.prank(prover1);
        proverStaking.requestUnstake(prover1, MIN_SELF_STAKE);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(prover1);
        proverStaking.completeUnstake(prover1);

        // Retire prover
        vm.prank(owner);
        proverStaking.retireProver(prover1);

        // Verify prover is retired
        (ProverStaking.ProverState state1,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(state1 == ProverStaking.ProverState.Retired, "Prover should be retired");

        // Self-stake while retired to meet minimum requirements
        vm.prank(prover1);
        brevToken.approve(address(proverStaking), GLOBAL_MIN_SELF_STAKE);
        vm.prank(prover1);
        proverStaking.stake(prover1, GLOBAL_MIN_SELF_STAKE);

        // Unretire prover (state change only)
        vm.expectEmit(true, false, false, false);
        emit ProverUnretired(prover1);
        vm.prank(prover1);
        proverStaking.unretireProver();

        // Verify prover is active again
        (ProverStaking.ProverState state2,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(state2 == ProverStaking.ProverState.Active, "Prover should be active after unretiring");

        // Verify stake was applied
        (uint256 amount,,,) = proverStaking.getStakeInfo(prover1, prover1);
        assertEq(amount, MIN_SELF_STAKE, "Prover should have self-stake");
    }

    function test_AdminReactivateDeactivatedProver() public {
        // Initialize prover
        _initializeProver(prover1);

        // Deactivate prover (admin action)
        vm.prank(owner);
        proverStaking.deactivateProver(prover1);

        // Verify prover is deactivated
        (ProverStaking.ProverState state1,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(state1 == ProverStaking.ProverState.Deactivated, "Prover should be deactivated");

        // Admin reactivates prover
        vm.expectEmit(true, false, false, false);
        emit ProverReactivated(prover1);
        vm.prank(owner);
        proverStaking.reactivateProver(prover1);

        // Verify prover is active again
        (ProverStaking.ProverState state2,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(state2 == ProverStaking.ProverState.Active, "Prover should be active after admin reactivation");
    }

    function test_CannotUnretireActiveProver() public {
        _initializeProver(prover1);

        // Try to unretire active prover
        vm.expectRevert(TestErrors.InvalidProverState.selector);
        vm.prank(prover1);
        proverStaking.unretireProver();
    }

    function test_CannotUnretireWithoutMinimumStake() public {
        // Initialize and retire prover
        _initializeProver(prover1);

        vm.prank(prover1);
        proverStaking.requestUnstake(prover1, MIN_SELF_STAKE);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(prover1);
        proverStaking.completeUnstake(prover1);
        vm.prank(owner);
        proverStaking.retireProver(prover1);

        // Try to unretire without self-staking first
        vm.expectRevert(TestErrors.MinSelfStakeNotMet.selector);
        vm.prank(prover1);
        proverStaking.unretireProver();
    }

    function test_CannotAdminReactivateRetiredProver() public {
        // Initialize and retire prover
        _initializeProver(prover1);

        vm.prank(prover1);
        proverStaking.requestUnstake(prover1, MIN_SELF_STAKE);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(prover1);
        proverStaking.completeUnstake(prover1);
        vm.prank(owner);
        proverStaking.retireProver(prover1);

        // Admin cannot reactivate retired prover (only deactivated)
        vm.expectRevert(TestErrors.InvalidProverState.selector);
        vm.prank(owner);
        proverStaking.reactivateProver(prover1);
    }

    function test_RequestUnstakeAll_BasicFunctionality() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 1000e18);

        // Get initial stake info
        (uint256 initialAmount,,,) = proverStaking.getStakeInfo(prover1, staker1);
        assertEq(initialAmount, 1000e18, "Initial stake should be 1000e18");

        // Request unstake all
        vm.startPrank(staker1);
        proverStaking.requestUnstakeAll(prover1);
        vm.stopPrank();

        // Verify all stake is now pending unstake
        (uint256 remainingAmount, uint256 pendingUnstake, uint256 pendingCount,) =
            proverStaking.getStakeInfo(prover1, staker1);

        assertEq(remainingAmount, 0, "No active stake should remain");
        assertEq(pendingUnstake, 1000e18, "All stake should be pending unstake");
        assertEq(pendingCount, 1, "Should have one pending unstake request");
    }

    function test_RequestUnstakeAll_RevertOnNoStake() public {
        _initializeProver(prover1);

        // Try to unstake all when staker has no stake
        vm.startPrank(staker1);
        vm.expectRevert(TestErrors.InsufficientStake.selector);
        proverStaking.requestUnstakeAll(prover1);
        vm.stopPrank();
    }

    function test_RequestUnstakeAll_RevertOnUnknownProver() public {
        address unknownProver = makeAddr("unknownProver");

        vm.startPrank(staker1);
        vm.expectRevert(TestErrors.ProverNotRegistered.selector);
        proverStaking.requestUnstakeAll(unknownProver);
        vm.stopPrank();
    }

    function test_RequestUnstakeAll_ConsistencyWithRegularUnstake() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 1000e18);
        _stakeToProver(staker2, prover1, 1000e18);

        // Get effective amounts for both stakers
        (uint256 staker2Amount,,,) = proverStaking.getStakeInfo(prover1, staker2);

        // Staker1 uses requestUnstakeAll
        vm.startPrank(staker1);
        proverStaking.requestUnstakeAll(prover1);
        vm.stopPrank();

        // Staker2 uses regular requestUnstake with full amount
        vm.startPrank(staker2);
        proverStaking.requestUnstake(prover1, staker2Amount);
        vm.stopPrank();

        // Both should have identical results
        (, uint256 staker1Pending, uint256 staker1Count,) = proverStaking.getStakeInfo(prover1, staker1);
        (, uint256 staker2Pending, uint256 staker2Count,) = proverStaking.getStakeInfo(prover1, staker2);

        assertEq(staker1Pending, staker2Pending, "Pending amounts should be identical");
        assertEq(staker1Count, staker2Count, "Pending counts should be identical");
    }

    function test_AutoDeactivationOnCompleteUnstake() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 1000e18);

        // Verify prover is initially active
        (ProverStaking.ProverState initialState,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(initialState == ProverStaking.ProverState.Active, "Prover should be active initially");

        // Prover unstakes all - should trigger auto-deactivation
        vm.startPrank(prover1);
        vm.expectEmit(true, false, false, false);
        emit ProverDeactivated(prover1);
        proverStaking.requestUnstakeAll(prover1);
        vm.stopPrank();

        // Verify prover is now deactivated
        (ProverStaking.ProverState finalState,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(finalState == ProverStaking.ProverState.Deactivated, "Prover should be auto-deactivated");

        // Verify existing delegator can still unstake from deactivated prover
        vm.startPrank(staker1);
        proverStaking.requestUnstakeAll(prover1);
        vm.stopPrank();

        // New delegations should be rejected
        vm.startPrank(staker2);
        vm.expectRevert(TestErrors.InvalidProverState.selector);
        proverStaking.stake(prover1, 500e18);
        vm.stopPrank();
    }

    function test_CannotUnretireSlashedProver() public {
        // Initialize prover
        _initializeProver(prover1);

        // Slash prover by maximum allowed (50% slash - brings scale to 0.5 which is above DEACTIVATION_SCALE of 0.2)
        // Need to slash prover multiple times to get below deactivation threshold
        vm.prank(owner);
        proverStaking.slash(prover1, 500000); // 50% slash -> scale becomes 0.5

        vm.prank(owner);
        proverStaking.slash(prover1, 500000); // Another 50% of remaining -> scale becomes 0.25

        vm.prank(owner);
        proverStaking.slash(prover1, 400000); // 40% of remaining -> scale becomes 0.15 (below 0.2 threshold)

        // Prover should be auto-deactivated due to slashing
        (ProverStaking.ProverState state,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(state == ProverStaking.ProverState.Deactivated, "Prover should be deactivated after heavy slash");

        // Unstake remaining and retire
        (uint256 remainingStake,,,) = proverStaking.getStakeInfo(prover1, prover1);
        vm.prank(prover1);
        proverStaking.requestUnstake(prover1, remainingStake);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(prover1);
        proverStaking.completeUnstake(prover1);

        // Retire the prover
        vm.prank(owner);
        proverStaking.retireProver(prover1);

        // Try to stake while retired to meet minimum requirements
        vm.prank(prover1);
        brevToken.approve(address(proverStaking), MIN_SELF_STAKE);
        vm.prank(prover1);
        proverStaking.stake(prover1, MIN_SELF_STAKE);

        // Cannot unretire due to low scale (InvalidScale error)
        vm.expectRevert(TestErrors.InvalidScale.selector);
        vm.prank(prover1);
        proverStaking.unretireProver();
    }

    function test_CannotReactivateSlashedProver() public {
        // Initialize prover
        _initializeProver(prover1);

        // Slash prover by maximum allowed multiple times to get below deactivation threshold
        vm.prank(owner);
        proverStaking.slash(prover1, 500000); // 50% slash -> scale becomes 0.5

        vm.prank(owner);
        proverStaking.slash(prover1, 500000); // Another 50% of remaining -> scale becomes 0.25

        vm.prank(owner);
        proverStaking.slash(prover1, 400000); // 40% of remaining -> scale becomes 0.15 (below 0.2 threshold)

        // Prover should be auto-deactivated due to slashing
        (ProverStaking.ProverState state,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(state == ProverStaking.ProverState.Deactivated, "Prover should be deactivated after heavy slash");

        // Admin cannot reactivate due to low scale (InvalidScale error)
        vm.expectRevert(TestErrors.InvalidScale.selector);
        vm.prank(owner);
        proverStaking.reactivateProver(prover1);
    }

    // ========== HELPER FUNCTIONS ==========

    // Add the event declarations
    event GlobalParamUpdated(ProverStaking.ParamName indexed param, uint256 newValue);

    event ProverDeactivated(address indexed prover);
    event ProverRetired(address indexed prover);
    event ProverUnretired(address indexed prover);
    event ProverReactivated(address indexed prover);
}
