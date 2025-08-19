// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../lib/forge-std/src/Script.sol";
import "../src/pico/MockPicoVerifier.sol";

contract DeployMockPicoVerifier is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        MockPicoVerifier c = new MockPicoVerifier();
        console.log("MockPicoVerifier contract deployed at ", address(c));
        vm.stopBroadcast();
    }
}
