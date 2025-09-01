// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../src/staking/interfaces/IStakingController.sol";

contract MockStakingController {
    IERC20 public stakingToken;
    mapping(address => uint256) public proverStakes;
    mapping(address => IStakingController.ProverState) public proverStates;
    mapping(address => bool) public proverEligibility;
    mapping(address => uint256) public proverCurrentStakes;
    uint256 public minSelfStake = 1e17; // 0.1 token, less than test MIN_STAKE

    // Slash tracking for tests
    mapping(address => mapping(uint256 => bool)) public slashByAmountCalls;
    mapping(address => mapping(uint256 => uint256)) public slashByAmountResults;
    bool public anySlashCalled;

    // Rewards tracking for tests
    mapping(address => mapping(uint256 => bool)) public addRewardsCalls;
    bool public anyAddRewardsCalled;

    constructor(IERC20 _stakingToken) {
        stakingToken = _stakingToken;
    }

    function setProverState(address prover, IStakingController.ProverState state) external {
        proverStates[prover] = state;
    }

    function setProverEligible(address prover, bool eligible, uint256 stake) external {
        proverEligibility[prover] = eligible;
        proverCurrentStakes[prover] = stake;
        proverStakes[prover] = stake;
    }

    function getProverState(address prover) external view returns (IStakingController.ProverState state) {
        return proverStates[prover];
    }

    function setProverStake(address prover, uint256 stake) external {
        proverStakes[prover] = stake;
        proverCurrentStakes[prover] = stake; // Also update current stakes used for eligibility
    }

    function isProverEligible(address prover, uint256 minimumStake)
        external
        view
        returns (bool eligible, uint256 currentStake)
    {
        currentStake = proverCurrentStakes[prover];
        eligible = proverEligibility[prover] && currentStake >= minimumStake;
    }

    function addRewards(address prover, uint256 amount) external returns (uint256 commission, uint256 toStakers) {
        // Track the call for tests
        addRewardsCalls[prover][amount] = true;
        anyAddRewardsCalled = true;

        // Transfer tokens from the market contract to this staking controller
        stakingToken.transferFrom(msg.sender, address(this), amount);

        // Simple mock: no commission, all goes to stakers
        commission = 0;
        toStakers = amount;
    }

    function slashByAmount(address prover, uint256 amount) external returns (uint256 slashedAmount) {
        // Track the call
        slashByAmountCalls[prover][amount] = true;
        anySlashCalled = true;

        // Return configured result or default to requested amount
        slashedAmount = slashByAmountResults[prover][amount];
        if (slashedAmount == 0) {
            slashedAmount = amount; // Default: slash the requested amount
        }

        return slashedAmount;
    }

    // Test helper functions
    function wasSlashByAmountCalled(address prover, uint256 amount) external view returns (bool) {
        return slashByAmountCalls[prover][amount];
    }

    function wasAnySlashCalled() external view returns (bool) {
        return anySlashCalled;
    }

    function setSlashByAmountResult(address prover, uint256 amount, uint256 result) external {
        slashByAmountResults[prover][amount] = result;
    }

    function resetSlashTracking() external {
        anySlashCalled = false;
        // Note: Individual call tracking would need to be reset per prover/amount if needed
    }

    // Test helper functions for rewards tracking
    function wasAddRewardsCalled(address prover, uint256 amount) external view returns (bool) {
        return addRewardsCalls[prover][amount];
    }

    function wasAnyAddRewardsCalled() external view returns (bool) {
        return anyAddRewardsCalled;
    }

    function resetRewardsTracking() external {
        anyAddRewardsCalled = false;
        // Note: Individual call tracking would need to be reset per prover/amount if needed
    }
}
