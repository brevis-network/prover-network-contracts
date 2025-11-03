// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../lib/forge-std/src/Script.sol";
import "../lib/forge-std/src/StdJson.sol";
import "../src/market/MarketViewer.sol";

/**
 * @title DeployMarketViewer
 * @notice Standalone deployment script for MarketViewer (read-only, non-upgradeable)
 * @dev Expects BrevisMarket proxy/address in config at addresses.brevisMarket
 */
contract DeployMarketViewer is Script {
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

        console.log("Deploying MarketViewer with deployer:", deployer);
        require(json.keyExists("$.addresses.brevisMarket"), "config.addresses.brevisMarket missing");
        address market = json.readAddress("$.addresses.brevisMarket");
        console.log("BrevisMarket address:", market);

        // Deploy MarketViewer (no proxy needed - read-only contract)
        address marketViewer = address(new MarketViewer(market));

        vm.stopBroadcast();

        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("MarketViewer:", marketViewer);
        console.log("Connected to BrevisMarket:", market);

        console.log("\n=== NEXT STEPS ===");
        console.log("1. Update your frontend to use MarketViewer for read aggregations");
        console.log("2. Configure your frontend with the MarketViewer address:", marketViewer);
        console.log("3. Use MarketViewer composites and pagination to minimize RPC calls");
    }
}
