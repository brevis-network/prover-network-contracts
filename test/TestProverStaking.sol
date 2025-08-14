// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../src/ProverStaking.sol";

/**
 * @title TestProverStaking
 * @notice Test contract that inherits from ProverStaking to expose internal functions for testing
 * @dev This contract should ONLY be used for testing purposes and never deployed to production.
 *      Supports both direct deployment (with constructor) and upgradeable deployment (with init).
 */
contract TestProverStaking is ProverStaking {
    /**
     * @notice Test contract constructor
     * @param _token ERC20 token address (pass address(0) for upgradeable deployment)
     * @param _globalMinSelfStake Global minimum self-stake requirement for all provers
     */
    constructor(address _token, uint256 _globalMinSelfStake) ProverStaking(_token, _globalMinSelfStake) {}

    // Additional test helpers
    function getEffectiveAmount(address _prover, uint256 rawShares) external view returns (uint256) {
        return _effectiveAmount(_prover, rawShares);
    }

    function getRawSharesFromAmount(address _prover, uint256 amount) external view returns (uint256) {
        return _rawSharesFromAmount(_prover, amount);
    }

    function getTotalEffectiveStake(address _prover) external view returns (uint256) {
        return _getTotalEffectiveStake(_prover);
    }
}
