// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StakingController} from "../../src/staking/controller/StakingController.sol";
import {VaultFactory} from "../../src/staking/vault/VaultFactory.sol";
import {ProverVault} from "../../src/staking/vault/ProverVault.sol";
import {IStakingController} from "../../src/staking/interfaces/IStakingController.sol";
import {IProverVault} from "../../src/staking/interfaces/IProverVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract RewardsTest is Test {
    StakingController public controller;
    VaultFactory public factory;
    MockERC20 public stakingToken;

    address public admin = makeAddr("admin");
    address public prover1 = makeAddr("prover1");
    address public prover2 = makeAddr("prover2");
    address public staker1 = makeAddr("staker1");
    address public staker2 = makeAddr("staker2");
    address public rewardPayer = makeAddr("rewardPayer");

    uint256 public constant INITIAL_MINT = 1000000e18;
    uint256 public constant INITIAL_UNBOND_DELAY = 7 days;
    uint256 public constant MIN_SELF_STAKE = 100e18;

    function setUp() public {
        vm.startPrank(admin);

        stakingToken = new MockERC20("Staking Token", "STK");
        stakingToken.mint(admin, INITIAL_MINT);

        factory = new VaultFactory();

        controller = new StakingController(
            address(stakingToken),
            address(factory),
            INITIAL_UNBOND_DELAY,
            1e18, // minSelfStake: 1 token
            5000 // maxSlashBps: 50%
        );

        // Grant roles
        factory.init(address(controller));

        // Grant slasher role to admin for testing
        controller.grantRole(controller.SLASHER_ROLE(), admin);

        // Transfer ownership to admin
        controller.transferOwnership(admin);

        // Set MinSelfStake parameter
        controller.setMinSelfStake(MIN_SELF_STAKE);

        vm.stopPrank();

        // Setup provers
        stakingToken.mint(prover1, 1000e18);
        stakingToken.mint(prover2, 1000e18);

        // Setup stakers
        stakingToken.mint(staker1, 1000e18);
        stakingToken.mint(staker2, 1000e18);
        stakingToken.mint(rewardPayer, 10000e18); // More tokens for reward testing
    }

    // ===============================
    // COMMISSION MANAGEMENT TESTS
    // ===============================

    function testUpdateCommissionRate() public {
        // Setup prover approval
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(1000); // 10% commission

        // Update commission rate
        uint64 newRate = 1500; // 15%
        vm.prank(prover1);
        controller.setCommissionRate(address(0), newRate); // Update default rate

        // Verify update
        (,, uint64 commissionRate,,,,) = controller.getProverInfo(prover1);
        assertEq(commissionRate, newRate);
    }

    function testDeactivatedProverCanClaimCommission() public {
        // Setup prover approval
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(1000); // 10% commission

        // Add rewards to generate commission
        uint256 rewardAmount = 100e18;
        vm.startPrank(rewardPayer);
        stakingToken.approve(address(controller), rewardAmount);
        controller.addRewards(prover1, rewardAmount);
        vm.stopPrank();

        // Deactivate prover
        vm.prank(admin);
        controller.deactivateProver(prover1);

        // Prover should still be able to claim commission
        uint256 balanceBefore = stakingToken.balanceOf(prover1);
        vm.prank(prover1);
        uint256 claimed = controller.claimCommission();
        uint256 balanceAfter = stakingToken.balanceOf(prover1);

        assertTrue(claimed > 0, "Should be able to claim commission even when deactivated");
        assertEq(balanceAfter - balanceBefore, claimed, "Balance should increase by claimed amount");
    }

    function testSourceBasedCommissionRates() public {
        // Setup prover
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);
        vm.prank(prover1);
        controller.initializeProver(1000); // 10% default commission

        // Create different reward sources
        address marketSource = makeAddr("marketSource");
        address foundationSource = makeAddr("foundationSource");

        // Set different commission rates for different sources
        vm.prank(prover1);
        controller.setCommissionRate(marketSource, 2000); // 20% for market rewards
        vm.prank(prover1);
        controller.setCommissionRate(foundationSource, 500); // 5% for foundation rewards

        // Test rewards from different sources
        uint256 rewardAmount = 100e18;

        // Market rewards (20% commission)
        stakingToken.mint(marketSource, rewardAmount);
        vm.startPrank(marketSource);
        stakingToken.approve(address(controller), rewardAmount);
        (uint256 marketCommission,) = controller.addRewards(prover1, rewardAmount);
        vm.stopPrank();

        uint256 expectedMarketCommission = (rewardAmount * 2000) / 10000;
        assertEq(marketCommission, expectedMarketCommission, "Market commission should be 20%");

        // Foundation rewards (5% commission)
        stakingToken.mint(foundationSource, rewardAmount);
        vm.startPrank(foundationSource);
        stakingToken.approve(address(controller), rewardAmount);
        (uint256 foundationCommission,) = controller.addRewards(prover1, rewardAmount);
        vm.stopPrank();

        uint256 expectedFoundationCommission = (rewardAmount * 500) / 10000;
        assertEq(foundationCommission, expectedFoundationCommission, "Foundation commission should be 5%");

        // Default source (10% commission)
        address defaultSource = makeAddr("defaultSource");
        stakingToken.mint(defaultSource, rewardAmount);
        vm.startPrank(defaultSource);
        stakingToken.approve(address(controller), rewardAmount);
        (uint256 defaultCommission,) = controller.addRewards(prover1, rewardAmount);
        vm.stopPrank();

        uint256 expectedDefaultCommission = (rewardAmount * 1000) / 10000;
        assertEq(defaultCommission, expectedDefaultCommission, "Default commission should be 10%");
    }

    function testGetCommissionRatesFunction() public {
        // Setup prover
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);
        vm.prank(prover1);
        controller.initializeProver(1500); // 15% default commission

        // Initially should only have default rate
        (address[] memory sources, uint64[] memory rates) = controller.getCommissionRates(prover1);
        assertEq(sources.length, 1, "Should have only default rate initially");
        assertEq(sources[0], address(0), "First source should be address(0)");
        assertEq(rates[0], 1500, "Default rate should be 15%");

        // Add custom rates
        address source1 = makeAddr("source1");
        address source2 = makeAddr("source2");

        vm.prank(prover1);
        controller.setCommissionRate(source1, 2000); // 20%
        vm.prank(prover1);
        controller.setCommissionRate(source2, 500); // 5%

        // Check updated rates
        (sources, rates) = controller.getCommissionRates(prover1);
        assertEq(sources.length, 3, "Should have 3 rates (default + 2 custom)");
        assertEq(sources[0], address(0), "First source should still be address(0)");
        assertEq(rates[0], 1500, "Default rate should still be 15%");

        // Find custom rates (order may vary due to EnumerableMap)
        bool foundSource1 = false;
        bool foundSource2 = false;
        for (uint256 i = 1; i < sources.length; i++) {
            if (sources[i] == source1) {
                assertEq(rates[i], 2000, "Source1 rate should be 20%");
                foundSource1 = true;
            } else if (sources[i] == source2) {
                assertEq(rates[i], 500, "Source2 rate should be 5%");
                foundSource2 = true;
            }
        }
        assertTrue(foundSource1, "Should find source1 in results");
        assertTrue(foundSource2, "Should find source2 in results");
    }

    function testGetCommissionRateFunction() public {
        // Setup prover
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);
        vm.prank(prover1);
        controller.initializeProver(1200); // 12% default commission

        address customSource = makeAddr("customSource");
        address unknownSource = makeAddr("unknownSource");

        // Test default rate
        uint64 defaultRate = controller.getCommissionRate(prover1, address(0));
        assertEq(defaultRate, 1200, "Default rate should be 12%");

        // Test unknown source falls back to default
        uint64 unknownRate = controller.getCommissionRate(prover1, unknownSource);
        assertEq(unknownRate, 1200, "Unknown source should use default rate");

        // Set custom rate
        vm.prank(prover1);
        controller.setCommissionRate(customSource, 1800); // 18%

        // Test custom rate
        uint64 customRate = controller.getCommissionRate(prover1, customSource);
        assertEq(customRate, 1800, "Custom source should have 18% rate");

        // Test that default is still unchanged
        defaultRate = controller.getCommissionRate(prover1, address(0));
        assertEq(defaultRate, 1200, "Default rate should still be 12%");
    }

    function testResetCommissionRate() public {
        // Setup prover
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);
        vm.prank(prover1);
        controller.initializeProver(1000); // 10% default commission

        address customSource = makeAddr("customSource");

        // Set custom rate
        vm.prank(prover1);
        controller.setCommissionRate(customSource, 2500); // 25%

        // Verify custom rate is set
        uint64 customRate = controller.getCommissionRate(prover1, customSource);
        assertEq(customRate, 2500, "Custom rate should be 25%");

        // Reset to default
        vm.prank(prover1);
        controller.resetCommissionRate(customSource);

        // Verify it now uses default rate
        uint64 resetRate = controller.getCommissionRate(prover1, customSource);
        assertEq(resetRate, 1000, "Should use default rate after reset");

        // Check that custom source is removed from list
        (address[] memory sources,) = controller.getCommissionRates(prover1);
        assertEq(sources.length, 1, "Should only have default rate after reset");
        assertEq(sources[0], address(0), "Only remaining source should be address(0)");
    }

    function testExplicitZeroCommissionRate() public {
        // Setup prover
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);
        vm.prank(prover1);
        controller.initializeProver(1000); // 10% default commission

        address zeroSource = makeAddr("zeroSource");

        // Explicitly set 0% commission for a source
        vm.prank(prover1);
        controller.setCommissionRate(zeroSource, 0);

        // Verify 0% commission is honored (not falling back to default)
        uint64 zeroRate = controller.getCommissionRate(prover1, zeroSource);
        assertEq(zeroRate, 0, "Explicit zero rate should be 0%");

        // Test rewards with 0% commission
        uint256 rewardAmount = 100e18;
        stakingToken.mint(zeroSource, rewardAmount);
        vm.startPrank(zeroSource);
        stakingToken.approve(address(controller), rewardAmount);
        (uint256 commission, uint256 toStakers) = controller.addRewards(prover1, rewardAmount);
        vm.stopPrank();

        assertEq(commission, 0, "Commission should be 0");
        assertEq(toStakers, rewardAmount, "All rewards should go to stakers");
    }

    function testDeactivatedProverCannotReceiveNewRewards() public {
        // Setup prover approval
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Deactivate prover
        vm.prank(admin);
        controller.deactivateProver(prover1);

        // Try to add rewards - should revert
        uint256 rewardAmount = 100e18;
        vm.startPrank(rewardPayer);
        stakingToken.approve(address(controller), rewardAmount);
        vm.expectRevert(IStakingController.ControllerProverNotActive.selector);
        controller.addRewards(prover1, rewardAmount);
        vm.stopPrank();
    }

    function testProverExitCanStillClaimCommission() public {
        // Setup prover approval
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Add rewards to generate commission
        uint256 rewardAmount = 100e18;
        vm.startPrank(rewardPayer);
        stakingToken.approve(address(controller), rewardAmount);
        controller.addRewards(prover1, rewardAmount);
        vm.stopPrank();

        // Prover exits (deactivates themselves)
        vm.prank(admin);
        controller.deactivateProver(prover1);

        // Should still be able to claim accumulated commission
        uint256 balanceBefore = stakingToken.balanceOf(prover1);
        vm.prank(prover1);
        uint256 claimed = controller.claimCommission();
        uint256 balanceAfter = stakingToken.balanceOf(prover1);

        assertTrue(claimed > 0, "Should be able to claim commission after exit");
        assertEq(balanceAfter - balanceBefore, claimed, "Balance should increase correctly");

        // Verify no pending commission left
        (,,, uint256 pendingCommission,,,) = controller.getProverInfo(prover1);
        assertEq(pendingCommission, 0, "No pending commission should remain");
    }

    // ===============================
    // ADVANCED COMMISSION & REWARDS TESTS
    // ===============================

    function testAddRewardsRevertsWhenProverCompletelyExits() public {
        // Create a second prover to test donation guard
        vm.prank(prover2);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        vm.startPrank(prover2);
        address vault2 = controller.initializeProver(1000); // 10% commission

        // Unstake everything to make the vault empty
        IProverVault proverVault2 = IProverVault(vault2);
        uint256 shares = proverVault2.balanceOf(prover2);
        proverVault2.approve(address(controller), shares);
        controller.requestUnstake(prover2, shares);

        // Complete unstaking
        skip(INITIAL_UNBOND_DELAY + 1);
        controller.completeUnstake(prover2);
        vm.stopPrank();

        // Verify vault has no shares
        assertEq(proverVault2.totalSupply(), 0, "Vault should have no shares");

        // The prover should be auto-deactivated, so trying to add rewards should fail with ControllerProverNotActive
        uint256 rewardAmount = 100e18;
        vm.startPrank(rewardPayer);
        stakingToken.approve(address(controller), rewardAmount);
        vm.expectRevert(IStakingController.ControllerProverNotActive.selector);
        controller.addRewards(prover2, rewardAmount);
        vm.stopPrank();
    }

    function testMultipleAddRewardsAccumulatePendingCommissionCorrectly() public {
        // Setup prover
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        vm.prank(prover1);
        controller.initializeProver(1000); // 10% commission

        // Add some external stake to prevent donation guard
        vm.startPrank(staker1);
        stakingToken.approve(address(controller), 200e18);
        controller.stake(prover1, 200e18);
        vm.stopPrank();

        // Add first rewards
        uint256 firstReward = 100e18;
        vm.startPrank(rewardPayer);
        stakingToken.approve(address(controller), firstReward);
        (uint256 firstCommission, uint256 firstToStakers) = controller.addRewards(prover1, firstReward);
        vm.stopPrank();

        // Verify first commission calculation
        uint256 expectedFirstCommission = (firstReward * 1000) / 10000; // 10%
        assertEq(firstCommission, expectedFirstCommission);
        assertEq(firstToStakers, firstReward - expectedFirstCommission);

        // Check pending commission
        (,,, uint256 pendingAfterFirst,,,) = controller.getProverInfo(prover1);
        assertEq(pendingAfterFirst, expectedFirstCommission);

        // Add second rewards
        uint256 secondReward = 200e18;
        vm.startPrank(rewardPayer);
        stakingToken.approve(address(controller), secondReward);
        (uint256 secondCommission, uint256 secondToStakers) = controller.addRewards(prover1, secondReward);
        vm.stopPrank();

        // Verify second commission calculation
        uint256 expectedSecondCommission = (secondReward * 1000) / 10000; // 10%
        assertEq(secondCommission, expectedSecondCommission);
        assertEq(secondToStakers, secondReward - expectedSecondCommission);

        // Check accumulated pending commission
        (,,, uint256 pendingAfterSecond,,,) = controller.getProverInfo(prover1);
        assertEq(pendingAfterSecond, expectedFirstCommission + expectedSecondCommission);

        // Claim commission and verify transfer and zeroing
        uint256 balanceBefore = stakingToken.balanceOf(prover1);
        vm.prank(prover1);
        uint256 claimed = controller.claimCommission();
        uint256 balanceAfter = stakingToken.balanceOf(prover1);

        assertEq(claimed, expectedFirstCommission + expectedSecondCommission);
        assertEq(balanceAfter - balanceBefore, claimed);

        // Verify pending commission is zeroed
        (,,, uint256 pendingAfterClaim,,,) = controller.getProverInfo(prover1);
        assertEq(pendingAfterClaim, 0);
    }

    function testCommissionRateChangeOnlyAffectsSubsequentRewards() public {
        // Setup prover
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        vm.prank(prover1);
        controller.initializeProver(1000); // 10% commission

        // Add some external stake
        vm.startPrank(staker1);
        stakingToken.approve(address(controller), 200e18);
        controller.stake(prover1, 200e18);
        vm.stopPrank();

        // Add rewards with initial rate
        uint256 firstReward = 100e18;
        vm.startPrank(rewardPayer);
        stakingToken.approve(address(controller), firstReward);
        (uint256 firstCommission,) = controller.addRewards(prover1, firstReward);
        vm.stopPrank();

        uint256 expectedFirstCommission = (firstReward * 1000) / 10000; // 10%
        assertEq(firstCommission, expectedFirstCommission);

        // Change commission rate
        uint64 newRate = 1500; // 15%
        vm.prank(prover1);
        controller.setCommissionRate(address(0), newRate); // Update default rate

        // Add rewards with new rate
        uint256 secondReward = 100e18;
        vm.startPrank(rewardPayer);
        stakingToken.approve(address(controller), secondReward);
        (uint256 secondCommission,) = controller.addRewards(prover1, secondReward);
        vm.stopPrank();

        uint256 expectedSecondCommission = (secondReward * 1500) / 10000; // 15%
        assertEq(secondCommission, expectedSecondCommission);

        // Verify total pending commission uses different rates per call
        (,,, uint256 totalPending,,,) = controller.getProverInfo(prover1);
        assertEq(totalPending, expectedFirstCommission + expectedSecondCommission);
    }

    function testAddRewardsWhilePausedReverts() public {
        // Setup prover
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        vm.prank(prover1);
        controller.initializeProver(1000); // 10% commission

        // Add some external stake
        vm.startPrank(staker1);
        stakingToken.approve(address(controller), 200e18);
        controller.stake(prover1, 200e18);
        vm.stopPrank();

        // Pause the contract
        vm.startPrank(admin);
        controller.grantRole(controller.PAUSER_ROLE(), admin);
        controller.pause();
        vm.stopPrank();

        // Try to add rewards while paused - should revert
        uint256 rewardAmount = 100e18;
        vm.startPrank(rewardPayer);
        stakingToken.approve(address(controller), rewardAmount);
        vm.expectRevert(); // Updated OpenZeppelin uses EnforcedPause()
        controller.addRewards(prover1, rewardAmount);
        vm.stopPrank();
    }

    function testClaimCommissionWhenNoCommissionReturnsZero() public {
        // Setup prover
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        vm.prank(prover1);
        controller.initializeProver(1000); // 10% commission

        // Verify initial state - no pending commission
        (,,, uint256 initialPending,,,) = controller.getProverInfo(prover1);
        assertEq(initialPending, 0);

        // Claim commission when none exists
        uint256 balanceBefore = stakingToken.balanceOf(prover1);
        vm.prank(prover1);
        uint256 claimed = controller.claimCommission();
        uint256 balanceAfter = stakingToken.balanceOf(prover1);

        // Should return 0 and not change balance
        assertEq(claimed, 0);
        assertEq(balanceAfter, balanceBefore);

        // Verify no state changes occurred
        (,,, uint256 pendingAfterClaim,,,) = controller.getProverInfo(prover1);
        assertEq(pendingAfterClaim, 0);
    }

    function testRewardsDistributionCalculations() public {
        // Setup prover with specific commission rate
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        vm.prank(prover1);
        controller.initializeProver(2500); // 25% commission

        // Add external stake
        vm.startPrank(staker1);
        stakingToken.approve(address(controller), 300e18);
        controller.stake(prover1, 300e18);
        vm.stopPrank();

        // Add rewards and verify precise calculations
        uint256 rewardAmount = 1000e18;
        vm.startPrank(rewardPayer);
        stakingToken.approve(address(controller), rewardAmount);
        (uint256 commission, uint256 toStakers) = controller.addRewards(prover1, rewardAmount);
        vm.stopPrank();

        // Verify exact calculations
        uint256 expectedCommission = (rewardAmount * 2500) / 10000; // 25%
        uint256 expectedToStakers = rewardAmount - expectedCommission;

        assertEq(commission, expectedCommission);
        assertEq(toStakers, expectedToStakers);
        assertEq(commission + toStakers, rewardAmount); // Total should equal input

        // Verify vault received the staker portion
        address vault = controller.getProverVault(prover1);
        uint256 vaultAssetsBefore = MIN_SELF_STAKE + 300e18; // initial + stake
        uint256 vaultAssetsAfter = IProverVault(vault).totalAssets();
        assertEq(vaultAssetsAfter, vaultAssetsBefore + expectedToStakers);
    }

    // =========================================================================
    // PRECISION AND EDGE CASE TESTS
    // =========================================================================

    function testTinyRewardDistribution() public {
        // Test: Reward distribution with very small amounts
        // Value: Ensures precision is maintained even with minimal rewards

        // Setup prover
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        vm.prank(prover1);
        controller.initializeProver(1500); // 15% commission

        // Setup staker
        stakingToken.mint(staker1, 100e18);
        vm.startPrank(staker1);
        stakingToken.approve(address(controller), 100e18);
        controller.stake(prover1, 100e18);
        vm.stopPrank();

        // Add tiny reward (1 wei)
        vm.startPrank(rewardPayer);
        stakingToken.approve(address(controller), 1);
        (uint256 commission, uint256 toStakers) = controller.addRewards(prover1, 1);
        vm.stopPrank();

        // With 1500 basis points (15%) and 1 wei reward:
        // commission = (1 * 1500) / 10000 = 0 (rounds down)
        // toStakers = 1 - 0 = 1
        assertEq(commission, 0, "Tiny commission should round down to 0");
        assertEq(toStakers, 1, "Remaining should go to stakers");
        assertEq(commission + toStakers, 1, "Total should equal input");
    }

    function testMaximumRewardDistribution() public {
        // Test: Distribution with very large rewards
        // Value: Ensures no overflow in commission calculations

        // Setup prover
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        vm.prank(prover1);
        controller.initializeProver(1500); // 15% commission

        uint256 maxReward = type(uint128).max; // Large but safe value
        stakingToken.mint(rewardPayer, maxReward);

        // Setup staker
        stakingToken.mint(staker1, 1000e18);
        vm.startPrank(staker1);
        stakingToken.approve(address(controller), 1000e18);
        controller.stake(prover1, 1000e18);
        vm.stopPrank();

        vm.startPrank(rewardPayer);
        stakingToken.approve(address(controller), maxReward);
        (uint256 commission, uint256 toStakers) = controller.addRewards(prover1, maxReward);
        vm.stopPrank();

        // Verify calculations are correct for large amounts
        uint256 expectedCommission = (maxReward * 1500) / 10000;
        uint256 expectedToStakers = maxReward - expectedCommission;

        assertEq(commission, expectedCommission, "Large commission calculation should be accurate");
        assertEq(toStakers, expectedToStakers, "Large staker reward calculation should be accurate");
        assertEq(commission + toStakers, maxReward, "Total should equal large input");
    }

    function testCommissionRoundingEdgeCases() public {
        // Test: Commission calculations that result in rounding
        // Value: Ensures consistent rounding behavior

        // Setup prover
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        vm.prank(prover1);
        controller.initializeProver(1500); // 15% commission

        stakingToken.mint(staker1, 100e18);
        vm.startPrank(staker1);
        stakingToken.approve(address(controller), 100e18);
        controller.stake(prover1, 100e18);
        vm.stopPrank();

        // Test amounts that cause rounding in commission calculation
        uint256[] memory testAmounts = new uint256[](5);
        testAmounts[0] = 7; // 7 * 1500 / 10000 = 1.05 -> 1
        testAmounts[1] = 13; // 13 * 1500 / 10000 = 1.95 -> 1
        testAmounts[2] = 67; // 67 * 1500 / 10000 = 10.05 -> 10
        testAmounts[3] = 133; // 133 * 1500 / 10000 = 19.95 -> 19
        testAmounts[4] = 9999; // 9999 * 1500 / 10000 = 1499.85 -> 1499

        for (uint256 i = 0; i < testAmounts.length; i++) {
            uint256 amount = testAmounts[i];
            stakingToken.mint(rewardPayer, amount);

            vm.startPrank(rewardPayer);
            stakingToken.approve(address(controller), amount);
            (uint256 commission, uint256 toStakers) = controller.addRewards(prover1, amount);
            vm.stopPrank();

            // Verify no funds are lost in rounding
            assertEq(
                commission + toStakers,
                amount,
                string(abi.encodePacked("Total should equal input for amount ", vm.toString(amount)))
            );

            // Commission should be <= expected (due to rounding down)
            uint256 expectedCommission = (amount * 1500) / 10000;
            assertEq(
                commission,
                expectedCommission,
                string(abi.encodePacked("Commission should match calculation for amount ", vm.toString(amount)))
            );
        }
    }

    function testZeroCommissionRate() public {
        // Test: Rewards with zero commission rate
        // Value: Edge case where prover takes no commission

        // Setup prover first
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        vm.prank(prover1);
        controller.initializeProver(1000); // Initialize with any rate first

        // Set commission to 0
        vm.prank(prover1);
        controller.setCommissionRate(address(0), 0); // Set default rate to 0

        stakingToken.mint(staker1, 100e18);
        vm.startPrank(staker1);
        stakingToken.approve(address(controller), 100e18);
        controller.stake(prover1, 100e18);
        vm.stopPrank();

        uint256 rewardAmount = 1000e18;
        vm.startPrank(rewardPayer);
        stakingToken.approve(address(controller), rewardAmount);
        (uint256 commission, uint256 toStakers) = controller.addRewards(prover1, rewardAmount);
        vm.stopPrank();

        assertEq(commission, 0, "Commission should be 0 with 0% rate");
        assertEq(toStakers, rewardAmount, "All rewards should go to stakers");
    }

    function testMaxCommissionRate() public {
        // Test: Rewards with maximum commission rate (50%)
        // Value: Edge case with highest allowed commission

        // Setup prover first
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        vm.prank(prover1);
        controller.initializeProver(1000); // Initialize with any rate first

        // Set commission to maximum (5000 basis points = 50%)
        vm.prank(prover1);
        controller.setCommissionRate(address(0), 5000); // Set default rate to 50%

        stakingToken.mint(staker1, 100e18);
        vm.startPrank(staker1);
        stakingToken.approve(address(controller), 100e18);
        controller.stake(prover1, 100e18);
        vm.stopPrank();

        uint256 rewardAmount = 1000e18;
        vm.startPrank(rewardPayer);
        stakingToken.approve(address(controller), rewardAmount);
        (uint256 commission, uint256 toStakers) = controller.addRewards(prover1, rewardAmount);
        vm.stopPrank();

        uint256 expectedCommission = rewardAmount / 2; // 50%
        assertEq(commission, expectedCommission, "Commission should be 50% of rewards");
        assertEq(toStakers, rewardAmount - expectedCommission, "Remaining should go to stakers");
        assertEq(commission + toStakers, rewardAmount, "Total should equal input");
    }

    function testRewardDistributionWithMultipleStakers() public {
        // Test: Complex reward distribution among multiple stakers
        // Value: Ensures proportional distribution is mathematically correct

        // Setup prover first
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        vm.prank(prover1);
        controller.initializeProver(1500); // 15% commission

        address staker3 = makeAddr("staker3");

        // Setup stakers with different amounts
        uint256[] memory stakes = new uint256[](3);
        stakes[0] = 100e18; // staker1
        stakes[1] = 250e18; // staker2
        stakes[2] = 150e18; // staker3

        address[] memory stakers = new address[](3);
        stakers[0] = staker1;
        stakers[1] = staker2;
        stakers[2] = staker3;

        for (uint256 i = 0; i < 3; i++) {
            stakingToken.mint(stakers[i], stakes[i]);
            vm.startPrank(stakers[i]);
            stakingToken.approve(address(controller), stakes[i]);
            controller.stake(prover1, stakes[i]);
            vm.stopPrank();
        }

        // Record pre-reward shares
        address vault = controller.getProverVault(prover1);
        uint256[] memory preTotSupply = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            preTotSupply[i] = IProverVault(vault).balanceOf(stakers[i]);
        }
        uint256 totalShares = IProverVault(vault).totalSupply();

        // Add rewards
        uint256 rewardAmount = 1000e18;
        vm.startPrank(rewardPayer);
        stakingToken.approve(address(controller), rewardAmount);
        (, uint256 toStakers) = controller.addRewards(prover1, rewardAmount);
        vm.stopPrank();

        // Verify proportional distribution
        for (uint256 i = 0; i < 3; i++) {
            uint256 expectedAssets = IProverVault(vault).convertToAssets(preTotSupply[i]);
            uint256 shareOfReward = (toStakers * preTotSupply[i]) / totalShares;
            uint256 expectedTotal = stakes[i] + shareOfReward;

            // Allow small rounding differences (< 0.01%)
            assertTrue(
                expectedAssets >= expectedTotal - expectedTotal / 10000,
                string(abi.encodePacked("Staker ", vm.toString(i), " should receive proportional reward (lower bound)"))
            );
            assertTrue(
                expectedAssets <= expectedTotal + expectedTotal / 10000,
                string(abi.encodePacked("Staker ", vm.toString(i), " should receive proportional reward (upper bound)"))
            );
        }
    }

    function testRewardAccumulationPrecision() public {
        // Test: Multiple small rewards accumulate correctly
        // Value: Ensures precision doesn't degrade over many operations

        // Setup prover first
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        vm.prank(prover1);
        controller.initializeProver(1500); // 15% commission

        stakingToken.mint(staker1, 1000e18);
        vm.startPrank(staker1);
        stakingToken.approve(address(controller), 1000e18);
        controller.stake(prover1, 1000e18);
        vm.stopPrank();

        address vault = controller.getProverVault(prover1);
        uint256 initialAssets = IProverVault(vault).totalAssets();

        // Add many small rewards
        uint256 smallReward = 1e15; // 0.001 tokens
        uint256 numRewards = 100;
        uint256 totalRewardAmount = smallReward * numRewards;

        stakingToken.mint(rewardPayer, totalRewardAmount);
        vm.startPrank(rewardPayer);
        stakingToken.approve(address(controller), totalRewardAmount);

        uint256 totalCommission = 0;
        uint256 totalToStakers = 0;

        for (uint256 i = 0; i < numRewards; i++) {
            (uint256 commission, uint256 toStakers) = controller.addRewards(prover1, smallReward);
            totalCommission += commission;
            totalToStakers += toStakers;
        }
        vm.stopPrank();

        // Verify accumulation is accurate
        assertEq(totalCommission + totalToStakers, totalRewardAmount, "Total accumulation should equal sum of inputs");

        uint256 finalAssets = IProverVault(vault).totalAssets();
        uint256 expectedFinalAssets = initialAssets + totalToStakers;

        // Should be exactly equal (no precision loss)
        assertEq(finalAssets, expectedFinalAssets, "Final vault assets should match expected accumulation");
    }

    function testRewardDistributionAfterPartialUnstaking() public {
        // Test: Reward distribution after some stakers have unstaked
        // Value: Ensures rewards are properly distributed to remaining stakers

        // Setup prover first
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        vm.prank(prover1);
        controller.initializeProver(1500); // 15% commission

        // Setup two stakers
        stakingToken.mint(staker1, 200e18);
        stakingToken.mint(staker2, 300e18);

        vm.startPrank(staker1);
        stakingToken.approve(address(controller), 200e18);
        controller.stake(prover1, 200e18);
        vm.stopPrank();

        vm.startPrank(staker2);
        stakingToken.approve(address(controller), 300e18);
        controller.stake(prover1, 300e18);
        vm.stopPrank();

        address vault = controller.getProverVault(prover1);

        // staker2 partially unstakes
        vm.startPrank(staker2);
        IProverVault(vault).approve(address(controller), 100e18);
        controller.requestUnstake(prover1, 100e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(staker2);
        controller.completeUnstake(prover1);

        // Record state before rewards
        uint256 staker1Shares = IProverVault(vault).balanceOf(staker1);
        uint256 staker2Shares = IProverVault(vault).balanceOf(staker2);
        uint256 totalShares = IProverVault(vault).totalSupply();

        // Add rewards
        uint256 rewardAmount = 500e18;
        vm.startPrank(rewardPayer);
        stakingToken.approve(address(controller), rewardAmount);
        (, uint256 toStakers) = controller.addRewards(prover1, rewardAmount);
        vm.stopPrank();

        // Verify distribution reflects current stake proportions
        uint256 staker1ExpectedShare = (toStakers * staker1Shares) / totalShares;
        uint256 staker2ExpectedShare = (toStakers * staker2Shares) / totalShares;

        uint256 staker1Assets = IProverVault(vault).convertToAssets(staker1Shares);
        uint256 staker2Assets = IProverVault(vault).convertToAssets(staker2Shares);

        // Verify proportional distribution (allowing for small rounding)
        assertTrue(staker1Assets >= 200e18 + staker1ExpectedShare - 1e15, "Staker1 should receive proportional reward");
        assertTrue(staker2Assets >= 200e18 + staker2ExpectedShare - 1e15, "Staker2 should receive proportional reward");

        // Total should be conserved
        assertTrue(
            staker1Assets + staker2Assets <= IProverVault(vault).totalAssets() + 1e15,
            "Total assets should be conserved"
        );
    }

    function testRewardDistributionWithDynamicStakeChanges() public {
        // Setup initial state
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);
        vm.prank(prover1);
        controller.initializeProver(1000); // 10% commission

        address vault = controller.getProverVault(prover1);

        // Setup multiple stakers
        stakingToken.mint(staker1, 1000e18);
        stakingToken.mint(staker2, 1000e18);
        address staker3 = makeAddr("staker3");
        stakingToken.mint(staker3, 1000e18);

        // Initial stakes
        vm.prank(staker1);
        stakingToken.approve(address(controller), 300e18);
        vm.prank(staker1);
        controller.stake(prover1, 300e18);

        vm.prank(staker2);
        stakingToken.approve(address(controller), 400e18);
        vm.prank(staker2);
        controller.stake(prover1, 400e18);

        // First reward period
        uint256 reward1 = 100e18;
        vm.startPrank(rewardPayer);
        stakingToken.approve(address(controller), reward1);
        controller.addRewards(prover1, reward1);
        vm.stopPrank();

        // New staker joins
        vm.prank(staker3);
        stakingToken.approve(address(controller), 500e18);
        vm.prank(staker3);
        controller.stake(prover1, 500e18);

        // Second reward period with different stake distribution
        uint256 reward2 = 150e18;
        vm.startPrank(rewardPayer);
        stakingToken.approve(address(controller), reward2);
        controller.addRewards(prover1, reward2);
        vm.stopPrank();

        uint256 finalTotalAssets = IProverVault(vault).totalAssets();

        // Verify total rewards were distributed correctly
        uint256 totalRewardsToStakers = (reward1 + reward2) * 9000 / 10000; // 90% of total rewards
        uint256 expectedFinalAssets = MIN_SELF_STAKE + 300e18 + 400e18 + 500e18 + totalRewardsToStakers;

        assertTrue(finalTotalAssets >= expectedFinalAssets - 1e15, "Final assets should include all rewards");
        assertTrue(finalTotalAssets <= expectedFinalAssets + 1e15, "Final assets should not exceed expected");
    }

    function testCommissionClaimingWithConcurrentRewards() public {
        // Setup prover with commission
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);
        vm.prank(prover1);
        controller.initializeProver(2000); // 20% commission

        controller.getProverVault(prover1);

        // Add staker
        stakingToken.mint(staker1, 500e18);
        vm.prank(staker1);
        stakingToken.approve(address(controller), 500e18);
        vm.prank(staker1);
        controller.stake(prover1, 500e18);

        // Multiple reward periods
        for (uint256 i = 0; i < 5; i++) {
            uint256 rewardAmount = 50e18 + (i * 10e18);
            vm.startPrank(rewardPayer);
            stakingToken.approve(address(controller), rewardAmount);
            controller.addRewards(prover1, rewardAmount);
            vm.stopPrank();

            // Claim commission every other round
            if (i % 2 == 1) {
                uint256 balanceBefore = stakingToken.balanceOf(prover1);
                vm.prank(prover1);
                uint256 claimed = controller.claimCommission();
                uint256 balanceAfter = stakingToken.balanceOf(prover1);

                assertEq(balanceAfter - balanceBefore, claimed, "Claimed amount should match balance increase");
                assertTrue(claimed > 0, "Should have claimed some commission");
            }
        }

        // Final commission claim should have remaining amount
        (,,, uint256 finalPendingCommission,,,) = controller.getProverInfo(prover1);
        assertTrue(finalPendingCommission > 0, "Should have pending commission from unclaimed periods");

        uint256 finalBalanceBefore = stakingToken.balanceOf(prover1);
        vm.prank(prover1);
        uint256 finalClaimed = controller.claimCommission();
        uint256 finalBalanceAfter = stakingToken.balanceOf(prover1);

        assertEq(finalBalanceAfter - finalBalanceBefore, finalClaimed, "Final claim should match balance increase");
        assertEq(finalClaimed, finalPendingCommission, "Final claim should equal pending commission");
    }

    function testRewardPrecisionWithSmallAndLargeAmounts() public {
        // Setup with very low commission rate for precision testing
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);
        vm.prank(prover1);
        controller.initializeProver(1); // 0.01% commission

        controller.getProverVault(prover1);

        // Add large stake to amplify precision issues
        uint256 largeStake = 1000000e18;
        stakingToken.mint(staker1, largeStake);
        vm.prank(staker1);
        stakingToken.approve(address(controller), largeStake);
        vm.prank(staker1);
        controller.stake(prover1, largeStake);

        // Test with very small reward
        uint256 tinyReward = 1;
        vm.startPrank(rewardPayer);
        stakingToken.approve(address(controller), tinyReward);
        (uint256 tinyCommission,) = controller.addRewards(prover1, tinyReward);
        vm.stopPrank();

        // Even tiny rewards should be handled correctly (may round to 0)
        assertTrue(tinyCommission <= 1, "Tiny commission should be 0 or 1");

        // Test with medium reward to verify precision
        uint256 mediumReward = 10000;
        vm.startPrank(rewardPayer);
        stakingToken.approve(address(controller), mediumReward);
        (uint256 mediumCommission, uint256 toStakers) = controller.addRewards(prover1, mediumReward);
        vm.stopPrank();

        uint256 expectedCommission = (mediumReward * 1) / 10000; // 0.01%
        assertEq(mediumCommission, expectedCommission, "Medium reward commission should be precise");
        assertEq(mediumCommission + toStakers, mediumReward, "Total should be conserved");
    }

    function testRewardDistributionAfterProverExit() public {
        // Setup prover
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);
        vm.prank(prover1);
        controller.initializeProver(1500); // 15% commission

        address vault = controller.getProverVault(prover1);

        // Add stakers
        stakingToken.mint(staker1, 300e18);
        stakingToken.mint(staker2, 400e18);

        vm.prank(staker1);
        stakingToken.approve(address(controller), 300e18);
        vm.prank(staker1);
        controller.stake(prover1, 300e18);

        vm.prank(staker2);
        stakingToken.approve(address(controller), 400e18);
        vm.prank(staker2);
        controller.stake(prover1, 400e18);

        // Add initial rewards
        uint256 reward1 = 100e18;
        vm.startPrank(rewardPayer);
        stakingToken.approve(address(controller), reward1);
        controller.addRewards(prover1, reward1);
        vm.stopPrank();

        // Prover exits completely
        uint256 proverShares = IProverVault(vault).balanceOf(prover1);
        vm.prank(prover1);
        IProverVault(vault).approve(address(controller), proverShares);
        vm.prank(prover1);
        controller.requestUnstake(prover1, proverShares);

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(prover1);
        controller.completeUnstake(prover1);

        // Prover should still be able to claim accumulated commission
        (,,, uint256 pendingCommission,,,) = controller.getProverInfo(prover1);
        assertTrue(pendingCommission > 0, "Prover should have pending commission even after exit");

        uint256 proverBalanceBefore = stakingToken.balanceOf(prover1);
        vm.prank(prover1);
        uint256 claimedCommission = controller.claimCommission();
        uint256 proverBalanceAfter = stakingToken.balanceOf(prover1);

        assertEq(claimedCommission, pendingCommission, "Claimed should equal pending");
        assertEq(
            proverBalanceAfter - proverBalanceBefore, claimedCommission, "Balance should increase by claimed amount"
        );

        // New rewards should fail since prover exited
        uint256 reward2 = 50e18;
        vm.startPrank(rewardPayer);
        stakingToken.approve(address(controller), reward2);
        vm.expectRevert();
        controller.addRewards(prover1, reward2);
        vm.stopPrank();
    }

    function testLongTermRewardAccumulation() public {
        // Setup for long-term testing
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);
        vm.prank(prover1);
        controller.initializeProver(750); // 7.5% commission

        address vault = controller.getProverVault(prover1);

        // Add stakers with different amounts
        uint256[] memory stakeAmounts = new uint256[](3);
        stakeAmounts[0] = 100e18;
        stakeAmounts[1] = 250e18;
        stakeAmounts[2] = 500e18;

        address[] memory stakers = new address[](3);
        stakers[0] = staker1;
        stakers[1] = staker2;
        stakers[2] = makeAddr("staker3");

        for (uint256 i = 0; i < stakers.length; i++) {
            stakingToken.mint(stakers[i], stakeAmounts[i]);
            vm.prank(stakers[i]);
            stakingToken.approve(address(controller), stakeAmounts[i]);
            vm.prank(stakers[i]);
            controller.stake(prover1, stakeAmounts[i]);
        }

        uint256 totalCommissionAccumulated = 0;
        uint256 totalRewardsAdded = 0;

        // Simulate 10 periods of rewards
        for (uint256 period = 0; period < 10; period++) {
            uint256 periodReward = 30e18 + (period * 5e18);
            totalRewardsAdded += periodReward;

            vm.startPrank(rewardPayer);
            stakingToken.approve(address(controller), periodReward);
            (uint256 commission,) = controller.addRewards(prover1, periodReward);
            vm.stopPrank();

            totalCommissionAccumulated += commission;

            // Occasionally claim commission to test accumulated vs claimed
            if (period % 3 == 2) {
                vm.prank(prover1);
                uint256 claimed = controller.claimCommission();
                assertTrue(claimed > 0, "Should claim accumulated commission");
            }
        }

        // Final verification
        (,,, uint256 pendingCommission,,,) = controller.getProverInfo(prover1);
        uint256 expectedTotalCommission = (totalRewardsAdded * 750) / 10000;

        // Account for already claimed commission
        uint256 initialBalance = 800e18; // Initial balance before staking
        uint256 proverCurrentBalance = stakingToken.balanceOf(prover1);
        uint256 proverTotalReceived = proverCurrentBalance - initialBalance - MIN_SELF_STAKE;
        uint256 totalCommissionFromContract = proverTotalReceived + pendingCommission;

        assertEq(
            totalCommissionFromContract, expectedTotalCommission, "Long-term commission accumulation should be accurate"
        );
        assertTrue(IProverVault(vault).totalAssets() > MIN_SELF_STAKE + 850e18, "Vault should have grown significantly");
    }
}
