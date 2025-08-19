// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../lib/forge-std/src/Script.sol";
import {UnsafeUpgrades} from "../lib/openzeppelin-foundry-upgrades/src/Upgrades.sol";
import "../src/BrevisMarket.sol";

contract DeployBrevisMarket is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("OWNER_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);
        address implementation = address(new BrevisMarket());
        bytes memory data = abi.encodeWithSignature(
            "init(address,address,uint64,uint64)",
            owner,
            vm.envAddress("PICO_VERIFIER_ADDRESS"),
            vm.envUint("BIDDING_PHASE_DURATION"),
            vm.envUint("REVEAL_PHASE_DURATION")
        );
        address proxy = UnsafeUpgrades.deployTransparentProxy(implementation, owner, data);
        vm.stopBroadcast();

        console.log("BrevisMarket implementation:", implementation);
        console.log("BrevisMarket proxy:", proxy);
    }
}
