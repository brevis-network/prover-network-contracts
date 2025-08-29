// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../lib/forge-std/src/Script.sol";
import {UnsafeUpgrades} from "../lib/openzeppelin-foundry-upgrades/src/Upgrades.sol";
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
            vm.envUint("MAX_SLASH_FACTOR")
        );

        // Deploy transparent proxy
        address proxy = UnsafeUpgrades.deployTransparentProxy(implementation, deployer, data);

        vm.stopBroadcast();

        console.log("StakingController implementation:", implementation);
        console.log("StakingController proxy:", proxy);
        console.log("Initial owner:", deployer);
    }
}
