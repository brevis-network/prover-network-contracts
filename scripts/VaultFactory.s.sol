// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../lib/forge-std/src/Script.sol";
// Use v4 proxy contracts for shared ProxyAdmin pattern
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import "../src/staking/vault/VaultFactory.sol";

contract DeployVaultFactory is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        console.log("=== Deploying VaultFactory (Upgradeable) ===");
        console.log("Deployer:", deployer);
        console.log("Initial Owner:", deployer);
        console.log("NOTE: Transfer ownership to multisig after deployment for production security");

        // Deploy VaultFactory implementation
        console.log("\nDeploying VaultFactory implementation...");
        address vaultFactoryImpl = address(new VaultFactory());
        console.log("VaultFactory implementation:", vaultFactoryImpl);

        // Deploy or use existing ProxyAdmin
        console.log("\nConfiguring ProxyAdmin for VaultFactory...");
        ProxyAdmin proxyAdmin = _deployOrUseProxyAdmin();

        console.log("\nDeploying VaultFactory proxy...");
        bytes memory initData = ""; // Empty init data, will call init() separately
        TransparentUpgradeableProxy vaultFactoryProxy =
            new TransparentUpgradeableProxy(vaultFactoryImpl, address(proxyAdmin), initData);
        VaultFactory vaultFactory = VaultFactory(address(vaultFactoryProxy));
        console.log("VaultFactory proxy:", address(vaultFactory));

        // Initialize with controller address if provided
        address controllerAddress = vm.envOr("STAKING_CONTROLLER_ADDRESS", address(0));
        if (controllerAddress != address(0)) {
            console.log("\nInitializing VaultFactory with controller...");
            vaultFactory.init(controllerAddress);
            console.log("VaultFactory initialized with controller:", controllerAddress);
        } else {
            console.log("\nVaultFactory deployed but not initialized.");
            console.log("Call init() with controller address after StakingController is deployed.");
        }

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("VaultFactory Implementation:", vaultFactoryImpl);
        console.log("VaultFactory Proxy:", address(vaultFactory));
        console.log("ProxyAdmin:", address(proxyAdmin));
        console.log("Initial Owner:", deployer);
        console.log("\nNOTE: For production, transfer ownership to multisig:");
        console.log(
            "cast send",
            address(vaultFactory),
            "'transferOwnership(address)' $MULTISIG_ADDRESS --private-key $PRIVATE_KEY"
        );
    }

    /// @notice Deploy new ProxyAdmin or use existing one from PROXY_ADMIN environment variable
    /// @return proxyAdmin The ProxyAdmin instance to use
    function _deployOrUseProxyAdmin() internal returns (ProxyAdmin proxyAdmin) {
        // Try to get existing ProxyAdmin from environment
        address existingProxyAdmin = vm.envOr("PROXY_ADMIN", address(0));
        if (existingProxyAdmin != address(0)) {
            proxyAdmin = ProxyAdmin(existingProxyAdmin);
            console.log("Using existing ProxyAdmin:", address(proxyAdmin));
            console.log("ProxyAdmin owner:", proxyAdmin.owner());
            return proxyAdmin;
        }

        // Deploy new ProxyAdmin
        console.log("Deploying new ProxyAdmin...");
        proxyAdmin = new ProxyAdmin();
        console.log("New ProxyAdmin deployed:", address(proxyAdmin));
        return proxyAdmin;
    }
}
