// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {StakingController} from "src/staking/controller/StakingController.sol";
import {VaultFactory} from "src/staking/vault/VaultFactory.sol";
import {IProverVault} from "src/staking/interfaces/IProverVault.sol";
import {IStakingController} from "src/staking/interfaces/IStakingController.sol";

// Minimal mock ERC20 (use existing MockERC20 if present)
import {MockERC20} from "test/mocks/MockERC20.sol";

contract ShareTransferTest is Test {
    StakingController controller;
    VaultFactory factory;
    MockERC20 token;

    address prover = address(0xA11CE);
    address staker1 = address(0xBEEF1);
    address staker2 = address(0xBEEF2);

    function setUp() public {
        token = new MockERC20("Mock Token", "MOCK");
        factory = new VaultFactory();

        controller = new StakingController(
            address(token),
            address(factory),
            3 days,
            1e18, // minSelfStake: 1 token
            5000 // maxSlashBps: 50%
        );
        // Grant controller permission to create vaults (test contract is default admin)
        factory.init(address(controller));

        // Grant slasher role to test contract for testing
        controller.grantRole(controller.SLASHER_ROLE(), address(this));

        // Set a meaningful MIN_SELF_STAKE for testing
        controller.setMinSelfStake(1 ether);

        // Fund accounts
        token.mint(prover, 10 ether);
        token.mint(staker1, 10 ether);
        token.mint(staker2, 10 ether);

        // Approvals
        vm.startPrank(prover);
        token.approve(address(controller), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(staker1);
        token.approve(address(controller), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(staker2);
        token.approve(address(controller), type(uint256).max);
        vm.stopPrank();

        // Initialize prover (commission 0)
        vm.prank(prover);
        controller.initializeProver(0);
    }

    function _vault() internal view returns (IProverVault) {
        return IProverVault(controller.getProverVault(prover));
    }

    function _sumShares() internal view returns (uint256 total) {
        address[] memory stakers = controller.getProverStakers(prover);
        for (uint256 i; i < stakers.length; ++i) {
            (uint256 shares,,) = _stakeInfo(stakers[i]);
            total += shares;
        }
    }

    function _stakeInfo(address staker)
        internal
        view
        returns (uint256 shares, uint256 pendingRequests, uint256 totalPendingShares)
    {
        shares = controller.getStakeInfo(prover, staker);

        // Get unstaking info from the controller
        IStakingController.UnstakeRequest[] memory unstakeRequests = controller.getPendingUnstakes(staker, prover);
        pendingRequests = unstakeRequests.length;
        for (uint256 i; i < unstakeRequests.length; ++i) {
            totalPendingShares += unstakeRequests[i].amount; // amount is in underlying tokens in unstaking contract
        }
    }

    function testTransferUpdatesAccounting() public {
        // Stake initial amounts
        vm.prank(staker1);
        controller.stake(prover, 5 ether);
        vm.prank(staker2);
        controller.stake(prover, 3 ether);

        IProverVault vault = _vault();
        // Transfer 2 ether (2 shares) from staker1 to staker2
        vm.prank(staker1);
        vault.transfer(staker2, 2 ether);

        (uint256 s1,,) = _stakeInfo(staker1);
        (uint256 s2,,) = _stakeInfo(staker2);
        assertEq(s1, 3 ether, "staker1 shares incorrect after transfer");
        assertEq(s2, 5 ether, "staker2 shares incorrect after transfer");
        assertEq(_sumShares(), vault.totalSupply(), "aggregate shares mismatch");
    }

    function testCannotTransferLockedPendingUnstake() public {
        vm.prank(staker1);
        controller.stake(prover, 5 ether);
        // Request unstake 3 ether
        vm.startPrank(staker1);
        _vault().approve(address(controller), 3 ether);
        controller.requestUnstake(prover, 3 ether);
        vm.stopPrank();
        IProverVault vault = _vault();
        // Attempt to transfer locked 3 shares should revert
        vm.prank(staker1);
        vm.expectRevert(IProverVault.VaultSharesLocked.selector);
        vault.transfer(staker2, 3 ether);
        // But transferring 2 (unlocked) should succeed
        vm.prank(staker1);
        vault.transfer(staker2, 2 ether);
    }

    function testProverTransferProjectedMinSelfStakeViolationReverts() public {
        // Prover already self-staked min stake during initialize (1 ether)
        // Add more self stake to reach 5 ether total
        vm.prank(prover);
        controller.stake(prover, 4 ether); // total self stake 5
        IProverVault vault = _vault();
        // Prover requests unstake of 4 -> remaining 1 (== min) valid
        vm.prank(prover);
        vault.approve(address(controller), 4 ether);
        vm.prank(prover);
        controller.requestUnstake(prover, 4 ether);
        // Now attempt transfer of 0.5 -> projected remainingAfter = 5 -0.5 -4 =0.5 (< min) should revert
        vm.prank(prover);
        vm.expectRevert(IStakingController.ControllerMinSelfStakeNotMet.selector);
        vault.transfer(staker1, 0.5 ether);
        // Transfer of 0.1 -> remainingAfter=0.9 (<min) also revert
        vm.prank(prover);
        vm.expectRevert(IStakingController.ControllerMinSelfStakeNotMet.selector);
        vault.transfer(staker1, 0.1 ether);
        // Full transfer of remaining 1 keeps remainingAfter = 0, which is allowed (prover can fully exit after pending unstake). Should succeed.
        vm.prank(prover);
        vault.transfer(staker1, 1 ether);
    }

    function testMintBurnNotDoubleCount() public {
        vm.prank(staker1);
        controller.stake(prover, 2 ether);
        vm.prank(staker2);
        controller.stake(prover, 3 ether);
        IProverVault vault = _vault();
        assertEq(_sumShares(), vault.totalSupply(), "pre-unstake aggregate mismatch");

        // staker1 unstakes 2
        vm.startPrank(staker1);
        // Approve vault shares to controller for requestUnstake (not completeUnstake)
        vault.approve(address(controller), 2 ether);
        controller.requestUnstake(prover, 2 ether);
        vm.stopPrank();
        // Fast-forward delay (3 days)
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(staker1);
        controller.completeUnstake(prover);

        // After burn aggregate shares should match vault totalSupply
        assertEq(_sumShares(), vault.totalSupply(), "post-burn aggregate mismatch");
    }

    function testProverTransferLeavingExactMinSelfStakeSucceeds() public {
        // Prover already has 1 ether from initialization (MIN_SELF_STAKE)
        // Add more self stake
        vm.prank(prover);
        controller.stake(prover, 2 ether); // total self stake = 3 ether

        IProverVault vault = _vault();
        uint256 staker1SharesBefore = vault.balanceOf(staker1);

        // Transfer exactly 2 ether, leaving exactly 1 ether (MIN_SELF_STAKE) - should succeed
        vm.prank(prover);
        vault.transfer(staker1, 2 ether);

        // Verify transfer succeeded
        assertEq(vault.balanceOf(prover), 1 ether, "Prover should have exactly MIN_SELF_STAKE left");
        assertEq(vault.balanceOf(staker1), staker1SharesBefore + 2 ether, "Staker1 should receive transferred shares");

        // Verify prover is still active (not deactivated when at exactly MIN_SELF_STAKE)
        assertEq(uint256(controller.getProverState(prover)), uint256(IStakingController.ProverState.Active));
    }

    function testProverTransferToZeroSelfStakeAutoDeactivates() public {
        // This test verifies that transfer to zero self-stake auto-deactivates prover
        // for consistency with unstake behavior

        // Prover already has 1 ether from initialization (MIN_SELF_STAKE)
        IProverVault vault = _vault();

        // Verify prover is active before transfer
        assertEq(uint256(controller.getProverState(prover)), uint256(IStakingController.ProverState.Active));

        // Transfer all shares to staker1, leaving 0 self-stake
        vm.prank(prover);
        vault.transfer(staker1, 1 ether);

        // Verify transfer succeeded
        assertEq(vault.balanceOf(prover), 0, "Prover should have 0 shares after complete transfer");
        assertEq(vault.balanceOf(staker1), 1 ether, "Staker1 should receive all transferred shares");

        // Verify prover is auto-deactivated when self-stake becomes 0 (consistent with unstake)
        assertEq(
            uint256(controller.getProverState(prover)),
            uint256(IStakingController.ProverState.Deactivated),
            "Prover should be auto-deactivated when transferring all self-stake to zero"
        );
    }

    function testProverTransferBelowMinSelfStakeRevertsDistinctFromUnstake() public {
        // This test ensures transfer path enforces same rule as unstake path

        // Prover already has 1 ether from initialization (MIN_SELF_STAKE)
        // Add more self stake
        vm.prank(prover);
        controller.stake(prover, 1.5 ether); // total self stake = 2.5 ether

        IProverVault vault = _vault();

        // Try to transfer 1.8 ether, which would leave 0.7 ether (< 1 ether MIN_SELF_STAKE)
        vm.prank(prover);
        vm.expectRevert(IStakingController.ControllerMinSelfStakeNotMet.selector);
        vault.transfer(staker1, 1.8 ether);

        // Try to transfer 1.6 ether, which would leave 0.9 ether (still < 1 ether MIN_SELF_STAKE)
        vm.prank(prover);
        vm.expectRevert(IStakingController.ControllerMinSelfStakeNotMet.selector);
        vault.transfer(staker1, 1.6 ether);

        // Verify prover is still active and has original balance (no transfer occurred)
        assertEq(vault.balanceOf(prover), 2.5 ether, "Prover should still have original balance");
        assertEq(uint256(controller.getProverState(prover)), uint256(IStakingController.ProverState.Active));

        // For comparison: same restriction applies via unstake path
        vm.prank(prover);
        vault.approve(address(controller), 1.6 ether);
        vm.prank(prover);
        vm.expectRevert(IStakingController.ControllerMinSelfStakeNotMet.selector);
        controller.requestUnstake(prover, 1.6 ether);
    }

    function testDirectVaultTransferBookkeepingIntegrity() public {
        // Test: Direct vault share transfer between two non-prover stakers updates
        // controller internal shares map; sender removed from stakers set when balance
        // reaches zero, receiver added when first acquiring.
        // Value: Integrity of accounting hook.

        address staker3 = address(0xBEEF3);
        token.mint(staker3, 10 ether);
        vm.prank(staker3);
        token.approve(address(controller), type(uint256).max);

        // Initial stakes: staker1=5, staker2=3, staker3=2
        vm.prank(staker1);
        controller.stake(prover, 5 ether);
        vm.prank(staker2);
        controller.stake(prover, 3 ether);
        vm.prank(staker3);
        controller.stake(prover, 2 ether);

        IProverVault vault = _vault();

        // Verify initial state
        address[] memory initialStakers = controller.getProverStakers(prover);
        assertEq(initialStakers.length, 4, "Should have 4 stakers initially (prover + 3 stakers)");
        assertEq(controller.getStakeInfo(prover, staker1), 5 ether, "staker1 initial shares");
        assertEq(controller.getStakeInfo(prover, staker2), 3 ether, "staker2 initial shares");
        assertEq(controller.getStakeInfo(prover, staker3), 2 ether, "staker3 initial shares");

        // Test 1: Transfer from staker1 to staker2 (both remain in stakers set)
        vm.prank(staker1);
        vault.transfer(staker2, 2 ether);

        assertEq(controller.getStakeInfo(prover, staker1), 3 ether, "staker1 shares after partial transfer");
        assertEq(controller.getStakeInfo(prover, staker2), 5 ether, "staker2 shares after receiving");
        address[] memory stakersAfterPartial = controller.getProverStakers(prover);
        assertEq(stakersAfterPartial.length, 4, "Stakers count unchanged after partial transfer");

        // Test 2: Transfer ALL remaining shares from staker1 to staker3 (staker1 removed from set)
        vm.prank(staker1);
        vault.transfer(staker3, 3 ether);

        assertEq(controller.getStakeInfo(prover, staker1), 0, "staker1 should have 0 shares");
        assertEq(controller.getStakeInfo(prover, staker3), 5 ether, "staker3 shares after receiving");

        address[] memory stakersAfterComplete = controller.getProverStakers(prover);
        assertEq(stakersAfterComplete.length, 3, "Stakers count reduced after complete transfer");

        // Verify staker1 is no longer in stakers set
        bool staker1Found = false;
        for (uint256 i = 0; i < stakersAfterComplete.length; i++) {
            if (stakersAfterComplete[i] == staker1) {
                staker1Found = true;
                break;
            }
        }
        assertFalse(staker1Found, "staker1 should be removed from stakers set when balance reaches 0");

        // Test 3: Transfer to a completely new address (addition to stakers set)
        address newStaker = address(0xBEEF4);
        vm.prank(staker2);
        vault.transfer(newStaker, 1 ether);

        assertEq(controller.getStakeInfo(prover, newStaker), 1 ether, "new staker shares");
        assertEq(controller.getStakeInfo(prover, staker2), 4 ether, "staker2 shares after transfer to new");

        address[] memory stakersAfterNewAddition = controller.getProverStakers(prover);
        assertEq(stakersAfterNewAddition.length, 4, "Stakers count increased after transfer to new address");

        // Verify new staker is in stakers set
        bool newStakerFound = false;
        for (uint256 i = 0; i < stakersAfterNewAddition.length; i++) {
            if (stakersAfterNewAddition[i] == newStaker) {
                newStakerFound = true;
                break;
            }
        }
        assertTrue(newStakerFound, "new staker should be added to stakers set when first acquiring shares");

        // Test 4: Verify aggregate accounting integrity
        uint256 totalControllerShares = 0;
        address[] memory finalStakers = controller.getProverStakers(prover);
        for (uint256 i = 0; i < finalStakers.length; i++) {
            totalControllerShares += controller.getStakeInfo(prover, finalStakers[i]);
        }

        assertEq(
            totalControllerShares, vault.totalSupply(), "Controller aggregate shares must match vault total supply"
        );
        assertEq(
            totalControllerShares,
            1 ether + 4 ether + 5 ether + 1 ether,
            "Total should equal prover + staker2 + staker3 + newStaker"
        );
    }
}
