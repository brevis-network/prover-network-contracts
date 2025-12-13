// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../lib/forge-std/src/Script.sol";
import "../src/staking/rewards/brevis-proof/SimpleBrevisProof.sol";

// usage: forge script scripts/SimpleBrevisProof.s.sol --rpc-url $RPC_URL --broadcast -vv
contract DeploySimpleBrevisProof is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        SimpleBrevisProof c = new SimpleBrevisProof();
        console.log("SimpleBrevisProof contract deployed at", address(c));
        vm.stopBroadcast();
    }
}
