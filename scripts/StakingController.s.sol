// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../lib/forge-std/src/Script.sol";
import "../lib/forge-std/src/StdJson.sol";
// Use v4 proxy contracts for shared ProxyAdmin pattern
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import "../src/staking/controller/StakingController.sol";

contract DeployStakingController is Script {
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

        console.log("Deploying StakingController with deployer as initial owner:", deployer);
        console.log("NOTE: Transfer ownership to multisig after deployment for production security");

        // Deploy or use existing ProxyAdmin
        ProxyAdmin proxyAdmin = _deployOrUseProxyAdmin(json);

        // Deploy implementation with zero values for upgradeable deployment
        address implementation = address(new StakingController(address(0), address(0), 0, 0, 0));

        // Prepare initialization data (required keys)
        require(json.keyExists("$.staking.token"), "config.staking.token missing");
        require(json.keyExists("$.addresses.vaultFactory"), "config.addresses.vaultFactory missing");
        require(json.keyExists("$.staking.unstakeDelay"), "config.staking.unstakeDelay missing");
        require(json.keyExists("$.staking.minSelfStake"), "config.staking.minSelfStake missing");
        require(json.keyExists("$.staking.maxSlashBps"), "config.staking.maxSlashBps missing");

        address stakingToken = json.readAddressOr("$.staking.token", address(0));
        address vaultFactoryAddr = json.readAddress("$.addresses.vaultFactory");
        uint256 unstakeDelay = json.readUint("$.staking.unstakeDelay");
        uint256 minSelfStake = json.readUint("$.staking.minSelfStake");
        uint256 maxSlashBps = json.readUint("$.staking.maxSlashBps");

        bytes memory data = abi.encodeWithSignature(
            "init(address,address,uint256,uint256,uint256)",
            stakingToken,
            vaultFactoryAddr,
            unstakeDelay,
            minSelfStake,
            maxSlashBps
        );

        // Deploy transparent proxy
        console.log("Deploying StakingController proxy...");
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(implementation, address(proxyAdmin), data);

        vm.stopBroadcast();

        console.log("StakingController implementation:", implementation);
        console.log("StakingController proxy:", address(proxy));
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
