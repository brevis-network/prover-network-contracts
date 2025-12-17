// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../lib/forge-std/src/Script.sol";
import "../lib/forge-std/src/StdJson.sol";
// Use v4 proxy contracts for shared ProxyAdmin pattern
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import "../src/staking/rewards/EpochRewards.sol";

contract DeployEpochRewards is Script {
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

        console.log("Deploying EpochRewards with deployer as initial owner:", deployer);
        console.log("NOTE: Transfer ownership to multisig after deployment for production security");

        // Optional: implementation-only deployment for upgrades
        bool implementationOnly = json.keyExists("$.epochRewards.implementationOnly")
            ? json.readBool("$.epochRewards.implementationOnly")
            : false;

        // Prepare initialization data (required keys)
        require(json.keyExists("$.addresses.stakingController"), "config.addresses.stakingController missing");
        address stakingController = json.readAddress("$.addresses.stakingController");

        // Deploy implementation with zero values for upgradeable deployment
        address implementation = address(new EpochRewards(stakingController, address(0), address(0), address(0)));
        console.log("EpochRewards implementation:", implementation);

        if (implementationOnly) {
            console.log(
                "implementationOnly=true: Skipping proxy deployment and initialization. Use ProxyAdmin.upgrade() to point an existing proxy at this implementation."
            );
            vm.stopBroadcast();
            return;
        }

        // Deploy or use existing ProxyAdmin
        ProxyAdmin proxyAdmin = _deployOrUseProxyAdmin(json);

        require(json.keyExists("$.epochRewards.brevisProof"), "config.epochRewards.brevisProof missing");
        require(json.keyExists("$.epochRewards.rewardUpdater"), "config.epochRewards.rewardUpdater missing");
        require(json.keyExists("$.epochRewards.epochUpdater"), "config.epochRewards.epochUpdater missing");

        address brevisProof = json.readAddress("$.epochRewards.brevisProof");
        address rewardUpdater = json.readAddress("$.epochRewards.rewardUpdater");
        address epochUpdater = json.readAddress("$.epochRewards.epochUpdater");

        bytes memory data = abi.encodeWithSignature(
            "init(address,address,address,address)", stakingController, brevisProof, rewardUpdater, epochUpdater
        );

        // Deploy transparent proxy
        console.log("Deploying EpochRewards proxy...");
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(implementation, address(proxyAdmin), data);

        // Optional VK hash configuration
        if (json.keyExists("$.epochRewards.vkHash")) {
            bytes32 vkHash = json.readBytes32("$.epochRewards.vkHash");
            console.log("Setting vkHash:");
            console.logBytes32(vkHash);
            EpochRewards(address(proxy)).setVkHash(vkHash);
        }

        vm.stopBroadcast();

        console.log("EpochRewards implementation:", implementation);
        console.log("EpochRewards proxy:", address(proxy));
        console.log("ProxyAdmin:", address(proxyAdmin));
        console.log("Initial owner:", deployer);
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
