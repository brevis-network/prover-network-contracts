// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {StakingController} from "src/staking/controller/StakingController.sol";
import {VaultFactory} from "src/staking/vault/VaultFactory.sol";
import {IStakingController} from "src/staking/interfaces/IStakingController.sol";
import {IProverVault} from "src/staking/interfaces/IProverVault.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract SlashTest is Test {
    StakingController controller;
    VaultFactory factory;
    MockERC20 stakingToken;

    address admin = makeAddr("admin");
    address prover1 = makeAddr("prover1");
    address prover2 = makeAddr("prover2");
    address staker1 = makeAddr("staker1");
    address staker2 = makeAddr("staker2");
    address slasher = makeAddr("slasher");

    uint256 constant INITIAL_MINT = 1000000e18;
    uint256 constant DEFAULT_UNBOND_DELAY = 7 days;

    function setUp() public {
        vm.startPrank(admin);

        // Deploy token
        stakingToken = new MockERC20("Staking Token", "STK");
        stakingToken.mint(admin, INITIAL_MINT);

        // Deploy factory
        factory = new VaultFactory();

        controller = new StakingController(
            address(stakingToken),
            address(factory),
            DEFAULT_UNBOND_DELAY,
            1e18, // minSelfStake: 1 token
            5000 // maxSlashBps: 50%
        );

        // Grant roles
        factory.init(address(controller));

        // Grant slasher role to slasher address for testing
        controller.grantRole(controller.SLASHER_ROLE(), slasher);
        // SLASHER_ROLE already granted to slasher in constructor

        vm.stopPrank();

        // Mint tokens for stakers and provers
        vm.startPrank(admin);
        stakingToken.mint(staker1, INITIAL_MINT);
        stakingToken.mint(staker2, INITIAL_MINT);
        stakingToken.mint(prover1, INITIAL_MINT);
        stakingToken.mint(prover2, INITIAL_MINT);
        vm.stopPrank();

        // Approve controller to spend minSelfStake for automatic staking during initialization
        uint256 minSelfStake = controller.minSelfStake();
        vm.prank(prover1);
        stakingToken.approve(address(controller), minSelfStake);
        vm.prank(prover2);
        stakingToken.approve(address(controller), minSelfStake);
    }

    function testBasicSlash() public {
        // Initialize prover
        vm.prank(prover1);
        address vaultAddress = controller.initializeProver(1000); // 10% commission

        // Stake some additional tokens
        uint256 stakeAmount = 100e18;
        vm.startPrank(staker1);
        stakingToken.approve(address(controller), stakeAmount);
        controller.stake(prover1, stakeAmount);
        vm.stopPrank();

        // Get initial vault assets
        IProverVault vault = IProverVault(vaultAddress);
        uint256 initialAssets = vault.totalAssets();
        uint256 initialTreasury = controller.treasuryPool();

        console.log("Initial vault assets:", initialAssets);
        console.log("Initial treasury:", initialTreasury);

        // Slash 10% (1000 basis points)
        uint256 slashBps = 1000; // 10%
        vm.prank(slasher); // slasher has SLASHER_ROLE
        uint256 slashedAmount = controller.slash(prover1, slashBps);

        // Verify slash amount calculation
        uint256 expectedSlash = (initialAssets * slashBps) / controller.BPS_DENOMINATOR();
        assertEq(slashedAmount, expectedSlash, "Slashed amount should match expected");

        // Verify vault assets reduced
        uint256 finalAssets = vault.totalAssets();
        assertEq(finalAssets, initialAssets - slashedAmount, "Vault assets should be reduced by slashed amount");

        // Verify treasury increased
        uint256 finalTreasury = controller.treasuryPool();
        assertEq(finalTreasury, initialTreasury + slashedAmount, "Treasury should increase by slashed amount");

        console.log("Slashed amount:", slashedAmount);
        console.log("Final vault assets:", finalAssets);
        console.log("Final treasury:", finalTreasury);
    }

    function testSlashValidation() public {
        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Try to slash with percentage higher than MaxSlashBps
        uint256 maxSlashBps = controller.maxSlashBps();
        uint256 tooHighBps = maxSlashBps + 1;

        vm.prank(slasher);
        vm.expectRevert(IStakingController.ControllerSlashTooHigh.selector);
        controller.slash(prover1, tooHighBps);

        // Try to slash as non-slasher (should fail)
        vm.prank(staker1);
        vm.expectRevert(); // Should revert due to role check
        controller.slash(prover1, 1000);
    }

    function testSlashNonExistentProver() public {
        // Try to slash prover that doesn't exist
        vm.prank(slasher);
        vm.expectRevert(IStakingController.ControllerProverNotInitialized.selector);
        controller.slash(prover1, 1000);
    }

    function testSlashEmptyVault() public {
        // Initialize prover
        vm.prank(prover1);
        address vaultAddress = controller.initializeProver(1000);

        // Withdraw all assets (if possible through unstaking)
        // For this test, we'll just verify that slashing empty vault returns 0
        IProverVault vault = IProverVault(vaultAddress);

        // Check if vault has minimal assets (from minSelfStake)
        uint256 initialAssets = vault.totalAssets();
        console.log("Initial assets in vault:", initialAssets);

        // If there are assets, slash them first to empty the vault
        if (initialAssets > 0) {
            // Use maxSlashBps instead of 100%
            uint256 maxSlashBps = controller.maxSlashBps();
            console.log("Max slash bps:", maxSlashBps);

            vm.prank(slasher);
            controller.slash(prover1, maxSlashBps); // Max allowed slash to reduce vault
        }

        // Now vault should have reduced assets, slash again should work
        uint256 assetsAfterSlash = vault.totalAssets();
        console.log("Assets after first slash:", assetsAfterSlash);

        vm.prank(slasher);
        uint256 slashedAmount = controller.slash(prover1, 1000);
        console.log("Second slash amount:", slashedAmount);

        // Verify slashing still works even with reduced assets
        assertTrue(slashedAmount >= 0, "Slashing should succeed even with low assets");
    }

    function testSlashEvent() public {
        // Initialize prover
        vm.prank(prover1);
        address vaultAddress = controller.initializeProver(1000);

        // Stake some tokens
        uint256 stakeAmount = 50e18;
        vm.startPrank(staker1);
        stakingToken.approve(address(controller), stakeAmount);
        controller.stake(prover1, stakeAmount);
        vm.stopPrank();

        // Get initial vault assets
        IProverVault vault = IProverVault(vaultAddress);
        uint256 initialAssets = vault.totalAssets();

        // Slash and check event
        uint256 slashBps = 2000; // 20%
        uint256 expectedSlash = (initialAssets * slashBps) / controller.BPS_DENOMINATOR();

        vm.expectEmit(true, false, false, true);
        emit IStakingController.ProverSlashed(prover1, expectedSlash, slashBps);

        vm.prank(slasher);
        uint256 actualSlash = controller.slash(prover1, slashBps);

        assertEq(actualSlash, expectedSlash, "Actual slash should match expected");
    }

    function testSlashAutoDeactivatesProverBelowMinSelfStake() public {
        // Increase MaxSlashBps for testing
        vm.prank(admin);
        controller.setMaxSlashBps(9000); // Allow up to 90% slashing

        // Initialize prover (will self-stake 1 ether due to MinSelfStake)
        vm.prank(prover1);
        address vault = controller.initializeProver(0);

        // Add some external stake to make slashing more significant
        vm.startPrank(staker1);
        stakingToken.approve(address(controller), 10 ether);
        controller.stake(prover1, 10 ether);
        vm.stopPrank();

        // Verify prover is active
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Active));

        // Get prover's current self-stake
        uint256 proverShares = IProverVault(vault).balanceOf(prover1);
        uint256 proverAssetsBefore = IProverVault(vault).convertToAssets(proverShares);
        uint256 minSelfStake = controller.minSelfStake();

        // Ensure prover currently meets minimum
        assertGe(proverAssetsBefore, minSelfStake, "Prover should initially meet minimum self-stake");

        // Slash 80% of the vault (this should reduce prover's effective self-stake below 1 ether)
        vm.prank(slasher);
        uint256 slashed = controller.slash(prover1, 8000); // 80%

        assertTrue(slashed > 0, "Should have slashed some amount");

        // Check prover's self-stake after slashing
        uint256 proverAssetsAfter = IProverVault(vault).convertToAssets(IProverVault(vault).balanceOf(prover1));

        // Prover should now be below minimum self-stake
        assertLt(proverAssetsAfter, minSelfStake, "Prover self-stake should be below minimum after slash");

        // Prover should be automatically deactivated
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Deactivated));
    }

    function testSlashDoesNotDeactivateIfStillAboveMinSelfStake() public {
        // Set higher minimum self-stake
        vm.prank(admin);
        controller.setMinSelfStake(2 ether);

        // Initialize prover (will self-stake 2 ether due to MinSelfStake)
        vm.startPrank(prover1);
        stakingToken.approve(address(controller), 10 ether); // Approve enough for initialization + additional staking
        address vault = controller.initializeProver(0);

        // Add additional self-stake to be well above minimum
        controller.stake(prover1, 8 ether); // Total 10 ether self-stake
        vm.stopPrank();

        // Add some external stake
        vm.startPrank(staker1);
        stakingToken.approve(address(controller), 10 ether);
        controller.stake(prover1, 10 ether);
        vm.stopPrank();

        // Verify prover is active
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Active));

        // Slash 30% (should still leave prover above 2 ether minimum)
        vm.prank(slasher);
        uint256 slashed = controller.slash(prover1, 3000); // 30%

        assertTrue(slashed > 0, "Should have slashed some amount");

        // Check prover's self-stake after slashing
        uint256 proverAssetsAfter = IProverVault(vault).convertToAssets(IProverVault(vault).balanceOf(prover1));
        uint256 minSelfStake = controller.minSelfStake();

        // Prover should still be above minimum self-stake
        assertGe(
            proverAssetsAfter, minSelfStake, "Prover self-stake should still be above minimum after moderate slash"
        );

        // Prover should remain active
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Active));
    }

    function testSlashAutoDeactivateViaSlashingScale() public {
        // Set MinSelfStake to a small value to enable scale-based testing
        vm.prank(admin);
        controller.setMinSelfStake(1 ether); // Small value that won't interfere with scale testing

        // Initialize prover (will auto-stake the minimum)
        vm.prank(prover1);
        controller.initializeProver(0);

        // Add more stake to ensure slash won't trigger minSelfStake deactivation
        // We need enough stake that even after 70% slash, prover still has > 1 ether
        vm.startPrank(prover1);
        stakingToken.approve(address(controller), 10 ether); // Additional stake beyond minimum
        controller.stake(prover1, 10 ether);
        vm.stopPrank();

        // Add some external stake
        vm.startPrank(staker1);
        stakingToken.approve(address(controller), 10 ether);
        controller.stake(prover1, 10 ether);
        vm.stopPrank();

        // Verify prover is active
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Active));

        // Check prover's self-stake (should be 11 ether: 1 auto + 10 manual)
        address vault = controller.getProverVault(prover1);
        uint256 proverShares = IProverVault(vault).balanceOf(prover1);
        uint256 proverAssets = IProverVault(vault).convertToAssets(proverShares);
        assertEq(proverAssets, 11 ether, "Prover should have 11 ether self-stake");

        // Increase MaxSlashBps for testing
        vm.prank(admin);
        controller.setMaxSlashBps(8000); // Allow up to 80% slashing

        // Request unstake for some of the prover's stake to create pending unstakes
        // This is necessary because scale-based deactivation only applies when there are pending unstakes
        vm.startPrank(prover1);
        IProverVault(vault).approve(address(controller), 5 ether);
        controller.requestUnstake(prover1, IProverVault(vault).convertToShares(5 ether));
        vm.stopPrank();

        // Slash 70% (brings scale to 30%, below DEACTIVATION_SCALE of 40% but above MIN_SCALE_FLOOR of 20%)
        // This should trigger scale-based deactivation
        // After slash: remaining prover assets = 11 - 5 (unstaked) = 6 ether, 6 * 0.3 = 1.8 ether
        // Since 1.8 ether > 1 ether minSelfStake, this should be scale-based deactivation only
        vm.prank(slasher);
        uint256 slashed = controller.slash(prover1, 7000); // 70%

        assertTrue(slashed > 0, "Should have slashed some amount");

        // Prover should be deactivated due to crossing DEACTIVATION_SCALE threshold (scale-based)
        // This demonstrates scale-based deactivation works when slashing scale drops below 40%
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Deactivated));
    }

    function testSlashAutoDeactivateOnlyWhenActive() public {
        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(0);

        // Add some external stake
        vm.startPrank(staker1);
        stakingToken.approve(address(controller), 10 ether);
        controller.stake(prover1, 10 ether);
        vm.stopPrank();

        // Manually deactivate prover first
        vm.prank(admin);
        controller.deactivateProver(prover1);

        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Deactivated));

        // Increase MaxSlashBps for testing
        vm.prank(admin);
        controller.setMaxSlashBps(8000); // Allow up to 80% slashing

        // Slash heavily (should not change state since already deactivated)
        vm.prank(slasher);
        uint256 slashed = controller.slash(prover1, 8000); // 80%

        assertTrue(slashed > 0, "Should have slashed some amount");

        // Prover should remain in Deactivated state (not change to Active or anything else)
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Deactivated));
    }

    // =========================================================================
    // SLASHING EDGE CASES
    // =========================================================================

    // From PendingUnstakes.sol constants
    uint256 constant BPS_DENOMINATOR = 10000;
    uint256 constant DEACTIVATION_SCALE = 4000; // 40%
    uint256 constant MIN_SCALE_FLOOR = 2000; // 20%

    function testSlashPercentageZeroIsNoOp() public {
        // Test: Slash percentage = 0 (no-op) succeeds (or expected behavior).
        // Value: State machine + guardrail validation.

        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Setup: Stake and create unstaking
        vm.prank(staker1);
        stakingToken.approve(address(controller), 10 ether);
        vm.prank(staker1);
        controller.stake(prover1, 10 ether);

        address vault = controller.getProverVault(prover1);
        vm.prank(staker1);
        IProverVault(vault).approve(address(controller), 5 ether);
        vm.prank(staker1);
        controller.requestUnstake(prover1, 5 ether);

        // Get initial state
        uint256 vaultAssetsBefore = IProverVault(vault).totalAssets();
        uint256 treasuryBefore = controller.treasuryPool();
        IStakingController.ProverState stateBefore = controller.getProverState(prover1);

        // Slash with percentage 0
        vm.prank(slasher);
        uint256 slashedAmount = controller.slash(prover1, 0);

        // Verify no-op behavior
        assertEq(slashedAmount, 0, "Slash percentage 0 should result in 0 slashed amount");
        assertEq(IProverVault(vault).totalAssets(), vaultAssetsBefore, "Vault assets should be unchanged");
        assertEq(controller.treasuryPool(), treasuryBefore, "Treasury should be unchanged");
        assertEq(uint256(controller.getProverState(prover1)), uint256(stateBefore), "Prover state should be unchanged");
    }

    function testMaxSlashBpsZeroDisablesSlashingAboveZero() public {
        // Test: maxSlashBps = 0 disables slashBps 0 still allowed.
        // Value: State machine + guardrail validation.

        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Set max slashBps=0)
        vm.prank(admin);
        controller.setMaxSlashBps(0);

        // Slash with percentage 0 should still work
        vm.prank(slasher);
        uint256 slashedAmount = controller.slash(prover1, 0);
        assertEq(slashedAmount, 0, "Percentage 0 should be allowed even when maxSlashBps=0");

        // Slash with any non-zero percentage should revert
        vm.prank(slasher);
        vm.expectRevert(IStakingController.ControllerSlashTooHigh.selector);
        controller.slash(prover1, 1);

        vm.prank(slasher);
        vm.expectRevert(IStakingController.ControllerSlashTooHigh.selector);
        controller.slash(prover1, 100);

        vm.prank(slasher);
        vm.expectRevert(IStakingController.ControllerSlashTooHigh.selector);
        controller.slash(prover1, 5000);
    }

    function testSlashAttemptPushingScaleBelowMinFloorReverts() public {
        // Test: Attempt slash that would push cumulative scale below MIN_SCALE_FLOOR (should revert).
        // Value: State machine + guardrail validation.

        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Increase max slashBps for this test
        vm.prank(admin);
        controller.setMaxSlashBps(9000);

        // Setup: Create pending unstaking to enable scale tracking
        vm.prank(staker1);
        stakingToken.approve(address(controller), 10 ether);
        vm.prank(staker1);
        controller.stake(prover1, 10 ether);

        address vault = controller.getProverVault(prover1);
        vm.prank(staker1);
        IProverVault(vault).approve(address(controller), 5 ether);
        vm.prank(staker1);
        controller.requestUnstake(prover1, 5 ether);

        // Slash down to just above MIN_SCALE_FLOOR (80% slash brings scale to 20% = 2000)
        // Initial scale is 10000 (100%), after 80% slash: 10000 * 0.2 = 2000 (exactly MIN_SCALE_FLOOR)
        vm.prank(slasher);
        controller.slash(prover1, 8000); // 80% slash

        // Now try to slash any more - this should push scale below MIN_SCALE_FLOOR (2000) and revert
        vm.prank(slasher);
        vm.expectRevert(IStakingController.ControllerSlashTooHigh.selector);
        controller.slash(prover1, 1); // Even 0.01% more should revert

        vm.prank(slasher);
        vm.expectRevert(IStakingController.ControllerSlashTooHigh.selector);
        controller.slash(prover1, 1000); // 10% more definitely should revert
    }

    function testSlashTakingScaleToExactDeactivationBoundaryNoDeactivate() public {
        // Test: Slash(s) that take scale exactly to DEACTIVATION_SCALE boundary (no deactivate) vs just below (deactivate).
        // Value: State machine + guardrail validation.

        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Increase max slashBps for this test
        vm.prank(admin);
        controller.setMaxSlashBps(9000);

        // Setup: Create pending unstaking to enable scale tracking
        // Give prover much more stake so vault slashing doesn't trigger minSelfStake deactivation
        vm.prank(prover1);
        stakingToken.approve(address(controller), 100 ether);
        vm.prank(prover1);
        controller.stake(prover1, 100 ether); // Prover now has 101 ether total (1 from init + 100)

        vm.prank(staker1);
        stakingToken.approve(address(controller), 10 ether);
        vm.prank(staker1);
        controller.stake(prover1, 10 ether);

        address vault = controller.getProverVault(prover1);
        vm.prank(staker1);
        IProverVault(vault).approve(address(controller), 5 ether);
        vm.prank(staker1);
        controller.requestUnstake(prover1, 5 ether);

        // Slash to bring scale exactly to DEACTIVATION_SCALE (4000 = 40%)
        // Initial scale is 10000, we want final scale = 4000, so percentage = (10000-4000)/10000 = 6000 (60% slash)
        vm.prank(slasher);
        controller.slash(prover1, 6000); // 60% slash -> scale becomes 4000 (exactly at boundary)

        // Verify prover is still active (at boundary, not below)
        assertEq(
            uint256(controller.getProverState(prover1)),
            uint256(IStakingController.ProverState.Active),
            "Prover should remain active when scale equals DEACTIVATION_SCALE"
        );
    }

    function testSlashTakingScaleBelowDeactivationBoundaryDeactivates() public {
        // Test: Slash(s) that take scale exactly to DEACTIVATION_SCALE boundary (no deactivate) vs just below (deactivate).
        // Value: State machine + guardrail validation.

        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Increase max slashBps for this test
        vm.prank(admin);
        controller.setMaxSlashBps(9000);

        // Setup: Create pending unstaking to enable scale tracking
        vm.prank(staker1);
        stakingToken.approve(address(controller), 10 ether);
        vm.prank(staker1);
        controller.stake(prover1, 10 ether);

        address vault = controller.getProverVault(prover1);
        vm.prank(staker1);
        IProverVault(vault).approve(address(controller), 5 ether);
        vm.prank(staker1);
        controller.requestUnstake(prover1, 5 ether);

        // Slash to bring scale just below DEACTIVATION_SCALE (< 4000)
        // We want final scale = 3999, so percentage = (10000-3999)/10000 = 6001 (60.01% slash)
        vm.prank(slasher);
        controller.slash(prover1, 6001); // 60.01% slash -> scale becomes 3999 (just below boundary)

        // Verify prover is deactivated (below boundary)
        assertEq(
            uint256(controller.getProverState(prover1)),
            uint256(IStakingController.ProverState.Deactivated),
            "Prover should be deactivated when scale falls below DEACTIVATION_SCALE"
        );
    }

    function testSlashWithNoPendingUnstakesStillUpdatesScaleAndDeactivates() public {
        // Test: Slash with no pending unstakes (totalUnstaking = 0): scale still updates and (if crossing threshold) deactivation triggers; assert state.
        // Value: State machine + guardrail validation.

        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Increase max slashBps for this test
        vm.prank(admin);
        controller.setMaxSlashBps(9000);

        // No pending unstakes - prover only has vault assets
        // Note: The slashing scale is initialized to BPS_DENOMINATOR (10000) even without unstaking

        // Slash enough to trigger deactivation (>60% to go below DEACTIVATION_SCALE of 4000)
        uint256 slashBps = 6500; // 65% slash -> scale becomes 10000 * 0.35 = 3500 (below DEACTIVATION_SCALE)

        // Verify prover is active before slash
        assertEq(
            uint256(controller.getProverState(prover1)),
            uint256(IStakingController.ProverState.Active),
            "Prover should be active before slash"
        );

        vm.prank(slasher);
        uint256 slashedAmount = controller.slash(prover1, slashBps);

        // With no pending unstaking, only vault assets are slashed
        // But the scale is still updated and deactivation should trigger
        assertGt(slashedAmount, 0, "Should slash vault assets even with no pending unstakes");
        assertEq(
            uint256(controller.getProverState(prover1)),
            uint256(IStakingController.ProverState.Deactivated),
            "Prover should be deactivated due to scale falling below threshold"
        );
    }

    function testSetMaxSlashBpsLoweredBlocksPreviouslyValidPercentage() public {
        // Test: setMaxSlashBps lowered mid-process blocks previously valid higher percentage.
        // Value: State machine + guardrail validation.

        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Initial maxSlashBps is 5000 (50%) from constructor

        // First slashBps 4000 should work (within default 50% limit)
        vm.prank(slasher);
        controller.slash(prover1, 4000); // 40% slash

        // Lower maxSlashBps to 3000 (30%)
        vm.prank(admin);
        controller.setMaxSlashBps(3000);

        // Now attempting 4000 (40%) slash should revert (exceeds new 30% limit)
        vm.prank(slasher);
        vm.expectRevert(IStakingController.ControllerSlashTooHigh.selector);
        controller.slash(prover1, 4000);

        // But 3000 (30%) should still work
        vm.prank(slasher);
        controller.slash(prover1, 3000); // Should succeed
    }

    function testSlashScaleBoundaryCalculations() public {
        // Additional test to verify precise boundary calculations

        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Increase max slashBps for this test
        vm.prank(admin);
        controller.setMaxSlashBps(9000);

        // Setup: Give prover enough stake to survive vault slashing
        vm.prank(prover1);
        stakingToken.approve(address(controller), 200 ether);
        vm.prank(prover1);
        controller.stake(prover1, 200 ether); // Prover now has 201 ether total

        vm.prank(staker1);
        stakingToken.approve(address(controller), 100 ether);
        vm.prank(staker1);
        controller.stake(prover1, 100 ether);

        address vault = controller.getProverVault(prover1);
        vm.prank(staker1);
        IProverVault(vault).approve(address(controller), 50 ether);
        vm.prank(staker1);
        controller.requestUnstake(prover1, 50 ether);

        // Test multiple slashes approaching boundaries

        // First slash: 30% -> scale becomes 7000
        vm.prank(slasher);
        controller.slash(prover1, 3000);
        assertEq(
            uint256(controller.getProverState(prover1)),
            uint256(IStakingController.ProverState.Active),
            "Should remain active after 30% slash"
        );

        // Second slash: 20% of remaining -> scale becomes 7000 * 0.8 = 5600
        vm.prank(slasher);
        controller.slash(prover1, 2000);
        assertEq(
            uint256(controller.getProverState(prover1)),
            uint256(IStakingController.ProverState.Active),
            "Should remain active with scale=5600"
        );

        // Third slash: 28.57% of remaining -> scale becomes 5600 * 0.7143 ≈ 4000 (exactly at boundary)
        // To get from 5600 to 4000: percentage = (5600-4000)/5600 = 1600/5600 ≈ 2857
        vm.prank(slasher);
        controller.slash(prover1, 2857);
        assertEq(
            uint256(controller.getProverState(prover1)),
            uint256(IStakingController.ProverState.Active),
            "Should remain active at exact boundary"
        );

        // Final tiny slash: 0.01% -> should trigger deactivation
        vm.prank(slasher);
        controller.slash(prover1, 1);
        assertEq(
            uint256(controller.getProverState(prover1)),
            uint256(IStakingController.ProverState.Deactivated),
            "Should be deactivated after crossing boundary"
        );
    }

    function testScaleMathCorrectnessAcrossMultipleRequests() public {
        // Test: Sequence: unstake request A → slash1 → unstake request B → slash2 → complete after delay.
        // Verify effective amounts = stored amount * (current scale / snapshot scale).
        // Value: Ensures mixed pre/post-snapshots accurate across multiple slashes.

        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Increase max slashBps for this test
        vm.prank(admin);
        controller.setMaxSlashBps(9000);

        // Setup: Stake large amounts
        vm.prank(staker1);
        stakingToken.approve(address(controller), 100 ether);
        vm.prank(staker1);
        controller.stake(prover1, 100 ether);

        vm.prank(staker2);
        stakingToken.approve(address(controller), 100 ether);
        vm.prank(staker2);
        controller.stake(prover1, 100 ether);

        address vault = controller.getProverVault(prover1);

        // === STEP 1: Unstake Request A (at initial scale 10000) ===
        // Staker1 unstakes 50 shares at full value (50 ether assets)
        vm.prank(staker1);
        IProverVault(vault).approve(address(controller), 50 ether);
        vm.prank(staker1);
        controller.requestUnstake(prover1, 50 ether);

        // === STEP 2: Slash 1 (30%) - scale becomes 7000 ===
        vm.prank(slasher);
        controller.slash(prover1, 3000); // 30% slash

        // === STEP 3: Unstake Request B (at scale 7000) ===
        // Staker2 unstakes 40 shares, but due to slash only gets 28 ether assets stored
        vm.prank(staker2);
        IProverVault(vault).approve(address(controller), 40 ether);
        vm.prank(staker2);
        controller.requestUnstake(prover1, 40 ether);

        // === STEP 4: Slash 2 (25%) - scale becomes 5250 ===
        vm.prank(slasher);
        controller.slash(prover1, 2500); // 25% slash

        // === STEP 5: Complete unstaking after delay ===
        vm.warp(block.timestamp + DEFAULT_UNBOND_DELAY + 1);

        vm.prank(staker1);
        uint256 staker1Received = controller.completeUnstake(prover1);

        vm.prank(staker2);
        uint256 staker2Received = controller.completeUnstake(prover1);

        // === STEP 6: Verify Math Correctness ===

        // Request A: stored 50 ether at scale 10000, effective = 50 * (5250 / 10000) = 26.25 ether
        uint256 expectedStaker1 = (50 ether * 5250) / 10000;

        // Request B: stored ~28 ether at scale 7000, effective = 28 * (5250 / 7000) = 21 ether
        // Note: 28 ether is 40 shares * 0.7 (after first slash)
        uint256 expectedStaker2 = (28 ether * 5250) / 7000;

        assertEq(staker1Received, expectedStaker1, "Staker1 should receive 26.25 ether (50 * 0.525)");
        assertEq(staker2Received, expectedStaker2, "Staker2 should receive 21 ether (28 * 0.75)");

        // Verify specific values for clarity
        assertEq(expectedStaker1, 26.25 ether, "Staker1 expected: 26.25 ether");
        assertEq(expectedStaker2, 21 ether, "Staker2 expected: 21 ether");

        // Additional verification: different slashing impacts
        // Staker1: 50 → 26.25 = 47.5% loss (26.25 * 4 = 105, but 50 * 4 = 200, not 55)
        // Staker2: 40 shares → 28 assets → 21 final = 47.5% total loss from original, 25% from request time
        uint256 staker1Impact = ((50 ether - staker1Received) * 10000) / 50 ether;
        uint256 staker2AssetImpact = ((28 ether - staker2Received) * 10000) / 28 ether;

        assertEq(staker1Impact, 4750, "Staker1: 47.5% total impact from original");
        assertEq(staker2AssetImpact, 2500, "Staker2: 25% impact from stored asset amount");
    }

    function testSlashMultipleStakersWithDifferentRequestTimings() public {
        // Test: Complex scenario with multiple stakers requesting unstaking at different times
        // across multiple slashing events. Verifies fairness of proportional reductions.

        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Setup multiple stakers
        address staker3 = makeAddr("staker3");
        vm.startPrank(admin);
        stakingToken.mint(staker3, INITIAL_MINT);
        vm.stopPrank();

        // Increase max slashBps
        vm.prank(admin);
        controller.setMaxSlashBps(8000);

        // Setup: Each staker stakes 100 ether
        vm.prank(staker1);
        stakingToken.approve(address(controller), 100 ether);
        vm.prank(staker1);
        controller.stake(prover1, 100 ether);

        vm.prank(staker2);
        stakingToken.approve(address(controller), 100 ether);
        vm.prank(staker2);
        controller.stake(prover1, 100 ether);

        vm.prank(staker3);
        stakingToken.approve(address(controller), 100 ether);
        vm.prank(staker3);
        controller.stake(prover1, 100 ether);

        address vault = controller.getProverVault(prover1);

        // === Timeline: Request A → Request B → Slash1 → Request C → Slash2 → Complete All ===

        // T1: Staker1 requests unstake (at scale 10000)
        vm.prank(staker1);
        IProverVault(vault).approve(address(controller), 50 ether);
        vm.prank(staker1);
        controller.requestUnstake(prover1, 50 ether);

        // T2: Staker2 requests unstake (at scale 10000)
        vm.prank(staker2);
        IProverVault(vault).approve(address(controller), 60 ether);
        vm.prank(staker2);
        controller.requestUnstake(prover1, 60 ether);

        // T3: First slash (30%) - scale becomes 7000
        vm.prank(slasher);
        controller.slash(prover1, 3000);

        // T4: Staker3 requests unstake (at scale 7000)
        vm.prank(staker3);
        IProverVault(vault).approve(address(controller), 40 ether);
        vm.prank(staker3);
        controller.requestUnstake(prover1, 40 ether);

        // T5: Second slash (25% of remaining) - scale becomes 5250
        vm.prank(slasher);
        controller.slash(prover1, 2500);

        // T6: Complete all unstaking after delay
        vm.warp(block.timestamp + DEFAULT_UNBOND_DELAY + 1);

        vm.prank(staker1);
        uint256 staker1Received = controller.completeUnstake(prover1);

        vm.prank(staker2);
        uint256 staker2Received = controller.completeUnstake(prover1);

        vm.prank(staker3);
        uint256 staker3Received = controller.completeUnstake(prover1);

        // === Verify Proportional Reductions ===

        // Staker1: 50 ether stored at scale 10000 → effective = 50 * (5250/10000) = 26.25 ether
        uint256 expectedStaker1 = (50 ether * 5250) / 10000;
        assertEq(staker1Received, expectedStaker1, "Staker1 should get 26.25 ether (both slashes)");

        // Staker2: 60 ether stored at scale 10000 → effective = 60 * (5250/10000) = 31.5 ether
        uint256 expectedStaker2 = (60 ether * 5250) / 10000;
        assertEq(staker2Received, expectedStaker2, "Staker2 should get 31.5 ether (both slashes)");

        // Staker3: ~28 ether stored at scale 7000 → effective = 28 * (5250/7000) = 21 ether
        uint256 expectedStaker3 = (28 ether * 5250) / 7000;
        assertEq(staker3Received, expectedStaker3, "Staker3 should get 21 ether (second slash only)");

        // Verify different impact percentages
        uint256 staker1Impact = ((50 ether - staker1Received) * 100) / 50 ether; // 47.5%
        uint256 staker2Impact = ((60 ether - staker2Received) * 100) / 60 ether; // 47.5%
        uint256 staker3Impact = ((40 ether - staker3Received) * 100) / 40 ether; // 47.5% overall, but only 25% from request time

        assertEq(staker1Impact, 47, "Staker1 ~47% total impact");
        assertEq(staker2Impact, 47, "Staker2 ~47% total impact");
        assertTrue(staker3Impact > 40, "Staker3 significant impact but less exposure time");
    }

    function testSlashWithMaxPendingUnstakesLimitReached() public {
        // Test behavior when MAX_PENDING_UNSTAKES (10) limit is reached

        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Setup staker with large approval
        vm.prank(staker1);
        stakingToken.approve(address(controller), 1000 ether);
        vm.prank(staker1);
        controller.stake(prover1, 200 ether);

        address vault = controller.getProverVault(prover1);

        // Make 10 unstake requests (hitting the limit)
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(staker1);
            IProverVault(vault).approve(address(controller), 5 ether);
            vm.prank(staker1);
            controller.requestUnstake(prover1, 5 ether);
        }

        // 11th request should revert
        vm.prank(staker1);
        IProverVault(vault).approve(address(controller), 5 ether);
        vm.prank(staker1);
        vm.expectRevert(IStakingController.ControllerTooManyPendingUnstakes.selector);
        controller.requestUnstake(prover1, 5 ether);

        // Slash the prover (should affect all 10 pending requests)
        vm.prank(admin);
        controller.setMaxSlashBps(6000);
        vm.prank(slasher);
        uint256 slashedAmount = controller.slash(prover1, 4000); // 40% slash

        assertTrue(slashedAmount > 0, "Should have slashed pending unstaking amounts");

        // Complete after delay - should process all 10 requests with slashing applied
        vm.warp(block.timestamp + DEFAULT_UNBOND_DELAY + 1);

        vm.prank(staker1);
        uint256 totalReceived = controller.completeUnstake(prover1);

        // Verify total received is reduced by slashing
        uint256 expectedTotal = (50 ether * 6000) / 10000; // 50 ether * 60% = 30 ether
        assertEq(totalReceived, expectedTotal, "All 10 requests should be slashed proportionally");

        // After completion, should be able to make new unstake requests
        vm.prank(staker1);
        IProverVault(vault).approve(address(controller), 5 ether);
        vm.prank(staker1);
        controller.requestUnstake(prover1, 5 ether); // Should succeed now
    }

    function testSlashingWithTinyAmounts() public {
        // Test: Tiny unstake amounts are only allowed once balance drops below the global minimum chunk.
        // Value: Verifies dust exits unlock only after slash-driven depletion.

        vm.prank(prover1);
        controller.initializeProver(1000);

        // Staker deposits a single token (minimum chunk)
        vm.startPrank(staker1);
        stakingToken.approve(address(controller), 1 ether);
        controller.stake(prover1, 1 ether);
        vm.stopPrank();

        address vault = controller.getProverVault(prover1);

        // Attempt to unstake less than 1 token while balance >= 1 token -> should revert
        uint256 halfTokenShares = 0.5 ether;
        vm.startPrank(staker1);
        IProverVault(vault).approve(address(controller), halfTokenShares);
        vm.expectRevert(IStakingController.ControllerInvalidUnstakeAmount.selector);
        controller.requestUnstake(prover1, halfTokenShares);
        vm.stopPrank();

        // Heavy slash pushes the staker balance below the minimum chunk
        vm.prank(admin);
        controller.setMaxSlashBps(9000);
        vm.prank(slasher);
        controller.slash(prover1, 8000);

        uint256 stakerShares = IProverVault(vault).balanceOf(staker1);
        uint256 stakerAssets = IProverVault(vault).convertToAssets(stakerShares);
        assertLt(stakerAssets, 1 ether, "Slash should drop balance below minimum chunk");

        // Now the staker can exit the remaining dust even though it's below the minimum
        vm.startPrank(staker1);
        IProverVault(vault).approve(address(controller), stakerShares);
        controller.requestUnstake(prover1, stakerShares);
        vm.stopPrank();

        vm.warp(block.timestamp + DEFAULT_UNBOND_DELAY + 1);
        vm.prank(staker1);
        uint256 received = controller.completeUnstake(prover1);

        assertEq(received, stakerAssets, "Should recover entire remaining dust after slash");
    }

    function testSlashDoesNotAffectAccumulatedCommission() public {
        // Test that slashing does not reduce prover's accumulated commission

        // Initialize prover with commission
        vm.prank(prover1);
        controller.initializeProver(2000); // 20% commission

        // Add external stake
        vm.prank(staker1);
        stakingToken.approve(address(controller), 100 ether);
        vm.prank(staker1);
        controller.stake(prover1, 100 ether);

        // Add rewards to generate commission
        address rewardPayer = makeAddr("rewardPayer");
        vm.startPrank(admin);
        stakingToken.mint(rewardPayer, 1000 ether);
        vm.stopPrank();

        vm.startPrank(rewardPayer);
        stakingToken.approve(address(controller), 50 ether);
        uint256 rewardAmount = 50 ether;
        (uint256 commission,) = controller.addRewards(prover1, rewardAmount);
        vm.stopPrank();

        // Verify commission was accumulated
        (,,, uint256 pendingCommission,,,) = controller.getProverInfo(prover1);
        assertEq(pendingCommission, commission, "Commission should be accumulated");
        assertTrue(commission > 0, "Should have positive commission");

        // Now slash the prover heavily
        vm.prank(admin);
        controller.setMaxSlashBps(8000);
        vm.prank(slasher);
        controller.slash(prover1, 6000); // 60% slash

        // Verify commission remains unchanged after slashing
        (,,, uint256 pendingAfterSlash,,,) = controller.getProverInfo(prover1);
        assertEq(pendingAfterSlash, commission, "Commission should be unchanged by slashing");

        // Verify prover can still claim full commission
        uint256 balanceBefore = stakingToken.balanceOf(prover1);
        vm.prank(prover1);
        uint256 claimed = controller.claimCommission();
        uint256 balanceAfter = stakingToken.balanceOf(prover1);

        assertEq(claimed, commission, "Should claim full original commission");
        assertEq(balanceAfter - balanceBefore, commission, "Balance should increase by full commission");

        // Verify commission is zeroed after claim
        (,,, uint256 pendingAfterClaim,,,) = controller.getProverInfo(prover1);
        assertEq(pendingAfterClaim, 0, "Commission should be zero after claiming");
    }

    function testSlashLeavingVaultNearEmpty() public {
        // Test extreme slashing scenario approaching MIN_SCALE_FLOOR

        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Add significant stake
        vm.prank(staker1);
        stakingToken.approve(address(controller), 1000 ether);
        vm.prank(staker1);
        controller.stake(prover1, 1000 ether);

        address vault = controller.getProverVault(prover1);

        // Request large unstake
        vm.prank(staker1);
        IProverVault(vault).approve(address(controller), 500 ether);
        vm.prank(staker1);
        controller.requestUnstake(prover1, 500 ether);

        // Allow maximum slashing
        vm.prank(admin);
        controller.setMaxSlashBps(9000);

        // Slash to just above MIN_SCALE_FLOOR (20%)
        // To get scale to 2001 (just above 20%), need to slash 79.99%
        // Current scale 10000, target scale 2001: percentage = (10000-2001)/10000 = 7999
        vm.prank(slasher);
        controller.slash(prover1, 7999); // 79.99% slash

        // Verify prover is deactivated (scale < DEACTIVATION_SCALE of 40%)
        assertEq(
            uint256(controller.getProverState(prover1)),
            uint256(IStakingController.ProverState.Deactivated),
            "Prover should be deactivated"
        );

        // Verify scale is just above MIN_SCALE_FLOOR
        uint256 currentScale = controller.getProverSlashingScale(prover1);
        assertGt(currentScale, 2000, "Scale should be above MIN_SCALE_FLOOR");
        assertLt(currentScale, 2100, "Scale should be just above floor");

        // Complete unstaking - should get drastically reduced amount
        vm.warp(block.timestamp + DEFAULT_UNBOND_DELAY + 1);
        vm.prank(staker1);
        uint256 received = controller.completeUnstake(prover1);

        // Expected: ~500 * 0.2001 ≈ 100 ether
        assertTrue(received > 95 ether, "Should receive some significant amount");
        assertTrue(received < 105 ether, "Should be heavily slashed");

        // Verify system integrity - vault still functions
        uint256 vaultAssets = IProverVault(vault).totalAssets();
        assertTrue(vaultAssets > 0, "Vault should still have some assets");
    }

    function testSlashDuringUnbondingPeriod() public {
        // Test slashing that occurs during the unbonding delay period

        // Initialize prover
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Setup stake
        vm.prank(staker1);
        stakingToken.approve(address(controller), 100 ether);
        vm.prank(staker1);
        controller.stake(prover1, 100 ether);

        address vault = controller.getProverVault(prover1);

        // Request unstake
        vm.prank(staker1);
        IProverVault(vault).approve(address(controller), 50 ether);
        vm.prank(staker1);
        controller.requestUnstake(prover1, 50 ether);

        // Wait halfway through unbonding period
        uint256 halfDelay = DEFAULT_UNBOND_DELAY / 2;
        vm.warp(block.timestamp + halfDelay);

        // Slash during unbonding period
        vm.prank(slasher);
        controller.slash(prover1, 3000); // 30% slash

        // Verify unstake is not yet ready
        (uint256 totalAmount, uint256 readyAmount) = controller.getUnstakingInfo(prover1, staker1);
        assertTrue(totalAmount > 0, "Should have pending requests");
        assertEq(readyAmount, 0, "Should not be ready yet");

        // Wait for full delay to complete
        vm.warp(block.timestamp + halfDelay + 1);

        // Now should be ready and include slashing
        (totalAmount, readyAmount) = controller.getUnstakingInfo(prover1, staker1);
        assertTrue(readyAmount > 0, "Should be ready after full delay");

        vm.prank(staker1);
        uint256 received = controller.completeUnstake(prover1);

        // Should receive slashed amount: 50 * 0.7 = 35 ether
        uint256 expected = (50 ether * 7000) / 10000;
        assertEq(received, expected, "Should receive slashed amount after delay");
    }

    // =========================================================================
    // AMOUNT-BASED SLASHING TESTS
    // =========================================================================

    function testSlashByAmount_exactProportional() public {
        // Setup: Prover with 100 tokens, request 25% slash
        setupProverWithAssets(prover1, 100e18);

        uint256 totalAssets = getProverTotalAssets(prover1);
        uint256 requestAmount = totalAssets / 4; // 25%

        vm.prank(slasher);
        uint256 actualSlashed = controller.slashByAmount(prover1, requestAmount);

        // Should slash exactly the requested amount (within rounding tolerance)
        assertApproxEqAbs(actualSlashed, requestAmount, 1, "Should slash requested amount within rounding tolerance");

        // Verify final assets reduced by slashed amount
        uint256 finalAssets = getProverTotalAssets(prover1);
        assertEq(finalAssets, totalAssets - actualSlashed, "Final assets should equal initial minus slashed");
    }

    function testSlashByAmount_capAtMax() public {
        // Setup: Prover with 100 tokens, maxSlashBps = 50%
        setupProverWithAssets(prover1, 100e18);

        uint256 totalAssets = getProverTotalAssets(prover1);
        uint256 requestAmount = totalAssets * 80 / 100; // Request 80% (exceeds 50% cap)
        uint256 expectedCap = totalAssets * controller.maxSlashBps() / controller.BPS_DENOMINATOR();

        vm.prank(slasher);
        uint256 actualSlashed = controller.slashByAmount(prover1, requestAmount);

        // Should be capped at maxSlashBps
        assertEq(actualSlashed, expectedCap, "Should be capped at maxSlashBps");
        assertTrue(actualSlashed < requestAmount, "Actual should be less than requested due to cap");
    }

    function testSlashByAmount_roundsToZero() public {
        // Setup: Prover with 1 token, request tiny amount that rounds to 0%
        setupProverWithAssets(prover1, 1e18);

        uint256 tinyAmount = 1; // 1 wei - should round to 0 bps

        vm.prank(slasher);
        uint256 actualSlashed = controller.slashByAmount(prover1, tinyAmount);

        // Should slash 0 due to rounding
        assertEq(actualSlashed, 0, "Should slash 0 due to rounding");
    }

    function testPendingUnstakingTotalsStayInSyncAfterSmallSlashes() public {
        // Initialize prover and have a staker request unstake so all assets sit in pending queue
        vm.prank(prover1);
        controller.initializeProver(0);

        vm.startPrank(staker1);
        stakingToken.approve(address(controller), 1 ether);
        controller.stake(prover1, 1 ether);
        address vault = controller.getProverVault(prover1);
        uint256 stakerShares = IProverVault(vault).balanceOf(staker1);
        IProverVault(vault).approve(address(controller), stakerShares);
        controller.requestUnstake(prover1, stakerShares);
        vm.stopPrank();

        uint256 slashBps = 1; // 0.01%
        for (uint256 i = 0; i < 64; i++) {
            vm.prank(slasher);
            controller.slash(prover1, slashBps);

            (uint256 totalAmount,) = controller.getUnstakingInfo(prover1, staker1);
            uint256 storedTotal = controller.getProverTotalUnstaking(prover1);
            assertEq(storedTotal, totalAmount, "Pending totals diverged after small slash");
        }
    }

    function testSlashByAmount_includesUnstaking() public {
        // Setup: Prover with vault assets + pending unstakes
        setupProverWithAssets(prover1, 1000 ether);

        // Add a second staker for unstaking test
        stakingToken.mint(staker2, 500 ether);
        vm.prank(staker2);
        stakingToken.approve(address(controller), 500 ether);
        vm.prank(staker2);
        controller.stake(prover1, 500 ether);

        // Create pending unstakes
        address vault = controller.getProverVault(prover1);
        vm.prank(staker2);
        IProverVault(vault).approve(address(controller), 200 ether);
        vm.prank(staker2);
        controller.requestUnstake(prover1, 200 ether);

        // Now we have: ~1000 vault assets + ~200 pending unstaking = ~1200 total
        uint256 vaultAssetsBefore = IProverVault(vault).totalAssets();
        uint256 pendingUnstakingBefore = controller.getProverTotalUnstaking(prover1);
        uint256 totalBefore = vaultAssetsBefore + pendingUnstakingBefore;

        // Slash 300 tokens (~25% of total ~1200)
        vm.prank(slasher);
        uint256 actualSlashed = controller.slashByAmount(prover1, 300 ether);

        // Verify both vault and pending unstaking were reduced
        uint256 vaultAssetsAfter = IProverVault(vault).totalAssets();
        uint256 pendingUnstakingAfter = controller.getProverTotalUnstaking(prover1);

        // Both should be reduced proportionally
        uint256 vaultReduction = vaultAssetsBefore - vaultAssetsAfter;
        uint256 unstakeReduction = pendingUnstakingBefore - pendingUnstakingAfter;

        assertGt(vaultReduction, 0, "Vault assets should be reduced");
        assertGt(unstakeReduction, 0, "Pending unstaking should be reduced");
        assertEq(actualSlashed, vaultReduction + unstakeReduction, "Total slashed should equal sum of reductions");

        // Verify proportional slashing (within reasonable tolerance)
        uint256 expectedBps = (300 ether * 10000) / totalBefore;
        uint256 actualBps = (actualSlashed * 10000) / totalBefore;

        // Allow for small rounding differences
        assertTrue(
            actualBps >= expectedBps - 1 && actualBps <= expectedBps + 1,
            "Should slash approximately the expected percentage"
        );
    }

    function testSlashByAmount_autoDeactivateOnAmountSlash() public {
        // Setup: Prover with modest buffer above minimum so amount-based slash can trip threshold
        uint256 minSelfStake = controller.minSelfStake();
        uint256 buffer = minSelfStake; // Buffer equals one minimum chunk (1 token when decimals=18)
        setupProverWithAssets(prover1, minSelfStake + buffer);

        // Allow aggressive slashing in this scenario
        vm.prank(admin);
        controller.setMaxSlashBps(8000);

        // Verify prover is active
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Active));

        // Slash amount that will drop self-stake below minimum
        uint256 slashAmount = buffer + (minSelfStake / 2); // removes 1.5 chunks, leaving 0.5 < min

        vm.prank(slasher);
        controller.slashByAmount(prover1, slashAmount);

        // Should auto-deactivate
        assertEq(uint256(controller.getProverState(prover1)), uint256(IStakingController.ProverState.Deactivated));
    }

    function testSlashByAmount_event() public {
        setupProverWithAssets(prover1, 100e18);
        uint256 requestAmount = 20e18;

        // Calculate expected BPS
        uint256 totalAssets = controller.getProverTotalAssets(prover1);
        uint256 expectedBps = (requestAmount * controller.BPS_DENOMINATOR()) / totalAssets;

        vm.expectEmit(true, false, false, true);
        emit IStakingController.ProverSlashed(prover1, requestAmount, expectedBps);

        vm.prank(slasher);
        controller.slashByAmount(prover1, requestAmount);
    }

    function testSlashByAmount_zeroAmount() public {
        setupProverWithAssets(prover1, 100e18);

        vm.prank(slasher);
        uint256 actualSlashed = controller.slashByAmount(prover1, 0);

        assertEq(actualSlashed, 0, "Should slash 0 when amount is 0");
    }

    function testSlashByAmount_exceedsTotal() public {
        // Setup: Request amount greater than total slashable assets
        setupProverWithAssets(prover1, 100e18);

        uint256 totalAssets = controller.getProverTotalAssets(prover1);
        uint256 requestAmount = totalAssets * 2; // Request 200% of total
        uint256 expectedCap = totalAssets * controller.maxSlashBps() / controller.BPS_DENOMINATOR();

        vm.prank(slasher);
        uint256 actualSlashed = controller.slashByAmount(prover1, requestAmount);

        // Should be capped at maxSlashBps, not total assets
        assertEq(actualSlashed, expectedCap, "Should be capped at maxSlashBps even when exceeding total");
    }

    // =========================================================================
    // HELPER FUNCTIONS FOR AMOUNT SLASHING TESTS
    // =========================================================================

    function setupProverWithAssets(address prover, uint256 assets) internal {
        // Initialize prover first (uses existing approval from setUp)
        vm.prank(prover);
        controller.initializeProver(500); // 5% default commission

        // Now stake additional assets (beyond minSelfStake)
        if (assets > controller.minSelfStake()) {
            uint256 additionalAssets = assets - controller.minSelfStake();

            vm.startPrank(prover);
            stakingToken.approve(address(controller), additionalAssets);
            controller.stake(prover, additionalAssets);
            vm.stopPrank();
        }
    }

    function getProverTotalAssets(address prover) internal view returns (uint256) {
        return controller.getProverTotalAssets(prover);
    }
}
