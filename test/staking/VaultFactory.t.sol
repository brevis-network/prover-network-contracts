// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/staking/vault/VaultFactory.sol";
import "../../src/staking/interfaces/IVaultFactory.sol";
import "../../src/staking/vault/ProverVault.sol";
import "../mocks/MockERC20.sol";

contract VaultFactoryTest is Test {
    VaultFactory public factory;
    MockERC20 public token;

    address public admin = makeAddr("admin");
    address public controller = makeAddr("controller");
    address public unauthorized = makeAddr("unauthorized");
    address public prover1 = makeAddr("prover1");
    address public prover2 = makeAddr("prover2");

    event VaultCreated(address indexed prover, address indexed vault, address asset, bytes32 salt);

    function setUp() public {
        vm.startPrank(admin);

        // Deploy token and factory
        token = new MockERC20("Test Token", "TEST");
        factory = new VaultFactory();

        // Initialize controller
        factory.init(controller);

        vm.stopPrank();
    }

    // =========================================================================
    // INITIALIZATION TESTS
    // =========================================================================

    function testInitializationSuccess() public {
        // Deploy a new factory to test initialization
        VaultFactory newFactory = new VaultFactory();
        address newController = makeAddr("newController");

        assertEq(newFactory.stakingController(), address(0));

        newFactory.init(newController);

        assertEq(newFactory.stakingController(), newController);
    }

    function testInitializationOnlyOnce() public {
        VaultFactory newFactory = new VaultFactory();
        address newController = makeAddr("newController");
        address anotherController = makeAddr("anotherController");

        newFactory.init(newController);

        vm.expectRevert(IVaultFactory.VaultFactoryAlreadyInitialized.selector);
        newFactory.init(anotherController);
    }

    function testInitializationRejectsZeroAddress() public {
        VaultFactory newFactory = new VaultFactory();

        vm.expectRevert(IVaultFactory.VaultFactoryZeroAddress.selector);
        newFactory.init(address(0));
    }

    // =========================================================================
    // ACCESS CONTROL TESTS
    // =========================================================================

    function testOnlyControllerCanCreateVault() public {
        vm.prank(unauthorized);
        vm.expectRevert(IVaultFactory.VaultFactoryOnlyController.selector);
        factory.createVault(address(token), prover1, controller);
    }

    function testControllerCanCreateVault() public {
        vm.prank(controller);
        address vault = factory.createVault(address(token), prover1, controller);

        assertTrue(vault != address(0));
        assertEq(factory.getVault(prover1), vault);
    }

    function testAdminCannotCreateVaultWithoutControllerRole() public {
        vm.prank(admin);
        vm.expectRevert(IVaultFactory.VaultFactoryOnlyController.selector);
        factory.createVault(address(token), prover1, controller);
    }

    // =========================================================================
    // DEPLOYMENT TESTS
    // =========================================================================

    function testCreateVaultSuccess() public {
        // Use startPrank to maintain sender across multiple calls
        vm.startPrank(controller);

        // Predict the vault address that will be created
        address predictedVault = factory.predictVaultAddress(address(token), prover1, controller);
        bytes32 expectedSalt = keccak256(abi.encode(address(token), prover1));

        // Expect VaultCreated event - only prover and vault are indexed
        vm.expectEmit(true, true, false, false);
        emit VaultCreated(prover1, predictedVault, address(token), expectedSalt);

        address vault = factory.createVault(address(token), prover1, controller);

        vm.stopPrank();

        // Verify prediction was correct
        assertEq(vault, predictedVault);

        // Verify vault was deployed
        assertTrue(vault != address(0));
        assertTrue(vault.code.length > 0);

        // Verify storage updates
        assertEq(factory.getVault(prover1), vault);
        assertEq(factory.vaults(0), vault);
        assertTrue(factory.isVaultDeployed(prover1));

        // Verify vault properties
        ProverVault deployedVault = ProverVault(vault);
        assertEq(address(deployedVault.asset()), address(token));
        assertEq(deployedVault.prover(), prover1);
        assertEq(deployedVault.controller(), controller);
        assertTrue(bytes(deployedVault.name()).length > 0);
        assertTrue(bytes(deployedVault.symbol()).length > 0);
    }

    function testCannotCreateDuplicateVault() public {
        vm.startPrank(controller);

        // Create first vault
        factory.createVault(address(token), prover1, controller);

        // Try to create duplicate
        vm.expectRevert(IVaultFactory.VaultFactoryVaultAlreadyExists.selector);
        factory.createVault(address(token), prover1, controller);

        vm.stopPrank();
    }

    function testMultipleVaultsForDifferentProvers() public {
        vm.startPrank(controller);

        address vault1 = factory.createVault(address(token), prover1, controller);
        address vault2 = factory.createVault(address(token), prover2, controller);

        // Verify different addresses
        assertTrue(vault1 != vault2);

        // Verify correct mappings
        assertEq(factory.getVault(prover1), vault1);
        assertEq(factory.getVault(prover2), vault2);

        // Verify both are in vaults array
        assertEq(factory.vaults(0), vault1);
        assertEq(factory.vaults(1), vault2);

        vm.stopPrank();
    }

    // =========================================================================
    // CREATE2 DETERMINISM TESTS
    // =========================================================================

    function testPredictVaultAddress() public {
        // Predict address before deployment
        address predicted = factory.predictVaultAddress(address(token), prover1, controller);

        // Deploy vault
        vm.prank(controller);
        address actual = factory.createVault(address(token), prover1, controller);

        // Verify prediction matches actual
        assertEq(predicted, actual);
    }

    function testSameInputsSamePrediction() public view {
        address predicted1 = factory.predictVaultAddress(address(token), prover1, controller);
        address predicted2 = factory.predictVaultAddress(address(token), prover1, controller);

        assertEq(predicted1, predicted2);
    }

    function testDifferentProversDifferentAddresses() public view {
        address predicted1 = factory.predictVaultAddress(address(token), prover1, controller);
        address predicted2 = factory.predictVaultAddress(address(token), prover2, controller);

        assertTrue(predicted1 != predicted2);
    }

    function testDifferentAssetsDifferentAddresses() public {
        MockERC20 token2 = new MockERC20("Token2", "TK2");

        address predicted1 = factory.predictVaultAddress(address(token), prover1, controller);
        address predicted2 = factory.predictVaultAddress(address(token2), prover1, controller);

        assertTrue(predicted1 != predicted2);
    }

    function testDifferentControllersSameAddress() public {
        // Note: Controller is in constructor args, so different controllers = different addresses
        address controller2 = makeAddr("controller2");

        address predicted1 = factory.predictVaultAddress(address(token), prover1, controller);
        address predicted2 = factory.predictVaultAddress(address(token), prover1, controller2);

        // This demonstrates the "controller upgrade = new vault address" behavior documented in interface
        assertTrue(predicted1 != predicted2);
    }

    // =========================================================================
    // VIEW FUNCTION TESTS
    // =========================================================================

    function testGetVaultForNonexistentProver() public view {
        assertEq(factory.getVault(prover1), address(0));
    }

    function testIsVaultDeployedForNonexistentProver() public view {
        assertFalse(factory.isVaultDeployed(prover1));
    }

    function testVaultsArrayEmpty() public {
        vm.expectRevert();
        factory.vaults(0);
    }

    function testGetVaultCount() public {
        assertEq(factory.getVaultCount(), 0);

        vm.startPrank(controller);
        factory.createVault(address(token), prover1, controller);
        assertEq(factory.getVaultCount(), 1);

        factory.createVault(address(token), prover2, controller);
        assertEq(factory.getVaultCount(), 2);
        vm.stopPrank();
    }

    // =========================================================================
    // EDGE CASE TESTS
    // =========================================================================

    function testCreateVaultWithZeroAddresses() public {
        vm.prank(controller);

        // The factory doesn't validate addresses - that's left to the vault constructor
        // In this case, the vault constructor accepts address(0) controller
        // This test verifies the factory can deploy even with unusual parameters
        address vault = factory.createVault(address(token), prover1, address(0));

        assertTrue(vault != address(0));
        assertEq(factory.getVault(prover1), vault);

        // Verify the vault has the zero controller
        ProverVault deployedVault = ProverVault(vault);
        assertEq(deployedVault.controller(), address(0));
    }

    function testVaultNamingIsUnique() public {
        vm.startPrank(controller);

        address vault1 = factory.createVault(address(token), prover1, controller);
        address vault2 = factory.createVault(address(token), prover2, controller);

        ProverVault v1 = ProverVault(vault1);
        ProverVault v2 = ProverVault(vault2);

        // Names should be different (contain different prover addresses)
        assertTrue(keccak256(bytes(v1.name())) != keccak256(bytes(v2.name())));
        assertTrue(keccak256(bytes(v1.symbol())) != keccak256(bytes(v2.symbol())));

        vm.stopPrank();
    }

    // =========================================================================
    // GAS OPTIMIZATION TESTS
    // =========================================================================

    function testCreateVaultGasCost() public {
        vm.prank(controller);

        uint256 gasBefore = gasleft();
        factory.createVault(address(token), prover1, controller);
        uint256 gasUsed = gasBefore - gasleft();

        // Gas usage should be reasonable (CREATE2 + storage updates)
        // This is mainly for monitoring, not a hard requirement
        emit log_named_uint("createVault gas used", gasUsed);
        assertTrue(gasUsed < 3_000_000); // Should be much less than block limit
    }

    function testPredictVaultAddressGasCost() public {
        uint256 gasBefore = gasleft();
        factory.predictVaultAddress(address(token), prover1, controller);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("predictVaultAddress gas used", gasUsed);
        assertTrue(gasUsed < 100_000); // Should be very cheap (just calculation)
    }
}
