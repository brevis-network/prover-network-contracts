// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IStakingController.sol";
import "../../token/WrappedNativeToken.sol";

/**
 * @title StakingHelper
 * @notice Helper contract for staking with native tokens (automatically wraps/unwraps)
 * @dev Provides UX improvements by handling native token → wrapped token conversion for staking
 */
contract StakingHelper {
    IStakingController public immutable stakingController;
    WrappedNativeToken public immutable wrappedToken;

    event NativeStaked(address indexed prover, address indexed staker, uint256 amount, uint256 shares);
    event NativeUnstakeCompleted(address indexed prover, address indexed staker, uint256 amount);

    error StakingHelperInsufficientValue();
    error StakingHelperTransferFailed();

    /**
     * @notice Initialize the helper with controller and wrapped token addresses
     * @param _stakingController Address of the StakingController contract
     * @param _wrappedToken Address of the WrappedNativeToken contract
     */
    constructor(address _stakingController, address payable _wrappedToken) {
        stakingController = IStakingController(_stakingController);
        wrappedToken = WrappedNativeToken(_wrappedToken);
    }

    /**
     * @notice Stake native tokens with a prover
     * @dev Wraps native tokens and stakes them on behalf of msg.sender
     * @param prover The prover address to stake with
     * @return shares The number of vault shares received
     */
    function stakeNative(address prover) external payable returns (uint256 shares) {
        if (msg.value == 0) revert StakingHelperInsufficientValue();

        // Wrap native tokens
        wrappedToken.deposit{value: msg.value}();

        // Approve controller to spend wrapped tokens
        wrappedToken.approve(address(stakingController), msg.value);

        // Stake on behalf of caller
        shares = stakingController.stakeFor(prover, msg.sender, msg.value);

        emit NativeStaked(prover, msg.sender, msg.value, shares);
        return shares;
    }

    /**
     * @notice Complete unstaking and receive native tokens in a single transaction
     * @dev Completes the unstake, receives wrapped tokens, unwraps them, and sends native tokens to caller
     * @param prover The prover to complete unstaking from
     * @return amount The amount of native tokens returned to the caller
     */
    function completeUnstakeNative(address prover) external returns (uint256 amount) {
        // Complete unstake on behalf of caller, helper receives wrapped tokens
        amount = stakingController.completeUnstakeFor(prover, msg.sender);

        if (amount > 0) {
            // Unwrap to native tokens (helper receives ETH via receive())
            wrappedToken.withdraw(amount);

            // Transfer native tokens to caller
            (bool success,) = msg.sender.call{value: amount}("");
            if (!success) revert StakingHelperTransferFailed();

            emit NativeUnstakeCompleted(prover, msg.sender, amount);
        }

        return amount;
    }

    receive() external payable {}
}
