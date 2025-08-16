// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ProverStaking} from "../src/ProverStaking.sol";
import {ProverRewards} from "../src/ProverRewards.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/**
 * @title IntegrationTest
 * @notice Tests for the integrated ProverStaking and ProverRewards contracts
 */
contract IntegrationTest is Test {
    ProverStaking public proverStaking;
    ProverRewards public proverRewards;
    MockERC20 public stakingToken;
    MockERC20 public rewardToken;

    address public owner = makeAddr("owner");
    address public prover1 = makeAddr("prover1");
    address public staker1 = makeAddr("staker1");
    address public rewarder = makeAddr("rewarder");

    uint256 public constant INITIAL_SUPPLY = 1_000_000e18;
    uint256 public constant MIN_SELF_STAKE = 10_000e18;
    uint256 public constant GLOBAL_MIN_SELF_STAKE = 1_000e18;
    uint64 public constant COMMISSION_RATE = 1000; // 10%

    function setUp() public {
        // Deploy tokens
        stakingToken = new MockERC20("Staking Token", "STAKE");
        rewardToken = new MockERC20("Reward Token", "REWARD");

        // Deploy contracts
        vm.startPrank(owner);
        proverStaking = new ProverStaking(address(stakingToken), GLOBAL_MIN_SELF_STAKE);
        proverRewards = new ProverRewards(address(proverStaking), address(rewardToken));

        // Link contracts
        proverStaking.setProverRewardsContract(address(proverRewards));

        // Grant slasher role
        proverStaking.grantRole(proverStaking.SLASHER_ROLE(), owner);
        vm.stopPrank();

        // Mint tokens
        stakingToken.mint(prover1, INITIAL_SUPPLY);
        stakingToken.mint(staker1, INITIAL_SUPPLY);
        rewardToken.mint(rewarder, INITIAL_SUPPLY);
    }

    function test_IntegratedFlow() public {
        // Test 1: Prover initialization
        vm.prank(prover1);
        stakingToken.approve(address(proverStaking), MIN_SELF_STAKE);

        vm.prank(prover1);
        proverStaking.initProver(MIN_SELF_STAKE, COMMISSION_RATE);

        // Verify prover info in both contracts
        (
            ProverStaking.ProverState state,
            uint256 minSelfStake,
            uint256 totalStaked,
            uint256 selfStake,
            uint256 stakerCount
        ) = proverStaking.getProverInfo(prover1);

        assertTrue(state == ProverStaking.ProverState.Active);
        assertEq(minSelfStake, MIN_SELF_STAKE);
        assertEq(totalStaked, MIN_SELF_STAKE);
        assertEq(selfStake, MIN_SELF_STAKE);
        assertEq(stakerCount, 1);

        (uint64 commissionRate, uint256 pendingCommission, uint256 accRewardPerRawShare) =
            proverRewards.getProverRewardInfo(prover1);

        assertEq(commissionRate, COMMISSION_RATE);
        assertEq(pendingCommission, 0);
        assertEq(accRewardPerRawShare, 0);

        // Test 2: External staking
        uint256 stakeAmount = 5_000e18;
        vm.prank(staker1);
        stakingToken.approve(address(proverStaking), stakeAmount);

        vm.prank(staker1);
        proverStaking.stake(prover1, stakeAmount);

        // Verify updated totals
        (,, totalStaked,, stakerCount) = proverStaking.getProverInfo(prover1);
        assertEq(totalStaked, MIN_SELF_STAKE + stakeAmount);
        assertEq(stakerCount, 2);

        // Test 3: Reward distribution
        uint256 rewardAmount = 1_000e18;
        vm.prank(rewarder);
        rewardToken.approve(address(proverRewards), rewardAmount);

        vm.prank(rewarder);
        proverRewards.addRewards(prover1, rewardAmount);

        // Test 4: Reward withdrawal
        uint256 expectedStakerReward = (rewardAmount * 9000 / 10000) * stakeAmount / (MIN_SELF_STAKE + stakeAmount); // 90% of rewards, proportional to stake
        uint256 expectedProverReward = rewardAmount - expectedStakerReward; // Commission + proportional stake reward

        vm.prank(staker1);
        proverRewards.withdrawRewards(prover1);

        vm.prank(prover1);
        proverRewards.withdrawRewards(prover1);

        // Verify reward token balances
        assertTrue(rewardToken.balanceOf(staker1) > 0);
        assertTrue(rewardToken.balanceOf(prover1) > 0);
    }

    function test_SecurityIsolation() public {
        // Test that ProverRewards contract failure doesn't affect staking operations

        // Initialize prover
        vm.prank(prover1);
        stakingToken.approve(address(proverStaking), MIN_SELF_STAKE);

        vm.prank(prover1);
        proverStaking.initProver(MIN_SELF_STAKE, COMMISSION_RATE);

        // Verify staking works even if ProverRewards is removed
        vm.prank(owner);
        proverStaking.setProverRewardsContract(address(0));

        uint256 stakeAmount = 5_000e18;
        vm.prank(staker1);
        stakingToken.approve(address(proverStaking), stakeAmount);

        vm.prank(staker1);
        proverStaking.stake(prover1, stakeAmount);

        // Verify stake was successful
        (uint256 amount,,,) = proverStaking.getStakeInfo(prover1, staker1);
        assertEq(amount, stakeAmount);

        // Verify unstaking still works
        vm.prank(staker1);
        proverStaking.requestUnstake(prover1, stakeAmount);

        // Skip delay and complete unstake
        vm.warp(block.timestamp + 8 days);
        vm.prank(staker1);
        proverStaking.completeUnstake(prover1);

        // Verify tokens were returned
        assertEq(stakingToken.balanceOf(staker1), INITIAL_SUPPLY);
    }
}
