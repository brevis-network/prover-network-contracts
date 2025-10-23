// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../lib/forge-std/src/Script.sol";
import "../lib/forge-std/src/StdJson.sol";
// Use v4 proxy contracts for shared ProxyAdmin pattern
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import "../src/market/BrevisMarket.sol";
import "../src/staking/interfaces/IStakingController.sol";

contract DeployBrevisMarket is Script {
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

        console.log("Deploying BrevisMarket with deployer as initial owner:", deployer);
        console.log("NOTE: Transfer ownership to multisig after deployment for production security");

        // Deploy or use existing ProxyAdmin
        ProxyAdmin proxyAdmin = _deployOrUseProxyAdmin(json);

        address implementation = address(
            // Zero values for upgradeable deployment
            new BrevisMarket(IPicoVerifier(address(0)), IStakingController(address(0)), 0, 0, 0)
        );
        // Required config keys
        require(json.keyExists("$.addresses.stakingController"), "config.addresses.stakingController missing");
        require(json.keyExists("$.market.picoVerifier"), "config.market.picoVerifier missing");
        require(json.keyExists("$.market.biddingPhaseDuration"), "config.market.biddingPhaseDuration missing");
        require(json.keyExists("$.market.revealPhaseDuration"), "config.market.revealPhaseDuration missing");
        require(json.keyExists("$.market.minMaxFee"), "config.market.minMaxFee missing");

        address picoVerifier = json.readAddress("$.market.picoVerifier");
        address stakingController = json.readAddress("$.addresses.stakingController");
        uint64 biddingPhaseDuration = uint64(json.readUint("$.market.biddingPhaseDuration"));
        uint64 revealPhaseDuration = uint64(json.readUint("$.market.revealPhaseDuration"));
        uint256 minMaxFee = json.readUint("$.market.minMaxFee");

        bytes memory data = abi.encodeWithSignature(
            "init(address,address,uint64,uint64,uint256)",
            picoVerifier,
            stakingController,
            biddingPhaseDuration,
            revealPhaseDuration,
            minMaxFee
        );
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(implementation, address(proxyAdmin), data);

        // Configure optional parameters if non-zero
        BrevisMarket market = BrevisMarket(payable(address(proxy)));

        // Set slashing parameters (if specified)
        uint256 slashBps = json.readUintOr("$.market.slashBps", 0);
        if (slashBps > 0) {
            console.log("Setting slashBps:", slashBps);
            market.setSlashBps(slashBps);
        }

        uint256 slashWindow = json.readUintOr("$.market.slashWindow", 0);
        if (slashWindow > 0) {
            console.log("Setting slashWindow:", slashWindow);
            market.setSlashWindow(slashWindow);
        }

        // Set protocol fee (if specified)
        uint256 protocolFeeBps = json.readUintOr("$.market.protocolFeeBps", 0);
        if (protocolFeeBps > 0) {
            console.log("Setting protocolFeeBps:", protocolFeeBps);
            market.setProtocolFeeBps(protocolFeeBps);
        }

        // Optional overcommitBps
        uint256 overcommitBps = json.readUintOr("$.market.overcommitBps", 0);
        if (overcommitBps > 0) {
            console.log("Setting overcommitBps:", overcommitBps);
            market.setOvercommitBps(overcommitBps);
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

    /// @notice Deploy new ProxyAdmin or use existing one from config
    /// @return proxyAdmin The ProxyAdmin instance to use
    function _deployOrUseProxyAdmin(string memory json) internal returns (ProxyAdmin proxyAdmin) {
        // Try to get existing ProxyAdmin from config
        address existingProxyAdmin = address(0);
        if (json.keyExists("$.proxyAdmin.address")) {
            existingProxyAdmin = json.readAddressOr("$.proxyAdmin.address", address(0));
        }
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
