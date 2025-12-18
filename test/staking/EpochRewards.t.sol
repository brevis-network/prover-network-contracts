// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/staking/rewards/EpochRewards.sol";
import "../../src/staking/controller/StakingController.sol";
import "../../src/staking/vault/VaultFactory.sol";
import "../mocks/MockERC20.sol";

contract MockBrevisProof {
    struct ProofData {
        bytes32 vkHash;
        bytes32 appCommitHash;
    }

    mapping(bytes32 => ProofData) public proofs;

    function submitProof(uint64, bytes calldata proof)
        external
        returns (bytes32 proofId, bytes32 appCommitHash, bytes32 appVkHash)
    {
        proofId = keccak256(proof);
        ProofData memory data = proofs[proofId];
        if (data.vkHash == bytes32(0)) {
            // First time seeing this proof - store it
            data.vkHash = bytes32(uint256(1)); // Mock vkHash
            data.appCommitHash = bytes32(uint256(2)); // Mock appCommitHash
            proofs[proofId] = data;
        }
        return (proofId, data.appCommitHash, data.vkHash);
    }

    function setProofData(bytes32 proofId, bytes32 vkHash, bytes32 appCommitHash) external {
        proofs[proofId] = ProofData(vkHash, appCommitHash);
    }
}

contract EpochRewardsTest is Test {
    EpochRewards public epochRewards;
    StakingController public controller;
    VaultFactory public factory;
    MockERC20 public stakingToken;
    MockBrevisProof public brevisProof;

    address public admin = makeAddr("admin");
    address public rewardUpdater = makeAddr("rewardUpdater");
    address public epochUpdater = makeAddr("epochUpdater");
    address public prover1 = address(0x1111);
    address public prover2 = address(0x2222);
    address public prover3 = address(0x3333);

    uint256 public constant INITIAL_MINT = 1000000e18;
    uint64 public constant EPOCH_LENGTH = 1 days;
    uint256 public constant MAX_EPOCH_REWARD = 1000e18;
    uint64 public startTime;

    function setUp() public {
        vm.startPrank(admin);

        stakingToken = new MockERC20("Staking Token", "STK");
        stakingToken.mint(admin, INITIAL_MINT);

        factory = new VaultFactory();
        controller = new StakingController(address(stakingToken), address(factory), 7 days, 1e18, 5000);
        factory.init(address(controller));

        brevisProof = new MockBrevisProof();
        epochRewards = new EpochRewards(address(controller), address(brevisProof), rewardUpdater, epochUpdater);

        startTime = uint64(block.timestamp);

        // Set vkHash as owner (admin deployed the contract)
        epochRewards.setVkHash(bytes32(uint256(1)));

        vm.stopPrank();

        // Initialize epoch config
        vm.prank(epochUpdater);
        epochRewards.initEpoch(startTime, EPOCH_LENGTH, MAX_EPOCH_REWARD);
    }

    // ===============================
    // EPOCH MANAGER TESTS
    // ===============================

    function testInitEpoch() public view {
        assertEq(epochRewards.startTimestamp(), startTime);
        (uint32 fromEpoch, uint64 fromTime, uint64 epochLength, uint256 maxReward) = epochRewards.epochConfigs(0);
        assertEq(fromEpoch, 1);
        assertEq(fromTime, startTime);
        assertEq(epochLength, EPOCH_LENGTH);
        assertEq(maxReward, MAX_EPOCH_REWARD);
    }

    function testCannotReinitializeEpoch() public {
        vm.prank(epochUpdater);
        vm.expectRevert(EpochManager.EpochManagerAlreadyInitialized.selector);
        epochRewards.initEpoch(startTime + 1000, EPOCH_LENGTH, MAX_EPOCH_REWARD);
    }

    function testGetCurrentEpochInfo() public {
        vm.warp(startTime + EPOCH_LENGTH * 2 + 100);

        (uint32 currentEpoch, uint64 epochLength, uint256 maxReward) = epochRewards.getCurrentEpochInfo();
        assertEq(currentEpoch, 3);
        assertEq(epochLength, EPOCH_LENGTH);
        assertEq(maxReward, MAX_EPOCH_REWARD);
    }

    function testGetEpochInfoByEpochNumber() public view {
        (uint64 epochStartTime, uint64 epochLength, uint256 maxReward) = epochRewards.getEpochInfoByEpochNumber(1);
        assertEq(epochStartTime, startTime);
        assertEq(epochLength, EPOCH_LENGTH);
        assertEq(maxReward, MAX_EPOCH_REWARD);

        (epochStartTime, epochLength, maxReward) = epochRewards.getEpochInfoByEpochNumber(5);
        assertEq(epochStartTime, startTime + EPOCH_LENGTH * 4);
        assertEq(epochLength, EPOCH_LENGTH);
        assertEq(maxReward, MAX_EPOCH_REWARD);
    }

    function testSetEpochConfig() public {
        uint64 newEpochLength = 2 days;
        uint256 newMaxReward = 2000e18;

        vm.prank(epochUpdater);
        epochRewards.setEpochConfig(10, newEpochLength, newMaxReward);

        (uint64 epochStartTime, uint64 epochLength, uint256 maxReward) = epochRewards.getEpochInfoByEpochNumber(10);
        assertEq(epochStartTime, startTime + EPOCH_LENGTH * 9);
        assertEq(epochLength, newEpochLength);
        assertEq(maxReward, newMaxReward);
    }

    function testPopEpochConfig() public {
        vm.startPrank(epochUpdater);
        epochRewards.setEpochConfig(10, 2 days, 2000e18);
        uint256 configCount = epochRewards.getEpochConfigNumber();
        assertEq(configCount, 2);

        epochRewards.popEpochConfig();
        configCount = epochRewards.getEpochConfigNumber();
        assertEq(configCount, 1);
        vm.stopPrank();
    }

    function testCannotPopLastEpochConfig() public {
        // Only one config exists (from initEpoch)
        assertEq(epochRewards.getEpochConfigNumber(), 1);

        vm.prank(epochUpdater);
        vm.expectRevert(EpochManager.EpochManagerNoConfigs.selector);
        epochRewards.popEpochConfig();
    }

    function testSetEpochConfigBeforeInit() public {
        // Deploy a new EpochRewards without initialization
        EpochRewards newRewards = new EpochRewards(address(controller), address(brevisProof), address(0), epochUpdater);

        vm.prank(epochUpdater);
        vm.expectRevert(EpochManager.EpochManagerNotInitialized.selector);
        newRewards.setEpochConfig(1, EPOCH_LENGTH, MAX_EPOCH_REWARD);
    }

    function testSetEpochConfigByTime() public {
        uint64 futureTime = startTime + EPOCH_LENGTH * 10;
        uint64 newEpochLength = 2 days;
        uint256 newMaxReward = 2000e18;

        vm.prank(epochUpdater);
        epochRewards.setEpochConfigByTime(futureTime, newEpochLength, newMaxReward);

        // Verify config was added
        assertEq(epochRewards.getEpochConfigNumber(), 2);

        // The new config starts at epoch 11 (epochsDelta = 10, fromEpoch = 1 + 10)
        // Check that epoch 10 still uses old config
        (uint64 epochStartTime10, uint64 epochLength10, uint256 maxReward10) =
            epochRewards.getEpochInfoByEpochNumber(10);
        assertEq(epochStartTime10, startTime + EPOCH_LENGTH * 9);
        assertEq(epochLength10, EPOCH_LENGTH);
        assertEq(maxReward10, MAX_EPOCH_REWARD);

        // Check that epoch 11 uses new config
        (uint64 epochStartTime11, uint64 epochLength11, uint256 maxReward11) =
            epochRewards.getEpochInfoByEpochNumber(11);
        assertEq(epochStartTime11, startTime + EPOCH_LENGTH * 10);
        assertEq(epochLength11, newEpochLength);
        assertEq(maxReward11, newMaxReward);
    }

    function testSetEpochConfigByTimeBeforeInit() public {
        // Deploy a new EpochRewards without initialization
        EpochRewards newRewards = new EpochRewards(address(controller), address(brevisProof), address(0), epochUpdater);

        vm.prank(epochUpdater);
        vm.expectRevert(EpochManager.EpochManagerNotInitialized.selector);
        newRewards.setEpochConfigByTime(uint64(block.timestamp + 1000), EPOCH_LENGTH, MAX_EPOCH_REWARD);
    }

    function testCannotSetEpochConfigByTimeInPast() public {
        vm.prank(epochUpdater);
        vm.expectRevert();
        epochRewards.setEpochConfigByTime(startTime, EPOCH_LENGTH, MAX_EPOCH_REWARD);
    }

    function testPopFutureEpochConfigs() public {
        vm.startPrank(epochUpdater);

        // Add multiple future configs
        uint64 futureTime1 = startTime + EPOCH_LENGTH * 10;
        uint64 futureTime2 = startTime + EPOCH_LENGTH * 20;

        epochRewards.setEpochConfigByTime(futureTime1, 2 days, 2000e18);
        epochRewards.setEpochConfigByTime(futureTime2, 3 days, 3000e18);

        assertEq(epochRewards.getEpochConfigNumber(), 3);

        // Pop future configs (both should be removed since we're still at startTime)
        epochRewards.popFutureEpochConfigs();

        assertEq(epochRewards.getEpochConfigNumber(), 1);
        vm.stopPrank();
    }

    function testPopFutureEpochConfigsPreservesActiveConfig() public {
        vm.startPrank(epochUpdater);

        // Add future config
        uint64 futureTime = startTime + EPOCH_LENGTH * 10;
        epochRewards.setEpochConfigByTime(futureTime, 2 days, 2000e18);

        // Warp to after the future config becomes active
        vm.warp(futureTime + 100);

        // Add another future config after current time
        uint64 furtherFutureTime = futureTime + EPOCH_LENGTH * 10;
        epochRewards.setEpochConfigByTime(furtherFutureTime, 3 days, 3000e18);

        assertEq(epochRewards.getEpochConfigNumber(), 3);

        // Pop future configs - should only remove the last one
        epochRewards.popFutureEpochConfigs();

        assertEq(epochRewards.getEpochConfigNumber(), 2);
        vm.stopPrank();
    }

    function testEpochConfigTransition() public {
        // Set a new config starting at epoch 5
        vm.prank(epochUpdater);
        epochRewards.setEpochConfig(5, 2 days, 2000e18);

        // Check epoch 4 uses old config
        (uint64 startTime4, uint64 length4, uint256 reward4) = epochRewards.getEpochInfoByEpochNumber(4);
        assertEq(startTime4, startTime + EPOCH_LENGTH * 3);
        assertEq(length4, EPOCH_LENGTH);
        assertEq(reward4, MAX_EPOCH_REWARD);

        // Check epoch 5 uses new config
        (uint64 startTime5, uint64 length5, uint256 reward5) = epochRewards.getEpochInfoByEpochNumber(5);
        assertEq(startTime5, startTime + EPOCH_LENGTH * 4);
        assertEq(length5, 2 days);
        assertEq(reward5, 2000e18);

        // Check epoch 6 also uses new config
        (uint64 startTime6, uint64 length6, uint256 reward6) = epochRewards.getEpochInfoByEpochNumber(6);
        assertEq(startTime6, startTime + EPOCH_LENGTH * 4 + 2 days);
        assertEq(length6, 2 days);
        assertEq(reward6, 2000e18);
    }

    function testGetCurrentEpochInfoAcrossConfigTransition() public {
        // Set a new config starting at epoch 3
        vm.prank(epochUpdater);
        epochRewards.setEpochConfig(3, 2 days, 2000e18);

        // Before transition (epoch 2)
        vm.warp(startTime + EPOCH_LENGTH + 100);
        (uint32 epoch, uint64 length, uint256 reward) = epochRewards.getCurrentEpochInfo();
        assertEq(epoch, 2);
        assertEq(length, EPOCH_LENGTH);
        assertEq(reward, MAX_EPOCH_REWARD);

        // After transition (epoch 3)
        vm.warp(startTime + EPOCH_LENGTH * 2 + 100);
        (epoch, length, reward) = epochRewards.getCurrentEpochInfo();
        assertEq(epoch, 3);
        assertEq(length, 2 days);
        assertEq(reward, 2000e18);
    }

    function testCannotSetEpochConfigWithZeroValues() public {
        vm.startPrank(epochUpdater);

        vm.expectRevert();
        epochRewards.setEpochConfig(0, EPOCH_LENGTH, MAX_EPOCH_REWARD);

        vm.expectRevert();
        epochRewards.setEpochConfig(10, 0, MAX_EPOCH_REWARD);

        vm.expectRevert();
        epochRewards.setEpochConfig(10, EPOCH_LENGTH, 0);

        vm.stopPrank();
    }

    // ===============================
    // REWARD SETTING TESTS
    // ===============================

    function testSetRewards() public {
        // Move to after epoch 1 completes
        vm.warp(startTime + EPOCH_LENGTH + 100);

        bytes memory circuitOutput = _buildCircuitOutput(1, startTime, startTime + EPOCH_LENGTH, prover1, 100e18);

        bytes32 proofId = keccak256("mockProof");
        bytes32 appCommitHash = keccak256(circuitOutput);
        brevisProof.setProofData(proofId, bytes32(uint256(1)), appCommitHash);

        vm.prank(rewardUpdater);
        epochRewards.setRewards("mockProof", circuitOutput);

        (uint128 amount, bool distributed) = epochRewards.epochProverRewards(1, prover1);
        assertEq(amount, 100e18);
        assertFalse(distributed);
        assertEq(epochRewards.epochTotalRewards(1), 100e18);
        assertEq(epochRewards.lastUpdatedEpoch(), 1);
    }

    function testSetRewardsMultipleProvers() public {
        vm.warp(startTime + EPOCH_LENGTH + 100);

        bytes memory circuitOutput =
            _buildCircuitOutputMulti(1, startTime, startTime + EPOCH_LENGTH, prover1, 100e18, prover2, 200e18);

        bytes32 proofId = keccak256("mockProof");
        bytes32 appCommitHash = keccak256(circuitOutput);
        brevisProof.setProofData(proofId, bytes32(uint256(1)), appCommitHash);

        vm.prank(rewardUpdater);
        epochRewards.setRewards("mockProof", circuitOutput);

        (uint128 amount1, bool distributed1) = epochRewards.epochProverRewards(1, prover1);
        (uint128 amount2, bool distributed2) = epochRewards.epochProverRewards(1, prover2);
        assertEq(amount1, 100e18);
        assertEq(amount2, 200e18);
        assertFalse(distributed1);
        assertFalse(distributed2);
        assertEq(epochRewards.epochTotalRewards(1), 300e18);
        assertEq(epochRewards.epochLastProver(1), prover2);
    }

    function testSetRewardsBatched() public {
        vm.warp(startTime + EPOCH_LENGTH + 100);

        // First batch
        bytes memory circuitOutput1 = _buildCircuitOutput(1, startTime, startTime + EPOCH_LENGTH, prover1, 100e18);
        bytes32 proofId1 = keccak256("mockProof1");
        brevisProof.setProofData(proofId1, bytes32(uint256(1)), keccak256(circuitOutput1));

        vm.prank(rewardUpdater);
        epochRewards.setRewards("mockProof1", circuitOutput1);

        // Second batch - must have prover address > prover1
        bytes memory circuitOutput2 = _buildCircuitOutput(1, startTime, startTime + EPOCH_LENGTH, prover2, 200e18);
        bytes32 proofId2 = keccak256("mockProof2");
        brevisProof.setProofData(proofId2, bytes32(uint256(1)), keccak256(circuitOutput2));

        vm.prank(rewardUpdater);
        epochRewards.setRewards("mockProof2", circuitOutput2);

        (uint128 amount1,) = epochRewards.epochProverRewards(1, prover1);
        (uint128 amount2,) = epochRewards.epochProverRewards(1, prover2);
        assertEq(amount1, 100e18);
        assertEq(amount2, 200e18);
        assertEq(epochRewards.epochTotalRewards(1), 300e18);
    }

    function testCannotSetRewardsForZeroEpoch() public {
        bytes memory circuitOutput = _buildCircuitOutput(0, startTime, startTime + EPOCH_LENGTH, prover1, 100e18);

        vm.prank(rewardUpdater);
        vm.expectRevert(EpochRewards.StakingRewardsInvalidEpoch.selector);
        epochRewards.setRewards("mockProof", circuitOutput);
    }

    function testCannotSetRewardsForPastEpoch() public {
        vm.warp(startTime + EPOCH_LENGTH * 2 + 100);

        // First set epoch 2
        bytes memory circuitOutput2 =
            _buildCircuitOutput(2, startTime + EPOCH_LENGTH, startTime + EPOCH_LENGTH * 2, prover1, 100e18);
        bytes32 proofId2 = keccak256("mockProof2");
        brevisProof.setProofData(proofId2, bytes32(uint256(1)), keccak256(circuitOutput2));

        vm.prank(rewardUpdater);
        epochRewards.setRewards("mockProof2", circuitOutput2);

        // Now try epoch 1 (should fail)
        bytes memory circuitOutput1 = _buildCircuitOutput(1, startTime, startTime + EPOCH_LENGTH, prover1, 100e18);

        vm.prank(rewardUpdater);
        vm.expectRevert(EpochRewards.StakingRewardsInvalidEpoch.selector);
        epochRewards.setRewards("mockProof1", circuitOutput1);
    }

    function testCannotSetRewardsBeforeEpochEnds() public {
        vm.warp(startTime + EPOCH_LENGTH / 2); // Mid-epoch

        bytes memory circuitOutput = _buildCircuitOutput(1, startTime, startTime + EPOCH_LENGTH, prover1, 100e18);

        vm.prank(rewardUpdater);
        vm.expectRevert();
        epochRewards.setRewards("mockProof", circuitOutput);
    }

    function testCannotSetRewardsWithWrongTimestamps() public {
        vm.warp(startTime + EPOCH_LENGTH + 100);

        // Wrong start time
        bytes memory circuitOutput = _buildCircuitOutput(1, startTime + 100, startTime + EPOCH_LENGTH, prover1, 100e18);

        vm.prank(rewardUpdater);
        vm.expectRevert();
        epochRewards.setRewards("mockProof", circuitOutput);
    }

    function testCannotExceedMaxReward() public {
        vm.warp(startTime + EPOCH_LENGTH + 100);

        bytes memory circuitOutput =
            _buildCircuitOutput(1, startTime, startTime + EPOCH_LENGTH, prover1, MAX_EPOCH_REWARD + 1);

        bytes32 proofId = keccak256("mockProof");
        brevisProof.setProofData(proofId, bytes32(uint256(1)), keccak256(circuitOutput));

        vm.prank(rewardUpdater);
        vm.expectRevert();
        epochRewards.setRewards("mockProof", circuitOutput);
    }

    function testCannotSetUnsortedProvers() public {
        vm.warp(startTime + EPOCH_LENGTH + 100);

        // prover2 < prover3 but we list them in wrong order
        bytes memory circuitOutput = abi.encodePacked(
            uint32(1),
            uint64(startTime),
            uint64(startTime + EPOCH_LENGTH),
            prover3,
            uint128(100e18),
            prover2,
            uint128(200e18)
        );

        bytes32 proofId = keccak256("mockProof");
        brevisProof.setProofData(proofId, bytes32(uint256(1)), keccak256(circuitOutput));

        vm.prank(rewardUpdater);
        vm.expectRevert();
        epochRewards.setRewards("mockProof", circuitOutput);
    }

    function testCannotResubmitSameProver() public {
        vm.warp(startTime + EPOCH_LENGTH + 100);

        // First batch
        bytes memory circuitOutput1 = _buildCircuitOutput(1, startTime, startTime + EPOCH_LENGTH, prover2, 100e18);
        bytes32 proofId1 = keccak256("mockProof1");
        brevisProof.setProofData(proofId1, bytes32(uint256(1)), keccak256(circuitOutput1));

        vm.prank(rewardUpdater);
        epochRewards.setRewards("mockProof1", circuitOutput1);

        // Try to submit prover2 again or lower address
        bytes memory circuitOutput2 = _buildCircuitOutput(1, startTime, startTime + EPOCH_LENGTH, prover1, 200e18);
        bytes32 proofId2 = keccak256("mockProof2");
        brevisProof.setProofData(proofId2, bytes32(uint256(1)), keccak256(circuitOutput2));

        vm.prank(rewardUpdater);
        vm.expectRevert();
        epochRewards.setRewards("mockProof2", circuitOutput2);
    }

    function testCapOverrunAcrossBatchesReverts() public {
        vm.warp(startTime + EPOCH_LENGTH + 100);

        // First batch: 600e18
        bytes memory circuitOutput1 = _buildCircuitOutput(1, startTime, startTime + EPOCH_LENGTH, prover1, 600e18);
        bytes32 proofId1 = keccak256("mockProof1");
        brevisProof.setProofData(proofId1, bytes32(uint256(1)), keccak256(circuitOutput1));

        vm.prank(rewardUpdater);
        epochRewards.setRewards("mockProof1", circuitOutput1);

        // Second batch would push total to 1100e18 (> 1000e18 cap)
        bytes memory circuitOutput2 = _buildCircuitOutput(1, startTime, startTime + EPOCH_LENGTH, prover2, 500e18);
        bytes32 proofId2 = keccak256("mockProof2");
        brevisProof.setProofData(proofId2, bytes32(uint256(1)), keccak256(circuitOutput2));

        vm.prank(rewardUpdater);
        vm.expectRevert();
        epochRewards.setRewards("mockProof2", circuitOutput2);

        // State should remain at the first batch totals
        assertEq(epochRewards.epochTotalRewards(1), 600e18);
        (uint128 amount1,) = epochRewards.epochProverRewards(1, prover1);
        (uint128 amount2,) = epochRewards.epochProverRewards(1, prover2);
        assertEq(amount1, 600e18);
        assertEq(amount2, 0);
    }

    // ===============================
    // DISTRIBUTION TESTS
    // ===============================

    function testDistributeRewards() public {
        // Setup: initialize prover1 in controller
        vm.startPrank(admin);
        stakingToken.mint(prover1, 100e18);
        vm.stopPrank();

        vm.startPrank(prover1);
        stakingToken.approve(address(controller), 100e18);
        controller.initializeProver(1000);
        vm.stopPrank();

        // Set rewards
        vm.warp(startTime + EPOCH_LENGTH + 100);

        bytes memory circuitOutput = _buildCircuitOutput(1, startTime, startTime + EPOCH_LENGTH, prover1, 100e18);
        bytes32 proofId = keccak256("mockProof");
        brevisProof.setProofData(proofId, bytes32(uint256(1)), keccak256(circuitOutput));

        vm.prank(rewardUpdater);
        epochRewards.setRewards("mockProof", circuitOutput);

        // Fund the EpochRewards contract with reward tokens
        vm.prank(admin);
        stakingToken.mint(address(epochRewards), 100e18);

        // Distribute
        address[] memory provers = new address[](1);
        provers[0] = prover1;

        vm.prank(rewardUpdater);
        epochRewards.distributeRewards(1, provers);

        // Verify rewards were marked as distributed
        (uint128 amount, bool distributed) = epochRewards.epochProverRewards(1, prover1);
        assertEq(amount, 100e18);
        assertTrue(distributed);
    }

    function testDistributeRewardsInsufficientFundingReverts() public {
        // Initialize prover1
        vm.startPrank(admin);
        stakingToken.mint(prover1, 100e18);
        vm.stopPrank();

        vm.startPrank(prover1);
        stakingToken.approve(address(controller), 100e18);
        controller.initializeProver(1000);
        vm.stopPrank();

        // Set rewards for 100e18
        vm.warp(startTime + EPOCH_LENGTH + 100);
        bytes memory circuitOutput = _buildCircuitOutput(1, startTime, startTime + EPOCH_LENGTH, prover1, 100e18);
        bytes32 proofId = keccak256("mockProof");
        brevisProof.setProofData(proofId, bytes32(uint256(1)), keccak256(circuitOutput));

        vm.prank(rewardUpdater);
        epochRewards.setRewards("mockProof", circuitOutput);

        // Fund contract with insufficient balance (50e18 < 100e18 owed)
        vm.prank(admin);
        stakingToken.mint(address(epochRewards), 50e18);

        address[] memory provers = new address[](1);
        provers[0] = prover1;

        vm.prank(rewardUpdater);
        vm.expectRevert();
        epochRewards.distributeRewards(1, provers);
    }

    function testCannotDistributeZeroReward() public {
        address[] memory provers = new address[](1);
        provers[0] = prover1;

        vm.prank(rewardUpdater);
        vm.expectRevert();
        epochRewards.distributeRewards(1, provers);
    }

    // ===============================
    // VIEW FUNCTION TESTS
    // ===============================

    function testGetDistributableRewards() public {
        // Set up rewards for multiple epochs
        vm.warp(startTime + EPOCH_LENGTH + 100);

        // Epoch 1: prover1 has 100e18
        bytes memory circuitOutput1 = _buildCircuitOutput(1, startTime, startTime + EPOCH_LENGTH, prover1, 100e18);
        bytes32 proofId1 = keccak256("mockProof1");
        brevisProof.setProofData(proofId1, bytes32(uint256(1)), keccak256(circuitOutput1));
        vm.prank(rewardUpdater);
        epochRewards.setRewards("mockProof1", circuitOutput1);

        // Epoch 2: prover1 has 200e18
        vm.warp(startTime + 2 * EPOCH_LENGTH + 100);
        bytes memory circuitOutput2 =
            _buildCircuitOutput(2, startTime + EPOCH_LENGTH, startTime + 2 * EPOCH_LENGTH, prover1, 200e18);
        bytes32 proofId2 = keccak256("mockProof2");
        brevisProof.setProofData(proofId2, bytes32(uint256(1)), keccak256(circuitOutput2));
        vm.prank(rewardUpdater);
        epochRewards.setRewards("mockProof2", circuitOutput2);

        // Epoch 3: prover1 has 300e18
        vm.warp(startTime + 3 * EPOCH_LENGTH + 100);
        bytes memory circuitOutput3 =
            _buildCircuitOutput(3, startTime + 2 * EPOCH_LENGTH, startTime + 3 * EPOCH_LENGTH, prover1, 300e18);
        bytes32 proofId3 = keccak256("mockProof3");
        brevisProof.setProofData(proofId3, bytes32(uint256(1)), keccak256(circuitOutput3));
        vm.prank(rewardUpdater);
        epochRewards.setRewards("mockProof3", circuitOutput3);

        // Query distributable rewards for epochs 1-3
        (uint32[] memory epochs, uint128[] memory amounts) = epochRewards.getDistributableRewards(1, 3, prover1);

        assertEq(epochs.length, 3);
        assertEq(amounts.length, 3);
        assertEq(epochs[0], 1);
        assertEq(amounts[0], 100e18);
        assertEq(epochs[1], 2);
        assertEq(amounts[1], 200e18);
        assertEq(epochs[2], 3);
        assertEq(amounts[2], 300e18);
    }

    function testGetDistributableRewardsAfterDistribution() public {
        // Set up rewards for epoch 1 and 2
        vm.warp(startTime + EPOCH_LENGTH + 100);
        bytes memory circuitOutput1 = _buildCircuitOutput(1, startTime, startTime + EPOCH_LENGTH, prover1, 100e18);
        bytes32 proofId1 = keccak256("mockProof1");
        brevisProof.setProofData(proofId1, bytes32(uint256(1)), keccak256(circuitOutput1));
        vm.prank(rewardUpdater);
        epochRewards.setRewards("mockProof1", circuitOutput1);

        vm.warp(startTime + 2 * EPOCH_LENGTH + 100);
        bytes memory circuitOutput2 =
            _buildCircuitOutput(2, startTime + EPOCH_LENGTH, startTime + 2 * EPOCH_LENGTH, prover1, 200e18);
        bytes32 proofId2 = keccak256("mockProof2");
        brevisProof.setProofData(proofId2, bytes32(uint256(1)), keccak256(circuitOutput2));
        vm.prank(rewardUpdater);
        epochRewards.setRewards("mockProof2", circuitOutput2);

        // Initialize prover1 in controller
        vm.prank(admin);
        stakingToken.mint(prover1, 100e18);

        vm.startPrank(prover1);
        stakingToken.approve(address(controller), 100e18);
        controller.initializeProver(1000);
        vm.stopPrank();

        // Distribute epoch 1 rewards
        vm.prank(admin);
        stakingToken.mint(address(epochRewards), 100e18);

        address[] memory provers = new address[](1);
        provers[0] = prover1;

        vm.prank(rewardUpdater);
        epochRewards.distributeRewards(1, provers);

        // Query distributable rewards - should only return epoch 2
        (uint32[] memory epochs, uint128[] memory amounts) = epochRewards.getDistributableRewards(1, 2, prover1);

        assertEq(epochs.length, 1);
        assertEq(amounts.length, 1);
        assertEq(epochs[0], 2);
        assertEq(amounts[0], 200e18);
    }

    function testGetDistributableRewardsNoRewards() public view {
        // Query when no rewards exist
        (uint32[] memory epochs, uint128[] memory amounts) = epochRewards.getDistributableRewards(1, 10, prover1);

        assertEq(epochs.length, 0);
        assertEq(amounts.length, 0);
    }

    function testGetBatchDistributableRewards() public {
        // Set up rewards for multiple provers and epochs
        vm.warp(startTime + EPOCH_LENGTH + 100);

        // Epoch 1: prover1 has 100e18, prover2 has 50e18
        bytes memory circuitOutput1 =
            _buildCircuitOutputMulti(1, startTime, startTime + EPOCH_LENGTH, prover1, 100e18, prover2, 50e18);
        bytes32 proofId1 = keccak256("mockProof1");
        brevisProof.setProofData(proofId1, bytes32(uint256(1)), keccak256(circuitOutput1));
        vm.prank(rewardUpdater);
        epochRewards.setRewards("mockProof1", circuitOutput1);

        // Epoch 2: prover1 has 200e18, prover3 has 75e18
        vm.warp(startTime + 2 * EPOCH_LENGTH + 100);
        bytes memory circuitOutput2 = _buildCircuitOutputMulti(
            2, startTime + EPOCH_LENGTH, startTime + 2 * EPOCH_LENGTH, prover1, 200e18, prover3, 75e18
        );
        bytes32 proofId2 = keccak256("mockProof2");
        brevisProof.setProofData(proofId2, bytes32(uint256(1)), keccak256(circuitOutput2));
        vm.prank(rewardUpdater);
        epochRewards.setRewards("mockProof2", circuitOutput2);

        // Query batch distributable rewards
        address[] memory provers = new address[](3);
        provers[0] = prover1;
        provers[1] = prover2;
        provers[2] = prover3;

        EpochRewards.ProverDistributableRewards[] memory results =
            epochRewards.getBatchDistributableRewards(1, 2, provers);

        assertEq(results.length, 3);

        // Prover1: has rewards in epoch 1 and 2
        assertEq(results[0].prover, prover1);
        assertEq(results[0].epochs.length, 2);
        assertEq(results[0].epochs[0], 1);
        assertEq(results[0].amounts[0], 100e18);
        assertEq(results[0].epochs[1], 2);
        assertEq(results[0].amounts[1], 200e18);

        // Prover2: has rewards only in epoch 1
        assertEq(results[1].prover, prover2);
        assertEq(results[1].epochs.length, 1);
        assertEq(results[1].epochs[0], 1);
        assertEq(results[1].amounts[0], 50e18);

        // Prover3: has rewards only in epoch 2
        assertEq(results[2].prover, prover3);
        assertEq(results[2].epochs.length, 1);
        assertEq(results[2].epochs[0], 2);
        assertEq(results[2].amounts[0], 75e18);
    }

    function testGetBatchDistributableRewardsAfterPartialDistribution() public {
        // Set up rewards
        vm.warp(startTime + EPOCH_LENGTH + 100);
        bytes memory circuitOutput1 =
            _buildCircuitOutputMulti(1, startTime, startTime + EPOCH_LENGTH, prover1, 100e18, prover2, 50e18);
        bytes32 proofId1 = keccak256("mockProof1");
        brevisProof.setProofData(proofId1, bytes32(uint256(1)), keccak256(circuitOutput1));
        vm.prank(rewardUpdater);
        epochRewards.setRewards("mockProof1", circuitOutput1);

        // Initialize prover1 in controller
        vm.prank(admin);
        stakingToken.mint(prover1, 100e18);

        vm.startPrank(prover1);
        stakingToken.approve(address(controller), 100e18);
        controller.initializeProver(1000);
        vm.stopPrank();

        // Distribute only prover1's rewards
        vm.prank(admin);
        stakingToken.mint(address(epochRewards), 100e18);

        address[] memory singleProver = new address[](1);
        singleProver[0] = prover1;

        vm.prank(rewardUpdater);
        epochRewards.distributeRewards(1, singleProver);

        // Query batch - prover1 should have no distributable, prover2 should still have rewards
        address[] memory provers = new address[](2);
        provers[0] = prover1;
        provers[1] = prover2;

        EpochRewards.ProverDistributableRewards[] memory results =
            epochRewards.getBatchDistributableRewards(1, 1, provers);

        assertEq(results.length, 2);

        // Prover1: no distributable rewards
        assertEq(results[0].prover, prover1);
        assertEq(results[0].epochs.length, 0);

        // Prover2: still has distributable rewards
        assertEq(results[1].prover, prover2);
        assertEq(results[1].epochs.length, 1);
        assertEq(results[1].epochs[0], 1);
        assertEq(results[1].amounts[0], 50e18);
    }

    function testGetBatchDistributableRewardsEmptyProvers() public view {
        address[] memory provers = new address[](0);

        EpochRewards.ProverDistributableRewards[] memory results =
            epochRewards.getBatchDistributableRewards(1, 10, provers);

        assertEq(results.length, 0);
    }

    // ===============================
    // HELPER FUNCTIONS
    // ===============================

    function _buildCircuitOutput(uint32 epoch, uint64 epochStart, uint64 epochEnd, address prover, uint256 amount)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(epoch, epochStart, epochEnd, prover, uint128(amount));
    }

    function _buildCircuitOutputMulti(
        uint32 epoch,
        uint64 epochStart,
        uint64 epochEnd,
        address prover1_,
        uint256 amount1,
        address prover2_,
        uint256 amount2
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(epoch, epochStart, epochEnd, prover1_, uint128(amount1), prover2_, uint128(amount2));
    }
}
