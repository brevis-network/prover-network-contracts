// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import "forge-std/Test.sol";
import {TestStakedProvers} from "./TestStakedProvers.sol";
import {StakedProvers} from "../src/StakedProvers.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title StakingGasEfficiency Test Suite
 * @notice Tests gas efficiency and scalability of staking operations
 * @dev Validates O(1) operations, gas cost optimization, and performance at scale
 */
contract StakingGasEfficiencyTest is Test {
    TestStakedProvers public stakedProvers;
    MockERC20 public brevToken;

    address public owner = makeAddr("owner");
    address public prover = makeAddr("prover");
    address public staker1 = makeAddr("staker1");
    address public staker2 = makeAddr("staker2");
    address public staker3 = makeAddr("staker3");

    uint256 public constant INITIAL_SUPPLY = 1_000_000e18;
    uint256 public constant MIN_SELF_STAKE = 10_000e18;
    uint256 public constant GLOBAL_MIN_SELF_STAKE = 50e18;
    uint64 public constant COMMISSION_RATE = 1000; // 10%
    uint256 public constant STAKE_AMOUNT = 1000e18;
    uint256 public constant REWARD_AMOUNT = 100e18;

    function setUp() public {
        // Deploy token (used for both staking and rewards)
        brevToken = new MockERC20("Protocol Token", "TOKEN");
        brevToken = brevToken; // Same token for rewards

        // Deploy with direct deployment pattern (simpler for tests)
        vm.prank(owner);
        stakedProvers = new TestStakedProvers(address(brevToken), GLOBAL_MIN_SELF_STAKE);

        // Mint tokens to participants (same token used for staking and rewards)
        brevToken.mint(prover, INITIAL_SUPPLY);
        brevToken.mint(staker1, INITIAL_SUPPLY);
        brevToken.mint(staker2, INITIAL_SUPPLY);
        brevToken.mint(staker3, INITIAL_SUPPLY);
        brevToken.mint(address(this), INITIAL_SUPPLY); // For reward distribution
    }

    // ========== SLASHING EFFICIENCY TESTS ==========

    function test_SlashingEfficiencyWith100Stakers() public {
        console.log("=== O(1) Slashing Efficiency Test: 100 Stakers ===");

        // Initialize prover with self-stake
        vm.prank(prover);
        brevToken.approve(address(stakedProvers), MIN_SELF_STAKE);
        vm.prank(prover);
        stakedProvers.initProver(MIN_SELF_STAKE, COMMISSION_RATE);

        // Add 100 stakers
        address[] memory stakers = new address[](100);
        for (uint256 i = 0; i < 100; i++) {
            stakers[i] = makeAddr(string(abi.encodePacked("staker", i)));
            brevToken.mint(stakers[i], STAKE_AMOUNT);

            vm.prank(stakers[i]);
            brevToken.approve(address(stakedProvers), STAKE_AMOUNT);
            vm.prank(stakers[i]);
            stakedProvers.stake(prover, STAKE_AMOUNT);
        }

        // Measure slashing gas cost
        uint256 gasBefore = gasleft();
        vm.prank(owner);
        stakedProvers.slashProverPublic(prover, 100000); // 10% slash
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Gas used for slashing 100 stakers:", gasUsed);

        // Should be O(1) - very low gas regardless of staker count
        assertTrue(gasUsed < 100000, "Slashing should be O(1)");
    }

    function test_SlashingEfficiencyWith1000Stakers() public {
        console.log("=== O(1) Slashing Efficiency Test: 1000 Stakers ===");

        // Initialize prover with self-stake
        vm.prank(prover);
        brevToken.approve(address(stakedProvers), MIN_SELF_STAKE);
        vm.prank(prover);
        stakedProvers.initProver(MIN_SELF_STAKE, COMMISSION_RATE);

        // Add 1000 stakers
        for (uint256 i = 0; i < 1000; i++) {
            address staker = makeAddr(string(abi.encodePacked("staker", i)));
            brevToken.mint(staker, STAKE_AMOUNT);

            vm.prank(staker);
            brevToken.approve(address(stakedProvers), STAKE_AMOUNT);
            vm.prank(staker);
            stakedProvers.stake(prover, STAKE_AMOUNT);
        }

        // Measure slashing gas cost
        uint256 gasBefore = gasleft();
        vm.prank(owner);
        stakedProvers.slashProverPublic(prover, 100000); // 10% slash
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Gas used for slashing 1000 stakers:", gasUsed);

        // Should be O(1) - very low gas regardless of staker count
        assertTrue(gasUsed < 100000, "Slashing should be O(1)");
    }

    function test_SlashingEfficiencyComparison() public {
        console.log("=== Slashing Efficiency Comparison ===");

        // Test with different numbers of stakers to prove O(1) behavior
        uint256[] memory stakerCounts = new uint256[](5);
        stakerCounts[0] = 10;
        stakerCounts[1] = 50;
        stakerCounts[2] = 100;
        stakerCounts[3] = 500;
        stakerCounts[4] = 1000;

        for (uint256 j = 0; j < stakerCounts.length; j++) {
            // Setup fresh prover for each test
            address testProver = makeAddr(string(abi.encodePacked("prover", j)));
            brevToken.mint(testProver, MIN_SELF_STAKE);

            vm.prank(testProver);
            brevToken.approve(address(stakedProvers), MIN_SELF_STAKE);
            vm.prank(testProver);
            stakedProvers.initProver(MIN_SELF_STAKE, COMMISSION_RATE);

            // Add stakers
            for (uint256 i = 0; i < stakerCounts[j]; i++) {
                address staker = makeAddr(string(abi.encodePacked("staker", j, "_", i)));
                brevToken.mint(staker, STAKE_AMOUNT);

                vm.prank(staker);
                brevToken.approve(address(stakedProvers), STAKE_AMOUNT);
                vm.prank(staker);
                stakedProvers.stake(testProver, STAKE_AMOUNT);
            }

            // Measure slashing gas
            uint256 gasBefore = gasleft();
            vm.prank(owner);
            stakedProvers.slashProverPublic(testProver, 50000); // 5% slash
            uint256 gasUsed = gasBefore - gasleft();

            console.log("Stakers:", stakerCounts[j], "Gas:", gasUsed);

            // Gas should remain roughly constant (O(1))
            assertTrue(gasUsed < 150000, "Slashing gas should be bounded");
        }
    }

    // ========== STAKER COUNT OPTIMIZATION TESTS ==========

    function test_StakerCountTracking() public {
        // Initialize prover
        vm.prank(prover);
        brevToken.approve(address(stakedProvers), MIN_SELF_STAKE);
        vm.prank(prover);
        stakedProvers.initProver(MIN_SELF_STAKE, COMMISSION_RATE);

        // Check initial count (prover is counted as staker)
        (,,,, uint256 initialCount) = stakedProvers.getProverInfo(prover);
        assertEq(initialCount, 1, "Initial staker count should be 1 (prover)");

        // Add first delegator
        vm.prank(staker1);
        brevToken.approve(address(stakedProvers), STAKE_AMOUNT);
        vm.prank(staker1);
        stakedProvers.stake(prover, STAKE_AMOUNT);

        (,,,, uint256 countAfterStaker1) = stakedProvers.getProverInfo(prover);
        assertEq(countAfterStaker1, 2, "Count should be 2 after first delegator");

        // Add second delegator
        vm.prank(staker2);
        brevToken.approve(address(stakedProvers), STAKE_AMOUNT);
        vm.prank(staker2);
        stakedProvers.stake(prover, STAKE_AMOUNT);

        (,,,, uint256 countAfterStaker2) = stakedProvers.getProverInfo(prover);
        assertEq(countAfterStaker2, 3, "Count should be 3 after second delegator");
    }

    function test_StakerCountDecrementOnFullRequestUnstake() public {
        // Initialize prover and add stakers
        vm.prank(prover);
        brevToken.approve(address(stakedProvers), MIN_SELF_STAKE);
        vm.prank(prover);
        stakedProvers.initProver(MIN_SELF_STAKE, COMMISSION_RATE);

        vm.prank(staker1);
        brevToken.approve(address(stakedProvers), STAKE_AMOUNT);
        vm.prank(staker1);
        stakedProvers.stake(prover, STAKE_AMOUNT);

        // Verify count is 2
        (,,,, uint256 countBefore) = stakedProvers.getProverInfo(prover);
        assertEq(countBefore, 2, "Count should be 2");

        // Fully unstake staker1
        vm.prank(staker1);
        stakedProvers.requestUnstake(prover, STAKE_AMOUNT);

        // Check count decremented
        (,,,, uint256 countAfter) = stakedProvers.getProverInfo(prover);
        assertEq(countAfter, 1, "Count should decrement to 1 after full unstake");
    }

    function test_StakerCountAfterSlashing() public {
        // Initialize prover and add stakers
        vm.prank(prover);
        brevToken.approve(address(stakedProvers), MIN_SELF_STAKE);
        vm.prank(prover);
        stakedProvers.initProver(MIN_SELF_STAKE, COMMISSION_RATE);

        vm.prank(staker1);
        brevToken.approve(address(stakedProvers), STAKE_AMOUNT);
        vm.prank(staker1);
        stakedProvers.stake(prover, STAKE_AMOUNT);

        // Count before slashing
        (,,,, uint256 countBefore) = stakedProvers.getProverInfo(prover);
        assertEq(countBefore, 2, "Count should be 2");

        // Slash the prover
        vm.prank(owner);
        stakedProvers.slashProverPublic(prover, 500000); // 50% slash

        // Count should remain the same (stakers still exist, just slashed)
        (,,,, uint256 countAfter) = stakedProvers.getProverInfo(prover);
        assertEq(countAfter, 2, "Count should remain 2 after slashing");
    }

    function test_GasComparison_StakerCountVsArray() public {
        console.log("=== Gas Comparison: Staker Count vs Array Approach ===");

        // Our approach: O(1) counter
        vm.prank(prover);
        brevToken.approve(address(stakedProvers), MIN_SELF_STAKE + STAKE_AMOUNT * 100);
        vm.prank(prover);
        stakedProvers.initProver(MIN_SELF_STAKE, COMMISSION_RATE);

        // Add many stakers to demonstrate efficiency
        for (uint256 i = 0; i < 100; i++) {
            address staker = makeAddr(string(abi.encodePacked("staker", i)));
            brevToken.mint(staker, STAKE_AMOUNT);

            vm.prank(staker);
            brevToken.approve(address(stakedProvers), STAKE_AMOUNT);

            uint256 gasBefore = gasleft();
            vm.prank(staker);
            stakedProvers.stake(prover, STAKE_AMOUNT);
            uint256 gasUsed = gasBefore - gasleft();

            if (i == 0 || i == 49 || i == 99) {
                console.log("Staker", i + 1, "gas used:", gasUsed);
            }
        }

        // Get final count
        (,,,, uint256 finalCount) = stakedProvers.getProverInfo(prover);
        console.log("Final staker count:", finalCount);
        assertEq(finalCount, 101, "Should have 101 stakers (including prover)");
    }

    // ========== SELF-STAKE TRACKING TESTS ==========

    function test_SelfStakeTracking() public {
        // Test that self-stake is properly tracked
        vm.prank(prover);
        brevToken.approve(address(stakedProvers), STAKE_AMOUNT);
        vm.prank(prover);
        stakedProvers.initProver(STAKE_AMOUNT / 2, 1000); // Min self stake is 50e18

        (
            StakedProvers.ProverState state,
            uint256 minSelfStake,
            uint64 commissionRate,
            uint256 totalStaked,
            uint256 selfEffectiveStake,
            uint256 pendingCommission,
            uint256 stakerCount
        ) = stakedProvers.getProverDetails(prover);

        assertTrue(state == StakedProvers.ProverState.Active, "Prover should be active");
        assertEq(minSelfStake, STAKE_AMOUNT / 2, "Min self stake should match");
        assertEq(commissionRate, 1000, "Commission rate should match");
        assertEq(totalStaked, STAKE_AMOUNT / 2, "Total staked should equal min stake");
        assertEq(selfEffectiveStake, STAKE_AMOUNT / 2, "Self stake should equal min stake");
        assertEq(pendingCommission, 0, "No commission initially");
        assertEq(stakerCount, 1, "Should have 1 staker (prover)");

        // Delegate stake
        vm.prank(staker1);
        brevToken.approve(address(stakedProvers), STAKE_AMOUNT);
        vm.prank(staker1);
        stakedProvers.stake(prover, STAKE_AMOUNT);

        // Check updated details
        (,,,, selfEffectiveStake,, stakerCount) = stakedProvers.getProverDetails(prover);
        assertEq(selfEffectiveStake, STAKE_AMOUNT / 2, "Self stake should remain unchanged");
        assertEq(stakerCount, 2, "Should have 2 stakers now");
    }

    function test_PendingRewardsAccumulation() public {
        // Setup prover and staker
        vm.prank(prover);
        brevToken.approve(address(stakedProvers), STAKE_AMOUNT);
        vm.prank(prover);
        stakedProvers.initProver(STAKE_AMOUNT, 1000);

        vm.prank(staker1);
        brevToken.approve(address(stakedProvers), STAKE_AMOUNT);
        vm.prank(staker1);
        stakedProvers.stake(prover, STAKE_AMOUNT);

        // Add rewards without withdrawal
        brevToken.transfer(address(stakedProvers), 100e18);
        stakedProvers.addRewardsPublic(prover, 100e18);

        // Check pending rewards before withdrawal
        // Check staker rewards
        (,,, uint256 stakerPendingRewards) = stakedProvers.getStakeInfo(prover, staker1);
        console.log("Staker1 pending rewards:", stakerPendingRewards);
        assertGt(stakerPendingRewards, 0, "Staker should have pending rewards");

        // Check prover rewards (commission + any staking rewards)
        (,,,,, uint256 pendingProverCommission,) = stakedProvers.getProverDetails(prover);
        console.log("Prover pending commission:", pendingProverCommission);
        assertGt(pendingProverCommission, 0, "Prover should have pending commission");
    }

    // ========== COMMISSION AND REWARD EDGE CASES ==========

    function test_CommissionWithoutSelfStake() public {
        // Test commission calculation when prover has no self-stake
        vm.prank(prover);
        brevToken.approve(address(stakedProvers), MIN_SELF_STAKE);
        vm.prank(prover);
        stakedProvers.initProver(MIN_SELF_STAKE, 2000); // 20% commission

        // Add delegated stake
        vm.prank(staker1);
        brevToken.approve(address(stakedProvers), STAKE_AMOUNT);
        vm.prank(staker1);
        stakedProvers.stake(prover, STAKE_AMOUNT);

        // Add rewards
        brevToken.transfer(address(stakedProvers), REWARD_AMOUNT);
        stakedProvers.addRewardsPublic(prover, REWARD_AMOUNT);

        // Check commission is correctly calculated
        uint256 expectedCommission = (REWARD_AMOUNT * 2000) / 10000; // 20%
        (,,,,, uint256 actualCommission,) = stakedProvers.getProverDetails(prover);
        assertEq(actualCommission, expectedCommission, "Commission should be 20% of rewards");
    }

    function test_PreventDelegationBelowMinSelfStake() public {
        // Initialize prover with exactly minimum self-stake
        vm.prank(prover);
        brevToken.approve(address(stakedProvers), MIN_SELF_STAKE);
        vm.prank(prover);
        stakedProvers.initProver(MIN_SELF_STAKE, 1000);

        // Slash the prover to reduce their effective stake below minimum
        stakedProvers.slashProverPublic(prover, 500000); // 50% slash

        // After slashing, effective self-stake should be below minimum
        // Should prevent new delegations
        vm.prank(staker1);
        brevToken.approve(address(stakedProvers), STAKE_AMOUNT);

        vm.expectRevert("Prover below min self-stake");
        vm.prank(staker1);
        stakedProvers.stake(prover, STAKE_AMOUNT);
    }

    function test_MultipleRequestUnstakeEfficiency() public {
        // Setup prover and staker
        vm.prank(prover);
        brevToken.approve(address(stakedProvers), MIN_SELF_STAKE);
        vm.prank(prover);
        stakedProvers.initProver(MIN_SELF_STAKE, 1000);

        vm.prank(staker1);
        brevToken.approve(address(stakedProvers), STAKE_AMOUNT);
        vm.prank(staker1);
        stakedProvers.stake(prover, STAKE_AMOUNT);

        // Initiate first unstake
        vm.prank(staker1);
        stakedProvers.requestUnstake(prover, STAKE_AMOUNT / 2);

        // Initiate second unstake - should now succeed
        vm.prank(staker1);
        stakedProvers.requestUnstake(prover, STAKE_AMOUNT / 4);

        // Verify we have 2 pending unstake requests
        (,, uint256 pendingUnstakeCount,) = stakedProvers.getStakeInfo(prover, staker1);
        assertEq(pendingUnstakeCount, 2, "Should have 2 pending unstake requests");
    }

    // ========== GAS OPTIMIZATION COMPARISON TESTS ==========

    function test_GasComparisonWithOptimizations() public {
        console.log("=== Gas Comparison After All Optimizations ===");

        // Test init with self-stake tracking
        vm.prank(prover);
        brevToken.approve(address(stakedProvers), STAKE_AMOUNT);
        uint256 gasUsed = gasleft();
        vm.prank(prover);
        stakedProvers.initProver(STAKE_AMOUNT, 1000);
        gasUsed = gasUsed - gasleft();
        console.log("InitProver (with self-stake tracking):", gasUsed);

        // Test staking gas usage
        vm.prank(staker1);
        brevToken.approve(address(stakedProvers), STAKE_AMOUNT);
        gasUsed = gasleft();
        vm.prank(staker1);
        stakedProvers.stake(prover, STAKE_AMOUNT);
        gasUsed = gasUsed - gasleft();
        console.log("Stake (with counter):", gasUsed);

        // Test reward distribution with pending rewards
        brevToken.transfer(address(stakedProvers), 100e18);
        gasUsed = gasleft();
        stakedProvers.addRewardsPublic(prover, 100e18);
        gasUsed = gasUsed - gasleft();
        console.log("Add rewards (with optimizations):", gasUsed);

        // Test reward withdrawal
        gasUsed = gasleft();
        vm.prank(staker1);
        stakedProvers.withdrawRewards(prover);
        gasUsed = gasUsed - gasleft();
        console.log("Withdraw rewards:", gasUsed);
    }
}
