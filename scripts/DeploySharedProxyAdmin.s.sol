// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../lib/forge-std/src/Script.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

/**
 * @title DeploySharedProxyAdmin
 * @notice Minimal script to deploy a shared ProxyAdmin
 * @dev Reads PRIVATE_KEY for broadcasting; deploys ProxyAdmin and prints the address.
 *      usage: forge script scripts/DeploySharedProxyAdmin.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
 */
contract DeploySharedProxyAdmin is Script {
    ProxyAdmin public proxyAdmin;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        proxyAdmin = new ProxyAdmin();

        vm.stopBroadcast();
        console.log("Shared ProxyAdmin deployed:", address(proxyAdmin));
        console.log("Owner:", proxyAdmin.owner());
        console.log("Note: Add this address to your config JSON under proxyAdmin.address");
    }
}
