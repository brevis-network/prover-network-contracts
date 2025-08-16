// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {TestErrors} from "./utils/TestErrors.sol";
import {TestProverStaking} from "./TestProverStaking.sol";
import {ProverStaking} from "../src/ProverStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title Staking Test Suite
 * @notice Core tests for staking functionality
 * @dev Tests basic user flows: initialization, staking, unstaking, rewards, slashing
 */
contract StakingTest is Test {
    TestProverStaking public proverStaking;
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
        vm.startPrank(owner);
        proverStaking = new TestProverStaking(address(brevToken), GLOBAL_MIN_SELF_STAKE);

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
        brevToken.approve(address(proverStaking), MIN_SELF_STAKE);

        vm.prank(prover1);
        proverStaking.initProver(MIN_SELF_STAKE, COMMISSION_RATE);

        // Verify prover details
        (
            ProverStaking.ProverState state,
            uint256 minSelfStake,
            uint256 totalStaked,
            uint256 selfEffectiveStake,
            uint256 stakersCount
        ) = proverStaking.getProverInfo(prover1);

        assertTrue(state == ProverStaking.ProverState.Active);
        assertEq(minSelfStake, MIN_SELF_STAKE);
        assertEq(totalStaked, MIN_SELF_STAKE);
        assertEq(stakersCount, 1); // Prover counts as one staker

        // Verify prover's stake
        (uint256 amount, uint256 pendingUnstake, uint256 pendingUnstakeCount, uint256 pendingRewards) =
            proverStaking.getStakeInfo(prover1, prover1);

        assertEq(amount, MIN_SELF_STAKE);
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
        brevToken.approve(address(proverStaking), MIN_SELF_STAKE);

        vm.expectRevert(TestErrors.InvalidProverState.selector);
        vm.prank(prover1);
        proverStaking.initProver(MIN_SELF_STAKE, COMMISSION_RATE);
    }

    function test_RevertOnInvalidCommissionRate() public {
        vm.prank(prover1);
        brevToken.approve(address(proverStaking), MIN_SELF_STAKE);

        vm.expectRevert(TestErrors.InvalidCommission.selector);
        vm.prank(prover1);
        proverStaking.initProver(MIN_SELF_STAKE, 10001); // > 100%
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
        (,, uint256 totalStaked,,) = proverStaking.getProverInfo(prover1);
        assertEq(totalStaked, MIN_SELF_STAKE + stakeAmount);
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
        brevToken.approve(address(proverStaking), MIN_SELF_STAKE);
        vm.prank(prover1);
        proverStaking.initProver(MIN_SELF_STAKE, COMMISSION_RATE);

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

        (,, uint256 totalStakeAfter,,) = proverStaking.getProverInfo(prover1);
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

        (,, uint256 stakeAfter,,) = proverStaking.getProverInfo(prover1);
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
        brevToken.approve(address(proverStaking), MIN_SELF_STAKE);

        vm.prank(prover);
        proverStaking.initProver(MIN_SELF_STAKE, COMMISSION_RATE);
    }

    function test_StakerTracking() public {
        // Initialize prover
        _initializeProver(prover1);

        // Check initial stakers list (should just be the prover)
        address[] memory stakers = proverStaking.getProverStakers(prover1);
        assertEq(stakers.length, 1, "Should have 1 staker initially");
        assertEq(stakers[0], prover1, "Prover should be in stakers list");

        // Check staker count from getProverInfo
        (,,,, uint256 stakerCount) = proverStaking.getProverInfo(prover1);
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
        (,,,, stakerCount) = proverStaking.getProverInfo(prover1);
        assertEq(stakerCount, 2, "Staker count should be 2");

        // Fully unstake one staker
        vm.prank(staker1);
        proverStaking.requestUnstake(prover1, 100e18);

        // Check stakers list after unstaking
        stakers = proverStaking.getProverStakers(prover1);
        assertEq(stakers.length, 1, "Should have 1 staker after unstaking");
        assertEq(stakers[0], prover1, "Only prover should remain in stakers list");

        // Check staker count
        (,,,, stakerCount) = proverStaking.getProverInfo(prover1);
        assertEq(stakerCount, 1, "Staker count should be 1 after unstaking");
    }

    function _stakeToProver(address staker, address prover, uint256 amount) internal {
        vm.prank(staker);
        brevToken.approve(address(proverStaking), amount);

        vm.prank(staker);
        proverStaking.stake(prover, amount);
    }

    // === GLOBAL MIN SELF STAKE TESTS ===

    function test_SetGlobalMinSelfStake() public {
        uint256 newGlobalMin = 75e18;

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit GlobalMinSelfStakeUpdated(GLOBAL_MIN_SELF_STAKE, newGlobalMin);
        proverStaking.setGlobalMinSelfStake(newGlobalMin);

        assertEq(proverStaking.globalMinSelfStake(), newGlobalMin, "Global min self stake should be updated");
    }

    function test_SetMinSelfStakeDecreaseDelay() public {
        uint256 newDelay = 14 days;

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit MinSelfStakeDecreaseDelayUpdated(7 days, newDelay);
        proverStaking.setMinSelfStakeDecreaseDelay(newDelay);

        assertEq(proverStaking.minSelfStakeDecreaseDelay(), newDelay, "MinSelfStake decrease delay should be updated");
    }

    function test_CannotSetMinSelfStakeDecreaseDelayTooLong() public {
        uint256 tooLongDelay = 31 days;

        vm.prank(owner);
        vm.expectRevert(TestErrors.InvalidArg.selector);
        proverStaking.setMinSelfStakeDecreaseDelay(tooLongDelay);
    }

    function test_OnlyOwnerCanSetMinSelfStakeDecreaseDelay() public {
        uint256 newDelay = 14 days;

        vm.prank(user);
        vm.expectRevert();
        proverStaking.setMinSelfStakeDecreaseDelay(newDelay);
    }

    function test_OnlyOwnerCanSetGlobalMinSelfStake() public {
        vm.expectRevert();
        vm.prank(user);
        proverStaking.setGlobalMinSelfStake(2000e18);
    }

    function test_CannotSetZeroGlobalMinSelfStake() public {
        vm.expectRevert(TestErrors.GlobalMinSelfStakeZero.selector);
        vm.prank(owner);
        proverStaking.setGlobalMinSelfStake(0);
    }

    function test_InitProverMeetsGlobalMinimum() public {
        uint256 minSelfStake = 75e18; // Above global minimum

        // Setup tokens for prover
        brevToken.mint(prover2, minSelfStake);
        vm.startPrank(prover2);
        brevToken.approve(address(proverStaking), minSelfStake);

        // Should succeed
        proverStaking.initProver(minSelfStake, COMMISSION_RATE);

        vm.stopPrank();

        (ProverStaking.ProverState state,,,,) = proverStaking.getProverInfo(prover2);
        assertTrue(state == ProverStaking.ProverState.Active);
    }

    function test_InitProverBelowGlobalMinimumFails() public {
        uint256 minSelfStake = 25e18; // Below global minimum of 50e18

        // Setup tokens for prover
        brevToken.mint(prover2, minSelfStake);
        vm.startPrank(prover2);
        brevToken.approve(address(proverStaking), minSelfStake);

        // Should fail
        vm.expectRevert(TestErrors.GlobalMinSelfStakeNotMet.selector);
        proverStaking.initProver(minSelfStake, COMMISSION_RATE);

        vm.stopPrank();
    }

    function test_GlobalMinDoesNotAffectExistingProvers() public {
        // First initialize prover1 with current requirements
        vm.prank(prover1);
        brevToken.approve(address(proverStaking), MIN_SELF_STAKE);
        vm.prank(prover1);
        proverStaking.initProver(MIN_SELF_STAKE, COMMISSION_RATE);

        // Verify prover1 is active
        (ProverStaking.ProverState initialState,,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(initialState == ProverStaking.ProverState.Active);

        // Increase global minimum above prover1's current requirement
        vm.prank(owner);
        proverStaking.setGlobalMinSelfStake(20000e18);

        // prover1 should still be active (not retroactive)
        (ProverStaking.ProverState state1,,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(state1 == ProverStaking.ProverState.Active);

        // But new provers must meet the new requirement
        uint256 lowMinSelfStake = 15000e18; // Below new global minimum

        brevToken.mint(prover2, lowMinSelfStake);
        vm.startPrank(prover2);
        brevToken.approve(address(proverStaking), lowMinSelfStake);

        vm.expectRevert(TestErrors.GlobalMinSelfStakeNotMet.selector);
        proverStaking.initProver(lowMinSelfStake, COMMISSION_RATE);

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
        proverStaking.initProver(1000e18, 1000); // 1000e18 > globalMinSelfStake (50e18)

        // Test 3: Eligible prover with sufficient stake
        (eligible, totalStake) = proverStaking.isProverEligible(prover, 500e18);
        assertTrue(eligible, "Properly initialized prover should be eligible");
        assertEq(totalStake, 1000e18, "Total stake should match self-stake");

        // Test 4: Prover with insufficient total stake
        (eligible, totalStake) = proverStaking.isProverEligible(prover, 2000e18);
        assertFalse(eligible, "Prover with insufficient total stake should not be eligible");
        assertEq(totalStake, 1000e18, "Should still return current total stake");

        // Test 5: Deactivated prover should not be eligible
        vm.prank(owner);
        proverStaking.deactivateProver(prover);
        (eligible, totalStake) = proverStaking.isProverEligible(prover, 500e18);
        assertFalse(eligible, "Deactivated prover should not be eligible");
        assertEq(totalStake, 1000e18, "Deactivated prover should still return actual total stake");

        // Test 6: Prover below global minimum (through global minimum change)
        address prover3 = makeAddr("prover3");
        brevToken.mint(prover3, 10000e18);
        vm.prank(prover3);
        brevToken.approve(address(proverStaking), 10000e18);

        // Initialize with current global minimum
        vm.prank(prover3);
        proverStaking.initProver(50e18, 1000); // Exactly at global minimum

        // Increase global minimum
        vm.prank(owner);
        proverStaking.setGlobalMinSelfStake(100e18);

        (eligible, totalStake) = proverStaking.isProverEligible(prover3, 25e18);
        assertFalse(eligible, "Prover below new global minimum should not be eligible");
        assertEq(totalStake, 50e18, "Should return actual total stake");

        // Test 7: Prover with insufficient actual self-stake due to slashing
        address prover4 = makeAddr("prover4");
        brevToken.mint(prover4, 10000e18);
        vm.prank(prover4);
        brevToken.approve(address(proverStaking), 10000e18);

        vm.prank(prover4);
        proverStaking.initProver(1000e18, 1000);

        // Slash the prover by 50%
        vm.prank(owner);
        proverStaking.slash(prover4, 500000);

        (eligible, totalStake) = proverStaking.isProverEligible(prover4, 200e18);
        assertFalse(eligible, "Slashed prover below minSelfStake should not be eligible");
        assertEq(totalStake, 500e18, "Should return slashed total stake"); // 1000e18 * 0.5 = 500e18
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
        (ProverStaking.ProverState state1,,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(state1 == ProverStaking.ProverState.Active, "Prover should be active");

        // Deactivate prover (admin action)
        vm.expectEmit(true, false, false, false);
        emit ProverDeactivated(prover1);
        vm.prank(owner);
        proverStaking.deactivateProver(prover1);

        // Verify prover is deactivated after deactivation
        (ProverStaking.ProverState state2,,,,) = proverStaking.getProverInfo(prover1);
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

    function test_AdminRetireProver() public {
        // Initialize prover with minimal stake
        vm.prank(prover1);
        brevToken.approve(address(proverStaking), GLOBAL_MIN_SELF_STAKE);
        vm.prank(prover1);
        proverStaking.initProver(GLOBAL_MIN_SELF_STAKE, COMMISSION_RATE);

        // Admin cannot retire with active stakes
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

        // Now admin can retire
        vm.expectEmit(true, false, false, false);
        emit ProverRetired(prover1);
        vm.prank(owner);
        proverStaking.retireProver(prover1);

        // Verify prover is retired
        (ProverStaking.ProverState state,,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(state == ProverStaking.ProverState.Retired, "Prover should be retired");
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
        (ProverStaking.ProverState state1,,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(state1 == ProverStaking.ProverState.Retired, "Prover should be retired");

        // Self-stake while retired to meet minimum requirements
        vm.prank(prover1);
        brevToken.approve(address(proverStaking), MIN_SELF_STAKE);
        vm.prank(prover1);
        proverStaking.stake(prover1, MIN_SELF_STAKE);

        // Unretire prover (state change only)
        vm.expectEmit(true, false, false, false);
        emit ProverUnretired(prover1);
        vm.prank(prover1);
        proverStaking.unretireProver();

        // Verify prover is active again
        (ProverStaking.ProverState state2,,,,) = proverStaking.getProverInfo(prover1);
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
        (ProverStaking.ProverState state1,,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(state1 == ProverStaking.ProverState.Deactivated, "Prover should be deactivated");

        // Admin reactivates prover
        vm.expectEmit(true, false, false, false);
        emit ProverReactivated(prover1);
        vm.prank(owner);
        proverStaking.reactivateProver(prover1);

        // Verify prover is active again
        (ProverStaking.ProverState state2,,,,) = proverStaking.getProverInfo(prover1);
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
        vm.expectRevert(TestErrors.NoStake.selector);
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

    // ========== HELPER FUNCTIONS ==========

    // Add the event declarations
    event GlobalMinSelfStakeUpdated(uint256 oldMinStake, uint256 newMinStake);
    event MinSelfStakeDecreaseDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event ProverDeactivated(address indexed prover);
    event ProverRetired(address indexed prover);
    event ProverUnretired(address indexed prover);
    event ProverReactivated(address indexed prover);
}
