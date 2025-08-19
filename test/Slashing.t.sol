// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {TestProverStaking} from "../test/TestProverStaking.sol";
import {ProverStaking} from "../src/ProverStaking.sol";
import {ProverRewards} from "../src/ProverRewards.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import "../test/utils/TestErrors.sol";

/**
 * @title SlashingTest
 * @notice Comprehensive tests for slashing functionality in the ProverStaking contract
 * @dev Tests slashing mechanics, access control, limits, and edge cases
 */
contract SlashingTest is Test {
    TestProverStaking public proverStaking;
    ProverRewards public proverRewards;
    MockERC20 public brevToken;
    MockERC20 public rewardToken;

    address public owner = makeAddr("owner");
    address public prover1 = makeAddr("prover1");
    address public prover2 = makeAddr("prover2");
    address public staker1 = makeAddr("staker1");
    address public staker2 = makeAddr("staker2");
    address public user = makeAddr("user");

    uint256 public constant INITIAL_SUPPLY = 1_000_000e18;
    uint256 public constant MIN_SELF_STAKE = 10_000e18;
    uint256 public constant GLOBAL_MIN_SELF_STAKE = 10_000e18;
    uint64 public constant COMMISSION_RATE = 1000; // 10%

    event GlobalParamUpdated(ProverStaking.ParamName indexed param, uint256 newValue);
    event ProverDeactivated(address indexed prover);
    event ProverRetired(address indexed prover);

    function setUp() public {
        // Deploy tokens
        brevToken = new MockERC20("Brevis Token", "BREV");
        rewardToken = new MockERC20("Reward Token", "REWARD");

        // Deploy contracts
        vm.startPrank(owner);
        proverStaking = new TestProverStaking(address(brevToken), GLOBAL_MIN_SELF_STAKE);
        proverRewards = new ProverRewards(address(proverStaking), address(rewardToken));

        // Link contracts
        proverStaking.setProverRewardsContract(address(proverRewards));

        // Grant slasher role to both this test contract and owner for testing
        proverStaking.grantRole(proverStaking.SLASHER_ROLE(), address(this));
        proverStaking.grantRole(proverStaking.SLASHER_ROLE(), owner);
        vm.stopPrank();

        // Mint tokens to various addresses
        brevToken.mint(prover1, INITIAL_SUPPLY);
        brevToken.mint(prover2, INITIAL_SUPPLY);
        brevToken.mint(staker1, INITIAL_SUPPLY);
        brevToken.mint(staker2, INITIAL_SUPPLY);
        brevToken.mint(owner, INITIAL_SUPPLY);
        brevToken.mint(address(this), INITIAL_SUPPLY);
        rewardToken.mint(owner, INITIAL_SUPPLY);

        // Approve spending
        brevToken.approve(address(proverStaking), INITIAL_SUPPLY);
        vm.prank(owner);
        brevToken.approve(address(proverRewards), INITIAL_SUPPLY);
        vm.prank(owner);
        rewardToken.approve(address(proverRewards), INITIAL_SUPPLY);
    }

    // ========== BASIC SLASHING TESTS ==========

    function test_SlashProver() public {
        // Setup staking
        _initializeProver(prover1);
        uint256 stakeAmount = 9000e18;
        _stakeToProver(staker1, prover1, stakeAmount);

        uint256 totalStakeBefore = 19000e18; // MIN_SELF_STAKE + 9000e18
        uint256 slashPercentage = 200000; // 20%

        vm.prank(owner);
        proverStaking.slash(prover1, slashPercentage);

        (, uint256 totalStakeAfter,,) = proverStaking.getProverInfo(prover1);
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

        (, uint256 stakeAfter,,) = proverStaking.getProverInfo(prover1);
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

    function test_SetMaxSlashFactor() public {
        uint256 newMaxSlash = 300000; // 30% (300,000 parts per million)

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit GlobalParamUpdated(ProverStaking.ParamName.MaxSlashFactor, newMaxSlash);
        proverStaking.setGlobalParam(ProverStaking.ParamName.MaxSlashFactor, newMaxSlash);

        assertEq(
            proverStaking.globalParams(ProverStaking.ParamName.MaxSlashFactor),
            newMaxSlash,
            "Max slash percentage should be updated"
        );
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

    // ========== SLASHING WITH PROVER STATES ==========

    function test_CannotUnretireSlashedProver() public {
        // Initialize prover
        _initializeProver(prover1);

        // Slash prover by maximum allowed (50% slash - brings scale to 0.5 which is above DEACTIVATION_SCALE of 0.2)
        // Need to slash prover multiple times to get below deactivation threshold
        vm.prank(owner);
        proverStaking.slash(prover1, 500000); // 50% slash -> scale becomes 0.5

        vm.prank(owner);
        proverStaking.slash(prover1, 500000); // Another 50% of remaining -> scale becomes 0.25

        vm.prank(owner);
        proverStaking.slash(prover1, 400000); // 40% of remaining -> scale becomes 0.15 (below 0.2 threshold)

        // Prover should be auto-deactivated due to slashing
        (ProverStaking.ProverState state,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(state == ProverStaking.ProverState.Deactivated, "Prover should be deactivated after heavy slash");

        // Unstake remaining and retire
        (uint256 remainingStake,,,) = proverStaking.getStakeInfo(prover1, prover1);
        vm.prank(prover1);
        proverStaking.requestUnstake(prover1, remainingStake);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(prover1);
        proverStaking.completeUnstake(prover1);

        // Retire the prover
        vm.prank(owner);
        proverStaking.retireProver(prover1);

        // Try to stake while retired to meet minimum requirements
        vm.prank(prover1);
        brevToken.approve(address(proverStaking), MIN_SELF_STAKE);
        vm.prank(prover1);
        proverStaking.stake(prover1, MIN_SELF_STAKE);

        // Cannot unretire due to low scale (InvalidScale error)
        vm.expectRevert(TestErrors.InvalidScale.selector);
        vm.prank(prover1);
        proverStaking.unretireProver();
    }

    function test_CannotReactivateSlashedProver() public {
        // Initialize prover
        _initializeProver(prover1);

        // Slash prover by maximum allowed multiple times to get below deactivation threshold
        vm.prank(owner);
        proverStaking.slash(prover1, 500000); // 50% slash -> scale becomes 0.5

        vm.prank(owner);
        proverStaking.slash(prover1, 500000); // Another 50% of remaining -> scale becomes 0.25

        vm.prank(owner);
        proverStaking.slash(prover1, 400000); // 40% of remaining -> scale becomes 0.15 (below 0.2 threshold)

        // Prover should be auto-deactivated due to slashing
        (ProverStaking.ProverState state,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(state == ProverStaking.ProverState.Deactivated, "Prover should be deactivated after heavy slash");

        // Admin cannot reactivate due to low scale (InvalidScale error)
        vm.expectRevert(TestErrors.InvalidScale.selector);
        vm.prank(owner);
        proverStaking.reactivateProver(prover1);
    }

    // ========== EXTREME SLASHING SCENARIOS ==========

    function test_MassiveStakeAndSlash() public {
        _initializeProver(prover1);

        // Stake enormous amount
        uint256 massiveStake = 100_000_000e18;
        brevToken.mint(staker1, massiveStake);
        vm.prank(staker1);
        brevToken.approve(address(proverStaking), massiveStake);
        vm.prank(staker1);
        proverStaking.stake(prover1, massiveStake);

        // Slash maximum allowed (50%)
        vm.prank(owner);
        proverStaking.slash(prover1, 500000); // 50%

        (, uint256 totalStake,,) = proverStaking.getProverInfo(prover1);
        uint256 expectedRemaining = (MIN_SELF_STAKE + massiveStake) / 2; // 50%
        assertApproxEqRel(totalStake, expectedRemaining, 1e15);
    }

    function test_ExtremeSlashingScenario() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 4000e18);

        // Multiple maximum slashes to demonstrate auto-deactivation at 20% threshold
        proverStaking.slash(prover1, 500000); // 50% slash - leaves 50%

        // Verify still active after first slash
        (ProverStaking.ProverState state1,,,) = proverStaking.getProverInfo(prover1);
        assertEq(uint256(state1), uint256(ProverStaking.ProverState.Active));

        proverStaking.slash(prover1, 500000); // 50% of remaining - leaves 25% total

        // Verify still active after second slash (still above 20% threshold)
        (ProverStaking.ProverState state2,,,) = proverStaking.getProverInfo(prover1);
        assertEq(uint256(state2), uint256(ProverStaking.ProverState.Active));

        proverStaking.slash(prover1, 500000); // 50% of remaining - leaves 12.5% total

        // NOW should be auto-deactivated (below 20% threshold)
        (ProverStaking.ProverState finalState,,,) = proverStaking.getProverInfo(prover1);
        assertEq(uint256(finalState), uint256(ProverStaking.ProverState.Deactivated));

        (, uint256 finalStake,,) = proverStaking.getProverInfo(prover1);
        uint256 originalStake = MIN_SELF_STAKE + 4000e18; // 14000e18
        // After 3 slashes of 50% each: 14000 * (0.5)^3 = 14000 * 0.125 = 1750e18
        uint256 expectedFinalStake = originalStake / 8; // 12.5% remaining

        assertEq(finalStake, expectedFinalStake);

        // Staker should still be able to unstake remaining amount
        // After 3 slashes of 50% each, the staker's stake is reduced by the same factor
        // Original staker stake: 4000e18, after slashes: 4000e18 * (0.5)^3 = 4000e18 * 0.125 = 500e18
        uint256 stakerRemainingStake = 4000e18 / 8; // 12.5% remaining

        vm.prank(staker1);
        proverStaking.requestUnstake(prover1, stakerRemainingStake);

        vm.warp(block.timestamp + 7 days + 1);
        uint256 balanceBefore = brevToken.balanceOf(staker1);
        vm.prank(staker1);
        proverStaking.completeUnstake(prover1);
        uint256 balanceAfter = brevToken.balanceOf(staker1);

        assertEq(balanceAfter - balanceBefore, stakerRemainingStake);
    }

    function test_SlashDuringUnstakingPeriod() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 1000e18);

        // Request unstake
        vm.prank(staker1);
        proverStaking.requestUnstake(prover1, 800e18);

        // Slash 30% during unstaking period
        vm.prank(owner);
        proverStaking.slash(prover1, 300000); // 30% slash

        // Complete unstake after delay
        vm.warp(block.timestamp + 7 days + 1);
        uint256 balanceBefore = brevToken.balanceOf(staker1);
        vm.prank(staker1);
        proverStaking.completeUnstake(prover1);
        uint256 balanceAfter = brevToken.balanceOf(staker1);

        // Should receive 70% of original unstake amount (800e18 * 0.7 = 560e18)
        uint256 expectedPayout = (800e18 * 70) / 100;
        assertEq(balanceAfter - balanceBefore, expectedPayout, "Unstake payout should reflect slash");
    }

    function test_SlashDuringMultipleUnbonding() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 5000e18);
        _stakeToProver(staker2, prover1, 3000e18);

        // Both stakers initiate unstaking
        vm.prank(staker1);
        proverStaking.requestUnstake(prover1, 2000e18);

        vm.warp(block.timestamp + 3600); // 1 hour later
        vm.prank(staker2);
        proverStaking.requestUnstake(prover1, 1000e18);

        // Slash 50% while both are unbonding
        vm.prank(owner);
        proverStaking.slash(prover1, 500000);

        // Complete first unstake
        vm.warp(block.timestamp + 7 days);
        uint256 balance1Before = brevToken.balanceOf(staker1);
        vm.prank(staker1);
        proverStaking.completeUnstake(prover1);
        uint256 balance1After = brevToken.balanceOf(staker1);

        // Complete second unstake
        vm.warp(block.timestamp + 3600); // Original unstake + 7 days for staker2
        uint256 balance2Before = brevToken.balanceOf(staker2);
        vm.prank(staker2);
        proverStaking.completeUnstake(prover1);
        uint256 balance2After = brevToken.balanceOf(staker2);

        // Both should receive 50% of their unstaked amounts
        assertEq(balance1After - balance1Before, 1000e18); // 50% of 2000e18
        assertEq(balance2After - balance2Before, 500e18); // 50% of 1000e18
    }

    function test_UnretireWithSlashingHistory() public {
        // Initialize prover and add delegations
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 1000e18);

        // Slash the prover by 10% (keep scale above DEACTIVATION_SCALE of 20%)
        vm.prank(owner);
        proverStaking.slash(prover1, 100000); // 10%

        // Verify slash took effect
        (uint256 totalStaked1,,,) = proverStaking.getStakeInfo(prover1, prover1);
        assertEq(totalStaked1, MIN_SELF_STAKE * 9 / 10, "Self-stake should be reduced by 10% after slash");

        // Unstake completely and retire
        vm.prank(prover1);
        proverStaking.requestUnstake(prover1, totalStaked1);
        vm.prank(staker1);
        proverStaking.requestUnstake(prover1, 900e18); // 90% of original 1000e18

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(prover1);
        proverStaking.completeUnstake(prover1);
        vm.prank(staker1);
        proverStaking.completeUnstake(prover1);

        vm.prank(owner);
        proverStaking.retireProver(prover1);

        // Self-stake while retired - need to stake more to account for slashing
        // With 10% slash, scale is 0.9, so need to stake ~111% of MIN_SELF_STAKE to get effective MIN_SELF_STAKE
        uint256 stakeAmount = (MIN_SELF_STAKE * 10) / 9; // Slightly more than MIN_SELF_STAKE / 0.9
        vm.prank(prover1);
        brevToken.approve(address(proverStaking), stakeAmount);
        vm.prank(prover1);
        proverStaking.stake(prover1, stakeAmount);

        // Unretire after self-staking (should work since scale is 0.9 > 0.2)
        vm.prank(prover1);
        proverStaking.unretireProver();

        // Verify stake retains slashing history - effective amount should meet minimum
        (uint256 totalStaked2,,,) = proverStaking.getStakeInfo(prover1, prover1);
        assertGe(totalStaked2, MIN_SELF_STAKE, "Effective stake should meet minimum self-stake requirement");

        // Verify prover scale retains slashing history (0.9 from 10% slash)
        (, uint256 scale,) = proverStaking.getProverInternals(prover1);
        assertEq(scale, 0.9e18, "Scale should retain slashing history (0.9 from 10% slash)");
    }

    function test_MaxSlashFactorLimit() public {
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 1000e18);

        // Try to slash more than 50% - should revert
        vm.expectRevert(TestErrors.SlashTooHigh.selector);
        proverStaking.slash(prover1, 500001); // 50.0001%

        // Slash exactly 50% - should work
        proverStaking.slash(prover1, 500000); // 50%

        // Verify prover is still active after 50% slash
        (ProverStaking.ProverState state,,,) = proverStaking.getProverInfo(prover1);
        assertTrue(state == ProverStaking.ProverState.Active, "Prover should still be active after 50% slash");
    }

    // ========== HELPER FUNCTIONS ==========

    function _initializeProver(address prover) internal {
        vm.prank(prover);
        brevToken.approve(address(proverStaking), GLOBAL_MIN_SELF_STAKE);

        vm.prank(prover);
        proverStaking.initProver(COMMISSION_RATE);
    }

    function _stakeToProver(address staker, address prover, uint256 amount) internal {
        vm.prank(staker);
        brevToken.approve(address(proverStaking), amount);
        vm.prank(staker);
        proverStaking.stake(prover, amount);
    }
}
