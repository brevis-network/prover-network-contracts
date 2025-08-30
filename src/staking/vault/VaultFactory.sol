// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/Strings.sol";
import "../interfaces/IVaultFactory.sol";
import "./ProverVault.sol";

/**
 * @title VaultFactory
 * @notice Deploys ProverVault contracts via CREATE2 for predictable addresses
 */
contract VaultFactory is IVaultFactory {
    // =========================================================================
    // STORAGE
    // =========================================================================

    address public stakingController;

    // Mapping from prover address to vault address
    mapping(address => address) public override getVault;

    // Array of all deployed vaults for enumeration
    address[] public vaults;

    // Storage gap for future upgrades. Reserves 40 slots.
    uint256[40] private __gap;

    // =========================================================================
    // MODIFIERS
    // =========================================================================

    modifier onlyController() {
        if (msg.sender != stakingController) {
            revert VaultFactoryOnlyController();
        }
        _;
    }

    // =========================================================================
    // EXTERNAL FUNCTIONS
    // =========================================================================

    /**
     * @notice Initialize controller (one-time only)
     * @param _controller The controller address to set
     */
    function init(address _controller) external {
        if (stakingController != address(0)) {
            revert VaultFactoryAlreadyInitialized();
        }
        if (_controller == address(0)) {
            revert VaultFactoryZeroAddress();
        }
        stakingController = _controller;
    }

    /**
     * @notice Deploy a new ProverVault for a prover using CREATE2
     */
    function createVault(address asset, address prover, address controller)
        external
        override
        onlyController
        returns (address vault)
    {
        // Check if vault already exists for this prover
        if (getVault[prover] != address(0)) {
            revert VaultFactoryVaultAlreadyExists();
        }

        // Generate deterministic salt from asset and prover
        bytes32 salt = _generateSalt(asset, prover);

        // Get creation code with constructor parameters
        bytes memory creationCode = _getCreationCode(asset, prover, controller);

        // Deploy with CREATE2
        assembly {
            vault := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }

        // Check deployment succeeded
        if (vault == address(0)) {
            revert VaultFactoryDeploymentFailed();
        }

        // Store vault address in mapping and array
        getVault[prover] = vault;
        vaults.push(vault);

        // Emit creation event
        emit VaultCreated(prover, vault, asset, salt);

        return vault;
    }

    /**
     * @notice Predict the vault address for a prover before deployment
     */
    function predictVaultAddress(address asset, address prover, address controller)
        external
        view
        override
        returns (address vault)
    {
        // Generate the same salt as createVault
        bytes32 salt = _generateSalt(asset, prover);

        // Get creation code with constructor parameters
        bytes memory creationCode = _getCreationCode(asset, prover, controller);

        // Calculate CREATE2 address
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(creationCode)));

        return address(uint160(uint256(hash)));
    }

    /**
     * @notice Check if a vault has been deployed for a prover
     */
    function isVaultDeployed(address prover) external view override returns (bool deployed) {
        return getVault[prover] != address(0);
    }

    /**
     * @notice Get the total number of deployed vaults
     */
    function getVaultCount() external view override returns (uint256 count) {
        return vaults.length;
    }

    /**
     * @notice Get vault address by index
     */
    function getVaultAtIndex(uint256 index) external view override returns (address vault) {
        if (index >= vaults.length) {
            revert VaultFactoryIndexOutOfBounds();
        }
        return vaults[index];
    }

    // =========================================================================
    // INTERNAL FUNCTIONS
    // =========================================================================

    /**
     * @notice Generate salt for CREATE2 deployment
     */
    function _generateSalt(address asset, address prover) internal pure returns (bytes32) {
        // Generate deterministic salt based on asset and prover for CREATE2
        return keccak256(abi.encode(asset, prover));
    }

    /**
     * @notice Get the creation code for ProverVault
     */
    function _getCreationCode(address asset, address prover, address controller) internal pure returns (bytes memory) {
        // Generate vault name and symbol
        string memory name = string(abi.encodePacked("Brevis Prover Vault - ", _addressToString(prover)));
        string memory symbol = string(abi.encodePacked("bpv-", _addressToString(prover)));

        // Encode constructor arguments
        bytes memory constructorArgs = abi.encode(
            asset, // IERC20 asset_
            name, // string memory name_
            symbol, // string memory symbol_
            prover, // address prover_
            controller // address controller_
        );

        // Combine creation code with constructor arguments
        return abi.encodePacked(type(ProverVault).creationCode, constructorArgs);
    }

    /**
     * @notice Convert address to string for vault naming
     */
    function _addressToString(address addr) internal pure returns (string memory) {
        return Strings.toHexString(uint256(uint160(addr)), 20);
    }
}
