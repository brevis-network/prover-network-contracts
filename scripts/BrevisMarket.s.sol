// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../lib/forge-std/src/Script.sol";
import {UnsafeUpgrades} from "../lib/openzeppelin-foundry-upgrades/src/Upgrades.sol";
import "../src/market/BrevisMarket.sol";
import "../src/staking/interfaces/IStakingController.sol";

contract DeployBrevisMarket is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        console.log("Deploying BrevisMarket with deployer as initial owner:", deployer);
        console.log("NOTE: Transfer ownership to multisig after deployment for production security");

        address implementation = address(
            // Zero values for upgradeable deployment
            new BrevisMarket(IPicoVerifier(address(0)), IStakingController(address(0)), 0, 0, 0)
        );
        bytes memory data = abi.encodeWithSignature(
            "init(address,address,uint64,uint64,uint256)",
            vm.envAddress("PICO_VERIFIER_ADDRESS"),
            vm.envAddress("STAKING_CONTROLLER_ADDRESS"),
            vm.envUint("BIDDING_PHASE_DURATION"),
            vm.envUint("REVEAL_PHASE_DURATION"),
            vm.envUint("MIN_MAX_FEE")
        );
        address proxy = UnsafeUpgrades.deployTransparentProxy(implementation, deployer, data);

        // Configure optional parameters if non-zero
        BrevisMarket market = BrevisMarket(payable(proxy));

        // Set slashing parameters (if specified)
        uint256 slashBps = vm.envOr("MARKET_SLASH_BPS", uint256(0));
        if (slashBps > 0) {
            console.log("Setting slashBps:", slashBps);
            market.setSlashBps(slashBps);
        }

        uint256 slashWindow = vm.envOr("MARKET_SLASH_WINDOW", uint256(0));
        if (slashWindow > 0) {
            console.log("Setting slashWindow:", slashWindow);
            market.setSlashWindow(slashWindow);
        }

        // Set protocol fee (if specified)
        uint256 protocolFeeBps = vm.envOr("MARKET_PROTOCOL_FEE_BPS", uint256(0));
        if (protocolFeeBps > 0) {
            console.log("Setting protocolFeeBps:", protocolFeeBps);
            market.setProtocolFeeBps(protocolFeeBps);
        }

        vm.stopBroadcast();

        console.log("BrevisMarket implementation:", implementation);
        console.log("BrevisMarket proxy:", proxy);
        console.log("Initial owner:", deployer);

        // Log configured parameters
        if (slashBps > 0) console.log("Configured slashBps:", slashBps);
        if (slashWindow > 0) console.log("Configured slashWindow:", slashWindow);
        if (protocolFeeBps > 0) console.log("Configured protocolFeeBps:", protocolFeeBps);
    }
}
