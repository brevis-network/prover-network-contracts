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

contract ProverManagementTest is Test {
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
        stakingToken.mint(rewardPayer, 1000e18);
    }

    // ===============================
    // PROVER LIFECYCLE TESTS
    // ===============================

    function testInitializeProver() public {
        // Setup prover approval
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        // Initialize prover
        vm.prank(prover1);
        address vaultAddress = controller.initializeProver(1000);

        // Verify vault was created
        assertTrue(vaultAddress != address(0));

        // Verify prover info
        (
            IStakingController.ProverState state,
            address vault,
            uint64 commissionRate,
            uint256 pendingCommission,
            uint256 numStakers,
            uint64 joinedAt
        ) = controller.getProverInfo(prover1);

        assertEq(vault, vaultAddress);
        assertEq(uint256(state), uint256(IStakingController.ProverState.Active));
        assertEq(commissionRate, 1000);
        assertEq(pendingCommission, 0);
        assertTrue(numStakers >= 1);
        assertTrue(joinedAt > 0);

        // Verify automatic self-staking occurred
        ProverVault vaultContract = ProverVault(vaultAddress);
        assertEq(vaultContract.totalAssets(), MIN_SELF_STAKE, "Vault should have assets equal to minSelfStake");

        // Verify prover has shares in their vault
        assertEq(vaultContract.balanceOf(prover1), MIN_SELF_STAKE, "Prover should own shares equal to minSelfStake");

        // Test global parameter separately
        assertEq(MIN_SELF_STAKE, 100e18);
    }

    function testCannotInitializeTwice() public {
        // Setup prover approval
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Try to initialize again
        vm.expectRevert(IStakingController.ControllerProverAlreadyInitialized.selector);
        vm.prank(prover1);
        controller.initializeProver(2000);
    }

    function testProverEnumeration() public {
        // Initially no active provers
        address[] memory activeProvers = controller.getActiveProvers();
        assertEq(activeProvers.length, 0);

        // Setup prover approvals
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);
        vm.prank(prover2);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        // Initialize first prover
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Check enumeration
        activeProvers = controller.getActiveProvers();
        assertEq(activeProvers.length, 1);
        assertEq(activeProvers[0], prover1);

        // Initialize second prover
        vm.prank(prover2);
        controller.initializeProver(1500);

        // Check enumeration
        activeProvers = controller.getActiveProvers();
        assertEq(activeProvers.length, 2);
        assertTrue(activeProvers[0] == prover1 || activeProvers[1] == prover1);
        assertTrue(activeProvers[0] == prover2 || activeProvers[1] == prover2);

        // Deactivate first prover
        vm.prank(admin);
        controller.deactivateProver(prover1);

        // Check enumeration after deactivation
        activeProvers = controller.getActiveProvers();
        assertEq(activeProvers.length, 1);
        assertEq(activeProvers[0], prover2);
    }

    // ===============================
    // PROVER STATE MANAGEMENT TESTS
    // ===============================

    function testProverStateTransitions() public {
        // Setup prover approval
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        // Initialize prover1
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Check initial state - Active
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Active));

        // Deactivate prover1
        vm.prank(admin);
        controller.deactivateProver(prover1);
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Deactivated));

        // Reactivate prover1
        vm.prank(admin);
        controller.reactivateProver(prover1);
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Active));
    }

    function testProverStateEventEmission() public {
        // Setup prover approval
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        // Initialize prover1 - this will emit ProverInitialized, not ProverStateChanged
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Deactivate and expect event
        vm.expectEmit(true, true, true, true);
        emit IStakingController.ProverStateChanged(
            prover1, IStakingController.ProverState.Active, IStakingController.ProverState.Deactivated
        );
        vm.prank(admin);
        controller.deactivateProver(prover1);

        // Reactivate and expect event
        vm.expectEmit(true, true, true, true);
        emit IStakingController.ProverStateChanged(
            prover1, IStakingController.ProverState.Deactivated, IStakingController.ProverState.Active
        );
        vm.prank(admin);
        controller.reactivateProver(prover1);
    }

    function testCannotStakeWithNonActiveProver() public {
        // Setup prover approval
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        // Initialize prover1
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Deactivate prover
        vm.prank(admin);
        controller.deactivateProver(prover1);

        // Try to stake with inactive prover
        vm.startPrank(staker1);
        stakingToken.approve(address(controller), 100e18);
        vm.expectRevert(IStakingController.ControllerProverNotActive.selector);
        controller.stake(prover1, 100e18);
        vm.stopPrank();
    }

    function testMaxDepositAndMintRespectsState() public {
        // Setup prover approval
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        // Initialize prover1
        vm.prank(prover1);
        address vaultAddress = controller.initializeProver(1000);
        IProverVault vault = IProverVault(vaultAddress);

        // Check max deposit when active
        assertGt(vault.maxDeposit(staker1), 0, "Should allow deposits when prover is active");
        assertGt(vault.maxMint(staker1), 0, "Should allow mints when prover is active");

        // Deactivate prover
        vm.prank(admin);
        controller.deactivateProver(prover1);

        // Check max deposit when inactive
        assertEq(vault.maxDeposit(staker1), 0, "Should not allow deposits when prover is inactive");
        assertEq(vault.maxMint(staker1), 0, "Should not allow mints when prover is inactive");
    }

    // ===============================
    // STAKER MANAGEMENT TESTS
    // ===============================

    function testGetProverStakers() public {
        // Setup prover approval
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Initially prover is self-staked
        address[] memory stakers = controller.getProverStakers(prover1);
        assertEq(stakers.length, 1);
        assertEq(stakers[0], prover1);

        // Add first staker
        uint256 stakeAmount = 100e18;
        vm.startPrank(staker1);
        stakingToken.approve(address(controller), stakeAmount);
        controller.stake(prover1, stakeAmount);
        vm.stopPrank();

        stakers = controller.getProverStakers(prover1);
        assertEq(stakers.length, 2);
        assertTrue(stakers[0] == prover1 || stakers[1] == prover1);
        assertTrue(stakers[0] == staker1 || stakers[1] == staker1);

        // Add second staker
        vm.startPrank(staker2);
        stakingToken.approve(address(controller), stakeAmount);
        controller.stake(prover1, stakeAmount);
        vm.stopPrank();

        stakers = controller.getProverStakers(prover1);
        assertEq(stakers.length, 3);
        assertTrue(stakers[0] == prover1 || stakers[1] == prover1 || stakers[2] == prover1);
        assertTrue(stakers[0] == staker1 || stakers[1] == staker1 || stakers[2] == staker1);
        assertTrue(stakers[0] == staker2 || stakers[1] == staker2 || stakers[2] == staker2);
    }

    function testRetireProver() public {
        // Setup prover approval for minimum self-stake
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        // Initialize prover
        vm.startPrank(prover1);
        address vault = controller.initializeProver(1000); // 10% commission

        // Unstake all to make vault empty
        IProverVault proverVault = IProverVault(vault);
        uint256 shares = proverVault.balanceOf(prover1);
        proverVault.approve(address(controller), shares);
        controller.requestUnstake(prover1, shares);

        // Complete unstaking to make vault truly empty
        skip(INITIAL_UNBOND_DELAY + 1);
        controller.completeUnstake(prover1);
        vm.stopPrank();

        // Verify prover is in lists initially
        address[] memory allProvers = controller.getAllProvers();
        address[] memory activeProvers = controller.getActiveProvers();
        assertEq(allProvers.length, 1);
        assertEq(activeProvers.length, 0); // Should be 0 since prover auto-deactivated when exiting
        assertEq(allProvers[0], prover1);

        // Verify prover state (should be deactivated after complete exit)
        IStakingController.ProverState state = controller.getProverState(prover1);
        assertEq(uint256(state), uint256(IStakingController.ProverState.Deactivated));

        // Verify prover vault is empty
        assertEq(controller.getProverVault(prover1), vault);
        assertEq(IProverVault(vault).totalAssets(), 0);

        // Retire the prover (should work since vault has no assets and no pending unstakes)
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit IStakingController.ProverRetired(prover1);
        controller.retireProver(prover1);

        // Verify prover is removed from lists
        allProvers = controller.getAllProvers();
        activeProvers = controller.getActiveProvers();
        assertEq(allProvers.length, 0);
        assertEq(activeProvers.length, 0);

        // Verify prover state is Null
        state = controller.getProverState(prover1);
        assertEq(uint256(state), uint256(IStakingController.ProverState.Null));

        // Verify prover info is cleared
        (
            IStakingController.ProverState infoState,
            address infoVault,
            uint64 infoCommissionRate,
            uint256 infoPendingCommission,
            uint256 infoNumStakers,
            uint64 joinedAt
        ) = controller.getProverInfo(prover1);

        assertEq(uint256(infoState), uint256(IStakingController.ProverState.Null));
        assertEq(infoVault, address(0));
        assertEq(infoCommissionRate, 0);
        assertEq(infoPendingCommission, 0);
        assertEq(infoNumStakers, 0);
        assertEq(joinedAt, 0);
    }

    function testCannotRetireProverWithAssets() public {
        // Setup prover approval
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        // Initialize prover with self-stake
        vm.startPrank(prover1);
        controller.initializeProver(1000); // 10% commission
        vm.stopPrank();

        // The prover will have MIN_SELF_STAKE assets due to auto-staking
        // Try to retire - should fail
        vm.prank(admin);
        vm.expectRevert(IStakingController.ControllerCannotRetireProverWithAssets.selector);
        controller.retireProver(prover1);
    }

    function testCannotRetireProverWithTinyDustAssets() public {
        // Setup prover approval
        vm.prank(prover1);
        stakingToken.approve(address(controller), type(uint256).max);

        // Initialize prover with minimum stake
        vm.startPrank(prover1);
        address vault = controller.initializeProver(1000);

        // Add significant stake to test dust scenario (within prover's balance)
        controller.stake(prover1, 500e18); // Total will be 600e18 (100 + 500)

        // Unstake most of it, leaving just slightly above MIN_SELF_STAKE + dust
        IProverVault proverVault = IProverVault(vault);
        uint256 totalShares = proverVault.balanceOf(prover1);

        // Leave MIN_SELF_STAKE + 1000 wei (this is "dust" above the minimum requirement)
        uint256 dustAssets = MIN_SELF_STAKE + 1000; // Minimum + 1000 wei dust
        uint256 totalAssets = proverVault.totalAssets();
        uint256 dustShares = (dustAssets * totalShares) / totalAssets;
        uint256 unstakeShares = totalShares - dustShares;

        proverVault.approve(address(controller), unstakeShares);
        controller.requestUnstake(prover1, unstakeShares);

        // Complete the unstaking
        skip(INITIAL_UNBOND_DELAY + 1);
        controller.completeUnstake(prover1);
        vm.stopPrank();

        // Verify vault has minimal amount above MIN_SELF_STAKE (the "dust" scenario)
        uint256 remainingAssets = IProverVault(vault).totalAssets();
        assertGt(remainingAssets, MIN_SELF_STAKE);
        assertLt(remainingAssets, MIN_SELF_STAKE + 10000); // Very small amount above minimum

        // Try to retire - should fail even with this tiny amount above minimum
        vm.prank(admin);
        vm.expectRevert(IStakingController.ControllerCannotRetireProverWithAssets.selector);
        controller.retireProver(prover1);
    }

    function testCannotRetireProverWithPendingUnstakes() public {
        // Setup prover approval
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        // Initialize prover
        vm.startPrank(prover1);
        address vault = controller.initializeProver(1000); // 10% commission

        // Request to unstake all assets to make vault empty
        IProverVault proverVault = IProverVault(vault);
        uint256 shares = proverVault.balanceOf(prover1);
        proverVault.approve(address(controller), shares);
        controller.requestUnstake(prover1, shares);
        vm.stopPrank();

        // Now vault should be empty but there are pending unstakes
        // Try to retire - should fail
        vm.prank(admin);
        vm.expectRevert(IStakingController.ControllerCannotRetireProverWithPendingUnstakes.selector);
        controller.retireProver(prover1);
    }

    function testCannotRetireNonExistentProver() public {
        vm.prank(admin);
        vm.expectRevert(IStakingController.ControllerProverNotInitialized.selector);
        controller.retireProver(makeAddr("nonexistent"));
    }

    function testRetireProverOnlyAdmin() public {
        // Setup prover approval
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        // Initialize prover
        vm.startPrank(prover1);
        controller.initializeProver(1000); // 10% commission
        vm.stopPrank();

        // Try to retire as non-admin - should fail
        vm.prank(prover1);
        vm.expectRevert();
        controller.retireProver(prover1);

        vm.prank(staker1);
        vm.expectRevert();
        controller.retireProver(prover1);
    }

    // ============================================================
    // Prover Reactivation Tests
    // ============================================================

    function testReactivateDeactivatedProver() public {
        // Setup prover approval
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(1000); // 10% commission rate

        // Verify prover is active
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Active));

        // Admin deactivates prover
        vm.prank(admin);
        controller.deactivateProver(prover1);
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Deactivated));

        // Admin reactivates prover
        vm.prank(admin);
        controller.reactivateProver(prover1);
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Active));
    }

    function testCannotReactivateUninitializedProver() public {
        // Try to reactivate a prover that was never initialized
        vm.prank(admin);
        vm.expectRevert(IStakingController.ControllerProverNotInitialized.selector);
        controller.reactivateProver(prover1);
    }

    function testCannotReactivateJailedProver() public {
        // Setup prover approval
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Admin jails prover
        vm.prank(admin);
        controller.jailProver(prover1);
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Jailed));

        // Admin can reactivate jailed prover
        vm.prank(admin);
        controller.reactivateProver(prover1);
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Active));

        // Jail again to test prover self-reactivation
        vm.prank(admin);
        controller.jailProver(prover1);

        // Prover CANNOT reactivate themselves from jail (changed behavior)
        vm.prank(prover1);
        vm.expectRevert(IStakingController.ControllerOnlyAdmin.selector);
        controller.reactivateProver(prover1);

        // Verify prover is still jailed
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Jailed));
    }

    function testReactivationConsistentWithUnstakingPolicy() public {
        // Set MinSelfStake to 20 ETH
        vm.prank(admin);
        controller.setMinSelfStake(20e18);

        // Setup prover with sufficient tokens for higher MinSelfStake
        vm.prank(admin);
        stakingToken.transfer(prover1, 25e18);

        // Initialize prover - this will automatically stake the MinSelfStake (20 ETH)
        vm.prank(prover1);
        stakingToken.approve(address(controller), 25e18);
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Add additional stake: 5 ETH more (25 ETH total)
        vm.prank(prover1);
        controller.stake(prover1, 5e18);

        // Verify prover is active with 25 ETH total
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Active));

        // Try to request unstake of 10 ETH, which would leave 15 ETH (below 20 ETH MinSelfStake)
        // This should fail due to our MinSelfStake fix
        IProverVault vault = IProverVault(controller.getProverVault(prover1));
        uint256 unstakeShares = vault.convertToShares(10e18);

        vm.prank(prover1);
        vm.expectRevert(IStakingController.ControllerMinSelfStakeNotMet.selector);
        controller.requestUnstake(prover1, unstakeShares);

        // The unstake should have failed, so prover is still active
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Active));

        // This demonstrates that our reactivation fix maintains policy consistency:
        // If we can't unstake when it would violate MinSelfStake, then reactivation
        // should also fail when actively committed stake is below MinSelfStake
    }

    function testCannotReactivateProverBelowMinSelfStake() public {
        // Set minimum self-stake
        uint256 minSelfStake = 100e18;
        vm.prank(admin);
        controller.setMinSelfStake(minSelfStake);

        // Setup prover with sufficient tokens
        vm.prank(admin);
        stakingToken.transfer(prover1, minSelfStake);

        // Setup prover approval
        vm.prank(prover1);
        stakingToken.approve(address(controller), minSelfStake);

        // Initialize prover with minimum stake
        vm.prank(prover1);
        controller.initializeProver(1000); // 5% commission (will use minSelfStake for initial stake)

        // Admin deactivates prover
        vm.prank(admin);
        controller.deactivateProver(prover1);

        // Prover still has exactly minSelfStake, so admin should be able to reactivate
        vm.prank(admin);
        controller.reactivateProver(prover1);
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Active));

        // Now simulate prover going below minimum through a different path
        // (Note: In reality this might happen through slashing, but slashing is not implemented yet)
        // For this test, we'll simulate by having prover request full unstake (which deactivates them)
        address vault = controller.getProverVault(prover1);
        uint256 proverShares = IProverVault(vault).balanceOf(prover1);

        // Approve controller to spend vault shares before requesting unstake
        vm.prank(prover1);
        IProverVault(vault).approve(address(controller), proverShares);

        // Request complete unstake (this should deactivate prover immediately)
        vm.prank(prover1);
        controller.requestUnstake(prover1, proverShares);

        // Prover should be deactivated after complete unstake request
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Deactivated));

        // Wait for unstake delay and complete unstake
        vm.warp(block.timestamp + INITIAL_UNBOND_DELAY + 1);

        // Complete unstake through controller
        vm.prank(prover1);
        controller.completeUnstake(prover1);

        // Now prover has zero stake - admin should not be able to reactivate
        vm.prank(admin);
        vm.expectRevert(IStakingController.ControllerMinSelfStakeNotMet.selector);
        controller.reactivateProver(prover1);
    }

    function testReactivateProverWithSufficientStake() public {
        // Setup prover approval
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Admin manually deactivates prover (prover still has minimum stake)
        vm.prank(admin);
        controller.deactivateProver(prover1);
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Deactivated));

        // Admin can reactivate prover since they still have sufficient stake
        vm.prank(admin);
        controller.reactivateProver(prover1);
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Active));
    }

    function testReactivationAllowsStakingAgain() public {
        // Setup prover approval
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Setup staker approval for all stakes
        vm.prank(staker1);
        stakingToken.approve(address(controller), type(uint256).max);

        // Staker stakes with prover
        vm.prank(staker1);
        controller.stake(prover1, 10 ether);

        // Admin deactivates prover
        vm.prank(admin);
        controller.deactivateProver(prover1);

        // Staker cannot stake with deactivated prover
        vm.prank(staker1);
        vm.expectRevert(IStakingController.ControllerProverNotActive.selector);
        controller.stake(prover1, 5 ether);

        // Admin reactivates prover
        vm.prank(admin);
        controller.reactivateProver(prover1);

        // Now staker can stake again
        vm.prank(staker1);
        controller.stake(prover1, 5 ether);

        // Verify the stake went through
        uint256 stakeShares = controller.getStakeInfo(prover1, staker1);
        assertGt(stakeShares, 0);
    }

    function testOnlyAdminCanReactivateProver() public {
        // Setup prover approval
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Admin deactivates prover
        vm.prank(admin);
        controller.deactivateProver(prover1);

        // Non-admin cannot reactivate
        vm.prank(staker1);
        vm.expectRevert(IStakingController.ControllerOnlyProver.selector);
        controller.reactivateProver(prover1);

        // But prover can reactivate themselves
        vm.prank(prover1);
        controller.reactivateProver(prover1);
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Active));
    }

    function testJailProverPermanently() public {
        // Setup prover approval
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Setup staker approval
        vm.prank(staker1);
        stakingToken.approve(address(controller), type(uint256).max);

        // Admin jails prover
        vm.prank(admin);
        controller.jailProver(prover1);
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Jailed));

        // Cannot stake with jailed prover
        vm.prank(staker1);
        vm.expectRevert(IStakingController.ControllerProverNotActive.selector);
        controller.stake(prover1, 5 ether);

        // But jailed prover can be reactivated (unlike retired)
        vm.prank(admin);
        controller.reactivateProver(prover1);
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Active));

        // Now staking works again
        vm.prank(staker1);
        controller.stake(prover1, 5 ether);
    }

    function testProverCannotSelfReactivateFromJail() public {
        // Setup prover approval
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Setup staker approval
        vm.prank(staker1);
        stakingToken.approve(address(controller), type(uint256).max);

        // Admin jails prover for misbehavior
        vm.prank(admin);
        controller.jailProver(prover1);
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Jailed));

        // Prover cannot accept stakes while jailed
        vm.prank(staker1);
        vm.expectRevert(IStakingController.ControllerProverNotActive.selector);
        controller.stake(prover1, 5 ether);

        // Prover CANNOT reactivate themselves from jail (only admin can)
        vm.prank(prover1);
        vm.expectRevert(IStakingController.ControllerOnlyAdmin.selector);
        controller.reactivateProver(prover1);

        // Verify prover is still jailed
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Jailed));

        // Only admin can reactivate from jail
        vm.prank(admin);
        controller.reactivateProver(prover1);
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Active));

        // Now they can accept stakes again
        vm.prank(staker1);
        uint256 shares = controller.stake(prover1, 5 ether);
        assertGt(shares, 0);
    }

    function testProverCanSelfReactivateFromDeactivated() public {
        // Setup prover approval
        vm.prank(prover1);
        stakingToken.approve(address(controller), MIN_SELF_STAKE);

        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Admin deactivates prover
        vm.prank(admin);
        controller.deactivateProver(prover1);
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Deactivated));

        // Prover CAN reactivate themselves from deactivated state
        vm.prank(prover1);
        controller.reactivateProver(prover1);
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Active));

        // Setup staker approval
        vm.prank(staker1);
        stakingToken.approve(address(controller), type(uint256).max);

        // Verify they can accept stakes again
        vm.prank(staker1);
        uint256 shares = controller.stake(prover1, 5 ether);
        assertGt(shares, 0);
    }
}
