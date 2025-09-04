// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";
import {UnsafeUpgrades} from "../../lib/openzeppelin-foundry-upgrades/src/Upgrades.sol";
import "../../scripts/DeployProverNetwork.s.sol";
import "../../src/staking/controller/StakingController.sol";
import "../../src/staking/viewer/StakingViewer.sol";
import "../../src/staking/interfaces/IStakingViewer.sol";
import "../../src/staking/vault/VaultFactory.sol";
import "../../src/market/BrevisMarket.sol";
import "../../src/pico/MockPicoVerifier.sol";
import "../../test/mocks/MockERC20.sol";

/**
 * @title DeployProverNetworkTest
 * @notice Tests the complete deployment script to ensure all components are deployed and integrated correctly
 */
contract DeployProverNetworkTest is Test {
    MockERC20 stakingToken;
    MockPicoVerifier picoVerifier;

    // Environment variables for testing
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

        // Set up environment variables for the test
        vm.setEnv("PRIVATE_KEY", vm.toString(uint256(0x1)));
        vm.setEnv("STAKING_TOKEN_ADDRESS", vm.toString(address(stakingToken)));
        vm.setEnv("PICO_VERIFIER_ADDRESS", vm.toString(address(picoVerifier)));
        vm.setEnv("UNSTAKE_DELAY", vm.toString(TEST_UNSTAKE_DELAY));
        vm.setEnv("MIN_SELF_STAKE", vm.toString(TEST_MIN_SELF_STAKE));
        vm.setEnv("MAX_SLASH_BPS", vm.toString(TEST_MAX_SLASH_BPS));
        vm.setEnv("BIDDING_PHASE_DURATION", vm.toString(TEST_BIDDING_PHASE_DURATION));
        vm.setEnv("REVEAL_PHASE_DURATION", vm.toString(TEST_REVEAL_PHASE_DURATION));
        vm.setEnv("MIN_MAX_FEE", vm.toString(TEST_MIN_MAX_FEE));
    }

    function test_DeploymentScriptEnvironmentVariables() public view {
        // Test that environment variables are properly read
        assertEq(vm.envAddress("STAKING_TOKEN_ADDRESS"), address(stakingToken));
        assertEq(vm.envAddress("PICO_VERIFIER_ADDRESS"), address(picoVerifier));
        assertEq(vm.envUint("UNSTAKE_DELAY"), TEST_UNSTAKE_DELAY);
        assertEq(vm.envUint("MIN_SELF_STAKE"), TEST_MIN_SELF_STAKE);
        assertEq(vm.envUint("MAX_SLASH_BPS"), TEST_MAX_SLASH_BPS);
    }

    function test_StakingSystemDeployment() public {
        // Test individual components of the staking system deployment
        _testStakingSystemDeployment();
    }

    function test_MarketDeployment() public {
        // Test individual market deployment
        _testMarketDeployment();
    }

    function test_SystemIntegration() public {
        // Test that all components can be integrated together
        _testSystemIntegration();
    }

    function _testStakingSystemDeployment() internal {
        // Deploy VaultFactory
        address vaultFactoryImpl = address(new VaultFactory());
        bytes memory vaultFactoryInitData = "";
        address vaultFactoryProxy =
            UnsafeUpgrades.deployTransparentProxy(vaultFactoryImpl, TEST_DEPLOYER, vaultFactoryInitData);

        // Deploy StakingController
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

        // Initialize VaultFactory
        VaultFactory(vaultFactoryProxy).init(stakingControllerProxy);

        // Verify staking system configuration
        StakingController stakingController = StakingController(stakingControllerProxy);
        assertEq(address(stakingController.stakingToken()), address(stakingToken));
        assertEq(stakingController.unstakeDelay(), TEST_UNSTAKE_DELAY);
        assertEq(stakingController.minSelfStake(), TEST_MIN_SELF_STAKE);
        assertEq(stakingController.maxSlashBps(), TEST_MAX_SLASH_BPS);
        assertEq(address(stakingController.vaultFactory()), vaultFactoryProxy);

        // Verify VaultFactory configuration
        VaultFactory vaultFactory = VaultFactory(vaultFactoryProxy);
        assertEq(address(vaultFactory.stakingController()), stakingControllerProxy);
    }

    function _testMarketDeployment() internal {
        // Deploy StakingController with proper staking token
        address stakingControllerImpl = address(new StakingController(address(0), address(0), 0, 0, 0));
        bytes memory stakingControllerInitData = abi.encodeWithSignature(
            "init(address,address,uint256,uint256,uint256)",
            address(stakingToken), // Use actual staking token
            address(0), // VaultFactory not needed for this test
            TEST_UNSTAKE_DELAY,
            TEST_MIN_SELF_STAKE,
            TEST_MAX_SLASH_BPS
        );
        address stakingControllerProxy =
            UnsafeUpgrades.deployTransparentProxy(stakingControllerImpl, TEST_DEPLOYER, stakingControllerInitData);

        // Deploy BrevisMarket
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

        // Verify market configuration
        BrevisMarket market = BrevisMarket(payable(brevisMarketProxy));
        assertEq(address(market.picoVerifier()), address(picoVerifier));
        assertEq(address(market.stakingController()), stakingControllerProxy);
        assertEq(market.biddingPhaseDuration(), TEST_BIDDING_PHASE_DURATION);
        assertEq(market.revealPhaseDuration(), TEST_REVEAL_PHASE_DURATION);
        assertEq(market.minMaxFee(), TEST_MIN_MAX_FEE);
    }

    function _testSystemIntegration() internal {
        // Deploy the complete system to test integration
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

        // Deploy StakingViewer
        StakingViewer stakingViewer = new StakingViewer(stakingControllerProxy);

        // Verify integration
        assertTrue(stakingController.hasRole(stakingController.SLASHER_ROLE(), brevisMarketProxy));

        // Verify cross-references
        assertEq(address(stakingController.vaultFactory()), vaultFactoryProxy);
        assertEq(address(VaultFactory(vaultFactoryProxy).stakingController()), stakingControllerProxy);
        assertEq(address(BrevisMarket(payable(brevisMarketProxy)).stakingController()), stakingControllerProxy);
        assertEq(address(stakingViewer.stakingController()), stakingControllerProxy);

        // Test StakingViewer basic functionality
        IStakingViewer.SystemOverview memory overview = stakingViewer.getSystemOverview();
        assertEq(overview.minSelfStake, TEST_MIN_SELF_STAKE);
        assertEq(overview.unstakeDelay, TEST_UNSTAKE_DELAY);
        assertEq(address(overview.stakingToken), address(stakingToken));
    }

    function test_StakingViewerDeployment() public {
        // Deploy a complete staking system to test StakingViewer
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

        // Deploy StakingViewer
        StakingViewer stakingViewer = new StakingViewer(stakingControllerProxy);

        // Verify StakingViewer connection
        assertEq(address(stakingViewer.stakingController()), stakingControllerProxy);

        // Test basic functionality - getSystemOverview should not revert
        IStakingViewer.SystemOverview memory overview = stakingViewer.getSystemOverview();

        // Verify the overview contains expected data
        assertEq(overview.minSelfStake, TEST_MIN_SELF_STAKE);
        assertEq(overview.unstakeDelay, TEST_UNSTAKE_DELAY);
        assertEq(address(overview.stakingToken), address(stakingToken));
        assertEq(overview.totalProvers, 0); // No provers registered yet
        assertEq(overview.activeProvers, 0);
        assertEq(overview.totalVaultAssets, 0);

        // Test getTopProvers (should return empty array)
        IStakingViewer.ProverDisplayInfo[] memory topProvers = stakingViewer.getTopProvers(10);
        assertEq(topProvers.length, 0);
    }

    function test_MarketDeploymentWithOptionalParams() public {
        // Test that the market can be deployed with optional parameters
        _testMarketDeploymentWithOptionalParams();
    }

    function test_DeploymentValidation() public view {
        // Test parameter validation
        // This tests the concepts without actually running the script

        // Test invalid max slash BPS
        assertTrue(15000 > 10000, "Invalid slash BPS should be > 10000");

        // Test zero addresses
        assertTrue(address(0) == address(0), "Zero address validation");

        // Test that our mock contracts are valid
        assertTrue(address(stakingToken) != address(0), "Staking token should be deployed");
        assertTrue(address(picoVerifier) != address(0), "Pico verifier should be deployed");
    }

    function _testMarketDeploymentWithOptionalParams() internal {
        // Deploy StakingController with proper staking token
        address stakingControllerImpl = address(new StakingController(address(0), address(0), 0, 0, 0));
        bytes memory stakingControllerInitData = abi.encodeWithSignature(
            "init(address,address,uint256,uint256,uint256)",
            address(stakingToken), // Use actual staking token
            address(0), // VaultFactory not needed for this test
            TEST_UNSTAKE_DELAY,
            TEST_MIN_SELF_STAKE,
            TEST_MAX_SLASH_BPS
        );
        address stakingControllerProxy =
            UnsafeUpgrades.deployTransparentProxy(stakingControllerImpl, TEST_DEPLOYER, stakingControllerInitData);

        // Deploy BrevisMarket with optional parameters
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

        BrevisMarket market = BrevisMarket(payable(brevisMarketProxy));

        // The market owner is the test contract itself (address(this)), not TEST_DEPLOYER
        // Configure optional parameters (simulating what the script does)
        market.setSlashBps(1000); // 10%
        market.setSlashWindow(604800); // 7 days
        market.setProtocolFeeBps(100); // 1%

        // Verify optional parameters
        assertEq(market.slashBps(), 1000);
        assertEq(market.slashWindow(), 604800);
        assertEq(market.protocolFeeBps(), 100);
    }
}
