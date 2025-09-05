// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../lib/forge-std/src/Script.sol";
// Use v4 proxy contracts for shared ProxyAdmin pattern
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import "../src/market/BrevisMarket.sol";
import "../src/staking/interfaces/IStakingController.sol";

contract DeployBrevisMarket is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        console.log("Deploying BrevisMarket with deployer as initial owner:", deployer);
        console.log("NOTE: Transfer ownership to multisig after deployment for production security");

        // Deploy or use existing ProxyAdmin
        ProxyAdmin proxyAdmin = _deployOrUseProxyAdmin();

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
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(implementation, address(proxyAdmin), data);

        // Configure optional parameters if non-zero
        BrevisMarket market = BrevisMarket(payable(address(proxy)));

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
        console.log("BrevisMarket proxy:", address(proxy));
        console.log("Initial owner:", deployer);

        // Log configured parameters
        if (slashBps > 0) console.log("Configured slashBps:", slashBps);
        if (slashWindow > 0) console.log("Configured slashWindow:", slashWindow);
        if (protocolFeeBps > 0) console.log("Configured protocolFeeBps:", protocolFeeBps);
    }

    /// @notice Deploy new ProxyAdmin or use existing one from PROXY_ADMIN environment variable
    /// @return proxyAdmin The ProxyAdmin instance to use
    function _deployOrUseProxyAdmin() internal returns (ProxyAdmin proxyAdmin) {
        // Try to get existing ProxyAdmin from environment
        address existingProxyAdmin = vm.envOr("PROXY_ADMIN", address(0));
        if (existingProxyAdmin != address(0)) {
            proxyAdmin = ProxyAdmin(existingProxyAdmin);
            console.log("Using existing ProxyAdmin:", address(proxyAdmin));
            console.log("ProxyAdmin owner:", proxyAdmin.owner());
            return proxyAdmin;
        }

        // Deploy new ProxyAdmin
        console.log("Deploying new ProxyAdmin...");
        proxyAdmin = new ProxyAdmin();
        console.log("New ProxyAdmin deployed:", address(proxyAdmin));
        return proxyAdmin;
    }
}
