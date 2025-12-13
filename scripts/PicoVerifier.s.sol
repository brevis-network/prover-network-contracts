// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../lib/forge-std/src/Script.sol";
import "../src/pico/PicoVerifier.sol";

// usage: forge script scripts/PicoVerifier.s.sol --rpc-url $RPC_URL --broadcast --verify -vv

contract DeployPicoVerifier is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        PicoVerifier c = new PicoVerifier();
        console.log("PicoVerifier contract deployed at ", address(c));
        vm.stopBroadcast();
    }
}
