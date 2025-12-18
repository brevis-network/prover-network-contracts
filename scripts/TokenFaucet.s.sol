// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../lib/forge-std/src/Script.sol";
import "../src/token/TokenFaucet.sol";

/**
 * @title DeployTokenFaucet
 * @notice Deployment script for TokenFaucet
 * @dev Optional environment variables:
 *   - DRIP_PERCENT_BPS: Initial drip percentage (default: 1 = 0.01%)
 *   - COOLDOWN_PERIOD: Initial cooldown period in seconds (default: 86400 = 24 hours)
 *
 * Example commands:
 *   Basic deployment:
 *     forge script scripts/TokenFaucet.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
 *
 *   With custom configuration:
 *     DRIP_PERCENT_BPS=100 COOLDOWN_PERIOD=3600 \
 *     forge script scripts/TokenFaucet.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
 *
 *   For Blockscout-based explorers, append: --verifier blockscout --verifier-url $VERIFIER_URL
 */
contract DeployTokenFaucet is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        console.log("=== Deploying TokenFaucet ===");

        TokenFaucet faucet = new TokenFaucet();
        console.log("TokenFaucet deployed at:", address(faucet));

        // Configure optional parameters if provided
        uint256 dripPercentBps = vm.envOr("DRIP_PERCENT_BPS", uint256(0));
        if (dripPercentBps > 0) {
            console.log("Setting dripPercentBps to:", dripPercentBps);
            faucet.setDripPercentBps(dripPercentBps);
        }

        uint256 cooldownPeriod = vm.envOr("COOLDOWN_PERIOD", uint256(0));
        if (cooldownPeriod > 0) {
            console.log("Setting cooldownPeriod to:", cooldownPeriod);
            faucet.setCooldownPeriod(cooldownPeriod);
        }

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("TokenFaucet:", address(faucet));
        console.log("Drip Percent BPS:", faucet.dripPercentBps());
        console.log("Cooldown Period:", faucet.cooldownPeriod());
        console.log("Owner:", faucet.owner());
    }
}
