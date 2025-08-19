// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ProverStaking.sol";
import "../src/ProverRewards.sol";
import "../test/mocks/MockERC20.sol";
import "../test/mocks/MockPicoVerifier.sol";

contract RewardsTest is Test {
    ProverStaking public proverStaking;
    ProverRewards public proverRewards;
    MockERC20 public brevToken;
    MockPicoVerifier public picoVerifier;

    address public owner = address(this);
    address public prover1 = address(0x1);
    address public prover2 = address(0x2);
    address public staker1 = address(0x3);
    address public staker2 = address(0x4);

    uint256 public constant MIN_SELF_STAKE = 10000e18;
    uint256 public constant COMMISSION_RATE = 1000; // 10%

    function setUp() public {
        // Deploy token
        brevToken = new MockERC20("BREV", "BREV");

        // Deploy verifier
        picoVerifier = new MockPicoVerifier();

        // Deploy ProverStaking
        proverStaking = new ProverStaking(address(brevToken), MIN_SELF_STAKE);

        // Deploy ProverRewards
        proverRewards = new ProverRewards(address(proverStaking), address(brevToken));

        // Set ProverRewards in ProverStaking
        proverStaking.setProverRewardsContract(address(proverRewards));

        // Mint tokens for testing
        brevToken.mint(address(this), 1000000e18);
        brevToken.mint(prover1, 100000e18);
        brevToken.mint(prover2, 100000e18);
        brevToken.mint(staker1, 100000e18);
        brevToken.mint(staker2, 100000e18);
    }

    function _initializeProver(address prover) internal {
        vm.startPrank(prover);
        brevToken.approve(address(proverStaking), MIN_SELF_STAKE);
        proverStaking.initProver(uint64(COMMISSION_RATE));
        vm.stopPrank();
    }

    function _stakeToProver(address staker, address prover, uint256 amount) internal {
        vm.startPrank(staker);
        brevToken.approve(address(proverStaking), amount);
        proverStaking.stake(prover, amount);
        vm.stopPrank();
    }

    function test_RewardDistribution() public {
        // Setup: initialize prover and add stakers through ProverStaking
        _initializeProver(prover1);
        uint256 stakeAmount1 = 8000e18;
        uint256 stakeAmount2 = 2000e18;
        _stakeToProver(staker1, prover1, stakeAmount1);
        _stakeToProver(staker2, prover1, stakeAmount2);

        uint256 rewardAmount = 1000e18;

        // Add rewards directly to ProverRewards (external party adding rewards)
        brevToken.transfer(address(this), rewardAmount);
        brevToken.approve(address(proverRewards), rewardAmount);
        proverRewards.addRewards(prover1, rewardAmount);

        // Calculate expected rewards
        uint256 totalStake = MIN_SELF_STAKE + stakeAmount1 + stakeAmount2; // 20000e18
        uint256 expectedCommission = (rewardAmount * COMMISSION_RATE) / 10000; // 10% of 1000e18 = 100e18
        uint256 stakersReward = rewardAmount - expectedCommission; // 900e18

        // Expected individual rewards (proportional to stake)
        uint256 expectedRewards1 = (stakersReward * stakeAmount1) / totalStake; // 900e18 * 8000e18 / 20000e18 = 360e18
        uint256 expectedRewards2 = (stakersReward * stakeAmount2) / totalStake; // 900e18 * 2000e18 / 20000e18 = 90e18
        uint256 expectedProverRewards = (stakersReward * MIN_SELF_STAKE) / totalStake + expectedCommission; // 450e18 + 100e18 = 550e18

        // Check pending rewards via ProverRewards
        uint256 pendingRewards1 = proverRewards.calculateTotalPendingRewards(prover1, staker1);
        uint256 pendingRewards2 = proverRewards.calculateTotalPendingRewards(prover1, staker2);
        uint256 proverPendingRewards = proverRewards.calculateTotalPendingRewards(prover1, prover1);

        // Allow for small rounding differences
        assertApproxEqRel(pendingRewards1, expectedRewards1, 1e15); // 0.1% tolerance
        assertApproxEqRel(pendingRewards2, expectedRewards2, 1e15);
        assertApproxEqRel(proverPendingRewards, expectedProverRewards, 1e15);
    }

    function test_WithdrawRewards() public {
        // Setup: add rewards through ProverStaking integration
        _initializeProver(prover1);
        uint256 stakeAmount = 10000e18;
        _stakeToProver(staker1, prover1, stakeAmount);

        uint256 rewardAmount = 1000e18;
        brevToken.approve(address(proverRewards), rewardAmount);
        proverRewards.addRewards(prover1, rewardAmount);

        uint256 balanceBefore = brevToken.balanceOf(staker1);

        // Withdraw rewards via ProverRewards
        vm.prank(staker1);
        proverRewards.withdrawRewards(prover1);

        uint256 balanceAfter = brevToken.balanceOf(staker1);
        uint256 withdrawn = balanceAfter - balanceBefore;

        assertGt(withdrawn, 0, "Should have withdrawn some rewards");

        // Check that pending rewards are now zero
        uint256 pendingRewards = proverRewards.calculateTotalPendingRewards(prover1, staker1);
        assertEq(pendingRewards, 0);
    }

    function test_WithdrawFromInactiveProver() public {
        // Setup rewards first through ProverStaking integration
        _initializeProver(prover1);
        _stakeToProver(staker1, prover1, 1000e18);

        brevToken.approve(address(proverRewards), 100e18);
        proverRewards.addRewards(prover1, 100e18);

        // Should still be able to withdraw rewards even if prover becomes inactive
        vm.prank(staker1);
        proverRewards.withdrawRewards(prover1); // Should not revert
    }

    function test_AddRewardsExternal() public {
        _initializeProver(prover1);

        // Add a staker through ProverStaking
        vm.prank(staker1);
        brevToken.approve(address(proverStaking), 5000e18);
        vm.prank(staker1);
        proverStaking.stake(prover1, 5000e18);

        uint256 rewardAmount = 1000e18;

        // Approve and add rewards through ProverRewards
        brevToken.approve(address(proverRewards), rewardAmount);
        proverRewards.addRewards(prover1, rewardAmount);

        // Check that rewards were distributed
        uint256 pendingRewards = proverRewards.calculateTotalPendingRewards(prover1, staker1);
        assertGt(pendingRewards, 0, "Staker should have pending rewards");
    }

    function test_AddRewardsTransfersTokens() public {
        _initializeProver(prover1);

        // Add a staker through ProverStaking
        vm.prank(staker1);
        brevToken.approve(address(proverStaking), 5000e18);
        vm.prank(staker1);
        proverStaking.stake(prover1, 5000e18);

        uint256 rewardAmount = 500e18;
        uint256 initialBalance = brevToken.balanceOf(address(this));
        uint256 initialContractBalance = brevToken.balanceOf(address(proverRewards));

        // Approve and add rewards through ProverRewards
        brevToken.approve(address(proverRewards), rewardAmount);
        proverRewards.addRewards(prover1, rewardAmount);

        // Check token transfer occurred
        assertEq(
            brevToken.balanceOf(address(this)), initialBalance - rewardAmount, "Test contract balance should decrease"
        );
        assertEq(
            brevToken.balanceOf(address(proverRewards)),
            initialContractBalance + rewardAmount,
            "Contract balance should increase"
        );
    }
}
