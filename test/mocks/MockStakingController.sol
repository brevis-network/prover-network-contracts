// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockStakingController {
    IERC20 public stakingToken;
    mapping(address => uint256) public proverStakes;
    uint256 public minSelfStake = 1e17; // 0.1 token, less than test MIN_STAKE

    constructor(IERC20 _stakingToken) {
        stakingToken = _stakingToken;
    }

    function setProverStake(address prover, uint256 stake) external {
        proverStakes[prover] = stake;
    }

    function isProverEligible(address prover, uint256 minimumStake)
        external
        view
        returns (bool eligible, uint256 currentStake)
    {
        currentStake = proverStakes[prover];
        eligible = currentStake >= minimumStake;
    }

    function addRewards(address, uint256 amount) external returns (uint256 commission, uint256 toStakers) {
        // Transfer tokens from the market contract to this staking controller
        stakingToken.transferFrom(msg.sender, address(this), amount);

        // Simple mock: no commission, all goes to stakers
        commission = 0;
        toStakers = amount;
    }
}
