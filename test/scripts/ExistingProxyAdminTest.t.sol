// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ExistingProxyAdminTest
 * @notice Validates deployment with an existing ProxyAdmin provided via JSON config
 * @dev Uses inline DEPLOY_CONFIG_JSON assembled from a readable base file
 */
import "../../lib/forge-std/src/Test.sol";
import "../../lib/forge-std/src/StdJson.sol";
import "../../scripts/DeployProverNetwork.s.sol";
import "../../test/mocks/MockERC20.sol";
import "../../src/pico/MockPicoVerifier.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from
    "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

contract ExistingProxyAdminTest is Test {
    using stdJson for string;

    uint256 constant TEST_PRIVATE_KEY = 0x1234567890123456789012345678901234567890123456789012345678901234;
    address internal testDeployer;

    MockERC20 internal stakingToken;
    MockPicoVerifier internal picoVerifier;
    ProxyAdmin internal existingProxyAdmin;

    function setUp() public {
        // Ensure a clean environment before each test
        vm.setEnv("DEPLOY_CONFIG_JSON", "");
        vm.setEnv("DEPLOY_CONFIG", "");
        testDeployer = vm.addr(TEST_PRIVATE_KEY);
        vm.deal(testDeployer, 100 ether);

        // Deploy test dependencies
        stakingToken = new MockERC20("Test Token", "TEST");
        picoVerifier = new MockPicoVerifier();

        // Deploy an existing ProxyAdmin to be reused by the script
        existingProxyAdmin = new ProxyAdmin();
    }

    function tearDown() public {
        // Avoid leaking env vars into other test suites
        // Clear DEPLOY_CONFIG_JSON to let other tests set their own config
        vm.setEnv("DEPLOY_CONFIG_JSON", "");
        vm.setEnv("DEPLOY_CONFIG", "");
        // Do not clear PRIVATE_KEY as other tests set it explicitly
    }

    function test_Deployment_UsesExistingProxyAdmin_FromJson() public {
        // Arrange: set env and inline JSON config including existing proxy admin
        vm.setEnv("PRIVATE_KEY", vm.toString(TEST_PRIVATE_KEY));
        address ownerBefore = existingProxyAdmin.owner();
        string memory json = _buildInlineConfigWithProxyAdmin(address(existingProxyAdmin));

        // Act
        DeployProverNetwork script = new DeployProverNetwork();
        script.runWithConfigJson(json);

        // Assert: proxies are actually administered by the existing ProxyAdmin
        // We can query admin using ProxyAdmin helper since it is the current admin
        address vaultFactoryProxy = address(script.vaultFactory());
        address stakingControllerProxy = script.stakingControllerProxy();
        address brevisMarketProxy = script.brevisMarketProxy();

        assertEq(
            existingProxyAdmin.getProxyAdmin(ITransparentUpgradeableProxy(vaultFactoryProxy)),
            address(existingProxyAdmin),
            "VaultFactory admin should be existing ProxyAdmin"
        );
        assertEq(
            existingProxyAdmin.getProxyAdmin(ITransparentUpgradeableProxy(stakingControllerProxy)),
            address(existingProxyAdmin),
            "StakingController admin should be existing ProxyAdmin"
        );
        assertEq(
            existingProxyAdmin.getProxyAdmin(ITransparentUpgradeableProxy(brevisMarketProxy)),
            address(existingProxyAdmin),
            "BrevisMarket admin should be existing ProxyAdmin"
        );

        // And ownership remains unchanged on the existing ProxyAdmin
        assertEq(existingProxyAdmin.owner(), ownerBefore, "ProxyAdmin owner should remain unchanged");
    }

    function test_Deployment_WithMultisigOwnedProxyAdmin() public {
        // Arrange: transfer ownership to a multisig and deploy with that admin
        address multisig = address(0x999);
        existingProxyAdmin.transferOwnership(multisig);

        vm.setEnv("PRIVATE_KEY", vm.toString(TEST_PRIVATE_KEY));
        string memory json = _buildInlineConfigWithProxyAdmin(address(existingProxyAdmin));

        // Act
        DeployProverNetwork script = new DeployProverNetwork();
        script.runWithConfigJson(json);

        // Assert: proxies are administered by the provided ProxyAdmin
        assertEq(
            existingProxyAdmin.getProxyAdmin(ITransparentUpgradeableProxy(address(script.vaultFactory()))),
            address(existingProxyAdmin),
            "VaultFactory admin should be provided ProxyAdmin"
        );
        assertEq(
            existingProxyAdmin.getProxyAdmin(ITransparentUpgradeableProxy(script.stakingControllerProxy())),
            address(existingProxyAdmin),
            "StakingController admin should be provided ProxyAdmin"
        );
        assertEq(
            existingProxyAdmin.getProxyAdmin(ITransparentUpgradeableProxy(script.brevisMarketProxy())),
            address(existingProxyAdmin),
            "BrevisMarket admin should be provided ProxyAdmin"
        );

        // Ownership is not changed by deployment
        assertEq(existingProxyAdmin.owner(), multisig, "ProxyAdmin ownership should remain with multisig");
    }

    // ===== Helpers =====
    function _buildInlineConfigWithProxyAdmin(address proxyAdminAddr) internal view returns (string memory) {
        // Dynamic values
        string memory tokenStr = vm.toString(address(stakingToken));
        string memory picoStr = vm.toString(address(picoVerifier));
        string memory proxyAdminStr = vm.toString(proxyAdminAddr);

        // Build nested JSON (use constants matching base test_config.json to keep it simple and avoid stack-too-deep)
        string memory proxyAdminJson = string.concat("{", '"address":"', proxyAdminStr, '"', "}");

        string memory stakingJson = string.concat(
            "{",
            '"token":"',
            tokenStr,
            '"',
            ",",
            '"unstakeDelay":',
            "604800",
            ",",
            '"minSelfStake":',
            "1000000000000000000000",
            ",",
            '"maxSlashBps":',
            "5000",
            "}"
        );

        string memory marketJson = string.concat(
            "{",
            '"picoVerifier":"',
            picoStr,
            '"',
            ",",
            '"biddingPhaseDuration":',
            "300",
            ",",
            '"revealPhaseDuration":',
            "600",
            ",",
            '"minMaxFee":',
            "1000000000000000",
            ",",
            '"slashBps":',
            "1000",
            ",",
            '"slashWindow":',
            "86400",
            ",",
            '"protocolFeeBps":',
            "100",
            ",",
            '"overcommitBps":',
            "0",
            "}"
        );

        string memory json = string.concat(
            "{", '"proxyAdmin":', proxyAdminJson, ",", '"staking":', stakingJson, ",", '"market":', marketJson, "}"
        );
        return json;
    }
}
