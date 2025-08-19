// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import "forge-std/Test.sol";
import {TestProverStaking} from "./TestProverStaking.sol";
import {ProverStaking} from "../src/ProverStaking.sol";
import {ProverRewards} from "../src/ProverRewards.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title Staking Gas Efficiency Test Suite
 * @notice Tests focusing exclusively on actual gas optimizations
 * @dev Measures gas costs for operations that have real optimizations:
 *      - O(1) slashing via global scale factor (instead of iterating over stakers)
 *      - Gas usage measurements for core operations
 */
contract StakingGasEfficiencyTest is Test {
    TestProverStaking public proverStaking;
    ProverRewards public proverRewards;
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
        vm.startPrank(owner);
        proverStaking = new TestProverStaking(address(brevToken), GLOBAL_MIN_SELF_STAKE);
        proverRewards = new ProverRewards(address(proverStaking), address(brevToken));

        // Set ProverRewards address in ProverStaking
        proverStaking.setProverRewardsContract(address(proverRewards));

        // Grant slasher role to both this test contract and owner for testing
        proverStaking.grantRole(proverStaking.SLASHER_ROLE(), address(this));
        proverStaking.grantRole(proverStaking.SLASHER_ROLE(), owner);
        vm.stopPrank();

        // Mint tokens to participants (same token used for staking and rewards)
        brevToken.mint(prover, INITIAL_SUPPLY);
        brevToken.mint(staker1, INITIAL_SUPPLY);
        brevToken.mint(staker2, INITIAL_SUPPLY);
        brevToken.mint(staker3, INITIAL_SUPPLY);
        brevToken.mint(address(this), INITIAL_SUPPLY); // For reward distribution

        // Approve tokens for the test contract to distribute rewards
        brevToken.approve(address(proverStaking), INITIAL_SUPPLY);
        brevToken.approve(address(proverRewards), INITIAL_SUPPLY);
    }

    // ========== SLASHING EFFICIENCY TESTS ==========

    function test_SlashingEfficiencyWith100Stakers() public {
        console.log("=== O(1) Slashing Efficiency Test: 100 Stakers ===");

        // Initialize prover with self-stake
        vm.prank(prover);
        brevToken.approve(address(proverStaking), MIN_SELF_STAKE);
        vm.prank(prover);
        proverStaking.initProver( COMMISSION_RATE);

        // Add 100 stakers
        address[] memory stakers = new address[](100);
        for (uint256 i = 0; i < 100; i++) {
            stakers[i] = makeAddr(string(abi.encodePacked("staker", i)));
            brevToken.mint(stakers[i], STAKE_AMOUNT);

            vm.prank(stakers[i]);
            brevToken.approve(address(proverStaking), STAKE_AMOUNT);
            vm.prank(stakers[i]);
            proverStaking.stake(prover, STAKE_AMOUNT);
        }

        // Measure slashing gas cost
        uint256 gasBefore = gasleft();
        vm.prank(owner);
        proverStaking.slash(prover, 100000); // 10% slash
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Gas used for slashing 100 stakers:", gasUsed);

        // Should be O(1) - very low gas regardless of staker count
        assertTrue(gasUsed < 100000, "Slashing should be O(1)");
    }

    function test_SlashingEfficiencyWith1000Stakers() public {
        console.log("=== O(1) Slashing Efficiency Test: 1000 Stakers ===");

        // Initialize prover with self-stake
        vm.prank(prover);
        brevToken.approve(address(proverStaking), MIN_SELF_STAKE);
        vm.prank(prover);
        proverStaking.initProver( COMMISSION_RATE);

        // Add 1000 stakers
        for (uint256 i = 0; i < 1000; i++) {
            address staker = makeAddr(string(abi.encodePacked("staker", i)));
            brevToken.mint(staker, STAKE_AMOUNT);

            vm.prank(staker);
            brevToken.approve(address(proverStaking), STAKE_AMOUNT);
            vm.prank(staker);
            proverStaking.stake(prover, STAKE_AMOUNT);
        }

        // Measure slashing gas cost
        uint256 gasBefore = gasleft();
        vm.prank(owner);
        proverStaking.slash(prover, 100000); // 10% slash
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
            brevToken.approve(address(proverStaking), MIN_SELF_STAKE);
            vm.prank(testProver);
            proverStaking.initProver( COMMISSION_RATE);

            // Add stakers
            for (uint256 i = 0; i < stakerCounts[j]; i++) {
                address staker = makeAddr(string(abi.encodePacked("staker", j, "_", i)));
                brevToken.mint(staker, STAKE_AMOUNT);

                vm.prank(staker);
                brevToken.approve(address(proverStaking), STAKE_AMOUNT);
                vm.prank(staker);
                proverStaking.stake(testProver, STAKE_AMOUNT);
            }

            // Measure slashing gas
            uint256 gasBefore = gasleft();
            vm.prank(owner);
            proverStaking.slash(testProver, 50000); // 5% slash
            uint256 gasUsed = gasBefore - gasleft();

            console.log("Stakers:", stakerCounts[j], "Gas:", gasUsed);

            // Gas should remain roughly constant (O(1))
            assertTrue(gasUsed < 150000, "Slashing gas should be bounded");
        }
    }

    function test_MultipleRequestUnstakeEfficiency() public {
        // Setup prover and staker
        vm.prank(prover);
        brevToken.approve(address(proverStaking), MIN_SELF_STAKE);
        vm.prank(prover);
        proverStaking.initProver( 1000);

        vm.prank(staker1);
        brevToken.approve(address(proverStaking), STAKE_AMOUNT);
        vm.prank(staker1);
        proverStaking.stake(prover, STAKE_AMOUNT);

        // Initiate first unstake
        vm.prank(staker1);
        proverStaking.requestUnstake(prover, STAKE_AMOUNT / 2);

        // Initiate second unstake - should now succeed
        vm.prank(staker1);
        proverStaking.requestUnstake(prover, STAKE_AMOUNT / 4);

        // Verify we have 2 pending unstake requests
        (,, uint256 pendingUnstakeCount,) = proverStaking.getStakeInfo(prover, staker1);
        assertEq(pendingUnstakeCount, 2, "Should have 2 pending unstake requests");
    }

    // ========== ACTUAL GAS MEASUREMENT ==========

    function test_GasOptimizedOperations() public {
        console.log("=== Gas Usage for Core Operations ===");

        // Test init prover
        vm.prank(prover);
        brevToken.approve(address(proverStaking), STAKE_AMOUNT);
        uint256 gasUsed = gasleft();
        vm.prank(prover);
        proverStaking.initProver( 1000);
        gasUsed = gasUsed - gasleft();
        console.log("InitProver:", gasUsed);

        // Test staking
        vm.prank(staker1);
        brevToken.approve(address(proverStaking), STAKE_AMOUNT);
        gasUsed = gasleft();
        vm.prank(staker1);
        proverStaking.stake(prover, STAKE_AMOUNT);
        gasUsed = gasUsed - gasleft();
        console.log("Stake:", gasUsed);

        // Test reward distribution
        brevToken.transfer(address(proverRewards), 100e18);
        gasUsed = gasleft();
        proverRewards.addRewards(prover, 100e18);
        gasUsed = gasUsed - gasleft();
        console.log("Add rewards:", gasUsed);

        // Test reward withdrawal
        gasUsed = gasleft();
        vm.prank(staker1);
        proverRewards.withdrawRewards(prover);
        gasUsed = gasUsed - gasleft();
        console.log("Withdraw rewards:", gasUsed);
    }
}
