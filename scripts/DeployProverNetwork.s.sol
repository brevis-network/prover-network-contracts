// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../lib/forge-std/src/Script.sol";
// Use v4 proxy contracts for shared ProxyAdmin pattern
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
// Keep v5 for everything else
import "../src/staking/controller/StakingController.sol";
import "../src/staking/viewer/StakingViewer.sol";
import "../src/staking/vault/VaultFactory.sol";
import "../src/market/BrevisMarket.sol";
import "../src/staking/interfaces/IStakingController.sol";
import "../src/pico/IPicoVerifier.sol";

/**
 * @title DeployProverNetwork
 * @notice Comprehensive deployment script for the entire Brevis Prover Network
 * @dev This script deploys the complete system: Staking System (VaultFactory, StakingController, StakingViewer) + BrevisMarket
 */
contract DeployProverNetwork is Script {
    // Storage variables to avoid stack too deep
    ProxyAdmin public sharedProxyAdmin;
    VaultFactory public vaultFactory;
    address public stakingControllerProxy;
    address public stakingViewer;
    address public brevisMarketProxy;
    address public stakingControllerImpl;
    address public brevisMarketImpl;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        console.log("=== Deploying Brevis Prover Network (v4 Shared ProxyAdmin Pattern) ===");

        _deploySharedProxyAdmin();
        _deployStakingSystem();
        _deployBrevisMarket();
        _connectSystems();

        vm.stopBroadcast();
        _printSummary();
    }

    function _deploySharedProxyAdmin() internal {
        console.log("\n0. Configuring ProxyAdmin...");

        // Try to get existing ProxyAdmin from environment
        address existingProxyAdmin = vm.envOr("PROXY_ADMIN", address(0));
        if (existingProxyAdmin != address(0)) {
            sharedProxyAdmin = ProxyAdmin(existingProxyAdmin);
            console.log("Using existing ProxyAdmin:", address(sharedProxyAdmin));
            console.log("ProxyAdmin owner:", sharedProxyAdmin.owner());
            return;
        }

        // Deploy new ProxyAdmin
        console.log("Deploying new ProxyAdmin...");
        sharedProxyAdmin = new ProxyAdmin();
        console.log("New ProxyAdmin deployed:", address(sharedProxyAdmin));
    }

    function _deployStakingSystem() internal {
        console.log("\n=== STAKING SYSTEM DEPLOYMENT ===");

        // Deploy VaultFactory implementation
        console.log("\n1a. Deploying VaultFactory implementation...");
        address vaultFactoryImpl = address(new VaultFactory());
        console.log("VaultFactory implementation:", vaultFactoryImpl);

        // Deploy VaultFactory proxy using shared ProxyAdmin
        console.log("\n1a2. Deploying VaultFactory proxy...");
        TransparentUpgradeableProxy vaultFactoryProxy =
            new TransparentUpgradeableProxy(vaultFactoryImpl, address(sharedProxyAdmin), "");
        vaultFactory = VaultFactory(address(vaultFactoryProxy));
        console.log("VaultFactory proxy:", address(vaultFactory));

        // Deploy StakingController implementation
        console.log("\n1b. Deploying StakingController implementation...");
        stakingControllerImpl = address(new StakingController(address(0), address(0), 0, 0, 0));
        console.log("StakingController implementation:", stakingControllerImpl);

        // Deploy StakingController proxy
        console.log("\n1d. Deploying StakingController proxy...");
        bytes memory stakingControllerInitData = abi.encodeWithSignature(
            "init(address,address,uint256,uint256,uint256)",
            vm.envAddress("STAKING_TOKEN_ADDRESS"),
            address(vaultFactory),
            vm.envUint("UNSTAKE_DELAY"),
            vm.envUint("MIN_SELF_STAKE"),
            vm.envUint("MAX_SLASH_BPS")
        );
        TransparentUpgradeableProxy stakingControllerProxy_ =
            new TransparentUpgradeableProxy(stakingControllerImpl, address(sharedProxyAdmin), stakingControllerInitData);
        stakingControllerProxy = address(stakingControllerProxy_);
        console.log("StakingController proxy:", stakingControllerProxy);

        // Initialize VaultFactory
        console.log("\n1e. Initializing VaultFactory...");
        vaultFactory.init(stakingControllerProxy);

        // Deploy StakingViewer
        console.log("\n1f. Deploying StakingViewer...");
        stakingViewer = address(new StakingViewer(stakingControllerProxy));
        console.log("StakingViewer:", stakingViewer);
    }

    function _deployBrevisMarket() internal {
        console.log("\n=== BREVIS MARKET DEPLOYMENT ===");

        // Deploy BrevisMarket implementation
        console.log("\n2a. Deploying BrevisMarket implementation...");
        brevisMarketImpl = address(new BrevisMarket(IPicoVerifier(address(0)), IStakingController(address(0)), 0, 0, 0));
        console.log("BrevisMarket implementation:", brevisMarketImpl);

        // Deploy BrevisMarket proxy
        console.log("\n2c. Deploying BrevisMarket proxy...");
        bytes memory brevisMarketInitData = abi.encodeWithSignature(
            "init(address,address,uint64,uint64,uint256)",
            vm.envAddress("PICO_VERIFIER_ADDRESS"),
            stakingControllerProxy,
            vm.envUint("BIDDING_PHASE_DURATION"),
            vm.envUint("REVEAL_PHASE_DURATION"),
            vm.envUint("MIN_MAX_FEE")
        );
        TransparentUpgradeableProxy brevisMarketProxy_ =
            new TransparentUpgradeableProxy(brevisMarketImpl, address(sharedProxyAdmin), brevisMarketInitData);
        brevisMarketProxy = address(brevisMarketProxy_);
        console.log("BrevisMarket proxy:", brevisMarketProxy);

        // Configure optional parameters if provided
        _configureOptionalMarketParams();
    }

    function _configureOptionalMarketParams() internal {
        console.log("\n2d. Configuring optional BrevisMarket parameters...");

        BrevisMarket market = BrevisMarket(brevisMarketProxy);

        // Set slashing parameters if provided
        uint256 slashBps = vm.envOr("MARKET_SLASH_BPS", uint256(0));
        uint256 slashWindow = vm.envOr("MARKET_SLASH_WINDOW", uint256(0));

        if (slashBps > 0) {
            console.log("Setting slash BPS:", slashBps);
            market.setSlashBps(slashBps);
        } else {
            console.log("Slash BPS not configured (disabled)");
        }

        if (slashWindow > 0) {
            console.log("Setting slash window:", slashWindow);
            market.setSlashWindow(slashWindow);
        } else {
            console.log("Slash window not configured (disabled)");
        }

        // Set protocol fee if provided
        uint256 protocolFeeBps = vm.envOr("MARKET_PROTOCOL_FEE_BPS", uint256(0));
        if (protocolFeeBps > 0) {
            console.log("Setting protocol fee BPS:", protocolFeeBps);
            market.setProtocolFeeBps(protocolFeeBps);
        } else {
            console.log("Protocol fee not configured (disabled)");
        }
    }

    function _connectSystems() internal {
        console.log("\n=== SYSTEM INTEGRATION ===");

        // Set BrevisMarket as slasher in StakingController
        console.log("\n3a. Setting BrevisMarket as slasher...");
        StakingController(stakingControllerProxy).grantRole(
            StakingController(stakingControllerProxy).SLASHER_ROLE(), brevisMarketProxy
        );
        console.log("Slasher role granted to BrevisMarket");
    }

    function _printSummary() internal view {
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Shared ProxyAdmin:", address(sharedProxyAdmin));
        console.log("VaultFactory:", address(vaultFactory));
        console.log("StakingController Implementation:", stakingControllerImpl);
        console.log("StakingController Proxy:", stakingControllerProxy);
        console.log("StakingViewer:", stakingViewer);
        console.log("BrevisMarket Implementation:", brevisMarketImpl);
        console.log("BrevisMarket Proxy:", brevisMarketProxy);
        console.log("\nTransfer ProxyAdmin ownership to multisig for production!");
    }
}
