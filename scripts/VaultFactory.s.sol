// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../lib/forge-std/src/Script.sol";
import {UnsafeUpgrades} from "../lib/openzeppelin-foundry-upgrades/src/Upgrades.sol";
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

        // Deploy VaultFactory proxy
        console.log("\nDeploying VaultFactory proxy...");
        bytes memory initData = ""; // Empty init data, will call init() separately
        address vaultFactoryProxy = UnsafeUpgrades.deployTransparentProxy(vaultFactoryImpl, deployer, initData);
        VaultFactory vaultFactory = VaultFactory(vaultFactoryProxy);
        console.log("VaultFactory proxy:", vaultFactoryProxy);

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
        console.log("VaultFactory Proxy:", vaultFactoryProxy);
        console.log("Initial Owner:", deployer);
        console.log("\nNOTE: For production, transfer ownership to multisig:");
        console.log(
            "cast send", vaultFactoryProxy, "'transferOwnership(address)' $MULTISIG_ADDRESS --private-key $PRIVATE_KEY"
        );
    }
}
