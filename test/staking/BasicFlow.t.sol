// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/staking/controller/StakingController.sol";
import "../../src/staking/vault/VaultFactory.sol";
import "../../src/staking/vault/ProverVault.sol";
import "../../src/staking/interfaces/IProverVault.sol";
import "../mocks/MockERC20.sol";

contract BasicFlowTest is Test {
    StakingController public controller;
    VaultFactory public factory;
    MockERC20 public stakingToken;

    address public admin = makeAddr("admin");
    address public prover1 = makeAddr("prover1");
    address public staker1 = makeAddr("staker1");
    address public staker2 = makeAddr("staker2");

    uint256 public constant INITIAL_MINT = 1000000e18;

    function setUp() public {
        vm.startPrank(admin);

        stakingToken = new MockERC20("Staking Token", "STK");
        stakingToken.mint(admin, INITIAL_MINT);

        factory = new VaultFactory();

        controller = new StakingController(
            address(stakingToken),
            address(factory),
            7 days,
            1e18, // minSelfStake: 1 token
            5000 // maxSlashBps: 50%
        );

        factory.init(address(controller));

        // Grant slasher role to admin for testing
        controller.grantRole(controller.SLASHER_ROLE(), admin);

        vm.stopPrank();

        // Mint tokens for participants
        vm.startPrank(admin);
        stakingToken.mint(staker1, INITIAL_MINT);
        stakingToken.mint(staker2, INITIAL_MINT);
        stakingToken.mint(prover1, INITIAL_MINT);
        vm.stopPrank();

        // Approve controller to spend minSelfStake for automatic staking during initialization
        uint256 minSelfStake = controller.minSelfStake();
        vm.prank(prover1);
        stakingToken.approve(address(controller), minSelfStake);
    }

    function testBasicFlowWithDirectVaultDeposit() public {
        // Initialize prover for testing scenario
        vm.prank(prover1);
        address vaultAddress = controller.initializeProver(1000); // 10% commission
        ProverVault vault = ProverVault(vaultAddress);

        uint256 shares;
        uint256 shares2;

        // Staker1 stakes via controller
        {
            uint256 stakeAmount = 100e18;
            vm.startPrank(staker1);
            stakingToken.approve(address(controller), stakeAmount);
            shares = controller.stake(prover1, stakeAmount);
            vm.stopPrank();

            // Verify controller accounting after controller.stake()
            uint256 stakeShares = controller.getStakeInfo(prover1, staker1);
            assertEq(stakeShares, shares, "Controller should track shares from stake()");
            assertEq(vault.balanceOf(staker1), shares, "Vault should have correct balance");
        }

        // Staker2 also stakes via controller (direct vault deposits no longer allowed)
        {
            uint256 stakeAmount2 = 50e18;
            vm.startPrank(staker2);
            stakingToken.approve(address(controller), stakeAmount2);
            shares2 = controller.stake(prover1, stakeAmount2);
            vm.stopPrank();

            // Verify controller accounting after controller.stake()
            uint256 stakeShares2 = controller.getStakeInfo(prover1, staker2);
            assertEq(stakeShares2, shares2, "Controller should track shares from controller stake");
            assertEq(vault.balanceOf(staker2), shares2, "Vault should have correct balance");
        }

        // Verify that direct vault deposits are now blocked
        vm.startPrank(staker2);
        stakingToken.approve(vaultAddress, 10e18);
        vm.expectRevert(IProverVault.VaultOnlyController.selector);
        vault.deposit(10e18, staker2);
        vm.stopPrank();

        // Test proper unstaking flow for staker1
        {
            uint256 unstakeAmount = shares / 4;
            vm.startPrank(staker1);

            // First approve vault shares for controller to spend
            vault.approve(address(controller), unstakeAmount);

            // Request unstake (returns assets, not timestamp)
            uint256 assetsUnstaked = controller.requestUnstake(prover1, unstakeAmount);
            vm.stopPrank();

            // Fast forward time to allow unstaking (7 days delay)
            vm.warp(block.timestamp + 7 days + 1);

            // Complete unstake through unstaking contract
            vm.startPrank(staker1);
            uint256 assetsReceived = controller.completeUnstake(prover1);
            vm.stopPrank();

            assertEq(assetsReceived, assetsUnstaked, "Should receive the same assets that were unstaked");

            // Verify controller accounting after proper unstaking
            uint256 stakeShares1After = controller.getStakeInfo(prover1, staker1);
            assertEq(stakeShares1After, shares - unstakeAmount, "Controller should update shares after unstaking");
            assertEq(vault.balanceOf(staker1), shares - unstakeAmount, "Vault balance should be updated");
        }

        // Test unstaking flow for staker2
        uint256 unstakeShares = shares2 / 2;
        {
            vm.startPrank(staker2);

            // Approve vault shares for controller to spend
            vault.approve(address(controller), unstakeShares);

            uint256 assetsUnstaked2 = controller.requestUnstake(prover1, unstakeShares);
            vm.stopPrank();

            // Check that staker2 has unstaking tokens in the unstaking contract
            (uint256 totalUnstaking,) = controller.getUnstakingInfo(prover1, staker2);
            assertEq(totalUnstaking, assetsUnstaked2, "Assets should be unstaking");

            // Test that completeUnstake fails before delay period
            vm.prank(staker2);
            vm.expectRevert(); // Unstaking contract will revert if not ready
            controller.completeUnstake(prover1);
        }

        // Test that direct vault operations still work for remaining shares
        vm.startPrank(staker2);

        // Should not be able to redeem more than available shares
        vm.expectRevert(IProverVault.VaultOnlyController.selector);
        vault.redeem(shares2, staker2, staker2); // Try to redeem all shares but half were already redeemed during unstaking

        // Should not be able to withdraw equivalent assets
        {
            uint256 allAssets = vault.convertToAssets(shares2);
            vm.expectRevert(IProverVault.VaultOnlyController.selector);
            vault.withdraw(allAssets, staker2, staker2);
        }

        // Direct transfer should work for remaining shares (unstaked shares were already burned)
        // This should work since shares were already burned during requestUnstake
        vm.expectRevert(IProverVault.VaultSharesLocked.selector);
        vault.transfer(staker1, (shares2 - unstakeShares) + 1); // Try to transfer more than available

        vm.stopPrank();

        // Complete unstake after time passes
        vm.warp(block.timestamp + 7 days + 1);

        // Complete unstake through unstaking contract and verify final state
        {
            vm.startPrank(staker2);
            uint256 assetsReceivedByStaker2 = controller.completeUnstake(prover1);
            vm.stopPrank();

            // Verify final state
            uint256 stakeShares2After = controller.getStakeInfo(prover1, staker2);
            uint256 expectedShares = shares2 - unstakeShares;
            assertEq(stakeShares2After, expectedShares, "Shares should be reduced after unstaking");
            (uint256 totalUnstakingAfter,) = controller.getUnstakingInfo(prover1, staker2);
            assertEq(totalUnstakingAfter, 0, "No assets should be unstaking after completion");

            assertTrue(assetsReceivedByStaker2 > 0, "Should receive assets from unstaking");

            // Check final state
            assertEq(vault.balanceOf(staker2), expectedShares, "Vault balance should match expected remaining shares");
        }
    }

    function testRewardsDistribution() public {
        // Initialize prover
        vm.prank(prover1);
        address vaultAddress = controller.initializeProver(1000); // 10% commission
        ProverVault vault = ProverVault(vaultAddress);

        // Staker stakes
        uint256 stakeAmount = 100e18;
        vm.startPrank(staker1);
        stakingToken.approve(address(controller), stakeAmount);
        controller.stake(prover1, stakeAmount);
        vm.stopPrank();

        // Check initial vault assets (includes prover's automatic self-stake)
        uint256 initialAssets = vault.totalAssets();
        uint256 minSelfStake = controller.minSelfStake();
        assertEq(initialAssets, stakeAmount + minSelfStake, "Initial assets should equal stake + minSelfStake");

        // Add rewards
        uint256 rewardAmount = 10e18;
        vm.startPrank(admin);
        stakingToken.approve(address(controller), rewardAmount);
        (uint256 commission, uint256 toStakers) = controller.addRewards(prover1, rewardAmount);
        vm.stopPrank();

        // Verify commission calculation
        uint256 expectedCommission = (rewardAmount * 1000) / 10000; // 10%
        assertEq(commission, expectedCommission, "Commission should be 10%");
        assertEq(toStakers, rewardAmount - expectedCommission, "Stakers should get 90%");

        // Check vault assets increased
        uint256 finalAssets = vault.totalAssets();
        assertEq(finalAssets, initialAssets + toStakers, "Vault assets should increase by staker rewards");

        // Verify prover can claim commission
        uint256 proverBalanceBefore = stakingToken.balanceOf(prover1);
        vm.prank(prover1);
        uint256 claimed = controller.claimCommission();
        uint256 proverBalanceAfter = stakingToken.balanceOf(prover1);

        assertEq(claimed, expectedCommission, "Claimed amount should equal commission");
        assertEq(proverBalanceAfter - proverBalanceBefore, expectedCommission, "Prover balance should increase");
    }

    function testStakeFlow() public {
        // Initialize prover first
        vm.prank(prover1);
        address vaultAddress = controller.initializeProver(1000);

        // Staker 1 stakes
        uint256 stakeAmount = 100e18;
        vm.startPrank(staker1);
        stakingToken.approve(address(controller), stakeAmount);
        uint256 sharesReceived = controller.stake(prover1, stakeAmount);
        vm.stopPrank();

        // Verify stake
        assertTrue(sharesReceived > 0);

        // Check vault balance (includes automatic minSelfStake from prover)
        ProverVault vault = ProverVault(vaultAddress);
        assertEq(vault.balanceOf(staker1), sharesReceived);
        uint256 minSelfStake = controller.minSelfStake();
        assertEq(stakingToken.balanceOf(vaultAddress), stakeAmount + minSelfStake);

        // Check stake info
        uint256 stakeShares = controller.getStakeInfo(prover1, staker1);
        assertEq(stakeShares, sharesReceived);
        // Check no pending unstakes in unstaking contract
        (uint256 totalUnstaking,) = controller.getUnstakingInfo(prover1, staker1);
        assertEq(totalUnstaking, 0);
    }

    function testCannotStakeWithInactiveProver() public {
        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Deactivate prover
        vm.prank(admin);
        controller.deactivateProver(prover1);

        // Try to stake
        uint256 stakeAmount = 100e18;
        vm.startPrank(staker1);
        stakingToken.approve(address(controller), stakeAmount);
        vm.expectRevert(IStakingController.ControllerProverNotActive.selector);
        controller.stake(prover1, stakeAmount);
        vm.stopPrank();
    }
}
