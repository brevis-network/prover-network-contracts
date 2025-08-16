// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

/**
 * @title IProverRewards
 * @notice Interface for ProverRewards contract to be used by ProverStaking
 */
interface IProverRewards {
    /**
     * @notice Initialize reward tracking for a new prover
     * @param _prover Address of the prover
     * @param _commissionRate Initial commission rate in basis points
     */
    function initProverRewards(address _prover, uint64 _commissionRate) external;

    /**
     * @notice Settle proof rewards for a staker before their shares change
     * @param _prover Address of the prover
     * @param _staker Address of the staker
     * @param _rawShares Current raw shares of the staker
     * @return accRewardPerRawShare Current accumulated reward per raw share
     */
    function settleStakerRewards(address _prover, address _staker, uint256 _rawShares)
        external
        returns (uint256 accRewardPerRawShare);

    /**
     * @notice Update staker's reward debt after share changes
     * @param _prover Address of the prover
     * @param _staker Address of the staker
     * @param _newRawShares New raw shares of the staker
     */
    function updateStakerRewardDebt(address _prover, address _staker, uint256 _newRawShares) external;

    /**
     * @notice Get prover reward information
     * @param _prover Address of the prover to query
     * @return commissionRate Commission rate in basis points
     * @return pendingCommission Unclaimed commission rewards
     * @return accRewardPerRawShare Accumulated rewards per raw share
     */
    function getProverRewardInfo(address _prover)
        external
        view
        returns (uint64 commissionRate, uint256 pendingCommission, uint256 accRewardPerRawShare);

    /**
     * @notice Calculate total pending rewards for a staker including commission if applicable
     * @param _prover Address of the prover
     * @param _staker Address of the staker
     * @return Total pending rewards including commission
     */
    function calculateTotalPendingRewards(address _prover, address _staker) external view returns (uint256);
}
