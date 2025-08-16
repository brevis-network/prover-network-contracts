// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

/**
 * @title IProverStaking
 * @notice Interface for ProverStaking contract to be used by ProverRewards
 */
interface IProverStaking {
    enum ProverState {
        Null,
        Active,
        Retired,
        Deactivated
    }

    /**
     * @notice Check if a prover is registered
     * @param _prover Address of the prover
     * @return True if prover is registered
     */
    function isProverRegistered(address _prover) external view returns (bool);

    /**
     * @notice Get total raw shares for a prover
     * @param _prover Address of the prover
     * @return Total raw shares
     */
    function getTotalRawShares(address _prover) external view returns (uint256);

    /**
     * @notice Get raw shares for a specific staker with a prover
     * @param _prover Address of the prover
     * @param _staker Address of the staker
     * @return Raw shares owned by the staker
     */
    function getStakerRawShares(address _prover, address _staker) external view returns (uint256);

    /**
     * @notice Get prover state
     * @param _prover Address of the prover
     * @return Current state of the prover
     */
    function getProverState(address _prover) external view returns (ProverState);
}
