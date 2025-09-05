// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../lib/forge-std/src/Script.sol";
// Use v4 proxy contracts for shared ProxyAdmin pattern
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import "../src/staking/controller/StakingController.sol";

contract DeployStakingController is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        console.log("Deploying StakingController with deployer as initial owner:", deployer);
        console.log("NOTE: Transfer ownership to multisig after deployment for production security");

        // Deploy implementation with zero values for upgradeable deployment
        address implementation = address(
            // Zero values for upgradeable deployment
            new StakingController(address(0), address(0), 0, 0, 0)
        );

        // Prepare initialization data
        bytes memory data = abi.encodeWithSignature(
            "init(address,address,uint256,uint256,uint256)",
            vm.envAddress("STAKING_TOKEN_ADDRESS"),
            vm.envAddress("VAULT_FACTORY_ADDRESS"),
            vm.envUint("UNSTAKE_DELAY"),
            vm.envUint("MIN_SELF_STAKE"),
            vm.envUint("MAX_SLASH_BPS")
        );

        // Deploy ProxyAdmin
        console.log("Deploying ProxyAdmin...");
        ProxyAdmin proxyAdmin = new ProxyAdmin();
        console.log("ProxyAdmin:", address(proxyAdmin));

        // Deploy transparent proxy
        console.log("Deploying StakingController proxy...");
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(implementation, address(proxyAdmin), data);

        vm.stopBroadcast();

        console.log("StakingController implementation:", implementation);
        console.log("StakingController proxy:", address(proxy));
        console.log("ProxyAdmin:", address(proxyAdmin));
        console.log("Initial owner:", deployer);
    }
}
