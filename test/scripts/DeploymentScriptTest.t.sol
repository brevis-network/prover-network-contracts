// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title DeploymentScriptTest
 * @notice Comprehensive tests for the DeployProverNetwork deployment script
 * @dev Tests production deployment scenarios, optional parameters, and upgrade operations
 *
 * These tests validate the core deployment script functionality including:
 * - Production deployment with required environment variables
 * - Optional parameter handling
 * - Upgrade operations using shared ProxyAdmin pattern
 * - Script instantiation and basic functionality
 *
 * Note: Tests for PROXY_ADMIN environment variable functionality are located in
 * ExistingProxyAdminTest.manual.sol for manual execution when needed.
 */
import "../../lib/forge-std/src/Test.sol";
import "../../lib/forge-std/src/StdJson.sol";
import "../../scripts/DeployProverNetwork.s.sol";
import "../../test/mocks/MockERC20.sol";
import "../../src/pico/MockPicoVerifier.sol";
import "../../src/staking/interfaces/IStakingController.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

/**
 * @title DeploymentScriptTest
 * @notice THE ONLY test file for validating production deployment scripts
 * @dev This test executes the actual DeployProverNetwork.s.sol script and validates all results
 *
 * Why only one test file?
 * - Avoids confusion and duplication
 * - Tests exactly what will be deployed in production
 * - Single source of truth for deployment validation
 */
