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

        assertEq(epochRewards.epochProverRewards(1, prover1), 100e18);
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

        assertEq(epochRewards.epochProverRewards(1, prover1), 100e18);
        assertEq(epochRewards.epochProverRewards(1, prover2), 200e18);
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

        assertEq(epochRewards.epochProverRewards(1, prover1), 100e18);
        assertEq(epochRewards.epochProverRewards(1, prover2), 200e18);
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
        assertEq(epochRewards.epochProverRewards(1, prover1), 600e18);
        assertEq(epochRewards.epochProverRewards(1, prover2), 0);
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

        // Verify rewards were zeroed
        assertEq(epochRewards.epochProverRewards(1, prover1), 0);
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
