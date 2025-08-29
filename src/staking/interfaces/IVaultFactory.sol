// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IVaultFactory
 * @notice Interface for deploying prover vaults via CREATE2
 */
interface IVaultFactory {
    // =========================================================================
    // ERRORS
    // =========================================================================

    error VaultFactoryOnlyController();
    error VaultFactoryAlreadyInitialized();
    error VaultFactoryZeroAddress();
    error VaultFactoryVaultAlreadyExists();
    error VaultFactoryDeploymentFailed();
    error VaultFactoryIndexOutOfBounds();

    // =========================================================================
    // EVENTS
    // =========================================================================

    event VaultCreated(address indexed prover, address indexed vault, address asset, bytes32 salt);

    // =========================================================================
    // EXTERNAL FUNCTIONS
    // =========================================================================

    /**
     * @notice Deploy a new ProverVault for a prover using CREATE2
     * @dev DEPLOYMENT NOTE: Only the controller can create vaults
     * @param asset The ERC20 token used as vault asset (staking/reward token)
     * @param prover The prover address this vault belongs to
     * @param controller The StakingController address that manages this vault
     * @return vault The address of the deployed vault
     */
    function createVault(address asset, address prover, address controller) external returns (address vault);

    /**
     * @notice Predict the vault address for a prover before deployment
     * @dev UPGRADE NOTE: Controller address is part of creation bytecode, so controller upgrades = new vault addresses
     * @param asset The ERC20 token used as vault asset
     * @param prover The prover address
     * @param controller The StakingController address
     * @return vault The predicted vault address
     */
    function predictVaultAddress(address asset, address prover, address controller)
        external
        view
        returns (address vault);

    /**
     * @notice Get the vault address for a specific prover
     * @param prover The prover address
     * @return vault The vault address (zero if not deployed)
     */
    function getVault(address prover) external view returns (address vault);

    /**
     * @notice Check if a vault has been deployed for a prover
     * @param prover The prover address
     * @return deployed True if vault exists
     */
    function isVaultDeployed(address prover) external view returns (bool deployed);

    /**
     * @notice Get the total number of deployed vaults
     * @return count The number of vaults deployed
     */
    function getVaultCount() external view returns (uint256 count);

    /**
     * @notice Get vault address by index
     * @param index The index in the vault list
     * @return vault The vault address
     */
    function getVaultAtIndex(uint256 index) external view returns (address vault);
}
