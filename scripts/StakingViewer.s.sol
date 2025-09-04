// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../lib/forge-std/src/Script.sol";
import "../src/staking/viewer/StakingViewer.sol";

/**
 * @title DeployStakingViewer
 * @notice Standalone deployment script for StakingViewer
 * @dev StakingViewer is a read-only contract that doesn't require upgrades
 */
contract DeployStakingViewer is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        console.log("Deploying StakingViewer with deployer:", deployer);
        console.log("StakingController address:", vm.envAddress("STAKING_CONTROLLER_ADDRESS"));

        // Deploy StakingViewer (no proxy needed - read-only contract)
        address stakingViewer = address(new StakingViewer(vm.envAddress("STAKING_CONTROLLER_ADDRESS")));

        vm.stopBroadcast();

        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("StakingViewer:", stakingViewer);
        console.log("Connected to StakingController:", vm.envAddress("STAKING_CONTROLLER_ADDRESS"));

        console.log("\n=== NEXT STEPS ===");
        console.log("1. Update your frontend to use StakingViewer for read operations");
        console.log("2. Configure your frontend with the StakingViewer address:", stakingViewer);
        console.log("3. Use StakingViewer functions to minimize RPC calls and improve performance");
    }
}
