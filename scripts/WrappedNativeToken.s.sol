// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../lib/forge-std/src/Script.sol";
import "../src/token/WrappedNativeToken.sol";

/**
 * @title DeployWrappedNativeToken
 * @notice Deployment script for WrappedNativeToken
 * @dev Usage: forge script scripts/WrappedNativeToken.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
 *      For Blockscout: add --verifier blockscout --verifier-url $VERIFIER_URL
 */
contract DeployWrappedNativeToken is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Token name and symbol can be customized
        string memory name = vm.envOr("TOKEN_NAME", string("Wrapped Brevis Token"));
        string memory symbol = vm.envOr("TOKEN_SYMBOL", string("WBREV"));

        vm.startBroadcast(deployerPrivateKey);

        console.log("=== Deploying WrappedNativeToken ===");
        console.log("Name:", name);
        console.log("Symbol:", symbol);

        WrappedNativeToken token = new WrappedNativeToken(name, symbol);

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("WrappedNativeToken deployed at:", address(token));
        console.log("\nTo use as staking/market token, add this address to your config.json:");
        console.log('  "staking": { "stakingToken": "', address(token), '" }');
    }
}
