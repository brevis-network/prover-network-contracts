// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title IProverVault
 * @notice Interface for individual prover staking vaults
 */
interface IProverVault is IERC4626 {
    // =========================================================================
    // EVENTS
    // =========================================================================

    event ControllerSlash(uint256 assets, address to);

    // =========================================================================
    // ERRORS
    // =========================================================================

    error VaultSharesLocked();
    error VaultOnlyController();
    error VaultTransferBlocked();

    // =========================================================================
    // VIEW FUNCTIONS
    // =========================================================================

    /**
     * @notice Get the prover this vault belongs to
     * @return prover The prover address
     */
    function prover() external view returns (address prover);

    /**
     * @notice Get the controller that manages this vault
     * @return controller The StakingController address
     */
    function controller() external view returns (address controller);

    /**
     * @notice Get the transferable (unlocked) shares for an owner
     * @param owner The share owner
     * @return transferable The number of shares that can be transferred
     */
    function getTransferableShares(address owner) external view returns (uint256 transferable);

    // =========================================================================
    // CONTROLLER FUNCTIONS
    // =========================================================================

    /**
     * @notice Remove assets from vault during slashing (only controller)
     * @param assets The amount of assets to remove
     * @param to The address to send slashed assets
     */
    function controllerSlash(uint256 assets, address to) external;
}