contract DeploymentScriptTest is Test {
    using stdJson for string;
    // Test deployer setup

    uint256 constant TEST_PRIVATE_KEY = 0x1234567890123456789012345678901234567890123456789012345678901234;
    address testDeployer;

    MockERC20 stakingToken;
    MockPicoVerifier picoVerifier;
    ProxyAdmin proxyAdmin;

    function setUp() public {
        // Ensure a clean environment before each test
        vm.setEnv("DEPLOY_CONFIG_JSON", "");
        vm.setEnv("DEPLOY_CONFIG", "");
        testDeployer = vm.addr(TEST_PRIVATE_KEY);
        vm.deal(testDeployer, 100 ether);

        // Deploy test dependencies
        stakingToken = new MockERC20("Test Token", "TEST");
        picoVerifier = new MockPicoVerifier();

        // Deploy a shared ProxyAdmin owned by the test deployer (to match production flow)
        vm.startPrank(testDeployer);
        proxyAdmin = new ProxyAdmin();
        vm.stopPrank();

        console.log("=== Test Setup ===");
        console.log("Test Deployer:", testDeployer);
        console.log("Staking Token:", address(stakingToken));
        console.log("Pico Verifier:", address(picoVerifier));
    }

    /**
     * @notice 🎯 MAIN TEST: Validates complete production deployment
     * @dev This is the most important test - it executes your actual production script
     */
    function test_ProductionDeploymentScript() public {
        console.log("\n=== Testing Production Deployment Script ===");

        // Set required environment
        vm.setEnv("PRIVATE_KEY", vm.toString(TEST_PRIVATE_KEY));
        // Build inline JSON config (single source of truth)
        string memory json = _buildInlineConfig(false);

        // Execute the actual production deployment script
        DeployProverNetwork deployScript = new DeployProverNetwork();
        deployScript.runWithConfigJson(json);

        // Validate critical deployments - comprehensive but focused
        _validateSharedProxyAdmin(deployScript);
        _validateStakingSystem(deployScript);
        _validateBrevisMarket(deployScript);
        _validateSystemIntegration(deployScript);

        console.log("Production deployment script validation: PASSED");
    }

    /**
     * @notice Test deployment with optional market parameters
     * @dev Validates the script handles optional environment variables correctly
     */
    function test_DeploymentWithOptionalParams() public {
        console.log("\n=== Testing Deployment With Optional Parameters ===");

        // Set required environment
        vm.setEnv("PRIVATE_KEY", vm.toString(TEST_PRIVATE_KEY));
        // Provide inline JSON config with optional params
        string memory json = _buildInlineConfig(true);

        DeployProverNetwork deployScript = new DeployProverNetwork();
        deployScript.runWithConfigJson(json);

        // Validate deployment completed successfully with optional params
        assertNotEq(deployScript.brevisMarketProxy(), address(0), "Market should deploy with optional params");

        // Validate that optional parameters were properly set
        BrevisMarket market = BrevisMarket(payable(deployScript.brevisMarketProxy()));

        // Check slashing parameters
        assertEq(market.slashBps(), 1000, "Slash BPS should be set to 1000 (10%)");
        assertEq(market.slashWindow(), 86400, "Slash window should be set to 86400 (1 day)");

        // Check protocol fee
        assertEq(market.protocolFeeBps(), 100, "Protocol fee BPS should be set to 100 (1%)");

        console.log("Deployment with optional parameters: PASSED");
    }

    /**
     * @notice Test basic script functionality without full execution
     * @dev Lightweight test for environment validation
     */
    function test_ScriptCanBeInstantiated() public {
        console.log("\n=== Testing Script Basic Functionality ===");

        // Test that the production script can be instantiated
        DeployProverNetwork deployScript = new DeployProverNetwork();
        assertTrue(address(deployScript) != address(0), "Production script should be instantiable");

        console.log("Script instantiation: PASSED");
    }

    /**
     * @notice 🔄 UPGRADE TEST: Validates upgrade operations using shared ProxyAdmin
     * @dev This test ensures the upgrade mechanism works correctly for production
     */
    function test_UpgradeOperations() public {
        console.log("\n=== Testing Upgrade Operations ===");

        // Step 1: Deploy initial system (use inline JSON config)
        vm.setEnv("PRIVATE_KEY", vm.toString(TEST_PRIVATE_KEY));
        string memory json = _buildInlineConfig(false);

        DeployProverNetwork deployScript = new DeployProverNetwork();
        deployScript.runWithConfigJson(json);

        console.log("Initial deployment completed");

        // Step 2: Deploy new implementation contracts (simulating upgrades)
        vm.startPrank(testDeployer);

        VaultFactory newVaultFactoryImpl = new VaultFactory();
        StakingController newStakingControllerImpl =
            new StakingController(address(stakingToken), address(deployScript.vaultFactory()), 604800, 1000e18, 5000);
        BrevisMarket newBrevisMarketImpl =
            new BrevisMarket(picoVerifier, IStakingController(deployScript.stakingControllerProxy()), 300, 600, 1e15);

        console.log("New implementation contracts deployed");

        // Step 3: Perform upgrades through shared ProxyAdmin
        ProxyAdmin proxyAdmin = deployScript.sharedProxyAdmin();

        // Upgrade VaultFactory
        address vaultFactoryProxy = address(deployScript.vaultFactory());
        address oldVaultFactoryImpl = proxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(vaultFactoryProxy));

        proxyAdmin.upgrade(ITransparentUpgradeableProxy(vaultFactoryProxy), address(newVaultFactoryImpl));

        // Upgrade StakingController
        address stakingControllerProxy = deployScript.stakingControllerProxy();
        address oldStakingControllerImpl =
            proxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(stakingControllerProxy));

        proxyAdmin.upgrade(ITransparentUpgradeableProxy(stakingControllerProxy), address(newStakingControllerImpl));

        // Upgrade BrevisMarket
        address brevisMarketProxy = deployScript.brevisMarketProxy();
        address oldBrevisMarketImpl = proxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(brevisMarketProxy));

        proxyAdmin.upgrade(ITransparentUpgradeableProxy(brevisMarketProxy), address(newBrevisMarketImpl));

        vm.stopPrank();

        console.log("All upgrades completed");

        // Step 4: Validate upgrades
        _validateUpgrades(
            proxyAdmin,
            vaultFactoryProxy,
            stakingControllerProxy,
            brevisMarketProxy,
            address(newVaultFactoryImpl),
            address(newStakingControllerImpl),
            address(newBrevisMarketImpl),
            oldVaultFactoryImpl,
            oldStakingControllerImpl,
            oldBrevisMarketImpl
        );

        // Step 5: Validate functionality still works after upgrades
        _validateSystemAfterUpgrade(deployScript);

        console.log("Upgrade operations validation: PASSED");
    }

    /**
     * @notice Validate deployment when the ProxyAdmin is owned by a multisig (non-deployer)
     * @dev Ensures the script uses the provided ProxyAdmin and does not change its owner
     */
    function test_Deployment_WithMultisigOwnedProxyAdmin() public {
        console.log("\n=== Testing Deployment With Multisig-owned ProxyAdmin ===");

        // Arrange: transfer ownership to a multisig and deploy with that admin
        address multisig = address(0x999);
        vm.prank(testDeployer);
        proxyAdmin.transferOwnership(multisig);

        vm.setEnv("PRIVATE_KEY", vm.toString(TEST_PRIVATE_KEY));
        string memory json = _buildInlineConfig(false);

        // Act
        DeployProverNetwork script = new DeployProverNetwork();
        script.runWithConfigJson(json);

        // Assert: proxies are administered by the provided ProxyAdmin
        assertEq(
            proxyAdmin.getProxyAdmin(ITransparentUpgradeableProxy(address(script.vaultFactory()))),
            address(proxyAdmin),
            "VaultFactory admin should be provided ProxyAdmin"
        );
        assertEq(
            proxyAdmin.getProxyAdmin(ITransparentUpgradeableProxy(script.stakingControllerProxy())),
            address(proxyAdmin),
            "StakingController admin should be provided ProxyAdmin"
        );
        assertEq(
            proxyAdmin.getProxyAdmin(ITransparentUpgradeableProxy(script.brevisMarketProxy())),
            address(proxyAdmin),
            "BrevisMarket admin should be provided ProxyAdmin"
        );

        // Ownership is not changed by deployment
        assertEq(proxyAdmin.owner(), multisig, "ProxyAdmin ownership should remain with multisig");

        console.log("Deployment with multisig-owned ProxyAdmin: PASSED");
    }

    // ============ Validation Helper Functions ============

    function _validateSharedProxyAdmin(DeployProverNetwork deployScript) internal view {
        address sharedAdminAddr = address(deployScript.sharedProxyAdmin());
        assertNotEq(sharedAdminAddr, address(0), "ProxyAdmin should be deployed");

        // Validate ownership
        assertEq(deployScript.sharedProxyAdmin().owner(), testDeployer, "ProxyAdmin owner should be deployer");
        // Validate that the script used the provided ProxyAdmin
        assertEq(sharedAdminAddr, address(proxyAdmin), "Should use provided ProxyAdmin from config");

        console.log("SharedProxyAdmin validation: PASSED");
    }

    function _validateStakingSystem(DeployProverNetwork deployScript) internal view {
        // Validate VaultFactory
        address vaultFactory = address(deployScript.vaultFactory());
        assertNotEq(vaultFactory, address(0), "VaultFactory should be deployed");

        // Validate StakingController
        address stakingController = deployScript.stakingControllerProxy();
        assertNotEq(stakingController, address(0), "StakingController should be deployed");

        StakingController controller = StakingController(stakingController);
        assertEq(address(controller.stakingToken()), address(stakingToken), "StakingToken should be configured");
        assertEq(address(controller.vaultFactory()), vaultFactory, "VaultFactory should be linked");
        assertEq(controller.unstakeDelay(), 604800, "Unstake delay should be 7 days");
        assertEq(controller.minSelfStake(), 1000e18, "Min self stake should be 1000 tokens");
        assertEq(controller.maxSlashBps(), 5000, "Max slash should be 50%");

        // Validate StakingViewer
        assertNotEq(deployScript.stakingViewer(), address(0), "StakingViewer should be deployed");

        console.log("Staking system validation: PASSED");
    }

    function _validateBrevisMarket(DeployProverNetwork deployScript) internal view {
        address brevisMarket = deployScript.brevisMarketProxy();
        assertNotEq(brevisMarket, address(0), "BrevisMarket should be deployed");

        BrevisMarket market = BrevisMarket(payable(brevisMarket));
        assertEq(address(market.picoVerifier()), address(picoVerifier), "Pico verifier should be configured");
        assertEq(
            address(market.stakingController()),
            deployScript.stakingControllerProxy(),
            "Staking controller should be linked"
        );
        assertEq(market.biddingPhaseDuration(), 300, "Bidding phase should be 5 minutes");
        assertEq(market.revealPhaseDuration(), 600, "Reveal phase should be 10 minutes");
        assertEq(market.minMaxFee(), 1e15, "Min max fee should be 0.001 ETH");

        console.log("BrevisMarket validation: PASSED");
    }

    function _validateSystemIntegration(DeployProverNetwork deployScript) internal view {
        StakingController stakingController = StakingController(deployScript.stakingControllerProxy());
        address brevisMarket = deployScript.brevisMarketProxy();

        // Validate market has slasher role
        assertTrue(
            stakingController.hasRole(stakingController.SLASHER_ROLE(), brevisMarket), "Market should have slasher role"
        );

        console.log("System integration validation: PASSED");
    }

    function _validateUpgrades(
        ProxyAdmin proxyAdmin,
        address vaultFactoryProxy,
        address stakingControllerProxy,
        address brevisMarketProxy,
        address newVaultFactoryImpl,
        address newStakingControllerImpl,
        address newBrevisMarketImpl,
        address oldVaultFactoryImpl,
        address oldStakingControllerImpl,
        address oldBrevisMarketImpl
    ) internal view {
        // Validate implementation addresses changed
        address currentVaultFactoryImpl =
            proxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(vaultFactoryProxy));
        address currentStakingControllerImpl =
            proxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(stakingControllerProxy));
        address currentBrevisMarketImpl =
            proxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(brevisMarketProxy));

        // Verify implementations were actually upgraded
        assertEq(currentVaultFactoryImpl, newVaultFactoryImpl, "VaultFactory implementation should be upgraded");
        assertEq(
            currentStakingControllerImpl,
            newStakingControllerImpl,
            "StakingController implementation should be upgraded"
        );
        assertEq(currentBrevisMarketImpl, newBrevisMarketImpl, "BrevisMarket implementation should be upgraded");

        // Verify old implementations are different
        assertNotEq(currentVaultFactoryImpl, oldVaultFactoryImpl, "VaultFactory implementation should have changed");
        assertNotEq(
            currentStakingControllerImpl,
            oldStakingControllerImpl,
            "StakingController implementation should have changed"
        );
        assertNotEq(currentBrevisMarketImpl, oldBrevisMarketImpl, "BrevisMarket implementation should have changed");

        console.log("Implementation upgrade validation: PASSED");
    }

    function _validateSystemAfterUpgrade(DeployProverNetwork deployScript) internal view {
        // Validate that the system still functions correctly after upgrade
        // This ensures storage layout compatibility and proper initialization

        // Check VaultFactory
        VaultFactory vaultFactory = deployScript.vaultFactory();
        assertNotEq(
            address(vaultFactory.stakingController()), address(0), "VaultFactory should still have staking controller"
        );

        // Check StakingController
        StakingController stakingController = StakingController(deployScript.stakingControllerProxy());
        assertEq(
            address(stakingController.stakingToken()),
            address(stakingToken),
            "StakingController should still have correct token"
        );
        assertEq(
            address(stakingController.vaultFactory()),
            address(vaultFactory),
            "StakingController should still be linked to VaultFactory"
        );
        assertEq(stakingController.unstakeDelay(), 604800, "StakingController should preserve unstake delay");
        assertEq(stakingController.minSelfStake(), 1000e18, "StakingController should preserve min self stake");
        assertEq(stakingController.maxSlashBps(), 5000, "StakingController should preserve max slash bps");

        // Check BrevisMarket
        BrevisMarket brevisMarket = BrevisMarket(payable(deployScript.brevisMarketProxy()));
        assertEq(
            address(brevisMarket.picoVerifier()),
            address(picoVerifier),
            "BrevisMarket should still have correct verifier"
        );
        assertEq(
            address(brevisMarket.stakingController()),
            deployScript.stakingControllerProxy(),
            "BrevisMarket should still be linked to StakingController"
        );
        assertEq(brevisMarket.biddingPhaseDuration(), 300, "BrevisMarket should preserve bidding duration");
        assertEq(brevisMarket.revealPhaseDuration(), 600, "BrevisMarket should preserve reveal duration");
        assertEq(brevisMarket.minMaxFee(), 1e15, "BrevisMarket should preserve min max fee");

        // Check that roles are still intact
        assertTrue(
            stakingController.hasRole(stakingController.SLASHER_ROLE(), deployScript.brevisMarketProxy()),
            "Market should still have slasher role after upgrade"
        );

        console.log("Post-upgrade system functionality validation: PASSED");
    }

    // ===== Test Helpers =====
    function _buildInlineConfig(bool withOptional) internal view returns (string memory) {
        // Load base config from file for readability
        string memory base = vm.readFile("test/scripts/test_config.json");

        // Dynamic addresses from freshly deployed mocks
        string memory tokenStr = vm.toString(address(stakingToken));
        string memory picoStr = vm.toString(address(picoVerifier));
        string memory proxyAdminStr = vm.toString(address(proxyAdmin));

        string memory stakingJson = _stakingJson(base, tokenStr);
        string memory marketJson = _marketJson(base, picoStr, withOptional);

        // ProxyAdmin JSON
        string memory proxyAdminJson = string.concat("{", '"address":"', proxyAdminStr, '"', "}");

        // Build final JSON using base values + dynamic addresses
        string memory json = string.concat(
            "{", '"proxyAdmin":', proxyAdminJson, ",", '"staking":', stakingJson, ",", '"market":', marketJson, "}"
        );
        return json;
    }

    function _stakingJson(string memory base, string memory tokenStr) internal view returns (string memory) {
        // Note: base string is expected to contain staking defaults
        return string.concat(
            "{",
            '"token":"',
            tokenStr,
            '",',
            '"unstakeDelay":',
            vm.toString(stdJson.readUint(base, "$.staking.unstakeDelay")),
            ",",
            '"minSelfStake":',
            vm.toString(stdJson.readUint(base, "$.staking.minSelfStake")),
            ",",
            '"maxSlashBps":',
            vm.toString(stdJson.readUint(base, "$.staking.maxSlashBps")),
            "}"
        );
    }

    function _marketJson(string memory base, string memory picoStr, bool withOptional)
        internal
        view
        returns (string memory)
    {
        string memory slashBpsStr = withOptional ? "1000" : vm.toString(stdJson.readUint(base, "$.market.slashBps"));
        string memory slashWindowStr =
            withOptional ? "86400" : vm.toString(stdJson.readUint(base, "$.market.slashWindow"));
        string memory protocolFeeBpsStr =
            withOptional ? "100" : vm.toString(stdJson.readUint(base, "$.market.protocolFeeBps"));
        string memory overcommitBpsStr = vm.toString(stdJson.readUintOr(base, "$.market.overcommitBps", 0));

        return string.concat(
            "{",
            '"picoVerifier":"',
            picoStr,
            '",',
            '"biddingPhaseDuration":',
            vm.toString(stdJson.readUint(base, "$.market.biddingPhaseDuration")),
            ",",
            '"revealPhaseDuration":',
            vm.toString(stdJson.readUint(base, "$.market.revealPhaseDuration")),
            ",",
            '"minMaxFee":',
            vm.toString(stdJson.readUint(base, "$.market.minMaxFee")),
            ",",
            '"slashBps":',
            slashBpsStr,
            ",",
            '"slashWindow":',
            slashWindowStr,
            ",",
            '"protocolFeeBps":',
            protocolFeeBpsStr,
            ",",
            '"overcommitBps":',
            overcommitBpsStr,
            "}"
        );
    }
}
