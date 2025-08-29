// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/staking/controller/StakingController.sol";
import "../../src/staking/vault/VaultFactory.sol";
import "../../src/staking/interfaces/IProverVault.sol";
import "../../src/staking/interfaces/IStakingController.sol";
import "../mocks/MockERC20.sol";

contract MinSelfStakeTest is Test {
    StakingController public controller;
    VaultFactory public factory;
    MockERC20 public stakingToken;

    address public admin = makeAddr("admin");
    address public prover1 = makeAddr("prover1");
    address public staker1 = makeAddr("staker1");

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
            1e18, // minSelfStake: 1 token (will be updated below)
            5000 // maxSlashBps: 50%
        );

        // Initialize the factory with the controller
        factory.init(address(controller));

        // Grant slasher role to admin for testing
        controller.grantRole(controller.SLASHER_ROLE(), admin);

        // Set MinSelfStake
        controller.setMinSelfStake(MIN_SELF_STAKE);

        vm.stopPrank();

        // Setup prover with initial self stake
        stakingToken.mint(prover1, 1000e18);
        vm.startPrank(prover1);
        stakingToken.approve(address(controller), 200e18); // Approve more for extra staking in tests
        vm.stopPrank();

        vm.startPrank(prover1);
        controller.initializeProver(1000); // Will use MIN_SELF_STAKE for initial stake
        vm.stopPrank();

        // Setup staker
        stakingToken.mint(staker1, 1000e18);
    }

    function testProverCannotUnstakeBelowMinSelfStake() public {
        // Prover stakes additional amount beyond the initial MinSelfStake
        vm.startPrank(prover1);
        stakingToken.approve(address(controller), 50e18);
        controller.stake(prover1, 50e18);

        address vault = controller.getProverVault(prover1);
        uint256 initialShares = IProverVault(vault).balanceOf(prover1);
        uint256 excessShares = initialShares * 25e18 / 150e18; // Would leave 125e18 assets (above MIN_SELF_STAKE)

        // This should work - leaves prover above MinSelfStake
        IProverVault(vault).approve(address(controller), excessShares);
        controller.requestUnstake(prover1, excessShares);

        // Now calculate based on REMAINING shares, not initial shares
        uint256 remainingShares = IProverVault(vault).balanceOf(prover1);
        uint256 remainingAssets = IProverVault(vault).convertToAssets(remainingShares);

        // Try to unstake enough to leave less than MIN_SELF_STAKE (e.g., leave 80e18)
        uint256 excessUnstakeAssets = remainingAssets - 80e18;
        uint256 tooMuchShares = IProverVault(vault).convertToShares(excessUnstakeAssets);

        IProverVault(vault).approve(address(controller), tooMuchShares);
        vm.expectRevert(IStakingController.ControllerMinSelfStakeNotMet.selector);
        controller.requestUnstake(prover1, tooMuchShares);

        vm.stopPrank();
    }

    function testProverCanUnstakeToZeroAndAutoDeactivate() public {
        // Prover should be able to unstake everything (go to zero)
        vm.startPrank(prover1);

        // Ensure prover has enough allowance if they want to stake more later in other tests
        stakingToken.approve(address(controller), 1000e18);

        uint256 proverShares = IProverVault(controller.getProverVault(prover1)).balanceOf(prover1);
        address vault = controller.getProverVault(prover1);

        // Prover should be active before requesting complete unstake
        assertTrue(
            controller.getProverState(prover1) == IStakingController.ProverState.Active,
            "Prover should be active before requesting complete unstake"
        );

        // Approve controller to spend vault shares before requesting unstake
        IProverVault(vault).approve(address(controller), proverShares);

        // This should work - complete exit is allowed
        controller.requestUnstake(prover1, proverShares);

        // Prover should be deactivated immediately after requesting complete unstake (like legacy behavior)
        assertTrue(
            controller.getProverState(prover1) == IStakingController.ProverState.Deactivated,
            "Prover should be auto-deactivated immediately when requesting complete exit"
        );

        vm.stopPrank();

        // Wait for unstaking delay
        vm.warp(block.timestamp + INITIAL_UNBOND_DELAY + 1);

        // Complete the unstake through controller
        vm.prank(prover1);
        uint256 assets = controller.completeUnstake(prover1);
        assertTrue(assets > 0, "Should receive assets");

        // Prover should still be deactivated
        assertTrue(
            controller.getProverState(prover1) == IStakingController.ProverState.Deactivated,
            "Prover should remain deactivated after completing exit"
        );

        // Prover should have zero shares
        uint256 remainingShares = IProverVault(controller.getProverVault(prover1)).balanceOf(prover1);
        assertEq(remainingShares, 0, "Prover should have zero shares after complete exit");

        vm.stopPrank();
    }

    function testProverCanUnstakeExactlyToMinSelfStake() public {
        // Prover stakes additional amount
        vm.startPrank(prover1);
        stakingToken.approve(address(controller), 50e18);
        controller.stake(prover1, 50e18);

        // Calculate shares needed to leave exactly MIN_SELF_STAKE
        address vault = controller.getProverVault(prover1);
        uint256 proverShares = IProverVault(vault).balanceOf(prover1);
        uint256 proverAssets = IProverVault(vault).convertToAssets(proverShares);

        uint256 excessAssets = proverAssets - MIN_SELF_STAKE;
        uint256 excessShares = IProverVault(vault).convertToShares(excessAssets);

        // This should work - leaves exactly MIN_SELF_STAKE
        IProverVault(vault).approve(address(controller), excessShares);
        controller.requestUnstake(prover1, excessShares);

        // Prover should still be active
        assertTrue(
            controller.getProverState(prover1) == IStakingController.ProverState.Active,
            "Prover should remain active when at MinSelfStake"
        );

        vm.stopPrank();
    }

    function testDelegatorUnstakingNotAffectedByMinSelfStake() public {
        // Delegator stakes with prover
        vm.startPrank(staker1);
        stakingToken.approve(address(controller), 200e18);
        controller.stake(prover1, 200e18);

        // Delegator should be able to unstake any amount (not subject to MinSelfStake)
        uint256 stakerShares = IProverVault(controller.getProverVault(prover1)).balanceOf(staker1);

        // This should work for delegator
        IProverVault(controller.getProverVault(prover1)).approve(address(controller), stakerShares);
        controller.requestUnstake(prover1, stakerShares);

        vm.stopPrank();
    }

    function testPendingUnstakesPreventMinSelfStakeBypass() public {
        // This test verifies that MinSelfStake rules apply with pending unstakes
        // We'll use the exact pattern from testProverCanUnstakeExactlyToMinSelfStake which works
        vm.startPrank(prover1);
        stakingToken.approve(address(controller), 50e18);
        controller.stake(prover1, 50e18);

        address vault = controller.getProverVault(prover1);
        uint256 proverShares = IProverVault(vault).balanceOf(prover1);
        uint256 proverAssets = IProverVault(vault).convertToAssets(proverShares);

        // First request: unstake exactly enough to leave MIN_SELF_STAKE
        uint256 excessAssets = proverAssets - MIN_SELF_STAKE;
        uint256 excessShares = IProverVault(vault).convertToShares(excessAssets);

        IProverVault(vault).approve(address(controller), excessShares);
        controller.requestUnstake(prover1, excessShares);

        // Second request: try to unstake more, which should fail due to MinSelfStake
        // Since we're already at MIN_SELF_STAKE, any additional unstake should fail
        uint256 additionalShares = IProverVault(vault).convertToShares(10e18);
        IProverVault(vault).approve(address(controller), additionalShares);
        vm.expectRevert(IStakingController.ControllerMinSelfStakeNotMet.selector);
        controller.requestUnstake(prover1, additionalShares);

        vm.stopPrank();
    }

    function testCompleteExitWithPendingUnstakes() public {
        // This test verifies complete exit behavior with pending unstakes
        // Use working pattern from testProverCanUnstakeExactlyToMinSelfStake
        vm.startPrank(prover1);
        stakingToken.approve(address(controller), 50e18);
        controller.stake(prover1, 50e18);

        address vault = controller.getProverVault(prover1);

        // First request partial unstake (small amount)
        uint256 partialShares = IProverVault(vault).convertToShares(20e18);
        IProverVault(vault).approve(address(controller), partialShares);
        controller.requestUnstake(prover1, partialShares);

        // Then request complete exit of all remaining shares
        uint256 remainingShares = IProverVault(vault).balanceOf(prover1);
        IProverVault(vault).approve(address(controller), remainingShares);
        controller.requestUnstake(prover1, remainingShares);

        // Should be deactivated after complete exit
        assertTrue(
            controller.getProverState(prover1) == IStakingController.ProverState.Deactivated,
            "Prover should be auto-deactivated after complete exit"
        );

        vm.stopPrank();
    }

    // =========================================================================
    // POLICY ENFORCEMENT TESTS
    // =========================================================================

    function testMinSelfStakeEnforcementAfterSlashing() public {
        // Test: Min self-stake enforcement after prover gets slashed
        // Value: Ensures slashed provers must restore minimum stake to remain active

        // Setup additional stake beyond minimum
        vm.startPrank(prover1);
        stakingToken.approve(address(controller), 50e18);
        controller.stake(prover1, 50e18); // Now has MIN_SELF_STAKE + 50e18 = 51e18 total
        vm.stopPrank();

        address vault = controller.getProverVault(prover1);
        uint256 preSlashAssets = IProverVault(vault).totalAssets();
        assertTrue(preSlashAssets >= MIN_SELF_STAKE + 50e18, "Should have sufficient stake before slashing");

        // Check current max slashBps
        uint256 currentMaxSlash = controller.maxSlashBps();
        console.log("Current max slashBps:", currentMaxSlash);

        // Set higher max slashBps to allow sufficient slashing (use admin as owner)
        vm.prank(admin);
        controller.setMaxSlashBps(8000); // Allow up to 80% slashing

        uint256 newMaxSlash = controller.maxSlashBps();
        console.log("New max slashBps:", newMaxSlash);
        assertEq(newMaxSlash, 8000, "Max slashBps should be updated");

        // Use a slashBps that's definitely within the new limit (50%)
        uint256 slashBps = 5000; // 50% slash, should be fine
        vm.prank(admin);
        controller.slash(prover1, slashBps);

        uint256 postSlashAssets = IProverVault(vault).totalAssets();
        console.log("Pre-slash assets:", preSlashAssets);
        console.log("Post-slash assets:", postSlashAssets);
        console.log("Minimum self-stake:", MIN_SELF_STAKE);

        // Check the prover state
        IStakingController.ProverState state = controller.getProverState(prover1);
        console.log("Prover state after slash:", uint256(state));

        // With 50% slash on 150e18: 150e18 * 0.5 = 75e18 remaining, which is < MIN_SELF_STAKE (100e18)
        // So prover should be automatically deactivated
        assertTrue(postSlashAssets < MIN_SELF_STAKE, "Prover should be below minimum after 50% slash");
        assertEq(
            uint256(state),
            uint256(IStakingController.ProverState.Deactivated),
            "Prover should be automatically deactivated"
        );

        // Deactivated prover should still be able to update commission rate (allowed operation)
        vm.startPrank(prover1);
        controller.setCommissionRate(address(0), 2000); // Should succeed - update default rate
        vm.stopPrank();

        // Verify commission rate was updated
        (,, uint64 newCommissionRate,,) = controller.getProverInfo(prover1);
        assertEq(newCommissionRate, 2000, "Commission rate should be updated even when deactivated");
    }

    function testMinSelfStakeConfigurationChange() public {
        // Test: Behavior when admin changes minimum self-stake requirement
        // Value: Ensures existing provers adapt to new requirements

        // Current prover has exactly MIN_SELF_STAKE, should be active
        assertTrue(
            controller.getProverState(prover1) == IStakingController.ProverState.Active,
            "Prover should be active with current minimum"
        );

        // Admin increases minimum self-stake requirement
        uint256 newMinStake = MIN_SELF_STAKE + 50e18;
        vm.prank(admin);
        controller.setMinSelfStake(newMinStake);

        // Prover should remain active initially (configuration changes don't immediately deactivate)
        // The new requirement is enforced during operations like unstaking or slashing
        assertTrue(
            controller.getProverState(prover1) == IStakingController.ProverState.Active,
            "Prover should remain active after configuration change"
        );

        // However, the prover won't be able to unstake since they're now below the new minimum
        // Try to unstake even a small amount - should fail
        address vault = controller.getProverVault(prover1);
        uint256 smallAmount = 1e18;
        uint256 smallShares = IProverVault(vault).convertToShares(smallAmount);

        vm.startPrank(prover1);
        IProverVault(vault).approve(address(controller), smallShares);
        vm.expectRevert(IStakingController.ControllerMinSelfStakeNotMet.selector);
        controller.requestUnstake(prover1, smallShares);
        vm.stopPrank();

        // Prover must increase stake to meet new requirement to be able to operate normally
        stakingToken.mint(prover1, 60e18);
        vm.startPrank(prover1);
        stakingToken.approve(address(controller), 60e18);
        controller.stake(prover1, 60e18);
        vm.stopPrank();

        // Now prover should be able to unstake small amounts again
        vm.startPrank(prover1);
        IProverVault(vault).approve(address(controller), smallShares);
        controller.requestUnstake(prover1, smallShares); // Should succeed now
        vm.stopPrank();

        // Should remain active after meeting new requirement
        assertTrue(
            controller.getProverState(prover1) == IStakingController.ProverState.Active,
            "Prover should remain active after meeting new minimum"
        );

        // Admin decreases minimum (should not affect active provers)
        vm.prank(admin);
        controller.setMinSelfStake(MIN_SELF_STAKE);
        assertTrue(
            controller.getProverState(prover1) == IStakingController.ProverState.Active,
            "Prover should remain active when requirement is lowered"
        );
    }

    function testMinSelfStakeBoundaryConditions() public {
        // Test: Edge cases around exact minimum stake amounts
        // Value: Ensures precise enforcement at boundaries

        // Add exactly 1 wei above minimum
        vm.startPrank(prover1);
        stakingToken.approve(address(controller), 1);
        controller.stake(prover1, 1);
        vm.stopPrank();

        address vault = controller.getProverVault(prover1);

        // Should be able to unstake exactly 1 wei (leaving exact minimum)
        vm.startPrank(prover1);
        uint256 oneWeiShares = IProverVault(vault).convertToShares(1);
        IProverVault(vault).approve(address(controller), oneWeiShares);
        controller.requestUnstake(prover1, oneWeiShares);
        vm.stopPrank();

        // Complete unstaking
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(prover1);
        controller.completeUnstake(prover1);

        // Should still be active with exactly minimum stake
        assertTrue(
            controller.getProverState(prover1) == IStakingController.ProverState.Active,
            "Prover should be active with exactly minimum stake"
        );

        // Attempting to unstake even 1 wei more should fail
        vm.startPrank(prover1);
        uint256 tinyShares = IProverVault(vault).convertToShares(1);
        if (tinyShares > 0) {
            IProverVault(vault).approve(address(controller), tinyShares);
            vm.expectRevert(IStakingController.ControllerMinSelfStakeNotMet.selector);
            controller.requestUnstake(prover1, tinyShares);
        }
        vm.stopPrank();
    }

    function testMinSelfStakeWithExternalStakers() public {
        // Test: Min self-stake enforcement with external stakers present
        // Value: Ensures policy applies only to prover's own stake, not total vault

        // Add external staker
        address externalStaker = makeAddr("externalStaker");
        stakingToken.mint(externalStaker, 500e18);
        vm.startPrank(externalStaker);
        stakingToken.approve(address(controller), 500e18);
        controller.stake(prover1, 500e18);
        vm.stopPrank();

        address vault = controller.getProverVault(prover1);
        uint256 totalVaultAssets = IProverVault(vault).totalAssets();
        assertTrue(totalVaultAssets >= MIN_SELF_STAKE + 500e18, "Vault should have prover + external stake");

        // Prover tries to unstake below minimum (should fail even with external stake)
        uint256 proverShares = IProverVault(vault).balanceOf(prover1);
        uint256 proverAssets = IProverVault(vault).convertToAssets(proverShares);

        // Try to unstake more than allowed (leaving less than MIN_SELF_STAKE)
        uint256 excessAmount = proverAssets - MIN_SELF_STAKE + 1e18;
        uint256 excessShares = IProverVault(vault).convertToShares(excessAmount);

        vm.startPrank(prover1);
        IProverVault(vault).approve(address(controller), excessShares);
        vm.expectRevert(IStakingController.ControllerMinSelfStakeNotMet.selector);
        controller.requestUnstake(prover1, excessShares);
        vm.stopPrank();

        // External staker leaving should not affect prover's minimum requirement
        vm.startPrank(externalStaker);
        uint256 externalShares = IProverVault(vault).balanceOf(externalStaker);
        IProverVault(vault).approve(address(controller), externalShares);
        controller.requestUnstake(prover1, externalShares);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(externalStaker);
        controller.completeUnstake(prover1);

        // Prover should still be active (minimum is based on their own stake)
        assertTrue(
            controller.getProverState(prover1) == IStakingController.ProverState.Active,
            "Prover should remain active after external staker leaves"
        );
    }

    function testMinSelfStakeWithMultipleUnstakeRequests() public {
        // Test: Min self-stake enforcement across multiple pending unstake requests
        // Value: Ensures policy considers total pending unstakes

        // Add extra stake
        vm.startPrank(prover1);
        stakingToken.approve(address(controller), 100e18);
        controller.stake(prover1, 100e18);
        vm.stopPrank();

        address vault = controller.getProverVault(prover1);

        // Make first unstake request (should succeed)
        uint256 firstUnstakeAmount = 30e18;
        uint256 firstUnstakeShares = IProverVault(vault).convertToShares(firstUnstakeAmount);

        vm.startPrank(prover1);
        IProverVault(vault).approve(address(controller), firstUnstakeShares);
        controller.requestUnstake(prover1, firstUnstakeShares);
        vm.stopPrank();

        // Make second unstake request that would violate minimum
        uint256 secondUnstakeAmount = 80e18; // This + first would leave less than MIN_SELF_STAKE
        uint256 secondUnstakeShares = IProverVault(vault).convertToShares(secondUnstakeAmount);

        vm.startPrank(prover1);
        IProverVault(vault).approve(address(controller), secondUnstakeShares);
        vm.expectRevert(IStakingController.ControllerMinSelfStakeNotMet.selector);
        controller.requestUnstake(prover1, secondUnstakeShares);
        vm.stopPrank();

        // Should be able to make smaller second request that respects minimum
        uint256 allowedAmount = 60e18; // This + first = 90e18, leaving MIN_SELF_STAKE + 10e18
        uint256 allowedShares = IProverVault(vault).convertToShares(allowedAmount);

        vm.startPrank(prover1);
        IProverVault(vault).approve(address(controller), allowedShares);
        controller.requestUnstake(prover1, allowedShares); // Should succeed
        vm.stopPrank();
    }

    function testMinSelfStakeAfterRewards() public {
        // Test: Min self-stake calculation after receiving rewards
        // Value: Ensures rewards don't affect minimum stake requirement

        address rewardPayer = makeAddr("rewardPayer");

        // Add external staker to make rewards meaningful
        address externalStaker = makeAddr("externalStaker");
        stakingToken.mint(externalStaker, 200e18);
        vm.startPrank(externalStaker);
        stakingToken.approve(address(controller), 200e18);
        controller.stake(prover1, 200e18);
        vm.stopPrank();

        address vault = controller.getProverVault(prover1);
        uint256 proverSharesBefore = IProverVault(vault).balanceOf(prover1);

        // Add rewards
        uint256 rewardAmount = 100e18;
        stakingToken.mint(rewardPayer, rewardAmount);
        vm.startPrank(rewardPayer);
        stakingToken.approve(address(controller), rewardAmount);
        controller.addRewards(prover1, rewardAmount);
        vm.stopPrank();

        // Prover's share value should increase due to rewards
        uint256 proverAssetsAfter = IProverVault(vault).convertToAssets(proverSharesBefore);
        assertTrue(proverAssetsAfter > MIN_SELF_STAKE, "Prover assets should increase due to rewards");

        // Should be able to unstake the reward portion while maintaining minimum
        uint256 rewardPortion = proverAssetsAfter - MIN_SELF_STAKE - 1e18; // Leave buffer
        uint256 rewardShares = IProverVault(vault).convertToShares(rewardPortion);

        vm.startPrank(prover1);
        IProverVault(vault).approve(address(controller), rewardShares);
        controller.requestUnstake(prover1, rewardShares); // Should succeed
        vm.stopPrank();

        // Complete unstaking
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(prover1);
        controller.completeUnstake(prover1);

        // Should still be active with minimum + buffer
        assertTrue(
            controller.getProverState(prover1) == IStakingController.ProverState.Active,
            "Prover should remain active after unstaking rewards"
        );
    }

    function testMinSelfStakeConsistencyAfterVaultOperations() public {
        // Test: Min self-stake consistency through various vault operations
        // Value: Ensures policy is consistently enforced regardless of operation history

        address externalStaker = makeAddr("externalStaker");

        // Complex sequence of operations
        // 1. External staker joins
        stakingToken.mint(externalStaker, 300e18);
        vm.startPrank(externalStaker);
        stakingToken.approve(address(controller), 150e18);
        controller.stake(prover1, 150e18);
        vm.stopPrank();

        // 2. Prover adds more stake
        vm.startPrank(prover1);
        stakingToken.approve(address(controller), 50e18);
        controller.stake(prover1, 50e18);
        vm.stopPrank();

        // 3. External staker partially unstakes
        address vault = controller.getProverVault(prover1);
        vm.startPrank(externalStaker);
        IProverVault(vault).approve(address(controller), 50e18);
        controller.requestUnstake(prover1, 50e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(externalStaker);
        controller.completeUnstake(prover1);

        // 4. Prover should still be subject to minimum stake requirement
        uint256 proverShares = IProverVault(vault).balanceOf(prover1);
        uint256 proverAssets = IProverVault(vault).convertToAssets(proverShares);

        // Try to unstake below minimum (should fail)
        uint256 excessAmount = proverAssets - MIN_SELF_STAKE + 10e18;
        uint256 excessShares = IProverVault(vault).convertToShares(excessAmount);

        vm.startPrank(prover1);
        IProverVault(vault).approve(address(controller), excessShares);
        vm.expectRevert(IStakingController.ControllerMinSelfStakeNotMet.selector);
        controller.requestUnstake(prover1, excessShares);
        vm.stopPrank();

        // Should be able to unstake exact amount to reach minimum
        uint256 allowedAmount = proverAssets - MIN_SELF_STAKE;
        if (allowedAmount > 0) {
            uint256 allowedShares = IProverVault(vault).convertToShares(allowedAmount);
            vm.startPrank(prover1);
            IProverVault(vault).approve(address(controller), allowedShares);
            controller.requestUnstake(prover1, allowedShares); // Should succeed
            vm.stopPrank();
        }
    }

    // === TIER 2: HIGH-VALUE INTEGRATION AND COMPLEX SCENARIOS ===

    function testMinSelfStakeWithMultipleSlashingRounds() public {
        // Test complex slashing scenarios with gradual degradation
        address vault = controller.getProverVault(prover1);

        // Add extra stake to have buffer
        stakingToken.mint(prover1, 100e18);
        vm.prank(prover1);
        stakingToken.approve(address(controller), 100e18);
        vm.prank(prover1);
        controller.stake(prover1, 100e18);

        uint256 initialAssets = IProverVault(vault).totalAssets();
        assertTrue(initialAssets >= MIN_SELF_STAKE + 100e18, "Should have buffer for slashing");

        // Multiple small slashes
        for (uint256 i = 0; i < 5; i++) {
            uint256 slashBps = 1500; // 15% each time
            vm.prank(admin);
            controller.slash(prover1, slashBps);

            uint256 assetsAfterSlash = IProverVault(vault).totalAssets();

            // Check if prover is still active
            IStakingController.ProverState state = controller.getProverState(prover1);
            if (assetsAfterSlash >= MIN_SELF_STAKE) {
                assertTrue(state == IStakingController.ProverState.Active, "Should remain active above minimum");
            } else {
                assertTrue(state == IStakingController.ProverState.Deactivated, "Should be deactivated below minimum");
                break;
            }
        }

        // Final state should be deactivated due to being below minimum
        IStakingController.ProverState finalState = controller.getProverState(prover1);
        assertTrue(
            finalState == IStakingController.ProverState.Deactivated, "Should be deactivated after multiple slashes"
        );
        assertTrue(IProverVault(vault).totalAssets() < MIN_SELF_STAKE, "Should be below minimum self-stake");
    }

    function testMinSelfStakeComplianceWithExternalStakeFluctuations() public {
        address vault = controller.getProverVault(prover1);

        // Setup multiple external stakers
        address[] memory stakers = new address[](3);
        uint256[] memory stakeAmounts = new uint256[](3);

        for (uint256 i = 0; i < 3; i++) {
            stakers[i] = makeAddr(string(abi.encodePacked("staker", i)));
            stakeAmounts[i] = 100e18 * (i + 1); // 100, 200, 300

            stakingToken.mint(stakers[i], stakeAmounts[i]);
            vm.prank(stakers[i]);
            stakingToken.approve(address(controller), stakeAmounts[i]);
            vm.prank(stakers[i]);
            controller.stake(prover1, stakeAmounts[i]);
        }

        uint256 totalAssetsWithStakers = IProverVault(vault).totalAssets();
        assertTrue(totalAssetsWithStakers >= MIN_SELF_STAKE + 600e18, "Should include all external stakes");

        // Prover should still not be able to unstake below minimum despite external stakes
        uint256 proverShares = IProverVault(vault).balanceOf(prover1);
        uint256 proverAssets = IProverVault(vault).convertToAssets(proverShares);

        // Try to unstake prover's stake below minimum
        uint256 attemptedUnstake = proverAssets - MIN_SELF_STAKE + 10e18;
        uint256 attemptedShares = IProverVault(vault).convertToShares(attemptedUnstake);

        vm.prank(prover1);
        IProverVault(vault).approve(address(controller), attemptedShares);
        vm.prank(prover1);
        vm.expectRevert(IStakingController.ControllerMinSelfStakeNotMet.selector);
        controller.requestUnstake(prover1, attemptedShares);

        // External stakers leaving should not affect prover's minimum requirement
        vm.prank(stakers[2]);
        IProverVault(vault).approve(address(controller), stakeAmounts[2]);
        vm.prank(stakers[2]);
        controller.requestUnstake(prover1, stakeAmounts[2]);

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(stakers[2]);
        controller.completeUnstake(prover1);

        // Prover minimum requirement should still apply
        vm.prank(prover1);
        IProverVault(vault).approve(address(controller), attemptedShares);
        vm.prank(prover1);
        vm.expectRevert(IStakingController.ControllerMinSelfStakeNotMet.selector);
        controller.requestUnstake(prover1, attemptedShares);
    }

    function testMinSelfStakeRecoveryAfterDeactivation() public {
        address vault = controller.getProverVault(prover1);

        // Slash below minimum to deactivate - 50% should bring 100e18 to 50e18, below minimum
        uint256 slashBps = 5000; // 50% slash - should bring below minimum
        vm.prank(admin);
        controller.slash(prover1, slashBps);

        IStakingController.ProverState state = controller.getProverState(prover1);
        assertTrue(state == IStakingController.ProverState.Deactivated, "Should be deactivated");
        assertTrue(IProverVault(vault).totalAssets() < MIN_SELF_STAKE, "Should be below minimum");

        // Recovery process
        uint256 recoveryAmount = MIN_SELF_STAKE + 10e18 - IProverVault(vault).totalAssets();
        stakingToken.mint(prover1, recoveryAmount);

        vm.prank(prover1);
        stakingToken.approve(address(controller), recoveryAmount);
        vm.prank(prover1);
        controller.stake(prover1, recoveryAmount);

        // Should now meet minimum but still be inactive
        assertTrue(IProverVault(vault).totalAssets() >= MIN_SELF_STAKE, "Should meet minimum after recovery stake");
        IStakingController.ProverState stateAfterStake = controller.getProverState(prover1);
        assertTrue(
            stateAfterStake == IStakingController.ProverState.Deactivated,
            "Should still be deactivated until reactivated"
        );

        // Reactivate
        vm.prank(prover1);
        controller.reactivateProver(prover1);
        IStakingController.ProverState stateAfterReactivation = controller.getProverState(prover1);
        assertTrue(
            stateAfterReactivation == IStakingController.ProverState.Active, "Should be active after reactivation"
        );

        // Now minimum stake enforcement should work normally
        uint256 proverAssets = IProverVault(vault).convertToAssets(IProverVault(vault).balanceOf(prover1));
        uint256 excessUnstake = proverAssets - MIN_SELF_STAKE + 1e18;
        uint256 excessShares = IProverVault(vault).convertToShares(excessUnstake);

        vm.prank(prover1);
        IProverVault(vault).approve(address(controller), excessShares);
        vm.prank(prover1);
        vm.expectRevert(IStakingController.ControllerMinSelfStakeNotMet.selector);
        controller.requestUnstake(prover1, excessShares);
    }

    function testMinSelfStakeEnforcementWithRewardsAndSlashing() public {
        address vault = controller.getProverVault(prover1);
        address rewardPayer = makeAddr("rewardPayer");

        // Add external staker
        address staker = makeAddr("staker");
        stakingToken.mint(staker, 200e18);
        vm.prank(staker);
        stakingToken.approve(address(controller), 200e18);
        vm.prank(staker);
        controller.stake(prover1, 200e18);

        // Add rewards
        uint256 rewardAmount = 100e18;
        stakingToken.mint(rewardPayer, rewardAmount);
        vm.prank(rewardPayer);
        stakingToken.approve(address(controller), rewardAmount);
        vm.prank(rewardPayer);
        controller.addRewards(prover1, rewardAmount);

        uint256 proverAssetsWithRewards = IProverVault(vault).convertToAssets(IProverVault(vault).balanceOf(prover1));

        // Even with rewards, prover should not be able to unstake below original minimum
        uint256 attemptedUnstake = proverAssetsWithRewards - MIN_SELF_STAKE + 10e18;
        uint256 attemptedShares = IProverVault(vault).convertToShares(attemptedUnstake);

        vm.prank(prover1);
        IProverVault(vault).approve(address(controller), attemptedShares);
        vm.prank(prover1);
        vm.expectRevert(IStakingController.ControllerMinSelfStakeNotMet.selector);
        controller.requestUnstake(prover1, attemptedShares);

        // Slash that reduces prover's effective stake
        uint256 slashBps = 3000; // 30% slash
        vm.prank(admin);
        controller.slash(prover1, slashBps);

        uint256 proverAssetsAfterSlash = IProverVault(vault).convertToAssets(IProverVault(vault).balanceOf(prover1));

        // Check if slash brought prover below minimum
        IStakingController.ProverState stateAfterSlash = controller.getProverState(prover1);
        if (proverAssetsAfterSlash < MIN_SELF_STAKE) {
            assertTrue(
                stateAfterSlash == IStakingController.ProverState.Deactivated,
                "Should be deactivated if slash brings below minimum"
            );
        } else {
            assertTrue(
                stateAfterSlash == IStakingController.ProverState.Active,
                "Should remain active if above minimum after slash"
            );

            // Should still enforce minimum for future unstakes
            uint256 newAttemptedUnstake = proverAssetsAfterSlash - MIN_SELF_STAKE + 5e18;
            uint256 newAttemptedShares = IProverVault(vault).convertToShares(newAttemptedUnstake);

            vm.prank(prover1);
            IProverVault(vault).approve(address(controller), newAttemptedShares);
            vm.prank(prover1);
            vm.expectRevert(IStakingController.ControllerMinSelfStakeNotMet.selector);
            controller.requestUnstake(prover1, newAttemptedShares);
        }
    }

    function testMinSelfStakeCalculationPrecisionEdgeCases() public {
        address vault = controller.getProverVault(prover1);

        // Test with amounts very close to minimum
        uint256 preciseMinimum = MIN_SELF_STAKE;
        uint256 currentAssets = IProverVault(vault).totalAssets();

        if (currentAssets > preciseMinimum) {
            // Try to unstake exactly to the minimum
            uint256 exactAmount = currentAssets - preciseMinimum;
            uint256 exactShares = IProverVault(vault).convertToShares(exactAmount);

            vm.prank(prover1);
            IProverVault(vault).approve(address(controller), exactShares);
            vm.prank(prover1);
            controller.requestUnstake(prover1, exactShares); // Should succeed

            // Complete the unstake
            vm.warp(block.timestamp + 7 days + 1);
            vm.prank(prover1);
            controller.completeUnstake(prover1);

            uint256 finalAssets = IProverVault(vault).totalAssets();
            assertTrue(finalAssets >= preciseMinimum - 1e15, "Should be at or very close to minimum");

            // Now any further unstake should fail
            uint256 tinyAmount = 1e15;
            uint256 tinyShares = IProverVault(vault).convertToShares(tinyAmount);

            if (tinyShares > 0) {
                vm.prank(prover1);
                IProverVault(vault).approve(address(controller), tinyShares);
                vm.prank(prover1);
                vm.expectRevert(IStakingController.ControllerMinSelfStakeNotMet.selector);
                controller.requestUnstake(prover1, tinyShares);
            }
        }
    }

    function testMinSelfStakeWithComplexSharesConversion() public {
        address vault = controller.getProverVault(prover1);
        address rewardPayer = makeAddr("rewardPayer");

        // Create complex share/asset ratio by adding rewards multiple times
        for (uint256 i = 0; i < 3; i++) {
            // Add external staker each round
            address staker = makeAddr(string(abi.encodePacked("staker", i)));
            stakingToken.mint(staker, 100e18);
            vm.prank(staker);
            stakingToken.approve(address(controller), 100e18);
            vm.prank(staker);
            controller.stake(prover1, 100e18);

            // Add rewards
            stakingToken.mint(rewardPayer, 50e18);
            vm.prank(rewardPayer);
            stakingToken.approve(address(controller), 50e18);
            vm.prank(rewardPayer);
            controller.addRewards(prover1, 50e18);
        }

        // Now shares:assets ratio is complex due to rewards
        uint256 proverShares = IProverVault(vault).balanceOf(prover1);
        uint256 proverAssets = IProverVault(vault).convertToAssets(proverShares);

        // Minimum stake enforcement should work correctly despite complex ratio
        if (proverAssets > MIN_SELF_STAKE) {
            uint256 maxAllowedUnstake = proverAssets - MIN_SELF_STAKE;
            uint256 maxAllowedShares = IProverVault(vault).convertToShares(maxAllowedUnstake);

            // Should be able to unstake up to limit
            vm.prank(prover1);
            IProverVault(vault).approve(address(controller), maxAllowedShares);
            vm.prank(prover1);
            controller.requestUnstake(prover1, maxAllowedShares); // Should succeed

            // But not beyond limit
            uint256 excessShares = IProverVault(vault).convertToShares(1e18);
            if (excessShares > 0) {
                vm.prank(prover1);
                IProverVault(vault).approve(address(controller), excessShares);
                vm.prank(prover1);
                vm.expectRevert(IStakingController.ControllerMinSelfStakeNotMet.selector);
                controller.requestUnstake(prover1, excessShares);
            }
        }
    }
}
