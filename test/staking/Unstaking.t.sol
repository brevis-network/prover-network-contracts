// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../src/staking/interfaces/IProverVault.sol";
import "../../src/staking/controller/StakingController.sol";
import "../../src/staking/vault/VaultFactory.sol";
import "../../test/mocks/MockERC20.sol";

contract UnstakingTest is Test {
    StakingController public controller;
    VaultFactory public factory;
    MockERC20 public stakingToken;

    address public admin = address(0x1);
    address public prover1 = address(0x2);
    address public staker1 = address(0x3);
    address public staker2 = address(0x4);

    uint256 public constant INITIAL_BALANCE = 10000e18;
    uint256 public constant UNSTAKE_DELAY = 7 days;

    event UnstakeRequested(address indexed prover, address indexed staker, uint256 shares, uint256 assets);
    event UnstakeCompleted(address indexed prover, address indexed staker, uint256 amount);
    event UnstakeDelayUpdated(uint256 oldDelay, uint256 newDelay);

    function setUp() public {
        // Deploy token
        stakingToken = new MockERC20("Staking Token", "STK");

        // Deploy factory
        factory = new VaultFactory();

        // Deploy controller with unstaking functionality
        controller = new StakingController(
            address(stakingToken),
            address(factory),
            UNSTAKE_DELAY,
            1e18, // minSelfStake: 1 token
            5000 // maxSlashBps: 50%
        );

        // Grant vault creator role to controller
        factory.init(address(controller));

        // Grant slasher role to admin for testing
        controller.grantRole(controller.SLASHER_ROLE(), admin);

        // Setup balances (increased for testMaxPendingUnstakes)
        stakingToken.mint(staker1, 15000e18);
        stakingToken.mint(staker2, INITIAL_BALANCE);
        stakingToken.mint(prover1, INITIAL_BALANCE);
        stakingToken.mint(admin, INITIAL_BALANCE);

        // Grant admin roles for slashing and other admin functions
        // Note: test contract is the deployer so it has ownership initially
        // SLASHER_ROLE already granted to admin in constructor

        // Transfer ownership to admin
        controller.transferOwnership(admin);

        // Approve controller
        vm.prank(staker1);
        stakingToken.approve(address(controller), type(uint256).max);
        vm.prank(staker2);
        stakingToken.approve(address(controller), type(uint256).max);
        vm.prank(prover1);
        stakingToken.approve(address(controller), type(uint256).max);
        vm.prank(admin);
        stakingToken.approve(address(controller), type(uint256).max);
    }

    // Helper function to setup vault approvals for a user
    function _setupVaultApproval(address user, address vaultAddress) internal {
        vm.prank(user);
        IERC20(vaultAddress).approve(address(controller), type(uint256).max);
    }

    function testInitialState() public view {
        assertEq(address(controller.stakingToken()), address(stakingToken));
        assertEq(controller.unstakeDelay(), UNSTAKE_DELAY);
        assertEq(controller.MAX_PENDING_UNSTAKES(), 10);
        assertEq(controller.BPS_DENOMINATOR(), 10000);
    }

    function testReceiveUnstake() public {
        // Initialize prover and stake
        vm.prank(prover1);
        address vault = controller.initializeProver(500); // 5% commission

        vm.prank(staker1);
        uint256 shares = controller.stake(prover1, 1000e18);

        // Setup vault approval for staker1
        _setupVaultApproval(staker1, vault);

        // Request unstake
        vm.prank(staker1);
        vm.expectEmit(true, true, false, true);
        emit UnstakeRequested(prover1, staker1, shares, 1000e18);

        uint256 assets = controller.requestUnstake(prover1, shares);
        assertEq(assets, 1000e18);

        // Check unstaking contract state
        assertEq(controller.getProverTotalUnstaking(prover1), 1000e18);
        (uint256 totalUnstaking,) = controller.getUnstakingInfo(prover1, staker1);
        assertEq(totalUnstaking, 1000e18);

        // Check pending requests
        IStakingController.UnstakeRequest[] memory requests = controller.getPendingUnstakes(prover1, staker1);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, 1000e18);
        assertEq(requests[0].requestTime, block.timestamp);
    }

    function testCompleteUnstakeTooEarly() public {
        // Setup unstake request
        vm.prank(prover1);
        address vault = controller.initializeProver(500);

        vm.prank(staker1);
        uint256 shares = controller.stake(prover1, 1000e18);

        // Setup vault approval for staker1
        _setupVaultApproval(staker1, vault);

        vm.prank(staker1);
        controller.requestUnstake(prover1, shares);

        // Try to complete before delay
        vm.prank(staker1);
        vm.expectRevert(IStakingController.ControllerUnstakeNotReady.selector);
        controller.completeUnstake(prover1);
    }

    function testCompleteUnstakeAfterDelay() public {
        // Setup unstake request
        vm.prank(prover1);
        address vault = controller.initializeProver(500);

        vm.prank(staker1);
        uint256 shares = controller.stake(prover1, 1000e18);

        // Approve vault shares before requesting unstake
        vm.startPrank(staker1);
        ProverVault vaultContract = ProverVault(vault);
        vaultContract.approve(address(controller), shares);
        controller.requestUnstake(prover1, shares);
        vm.stopPrank();

        // Wait for delay
        vm.warp(block.timestamp + UNSTAKE_DELAY + 1);

        // Complete unstake
        uint256 balanceBefore = stakingToken.balanceOf(staker1);

        vm.prank(staker1);
        vm.expectEmit(true, true, false, true);
        emit UnstakeCompleted(prover1, staker1, 1000e18);

        uint256 assets = controller.completeUnstake(prover1);
        assertEq(assets, 1000e18);

        uint256 balanceAfter = stakingToken.balanceOf(staker1);
        assertEq(balanceAfter - balanceBefore, 1000e18);

        // Check state after completion
        assertEq(controller.getProverTotalUnstaking(prover1), 0);
        (uint256 totalUnstaking,) = controller.getUnstakingInfo(prover1, staker1);
        assertEq(totalUnstaking, 0);
    }

    function testMultipleUnstakeRequests() public {
        // Setup
        vm.prank(prover1);
        address vault = controller.initializeProver(500);

        vm.prank(staker1);
        controller.stake(prover1, 3000e18);

        // Setup vault approval for staker1
        _setupVaultApproval(staker1, vault);

        // Make multiple unstake requests
        vm.prank(staker1);
        controller.requestUnstake(prover1, 1000e18);

        vm.warp(block.timestamp + 1 days);
        vm.prank(staker1);
        controller.requestUnstake(prover1, 1000e18);

        vm.warp(block.timestamp + 1 days);
        vm.prank(staker1);
        controller.requestUnstake(prover1, 1000e18);

        // Check total
        (uint256 totalUnstaking,) = controller.getUnstakingInfo(prover1, staker1);
        assertEq(totalUnstaking, 3000e18);
        assertEq(controller.getProverTotalUnstaking(prover1), 3000e18);

        // Complete first request only
        vm.warp(block.timestamp + UNSTAKE_DELAY - 2 days + 1); // 7 days after first request, but only 5-6 days for others

        vm.prank(staker1);
        uint256 assets = controller.completeUnstake(prover1);
        assertEq(assets, 1000e18); // Only first request ready

        (uint256 remainingUnstaking,) = controller.getUnstakingInfo(prover1, staker1);
        assertEq(remainingUnstaking, 2000e18);
    }

    function testSlashingBasic() public {
        // Setup
        vm.prank(prover1);
        address vault = controller.initializeProver(500);

        vm.prank(staker1);
        uint256 shares = controller.stake(prover1, 1000e18);

        // Setup vault approval for staker1
        _setupVaultApproval(staker1, vault);

        vm.prank(staker1);
        controller.requestUnstake(prover1, shares);

        // Slash 20%
        vm.prank(admin);
        controller.slash(prover1, 2000); // 20%

        // Check effective amount after slashing
        (uint256 effectiveAmount,) = controller.getUnstakingInfo(prover1, staker1);
        assertEq(effectiveAmount, 800e18); // 80% remaining

        // Complete unstake after delay
        vm.warp(block.timestamp + UNSTAKE_DELAY + 1);

        vm.prank(staker1);
        uint256 assets = controller.completeUnstake(prover1);
        assertEq(assets, 800e18); // Should receive slashed amount
    }

    function testSlashingMultiple() public {
        // Setup
        vm.prank(prover1);
        address vault = controller.initializeProver(500);

        vm.prank(staker1);
        uint256 shares = controller.stake(prover1, 1000e18);

        // Setup vault approval for staker1
        _setupVaultApproval(staker1, vault);

        vm.prank(staker1);
        controller.requestUnstake(prover1, shares);

        // First slash 20%
        vm.prank(admin);
        controller.slash(prover1, 2000); // 20%
        (uint256 totalUnstaking,) = controller.getUnstakingInfo(prover1, staker1);
        assertEq(totalUnstaking, 800e18);

        // Second slash 25% of remaining
        vm.prank(admin);
        controller.slash(prover1, 2500); // 25%
        (totalUnstaking,) = controller.getUnstakingInfo(prover1, staker1);
        assertEq(totalUnstaking, 600e18); // 80% * 75% = 60%

        // Complete unstake
        vm.warp(block.timestamp + UNSTAKE_DELAY + 1);

        vm.prank(staker1);
        uint256 assets = controller.completeUnstake(prover1);
        assertEq(assets, 600e18);
    }

    function testSlashingWithMultipleRequests() public {
        // Setup
        vm.prank(prover1);
        address vault = controller.initializeProver(500);

        vm.prank(staker1);
        controller.stake(prover1, 2000e18);

        // Setup vault approval for staker1
        _setupVaultApproval(staker1, vault);

        // Make first unstake request
        vm.prank(staker1);
        controller.requestUnstake(prover1, 1000e18);

        // Slash 20%
        vm.prank(admin);
        controller.slash(prover1, 2000);

        // Make second unstake request after slashing
        vm.prank(staker1);
        controller.requestUnstake(prover1, 800e18); // Remaining vault assets after slash

        // Check totals
        (uint256 totalUnstaking,) = controller.getUnstakingInfo(prover1, staker1);
        assertEq(totalUnstaking, 800e18 + 640e18); // Both requests slashed: 1000*0.8 + 800*0.8 = 800 + 640

        // Complete after delay
        vm.warp(block.timestamp + UNSTAKE_DELAY + 1);

        vm.prank(staker1);
        uint256 assets = controller.completeUnstake(prover1);
        assertEq(assets, 1440e18); // 800e18 + 640e18 (both requests slashed)
    }

    function testSetUnstakeDelay() public {
        uint256 newDelay = 14 days;

        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit UnstakeDelayUpdated(UNSTAKE_DELAY, newDelay);

        controller.setUnstakeDelay(newDelay);
        assertEq(controller.unstakeDelay(), newDelay);
    }

    function testSetUnstakeDelayOnlyAdmin() public {
        vm.prank(staker1);
        vm.expectRevert();
        controller.setUnstakeDelay(14 days);
    }

    function testImmediateUnstaking() public {
        // Set delay to 0
        vm.prank(admin);
        controller.setUnstakeDelay(0);

        // Setup unstake
        vm.prank(prover1);
        address vault = controller.initializeProver(500);

        vm.prank(staker1);
        uint256 shares = controller.stake(prover1, 1000e18);

        // Setup vault approval for staker1
        _setupVaultApproval(staker1, vault);

        vm.prank(staker1);
        controller.requestUnstake(prover1, shares);

        // Should be able to complete immediately
        vm.prank(staker1);
        uint256 assets = controller.completeUnstake(prover1);
        assertEq(assets, 1000e18);
    }

    function testMaxPendingUnstakes() public {
        // Setup
        vm.prank(prover1);
        address vault = controller.initializeProver(500);

        vm.prank(staker1);
        controller.stake(prover1, 11000e18);

        // Setup vault approval for staker1
        _setupVaultApproval(staker1, vault);

        // Make maximum allowed unstake requests
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(staker1);
            controller.requestUnstake(prover1, 1000e18);
        }

        // 11th request should fail
        vm.prank(staker1);
        vm.expectRevert(IStakingController.ControllerTooManyPendingUnstakes.selector);
        controller.requestUnstake(prover1, 1000e18);
    }

    function testGetProverSlashingScale() public {
        vm.prank(prover1);
        address vault = controller.initializeProver(500);

        // Initially should be 100%
        assertEq(controller.getProverSlashingScale(prover1), 10000);

        // After 20% slash should be 80%
        vm.prank(staker1);
        uint256 shares = controller.stake(prover1, 1000e18);

        // Setup vault approval and make unstake request (slashBps might only apply with pending unstakes)
        _setupVaultApproval(staker1, vault);
        vm.prank(staker1);
        controller.requestUnstake(prover1, shares);

        vm.prank(admin);
        controller.slash(prover1, 2000);

        assertEq(controller.getProverSlashingScale(prover1), 8000);
    }

    function testGetUnstakingInfo() public {
        // Setup
        vm.prank(prover1);
        address vault = controller.initializeProver(500);

        vm.prank(staker1);
        controller.stake(prover1, 2000e18);

        // Setup vault approval for staker1
        _setupVaultApproval(staker1, vault);

        // Make two requests
        vm.prank(staker1);
        controller.requestUnstake(prover1, 1000e18);

        vm.warp(block.timestamp + 1 days);

        vm.prank(staker1);
        controller.requestUnstake(prover1, 1000e18);

        // Initially no ready unstaking, but total is 2000
        (uint256 totalAmount, uint256 readyAmount) = controller.getUnstakingInfo(prover1, staker1);
        assertEq(totalAmount, 2000e18);
        assertEq(readyAmount, 0);

        // After first delay, only first request ready
        vm.warp(block.timestamp + UNSTAKE_DELAY - 1 days + 1); // 7 days after first request, 6 days + 1 second after second
        (totalAmount, readyAmount) = controller.getUnstakingInfo(prover1, staker1);
        assertEq(totalAmount, 2000e18);
        assertEq(readyAmount, 1000e18);

        // After second delay, both ready
        vm.warp(block.timestamp + 1 days);
        (totalAmount, readyAmount) = controller.getUnstakingInfo(prover1, staker1);
        assertEq(totalAmount, 2000e18);
        assertEq(readyAmount, 2000e18);
    }

    function testUnstakingStatusCheck() public {
        // Setup
        vm.prank(prover1);
        address vault = controller.initializeProver(500);

        // Initially no requests
        (uint256 totalAmount, uint256 readyAmount) = controller.getUnstakingInfo(prover1, staker1);
        assertEq(totalAmount, 0);
        assertEq(readyAmount, 0);

        // After request, has requests but not ready
        vm.prank(staker1);
        uint256 shares = controller.stake(prover1, 1000e18);

        // Setup vault approval for staker1
        _setupVaultApproval(staker1, vault);

        vm.prank(staker1);
        controller.requestUnstake(prover1, shares);

        (totalAmount, readyAmount) = controller.getUnstakingInfo(prover1, staker1);
        assertEq(totalAmount, 1000e18);
        assertEq(readyAmount, 0);

        // After delay, has ready
        vm.warp(block.timestamp + UNSTAKE_DELAY + 1);

        (totalAmount, readyAmount) = controller.getUnstakingInfo(prover1, staker1);
        assertEq(totalAmount, 1000e18);
        assertEq(readyAmount, 1000e18);
    }

    function testSlashingAccountingConsistency() public {
        // Setup multiple users with unstaking positions
        vm.prank(prover1);
        address vault = controller.initializeProver(500);

        // Setup vault approvals for both stakers
        _setupVaultApproval(staker1, vault);
        _setupVaultApproval(staker2, vault);

        // Staker1 stakes and unstakes
        vm.prank(staker1);
        uint256 shares1 = controller.stake(prover1, 1000e18);
        vm.prank(staker1);
        controller.requestUnstake(prover1, shares1);

        // Staker2 stakes and unstakes
        vm.prank(staker2);
        uint256 shares2 = controller.stake(prover1, 2000e18);
        vm.prank(staker2);
        controller.requestUnstake(prover1, shares2);

        // Initial total should be 3000
        assertEq(controller.getProverTotalUnstaking(prover1), 3000e18);
        (uint256 totalStaker1,) = controller.getUnstakingInfo(prover1, staker1);
        (uint256 totalStaker2,) = controller.getUnstakingInfo(prover1, staker2);
        assertEq(totalStaker1 + totalStaker2, 3000e18);

        // Slash 30%
        uint256 treasuryBefore = controller.treasuryPool();
        vm.prank(admin);
        controller.slash(prover1, 3000);

        // Check slashed amount was transferred to treasury
        uint256 expectedSlashed = 900.3e18; // 30% of 3000 + vault slashing precision
        assertEq(controller.treasuryPool() - treasuryBefore, expectedSlashed);

        // Check effective amounts
        (totalStaker1,) = controller.getUnstakingInfo(prover1, staker1);
        (totalStaker2,) = controller.getUnstakingInfo(prover1, staker2);
        assertEq(totalStaker1, 700e18); // 70% of 1000
        assertEq(totalStaker2, 1400e18); // 70% of 2000
    }

    function testDelayChangeAffectsPendingUnstakes() public {
        // Setup prover
        vm.prank(prover1);
        controller.initializeProver(500);

        address vault = controller.getProverVault(prover1);

        // Staker stakes and requests unstake
        vm.startPrank(staker1);
        uint256 shares = controller.stake(prover1, 100e18);
        IERC20(vault).approve(address(controller), shares / 2);
        uint256 requestTime = block.timestamp;
        controller.requestUnstake(prover1, shares / 2);
        vm.stopPrank();

        // Check initial delay
        assertEq(controller.unstakeDelay(), UNSTAKE_DELAY, "Initial delay should be 7 days");

        // Admin changes delay to 3 days
        vm.prank(admin);
        controller.setUnstakeDelay(3 days);
        assertEq(controller.unstakeDelay(), 3 days, "Delay should be updated to 3 days");

        // Should be able to complete after new shorter delay
        vm.warp(requestTime + 3 days + 1);

        vm.prank(staker1);
        uint256 assetsReceived = controller.completeUnstake(prover1);

        assertTrue(assetsReceived > 0, "Should receive assets after completing unstake");
        (uint256 totalUnstaking,) = controller.getUnstakingInfo(prover1, staker1);
        assertEq(totalUnstaking, 0, "Should have no unstaking shares remaining");
    }

    function testDelayIncreaseAffectsPendingUnstakes() public {
        // Setup prover
        vm.prank(prover1);
        controller.initializeProver(500);

        address vault = controller.getProverVault(prover1);

        // Staker stakes and requests unstake
        vm.startPrank(staker1);
        uint256 shares = controller.stake(prover1, 100e18);
        IERC20(vault).approve(address(controller), shares / 2);
        uint256 requestTime = block.timestamp;
        controller.requestUnstake(prover1, shares / 2);
        vm.stopPrank();

        // Admin increases delay to 14 days
        vm.prank(admin);
        controller.setUnstakeDelay(14 days);
        assertEq(controller.unstakeDelay(), 14 days, "Delay should be updated to 14 days");

        // Should not be able to complete after old delay (7 days)
        vm.warp(requestTime + UNSTAKE_DELAY + 1);

        vm.prank(staker1);
        vm.expectRevert(IStakingController.ControllerUnstakeNotReady.selector);
        controller.completeUnstake(prover1);

        // Should be able to complete after new longer delay
        vm.warp(requestTime + 14 days + 1);

        vm.prank(staker1);
        uint256 assetsReceived = controller.completeUnstake(prover1);
        assertTrue(assetsReceived > 0, "Should receive assets after new delay");
    }

    function testMultiplePendingUnstakesAllAffectedByDelayChange() public {
        // Setup prover
        vm.prank(prover1);
        controller.initializeProver(500);

        address vault = controller.getProverVault(prover1);

        // Multiple stakers with unstake requests
        vm.prank(staker1);
        uint256 shares1 = controller.stake(prover1, 100e18);
        vm.prank(staker2);
        uint256 shares2 = controller.stake(prover1, 100e18);

        // Both request unstakes at different times
        vm.startPrank(staker1);
        IERC20(vault).approve(address(controller), shares1 / 2);
        uint256 requestTime1 = block.timestamp;
        controller.requestUnstake(prover1, shares1 / 2);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);

        vm.startPrank(staker2);
        IERC20(vault).approve(address(controller), shares2 / 2);
        uint256 requestTime2 = block.timestamp;
        controller.requestUnstake(prover1, shares2 / 2);
        vm.stopPrank();

        // Admin changes delay to 14 days
        vm.prank(admin);
        controller.setUnstakeDelay(14 days);

        // Both requests should be affected by new delay
        vm.warp(requestTime1 + UNSTAKE_DELAY + 1); // Old delay passed for first request

        vm.prank(staker1);
        vm.expectRevert(IStakingController.ControllerUnstakeNotReady.selector);
        controller.completeUnstake(prover1);

        vm.warp(requestTime2 + UNSTAKE_DELAY + 1); // Old delay passed for second request

        vm.prank(staker2);
        vm.expectRevert(IStakingController.ControllerUnstakeNotReady.selector);
        controller.completeUnstake(prover1);

        // Both should complete after new delay
        vm.warp(requestTime1 + 14 days + 1);

        vm.prank(staker1);
        uint256 assets1 = controller.completeUnstake(prover1);
        assertTrue(assets1 > 0, "Staker1 should receive assets");

        vm.warp(requestTime2 + 14 days + 1);

        vm.prank(staker2);
        uint256 assets2 = controller.completeUnstake(prover1);
        assertTrue(assets2 > 0, "Staker2 should receive assets");
    }

    function testBasicUnstakingFlow() public {
        // Setup prover
        vm.prank(prover1);
        controller.initializeProver(500);

        address vault = controller.getProverVault(prover1);

        // User stakes
        vm.prank(staker1);
        controller.stake(prover1, 1000e18);

        // User requests unstake - need vault approval first
        vm.startPrank(staker1);
        IERC20(vault).approve(address(controller), 1000e18);
        controller.requestUnstake(prover1, 1000e18);
        vm.stopPrank();

        // Check unstaking contract received the tokens
        assertEq(stakingToken.balanceOf(address(controller)), 1000e18, "Unstaking contract should have tokens");

        // Check user has unstake request
        (uint256 totalUnstaking,) = controller.getUnstakingInfo(prover1, staker1);
        assertEq(totalUnstaking, 1000e18, "Should have correct amount unstaking");

        // Wait for delay and complete
        vm.warp(block.timestamp + UNSTAKE_DELAY + 1);

        vm.prank(staker1);
        uint256 received = controller.completeUnstake(prover1);
        assertEq(received, 1000e18, "Should receive full amount");
    }

    function testConfigurableDelayFeatures() public {
        // Test changing delay
        vm.prank(admin);
        controller.setUnstakeDelay(14 days);
        assertEq(controller.unstakeDelay(), 14 days, "Delay should be updated");

        // Test immediate unstaking (delay = 0)
        vm.prank(admin);
        controller.setUnstakeDelay(0);

        // Setup unstake
        vm.prank(prover1);
        controller.initializeProver(500);

        address vault = controller.getProverVault(prover1);

        vm.prank(staker1);
        uint256 shares = controller.stake(prover1, 1000e18);

        vm.startPrank(staker1);
        IERC20(vault).approve(address(controller), shares);
        controller.requestUnstake(prover1, shares);
        vm.stopPrank();

        // Should complete immediately
        vm.prank(staker1);
        uint256 received = controller.completeUnstake(prover1);
        assertEq(received, 1000e18, "Should receive full amount immediately");
    }

    // ============ Controller Integration Tests ============

    function testRequestAndCompleteUnstake() public {
        // Test full amount unstaking through controller interface
        vm.prank(prover1);
        address vault = controller.initializeProver(500);

        vm.prank(staker1);
        stakingToken.approve(address(controller), 1000e18);
        vm.prank(staker1);
        uint256 shares = controller.stake(prover1, 1000e18);

        // Setup vault approval
        _setupVaultApproval(staker1, vault);

        vm.prank(staker1);
        uint256 assets = controller.requestUnstake(prover1, shares);

        // Check unstaking was registered
        uint256 totalUnstaking;
        (totalUnstaking,) = controller.getUnstakingInfo(prover1, staker1);
        assertEq(totalUnstaking, assets);

        // Fast forward
        vm.warp(block.timestamp + UNSTAKE_DELAY + 1);

        // Complete
        vm.prank(staker1);
        uint256 received = controller.completeUnstake(prover1);

        assertEq(received, assets);
    }

    function testRequestAndCompleteUnstakePartialAmount() public {
        // Test partial amount unstaking (half)
        vm.prank(prover1);
        address vault = controller.initializeProver(500);

        vm.prank(staker1);
        stakingToken.approve(address(controller), 1000e18);
        vm.prank(staker1);
        uint256 sharesReceived = controller.stake(prover1, 1000e18);

        // Setup vault approval
        _setupVaultApproval(staker1, vault);

        // Unstake half the shares
        uint256 unstakeShares = sharesReceived / 2;
        vm.prank(staker1);
        uint256 assetsFromUnstake = controller.requestUnstake(prover1, unstakeShares);

        // Check unstaking was registered
        uint256 totalUnstaking;
        (totalUnstaking,) = controller.getUnstakingInfo(prover1, staker1);
        assertEq(totalUnstaking, assetsFromUnstake);
        assertTrue(assetsFromUnstake > 0, "Should receive assets from partial unstake");

        // Verify staker still has remaining shares in vault
        ProverVault vaultContract = ProverVault(vault);
        uint256 remainingShares = vaultContract.balanceOf(staker1);
        assertEq(remainingShares, sharesReceived - unstakeShares, "Should have remaining shares");

        // Fast forward time
        vm.warp(block.timestamp + UNSTAKE_DELAY + 1);

        (, uint256 readyAmount) = controller.getUnstakingInfo(prover1, staker1);
        assertEq(readyAmount, assetsFromUnstake, "Ready amount should match unstake amount");

        // Complete unstake
        uint256 balanceBefore = stakingToken.balanceOf(staker1);
        vm.prank(staker1);
        uint256 received = controller.completeUnstake(prover1);
        uint256 balanceAfter = stakingToken.balanceOf(staker1);

        assertEq(received, assetsFromUnstake, "Should receive correct amount");
        assertEq(balanceAfter - balanceBefore, assetsFromUnstake, "Balance should increase correctly");
        uint256 totalUnstakingRemaining;
        (totalUnstakingRemaining,) = controller.getUnstakingInfo(prover1, staker1);
        assertEq(totalUnstakingRemaining, 0, "Should have no remaining unstaking");
    }

    // ============ Complex Flow Tests ============

    function testUnstakingDelayRestrictions() public {
        // Initialize prover and stake
        vm.prank(prover1);
        address vaultAddress = controller.initializeProver(1000);
        ProverVault vault = ProverVault(vaultAddress);

        uint256 stakeAmount = 100e18;
        vm.startPrank(staker1);
        stakingToken.approve(address(controller), stakeAmount);
        uint256 totalShares = controller.stake(prover1, stakeAmount);
        vm.stopPrank();

        // Request partial unstaking
        uint256 unstakeShares = totalShares / 2;
        vm.startPrank(staker1);

        // Approve vault shares for controller to spend
        vault.approve(address(controller), unstakeShares);

        uint256 assetsUnstaked = controller.requestUnstake(prover1, unstakeShares);
        vm.stopPrank();

        // Test 1: completeUnstake should fail immediately after request
        vm.prank(staker1);
        vm.expectRevert(IStakingController.ControllerUnstakeNotReady.selector);
        controller.completeUnstake(prover1);

        // Test 2: completeUnstake should fail even 1 second before unlock time
        vm.warp(block.timestamp + UNSTAKE_DELAY - 1);
        vm.prank(staker1);
        vm.expectRevert(IStakingController.ControllerUnstakeNotReady.selector);
        controller.completeUnstake(prover1);

        // Test 3: Cannot redeem more than available shares during unstaking period
        vm.startPrank(staker1);
        vm.expectRevert(IProverVault.VaultOnlyController.selector); // Vault can only be called by controller
        vault.redeem(totalShares, staker1, staker1); // Try to redeem all shares but half were already redeemed
        vm.stopPrank();

        // Test 4: Can complete after proper delay
        vm.warp(block.timestamp + 1 + 1); // Move past the delay

        uint256 balanceBefore = stakingToken.balanceOf(staker1);
        vm.prank(staker1);
        uint256 assetsReceived = controller.completeUnstake(prover1);
        uint256 balanceAfter = stakingToken.balanceOf(staker1);

        assertEq(assetsReceived, assetsUnstaked, "Should receive correct unstaked amount");
        assertEq(balanceAfter - balanceBefore, assetsUnstaked, "Balance should increase by unstaked amount");

        // Verify remaining shares are still available in vault
        uint256 remainingShares = vault.balanceOf(staker1);
        uint256 expectedRemaining = totalShares - unstakeShares;
        assertEq(remainingShares, expectedRemaining, "Should have remaining shares in vault");
    }

    function testMultipleUnstakingRequests() public {
        // Initialize prover and stake
        vm.prank(prover1);
        address vaultAddress = controller.initializeProver(1000);
        ProverVault vault = ProverVault(vaultAddress);

        uint256 stakeAmount = 150e18;
        vm.startPrank(staker1);
        stakingToken.approve(address(controller), stakeAmount);
        uint256 totalShares = controller.stake(prover1, stakeAmount);
        vm.stopPrank();

        // First unstake request
        uint256 firstUnstakeShares = totalShares / 3;
        vm.startPrank(staker1);
        vault.approve(address(controller), firstUnstakeShares);
        uint256 firstAssetsUnstaked = controller.requestUnstake(prover1, firstUnstakeShares);
        vm.stopPrank();

        // Second unstake request (should be separate pending request)
        vm.warp(block.timestamp + 1 days); // Move forward 1 day
        uint256 secondUnstakeShares = totalShares / 3;
        vm.startPrank(staker1);
        vault.approve(address(controller), secondUnstakeShares);
        uint256 secondAssetsUnstaked = controller.requestUnstake(prover1, secondUnstakeShares);
        vm.stopPrank();

        // Verify state after second request - should have combined unstaking assets
        (uint256 totalUnstaking,) = controller.getUnstakingInfo(prover1, staker1);
        assertEq(totalUnstaking, firstAssetsUnstaked + secondAssetsUnstaked, "Should have combined unstaking assets");

        // Verify remaining shares in vault
        uint256 multiStakeShares = controller.getStakeInfo(prover1, staker1);
        uint256 expectedRemainingShares = totalShares - firstUnstakeShares - secondUnstakeShares;
        assertEq(multiStakeShares, expectedRemainingShares, "Should have remaining active shares");

        // Complete unstaking after delay - will complete all pending requests at once
        vm.warp(block.timestamp + UNSTAKE_DELAY + 1);
        vm.startPrank(staker1);
        uint256 totalAssetsReceived = controller.completeUnstake(prover1);
        vm.stopPrank();

        assertEq(totalAssetsReceived, firstAssetsUnstaked + secondAssetsUnstaked, "Should receive all unstaked assets");

        // Verify no unstaking assets remain
        uint256 totalUnstakingLeft;
        (totalUnstakingLeft,) = controller.getUnstakingInfo(prover1, staker1);
        assertEq(totalUnstakingLeft, 0, "Should have no unstaking assets remaining");
    }

    function testOptimizedUnstakingOperations() public {
        // Initialize prover first
        vm.prank(prover1);
        controller.initializeProver(1000);

        // Test optimized operations in new unstaking system
        uint256 numUnstakes = 3;
        uint256 stakeAmount = numUnstakes * 100e18;

        vm.startPrank(staker1);
        stakingToken.approve(address(controller), stakeAmount);
        uint256 totalShares = controller.stake(prover1, stakeAmount);

        uint256 sharesPerUnstake = totalShares / numUnstakes;
        address vault = controller.getProverVault(prover1);

        // Approve all shares for unstaking
        IProverVault(vault).approve(address(controller), totalShares);

        // Create multiple unstake requests
        controller.requestUnstake(prover1, sharesPerUnstake);

        vm.warp(block.timestamp + 1 days);
        controller.requestUnstake(prover1, sharesPerUnstake);

        vm.warp(block.timestamp + 1 days);
        controller.requestUnstake(prover1, sharesPerUnstake);
        vm.stopPrank();

        // Test optimization: getUnstakingInfo should be efficient
        uint256 gasBefore = gasleft();
        (uint256 totalUnstaking,) = controller.getUnstakingInfo(prover1, staker1);
        uint256 gasUsed = gasBefore - gasleft();

        // Should find all unstaking amounts efficiently
        assertTrue(gasUsed < 15000, "getUnstakingInfo should be gas efficient");
        assertTrue(totalUnstaking > 0, "Should have unstaking tokens");

        // Test batch completion after delay
        vm.warp(block.timestamp + UNSTAKE_DELAY + 1);

        vm.startPrank(staker1);
        gasBefore = gasleft();
        uint256 assets = controller.completeUnstake(prover1);
        uint256 gasUsed2 = gasBefore - gasleft();
        vm.stopPrank();

        assertTrue(assets > 0, "Should receive assets");
        assertTrue(gasUsed2 > 0, "Should use some gas");

        // Verify all unstaking completed efficiently
        uint256 finalTotalUnstaking;
        (finalTotalUnstaking,) = controller.getUnstakingInfo(prover1, staker1);
        assertEq(finalTotalUnstaking, 0, "All unstaking should be completed");
    }

    // =========================================================================
    // STAKERS TRACKING TESTS
    // =========================================================================

    function testStakersTrackingBasicFlow() public {
        // Initialize prover
        vm.prank(prover1);
        address vaultAddr = controller.initializeProver(1000);

        // Initially no stakers with pending unstakes
        address[] memory stakersWithPending = controller.getStakersWithPendingUnstakes(prover1);
        assertEq(stakersWithPending.length, 0);
        assertEq(controller.getStakersWithPendingUnstakesCount(prover1), 0);

        // Staker1 stakes and then unstakes
        vm.startPrank(staker1);
        stakingToken.approve(address(controller), 100e18);
        controller.stake(prover1, 100e18);
        vm.stopPrank();

        _setupVaultApproval(staker1, vaultAddr);

        vm.startPrank(staker1);
        controller.requestUnstake(prover1, 50e18);
        vm.stopPrank();

        // Should have 1 staker with pending unstakes
        stakersWithPending = controller.getStakersWithPendingUnstakes(prover1);
        assertEq(stakersWithPending.length, 1);
        assertEq(stakersWithPending[0], staker1);
        assertEq(controller.getStakersWithPendingUnstakesCount(prover1), 1);
        assertTrue(controller.stakerHasPendingUnstakes(prover1, staker1));
        assertFalse(controller.stakerHasPendingUnstakes(prover1, staker2));

        // Staker2 also stakes and unstakes
        vm.startPrank(staker2);
        stakingToken.approve(address(controller), 200e18);
        controller.stake(prover1, 200e18);
        vm.stopPrank();

        _setupVaultApproval(staker2, vaultAddr);

        vm.startPrank(staker2);
        controller.requestUnstake(prover1, 100e18);
        vm.stopPrank();

        // Should have 2 stakers with pending unstakes
        stakersWithPending = controller.getStakersWithPendingUnstakes(prover1);
        assertEq(stakersWithPending.length, 2);
        assertEq(controller.getStakersWithPendingUnstakesCount(prover1), 2);
        assertTrue(controller.stakerHasPendingUnstakes(prover1, staker1));
        assertTrue(controller.stakerHasPendingUnstakes(prover1, staker2));

        // Array should contain both stakers (order may vary)
        assertTrue(
            (stakersWithPending[0] == staker1 && stakersWithPending[1] == staker2)
                || (stakersWithPending[0] == staker2 && stakersWithPending[1] == staker1)
        );

        // Staker1 completes unstaking after delay
        vm.warp(block.timestamp + UNSTAKE_DELAY + 1);

        vm.startPrank(staker1);
        controller.completeUnstake(prover1);
        vm.stopPrank();

        // Should have 1 staker with pending unstakes (only staker2)
        stakersWithPending = controller.getStakersWithPendingUnstakes(prover1);
        assertEq(stakersWithPending.length, 1);
        assertEq(stakersWithPending[0], staker2);
        assertEq(controller.getStakersWithPendingUnstakesCount(prover1), 1);
        assertFalse(controller.stakerHasPendingUnstakes(prover1, staker1));
        assertTrue(controller.stakerHasPendingUnstakes(prover1, staker2));

        // Staker2 completes unstaking
        vm.startPrank(staker2);
        controller.completeUnstake(prover1);
        vm.stopPrank();

        // Should have no stakers with pending unstakes
        stakersWithPending = controller.getStakersWithPendingUnstakes(prover1);
        assertEq(stakersWithPending.length, 0);
        assertEq(controller.getStakersWithPendingUnstakesCount(prover1), 0);
        assertFalse(controller.stakerHasPendingUnstakes(prover1, staker1));
        assertFalse(controller.stakerHasPendingUnstakes(prover1, staker2));
    }

    function testStakersTrackingMultipleRequests() public {
        // Initialize prover
        vm.prank(prover1);
        address vaultAddr = controller.initializeProver(1000);

        // Staker1 makes multiple unstake requests
        vm.startPrank(staker1);
        stakingToken.approve(address(controller), 300e18);
        controller.stake(prover1, 300e18);
        vm.stopPrank();

        _setupVaultApproval(staker1, vaultAddr);

        vm.startPrank(staker1);
        // Make 3 separate unstake requests
        controller.requestUnstake(prover1, 100e18);
        controller.requestUnstake(prover1, 100e18);
        controller.requestUnstake(prover1, 100e18);
        vm.stopPrank();

        // Should have 1 staker with pending unstakes
        address[] memory stakersWithPending = controller.getStakersWithPendingUnstakes(prover1);
        assertEq(stakersWithPending.length, 1);
        assertEq(stakersWithPending[0], staker1);
        assertTrue(controller.stakerHasPendingUnstakes(prover1, staker1));

        // Complete unstaking after delay - should process all ready requests
        vm.warp(block.timestamp + UNSTAKE_DELAY + 1);

        vm.startPrank(staker1);
        controller.completeUnstake(prover1);
        vm.stopPrank();

        // Should have no stakers with pending unstakes (all requests completed)
        stakersWithPending = controller.getStakersWithPendingUnstakes(prover1);
        assertEq(stakersWithPending.length, 0);
        assertFalse(controller.stakerHasPendingUnstakes(prover1, staker1));
    }

    function testStakersTrackingWithSlashing() public {
        // Initialize prover
        vm.prank(prover1);
        address vaultAddr = controller.initializeProver(1000);

        // Staker1 stakes and requests unstake
        vm.startPrank(staker1);
        stakingToken.approve(address(controller), 200e18);
        controller.stake(prover1, 200e18);
        vm.stopPrank();

        _setupVaultApproval(staker1, vaultAddr);

        vm.startPrank(staker1);
        controller.requestUnstake(prover1, 100e18);
        vm.stopPrank();

        // Should have 1 staker with pending unstakes
        assertTrue(controller.stakerHasPendingUnstakes(prover1, staker1));

        // Slash the prover
        vm.startPrank(admin);
        controller.slash(prover1, 2000); // 20% slash
        vm.stopPrank();

        // Staker should still be tracked (slashing doesn't remove stakers from set)
        assertTrue(controller.stakerHasPendingUnstakes(prover1, staker1));
        assertEq(controller.getStakersWithPendingUnstakesCount(prover1), 1);

        // Complete unstaking after delay
        vm.warp(block.timestamp + UNSTAKE_DELAY + 1);

        vm.startPrank(staker1);
        controller.completeUnstake(prover1);
        vm.stopPrank();

        // Should have no stakers with pending unstakes
        assertFalse(controller.stakerHasPendingUnstakes(prover1, staker1));
        assertEq(controller.getStakersWithPendingUnstakesCount(prover1), 0);
    }
}
