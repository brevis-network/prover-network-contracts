// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../lib/forge-std/src/Script.sol";
import {UnsafeUpgrades} from "../lib/openzeppelin-foundry-upgrades/src/Upgrades.sol";
import "../src/staking/controller/StakingController.sol";
import "../src/staking/vault/VaultFactory.sol";
import "../src/market/BrevisMarket.sol";
import "../src/staking/interfaces/IStakingController.sol";
import "../src/pico/IPicoVerifier.sol";

/**
 * @title DeployProverNetwork
 * @notice Comprehensive deployment script for the entire Brevis Prover Network
 * @dev This script deploys the complete system: Staking System (VaultFactory, StakingController) + BrevisMarket
 */
contract DeployProverNetwork is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        console.log("=== Deploying Brevis Prover Network ===");
        console.log("Deployer:", deployer);
        console.log("Initial Owner:", deployer);
        console.log("NOTE: Transfer ownership to multisig after deployment for production security");

        // STEP 1: DEPLOY STAKING SYSTEM
        console.log("\n=== STAKING SYSTEM DEPLOYMENT ===");

        // Step 1a: Deploy VaultFactory implementation
        console.log("\n1a. Deploying VaultFactory implementation...");
        address vaultFactoryImpl = address(new VaultFactory());
        console.log("VaultFactory implementation:", vaultFactoryImpl);

        // Step 1a2: Deploy VaultFactory proxy
        console.log("\n1a2. Deploying VaultFactory proxy...");
        bytes memory vaultFactoryInitData = ""; // Empty init data, will call init() separately
        address vaultFactoryProxy =
            UnsafeUpgrades.deployTransparentProxy(vaultFactoryImpl, deployer, vaultFactoryInitData);
        VaultFactory vaultFactory = VaultFactory(vaultFactoryProxy);
        console.log("VaultFactory proxy:", vaultFactoryProxy);

        // Step 1b: Deploy StakingController implementation
        console.log("\n1b. Deploying StakingController implementation...");
        address stakingControllerImpl = address(
            // Zero values for upgradeable deployment
            new StakingController(address(0), address(0), 0, 0, 0)
        );
        console.log("StakingController implementation:", stakingControllerImpl);

        // Step 1c: Prepare initialization data for StakingController
        console.log("\n1c. Preparing StakingController initialization data...");
        bytes memory stakingControllerInitData = abi.encodeWithSignature(
            "init(address,address,uint256,uint256,uint256)",
            vm.envAddress("STAKING_TOKEN_ADDRESS"),
            vaultFactoryProxy, // Use the proxy address
            vm.envUint("UNSTAKE_DELAY"),
            vm.envUint("MIN_SELF_STAKE"),
            vm.envUint("MAX_SLASH_FACTOR")
        );

        // Step 1d: Deploy StakingController proxy
        console.log("\n1d. Deploying StakingController proxy...");
        address stakingControllerProxy =
            UnsafeUpgrades.deployTransparentProxy(stakingControllerImpl, deployer, stakingControllerInitData);
        console.log("StakingController proxy:", stakingControllerProxy);

        // Step 1e: Initialize VaultFactory with StakingController
        console.log("\n1e. Initializing VaultFactory with StakingController...");
        vaultFactory.init(stakingControllerProxy);
        console.log("VaultFactory initialized with controller:", stakingControllerProxy);

        // STEP 2: DEPLOY BREVIS MARKET
        console.log("\n=== BREVIS MARKET DEPLOYMENT ===");

        // Step 2a: Deploy BrevisMarket implementation
        console.log("\n2a. Deploying BrevisMarket implementation...");
        address brevisMarketImpl = address(
            // Zero values for upgradeable deployment
            new BrevisMarket(IPicoVerifier(address(0)), IStakingController(address(0)), 0, 0, 0)
        );
        console.log("BrevisMarket implementation:", brevisMarketImpl);

        // Step 2b: Prepare initialization data for BrevisMarket
        console.log("\n2b. Preparing BrevisMarket initialization data...");
        bytes memory brevisMarketInitData = abi.encodeWithSignature(
            "init(address,address,uint64,uint64,uint256)",
            vm.envAddress("PICO_VERIFIER_ADDRESS"),
            stakingControllerProxy, // Use the deployed StakingController
            vm.envUint("BIDDING_PHASE_DURATION"),
            vm.envUint("REVEAL_PHASE_DURATION"),
            vm.envUint("MIN_MAX_FEE")
        );

        // Step 2c: Deploy BrevisMarket proxy
        console.log("\n2c. Deploying BrevisMarket proxy...");
        address brevisMarketProxy =
            UnsafeUpgrades.deployTransparentProxy(brevisMarketImpl, deployer, brevisMarketInitData);
        console.log("BrevisMarket proxy:", brevisMarketProxy);

        // STEP 3: CONNECT SYSTEMS
        console.log("\n=== SYSTEM INTEGRATION ===");

        // Step 3a: Set BrevisMarket as slasher in StakingController
        console.log("\n3a. Setting BrevisMarket as slasher in StakingController...");
        StakingController(stakingControllerProxy).grantRole(
            StakingController(stakingControllerProxy).SLASHER_ROLE(), brevisMarketProxy
        );
        console.log("Slasher role granted to BrevisMarket:", brevisMarketProxy);

        vm.stopBroadcast();

        // Summary
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("=== Staking System ===");
        console.log("VaultFactory:", address(vaultFactory));
        console.log("StakingController Implementation:", stakingControllerImpl);
        console.log("StakingController Proxy:", stakingControllerProxy);
        console.log("=== Brevis Market ===");
        console.log("BrevisMarket Implementation:", brevisMarketImpl);
        console.log("BrevisMarket Proxy:", brevisMarketProxy);

        // Configuration summary
        console.log("\n=== CONFIGURATION ===");
        console.log("=== Staking System ===");
        console.log("Staking Token:", vm.envAddress("STAKING_TOKEN_ADDRESS"));
        console.log("Unstake Delay:", vm.envUint("UNSTAKE_DELAY"));
        console.log("Min Self Stake:", vm.envUint("MIN_SELF_STAKE"));
        console.log("Max Slash Factor:", vm.envUint("MAX_SLASH_FACTOR"));
        console.log("=== Brevis Market ===");
        console.log("Pico Verifier:", vm.envAddress("PICO_VERIFIER_ADDRESS"));
        console.log("Bidding Phase Duration:", vm.envUint("BIDDING_PHASE_DURATION"));
        console.log("Reveal Phase Duration:", vm.envUint("REVEAL_PHASE_DURATION"));
        console.log("Min Max Fee:", vm.envUint("MIN_MAX_FEE"));

        console.log("\n=== NEXT STEPS ===");
        console.log("1. Brevis Prover Network is ready for operation!");
        console.log("2. The Golang backend can now integrate with both systems:");
        console.log("   - Staking: Prover management, staking operations, slashing");
        console.log("   - Market: Proof requests, bidding, verification");
        console.log("\n3. FOR PRODUCTION: Transfer ownership to multisig for security:");
        console.log("   # Get ProxyAdmin address");
        console.log(
            "   PROXY_ADMIN=$(forge inspect UnsafeUpgrades/TransparentUpgradeableProxy.sol:ProxyAdmin deployed-bytecode --silent | head -1)"
        );
        console.log("   # Transfer ProxyAdmin ownership");
        console.log(
            "   cast send $PROXY_ADMIN 'transferOwnership(address)' $MULTISIG_ADDRESS --private-key $PRIVATE_KEY"
        );
        console.log("   # Transfer contract ownership");
        console.log(
            "   cast send",
            stakingControllerProxy,
            "'transferOwnership(address)' $MULTISIG_ADDRESS --private-key $PRIVATE_KEY"
        );
        console.log(
            "   cast send",
            brevisMarketProxy,
            "'transferOwnership(address)' $MULTISIG_ADDRESS --private-key $PRIVATE_KEY"
        );
    }
}
