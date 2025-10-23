// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../lib/forge-std/src/Script.sol";
import "../lib/forge-std/src/StdJson.sol";
import "../src/staking/viewer/StakingViewer.sol";

/**
 * @title DeployStakingViewer
 * @notice Standalone deployment script for StakingViewer
 * @dev StakingViewer is a read-only contract that doesn't require upgrades
 */
contract DeployStakingViewer is Script {
    using stdJson for string;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Load config (prefer inline JSON via DEPLOY_CONFIG_JSON, else read DEPLOY_CONFIG file path)
        string memory json = vm.envOr("DEPLOY_CONFIG_JSON", string(""));
        if (bytes(json).length == 0) {
            string memory configPath = vm.envString("DEPLOY_CONFIG");
            require(bytes(configPath).length != 0, "DEPLOY_CONFIG not set");
            json = vm.readFile(configPath);
        }

        vm.startBroadcast(deployerPrivateKey);

        console.log("Deploying StakingViewer with deployer:", deployer);
        require(json.keyExists("$.addresses.stakingController"), "config.addresses.stakingController missing");
        address controller = json.readAddress("$.addresses.stakingController");
        console.log("StakingController address:", controller);

        // Deploy StakingViewer (no proxy needed - read-only contract)
        address stakingViewer = address(new StakingViewer(controller));

        vm.stopBroadcast();

        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("StakingViewer:", stakingViewer);
        console.log("Connected to StakingController:", controller);

        console.log("\n=== NEXT STEPS ===");
        console.log("1. Update your frontend to use StakingViewer for read operations");
        console.log("2. Configure your frontend with the StakingViewer address:", stakingViewer);
        console.log("3. Use StakingViewer functions to minimize RPC calls and improve performance");
    }
}
