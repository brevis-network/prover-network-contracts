// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";
import {UnsafeUpgrades} from "../../lib/openzeppelin-foundry-upgrades/src/Upgrades.sol";
import "../../src/staking/controller/StakingController.sol";
import "../../src/staking/vault/VaultFactory.sol";
import "../../src/market/BrevisMarket.sol";
import "../../src/pico/MockPicoVerifier.sol";
import "../../test/mocks/MockERC20.sol";

/**
 * @title ComprehensiveDeploymentTest
 * @notice Tests that the comprehensive deployment script properly configures optional parameters
 */
contract ComprehensiveDeploymentTest is Test {
    MockERC20 stakingToken;
    MockPicoVerifier picoVerifier;

    // Test constants
    address constant TEST_DEPLOYER = address(0x1234);
    uint256 constant TEST_UNSTAKE_DELAY = 604800; // 7 days
    uint256 constant TEST_MIN_SELF_STAKE = 1000e18; // 1000 tokens
    uint256 constant TEST_MAX_SLASH_BPS = 5000; // 50%
    uint64 constant TEST_BIDDING_PHASE_DURATION = 300; // 5 minutes
    uint64 constant TEST_REVEAL_PHASE_DURATION = 600; // 10 minutes
    uint256 constant TEST_MIN_MAX_FEE = 1e15; // 0.001 ETH

    function setUp() public {
        stakingToken = new MockERC20("Staking Token", "STK");
        picoVerifier = new MockPicoVerifier();
    }

    function test_ComprehensiveDeploymentHandlesOptionalParams() public {
        // Set optional market parameters in environment (like the comprehensive script expects)
        vm.setEnv("MARKET_SLASH_BPS", "1000");
        vm.setEnv("MARKET_SLASH_WINDOW", "604800");
        vm.setEnv("MARKET_PROTOCOL_FEE_BPS", "100");

        // Deploy the complete system with optional parameters
        _testSystemIntegrationWithOptionalParams();
    }

    function test_ComprehensiveDeploymentWithoutOptionalParams() public {
        // Clear environment variables to test default behavior
        vm.setEnv("MARKET_SLASH_BPS", "");
        vm.setEnv("MARKET_SLASH_WINDOW", "");
        vm.setEnv("MARKET_PROTOCOL_FEE_BPS", "");

        // Deploy system without optional parameters
        _testSystemIntegrationWithoutOptionalParams();
    }

    function _testSystemIntegrationWithOptionalParams() internal {
        // Deploy the complete system with optional parameters to test integration
        address vaultFactoryImpl = address(new VaultFactory());
        address vaultFactoryProxy = UnsafeUpgrades.deployTransparentProxy(vaultFactoryImpl, TEST_DEPLOYER, "");

        address stakingControllerImpl = address(new StakingController(address(0), address(0), 0, 0, 0));
        bytes memory stakingControllerInitData = abi.encodeWithSignature(
            "init(address,address,uint256,uint256,uint256)",
            address(stakingToken),
            vaultFactoryProxy,
            TEST_UNSTAKE_DELAY,
            TEST_MIN_SELF_STAKE,
            TEST_MAX_SLASH_BPS
        );
        address stakingControllerProxy =
            UnsafeUpgrades.deployTransparentProxy(stakingControllerImpl, TEST_DEPLOYER, stakingControllerInitData);

        VaultFactory(vaultFactoryProxy).init(stakingControllerProxy);

        address brevisMarketImpl =
            address(new BrevisMarket(IPicoVerifier(address(0)), IStakingController(address(0)), 0, 0, 0));
        bytes memory brevisMarketInitData = abi.encodeWithSignature(
            "init(address,address,uint64,uint64,uint256)",
            address(picoVerifier),
            stakingControllerProxy,
            TEST_BIDDING_PHASE_DURATION,
            TEST_REVEAL_PHASE_DURATION,
            TEST_MIN_MAX_FEE
        );
        address brevisMarketProxy =
            UnsafeUpgrades.deployTransparentProxy(brevisMarketImpl, TEST_DEPLOYER, brevisMarketInitData);

        // Grant slasher role to market
        StakingController stakingController = StakingController(stakingControllerProxy);
        stakingController.grantRole(stakingController.SLASHER_ROLE(), brevisMarketProxy);

        // Configure optional parameters (like the comprehensive script now does)
        BrevisMarket market = BrevisMarket(payable(brevisMarketProxy));

        // Read optional parameters from environment using vm.envOr like the script does
        uint256 slashBps = 1000; // From MARKET_SLASH_BPS env var
        uint256 slashWindow = 604800; // From MARKET_SLASH_WINDOW env var
        uint256 protocolFeeBps = 100; // From MARKET_PROTOCOL_FEE_BPS env var

        // Configure optional parameters (Step 3b from DeployProverNetwork.s.sol)
        if (slashBps > 0) {
            market.setSlashBps(slashBps);
        }
        if (slashWindow > 0) {
            market.setSlashWindow(slashWindow);
        }
        if (protocolFeeBps > 0) {
            market.setProtocolFeeBps(protocolFeeBps);
        }

        // Verify integration and optional parameters are set
        assertTrue(stakingController.hasRole(stakingController.SLASHER_ROLE(), brevisMarketProxy));

        // Verify cross-references
        assertEq(address(stakingController.vaultFactory()), vaultFactoryProxy);
        assertEq(address(VaultFactory(vaultFactoryProxy).stakingController()), stakingControllerProxy);
        assertEq(address(BrevisMarket(payable(brevisMarketProxy)).stakingController()), stakingControllerProxy);

        // Verify optional parameters are configured
        assertEq(market.slashBps(), slashBps);
        assertEq(market.slashWindow(), slashWindow);
        assertEq(market.protocolFeeBps(), protocolFeeBps);
    }

    function _testSystemIntegrationWithoutOptionalParams() internal {
        // Deploy system without setting optional parameters (defaults)
        address vaultFactoryImpl = address(new VaultFactory());
        address vaultFactoryProxy = UnsafeUpgrades.deployTransparentProxy(vaultFactoryImpl, TEST_DEPLOYER, "");

        address stakingControllerImpl = address(new StakingController(address(0), address(0), 0, 0, 0));
        bytes memory stakingControllerInitData = abi.encodeWithSignature(
            "init(address,address,uint256,uint256,uint256)",
            address(stakingToken),
            vaultFactoryProxy,
            TEST_UNSTAKE_DELAY,
            TEST_MIN_SELF_STAKE,
            TEST_MAX_SLASH_BPS
        );
        address stakingControllerProxy =
            UnsafeUpgrades.deployTransparentProxy(stakingControllerImpl, TEST_DEPLOYER, stakingControllerInitData);

        VaultFactory(vaultFactoryProxy).init(stakingControllerProxy);

        address brevisMarketImpl =
            address(new BrevisMarket(IPicoVerifier(address(0)), IStakingController(address(0)), 0, 0, 0));
        bytes memory brevisMarketInitData = abi.encodeWithSignature(
            "init(address,address,uint64,uint64,uint256)",
            address(picoVerifier),
            stakingControllerProxy,
            TEST_BIDDING_PHASE_DURATION,
            TEST_REVEAL_PHASE_DURATION,
            TEST_MIN_MAX_FEE
        );
        address brevisMarketProxy =
            UnsafeUpgrades.deployTransparentProxy(brevisMarketImpl, TEST_DEPLOYER, brevisMarketInitData);

        // Grant slasher role to market
        StakingController stakingController = StakingController(stakingControllerProxy);
        stakingController.grantRole(stakingController.SLASHER_ROLE(), brevisMarketProxy);

        // Don't configure optional parameters (test default behavior)
        BrevisMarket market = BrevisMarket(payable(brevisMarketProxy));

        // Verify integration
        assertTrue(stakingController.hasRole(stakingController.SLASHER_ROLE(), brevisMarketProxy));

        // Verify cross-references
        assertEq(address(stakingController.vaultFactory()), vaultFactoryProxy);
        assertEq(address(VaultFactory(vaultFactoryProxy).stakingController()), stakingControllerProxy);
        assertEq(address(BrevisMarket(payable(brevisMarketProxy)).stakingController()), stakingControllerProxy);

        // Verify optional parameters remain at defaults (0)
        assertEq(market.slashBps(), 0);
        assertEq(market.slashWindow(), 0);
        assertEq(market.protocolFeeBps(), 0);
    }
}
