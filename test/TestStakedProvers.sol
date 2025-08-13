// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../src/StakedProvers.sol";

/**
 * @title TestStakedProvers
 * @notice Test contract that inherits from StakedProvers to expose internal functions for testing
 * @dev This contract should ONLY be used for testing purposes and never deployed to production.
 *      Supports both direct deployment (with constructor) and upgradeable deployment (with init).
 */
contract TestStakedProvers is StakedProvers {
    /**
     * @notice Constructor for direct deployment
     * @param _token ERC20 token address (pass address(0) for upgradeable deployment)
     * @param _globalMinSelfStake Global minimum self-stake requirement for all provers
     */
    constructor(address _token, uint256 _globalMinSelfStake) StakedProvers(_token, _globalMinSelfStake) {}

    // Expose internal functions for testing
    function addRewardsPublic(address _prover, uint256 _amount) external {
        addRewards(_prover, _amount);
    }

    function slashProverPublic(address _prover, uint256 _percentage) external {
        slash(_prover, _percentage);
    }

    // Additional test helpers if needed
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
