// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IStakingController.sol";
import "./brevis-proof/BrevisProofApp.sol";
import "./EpochManager.sol";

contract EpochRewards is BrevisProofApp, EpochManager {
    using SafeERC20 for IERC20;

    // =========================================================================
    // CONSTANTS
    // =========================================================================

    // 0x9188644bf0c7a694e572b54fd40005e1230f80a50c59be6fb567a312ab5a1d4d
    bytes32 public constant REWARD_UPDATER_ROLE = keccak256("REWARD_UPDATER_ROLE");

    // =========================================================================
    // STORAGE
    // =========================================================================

    IStakingController public stakingController;

    bytes32 public vkHash;
    // mapping of epoch => prover => reward amount
    mapping(uint32 => mapping(address => uint256)) public epochProverRewards;
    mapping(uint32 => address) public epochLastProver;
    mapping(uint32 => uint256) public epochTotalRewards;
    uint32 public lastUpdatedEpoch;

    // Storage gap for future upgrades. Reserves 40 slots.
    uint256[40] private __gap;

    // =========================================================================
    // EVENTS
    // =========================================================================

    event RewardsSet(uint32 indexed epoch, address indexed prover, uint256 amount);
    event EpochRewardsSet(uint32 indexed epoch, uint256 newAmount, uint256 cumulativeAmount);

    // =========================================================================
    // ERRORS
    // =========================================================================

    error StakingRewardsZeroAmount(address prover);
    error StakingRewardsExceedsMax(uint32 epoch, uint256 totalRewards, uint256 maxAllowed);
    error StakingRewardsInvalidEpoch();
    error StakingRewardsEpochWindowMismatch(
        uint32 epoch, uint64 expectedStart, uint64 providedStart, uint64 expectedEnd, uint64 providedEnd
    );
    error StakingRewardsEpochNotReady(uint32 epoch, uint64 epochEndTime, uint64 currentTime);
    error StakingRewardsUnsortedProvers(address previousProver, address currentProver);

    // =========================================================================
    // CONSTRUCTOR / INITIALIZATION
    // =========================================================================

    /**
     * @notice Deploy with initial staking controller, Brevis proof verifier, and reward updater.
     * @dev For upgradeable: pass zero values and call init() later. For direct: pass actual values for immediate initialization.
     * @param _stakingController Staking controller that holds vaults and distributes rewards.
     * @param _brevisProof Brevis proof verifier contract address.
     * @param _rewardUpdater Account granted reward/epoch updater roles.
     * @param _epochUpdater Account granted epoch updater role.
     */
    constructor(address _stakingController, address _brevisProof, address _rewardUpdater, address _epochUpdater) {
        _init(_stakingController, _brevisProof, _rewardUpdater, _epochUpdater);
    }

    /**
     * @notice Initialize the staking rewards contract for upgradeable deployment.
     * @dev Sets up controller, proof verifier, roles, and owner (when called via proxy init).
     * @param _stakingController Staking controller that holds vaults and distributes rewards.
     * @param _brevisProof Brevis proof verifier contract address.
     * @param _rewardUpdater Account granted reward/epoch updater roles.
     * @param _epochUpdater Account granted epoch updater role.
     */
    function init(address _stakingController, address _brevisProof, address _rewardUpdater, address _epochUpdater)
        external
    {
        _init(_stakingController, _brevisProof, _rewardUpdater, _epochUpdater);
        initOwner(); // requires _owner == address(0), which is only possible when it's a delegateCall
    }

    /**
     * @dev Shared initializer for constructor and proxy init.
     */
    function _init(address _stakingController, address _brevisProof, address _rewardUpdater, address _epochUpdater)
        internal
    {
        stakingController = IStakingController(_stakingController);
        brevisProof = IBrevisProof(_brevisProof);
        if (_rewardUpdater != address(0)) {
            _grantRole(REWARD_UPDATER_ROLE, _rewardUpdater);
        }
        if (_epochUpdater != address(0)) {
            _grantRole(EPOCH_UPDATER_ROLE, _epochUpdater);
        }
        // Approve unlimited tokens to staking controller for reward distribution
        IERC20(stakingController.stakingToken()).approve(address(stakingController), type(uint256).max);
    }

    // =========================================================================
    // EXTERNAL FUNCTIONS
    // =========================================================================

    /**
     * @notice Record per-prover rewards for an epoch using Brevis proof output.
     * @dev Validates epoch window, ordering, and max reward cap before storing.
     * @param proof Brevis proof bytes.
     * @param circuitOutput Encoded circuit output containing epoch window and prover rewards.
     */
    function setRewards(bytes calldata proof, bytes calldata circuitOutput) external onlyRole(REWARD_UPDATER_ROLE) {
        uint32 epoch = uint32(bytes4(circuitOutput[0:4]));
        if (epoch == 0 || epoch < lastUpdatedEpoch) {
            revert StakingRewardsInvalidEpoch();
        }

        uint64 startTime = uint64(bytes8(circuitOutput[4:12]));
        uint64 endTime = uint64(bytes8(circuitOutput[12:20]));

        (uint64 expectedStartTime, uint64 epochLength, uint256 maxEpochReward) = getEpochInfoByEpochNumber(epoch);
        uint64 expectedEndTime = expectedStartTime + epochLength;

        if (startTime != expectedStartTime || endTime != expectedEndTime) {
            revert StakingRewardsEpochWindowMismatch(epoch, expectedStartTime, startTime, expectedEndTime, endTime);
        }

        uint64 currentTime = uint64(block.timestamp);
        if (currentTime < expectedEndTime) {
            revert StakingRewardsEpochNotReady(epoch, expectedEndTime, currentTime);
        }

        _checkBrevisProof(uint64(block.chainid), proof, circuitOutput, vkHash);
        address lastProver = epochLastProver[epoch];
        uint256 newRewards = 0;
        // The first 20 bytes of circuitOutput is the uint32 epoch, uint64 startTime, uint64 endTime
        for (uint256 offset = 20; offset < circuitOutput.length; offset += 36) {
            address prover = address(bytes20(circuitOutput[offset:offset + 20]));
            // skip empty address placeholders for the rest of array
            if (prover == address(0)) {
                break;
            }
            if (prover <= lastProver) {
                revert StakingRewardsUnsortedProvers(lastProver, prover);
            }
            lastProver = prover;
            uint256 amount = uint128(bytes16(circuitOutput[(offset + 20):(offset + 20 + 16)]));
            epochProverRewards[epoch][prover] = amount;
            newRewards += amount;
            emit RewardsSet(epoch, prover, amount);
        }
        uint256 totalRewardsForEpoch = epochTotalRewards[epoch] + newRewards;
        if (totalRewardsForEpoch > maxEpochReward) {
            revert StakingRewardsExceedsMax(epoch, totalRewardsForEpoch, maxEpochReward);
        }
        epochTotalRewards[epoch] = totalRewardsForEpoch;
        epochLastProver[epoch] = lastProver;
        lastUpdatedEpoch = epoch;
        emit EpochRewardsSet(epoch, newRewards, totalRewardsForEpoch);
    }

    /**
     * @notice Push stored rewards for a list of provers into the staking controller for distribution.
     * @param epoch Epoch number whose rewards are being distributed.
     * @param provers Ordered list of provers to pay out.
     */
    function distributeRewards(uint32 epoch, address[] calldata provers) external onlyRole(REWARD_UPDATER_ROLE) {
        uint256[] memory amounts = new uint256[](provers.length);
        for (uint256 i = 0; i < provers.length; i++) {
            address prover = provers[i];
            uint256 amount = epochProverRewards[epoch][prover];
            if (amount > 0) {
                amounts[i] = amount;
                epochProverRewards[epoch][prover] = 0;
            } else {
                revert StakingRewardsZeroAmount(prover);
            }
        }
        stakingController.addRewards(provers, amounts);
    }

    // =========================================================================
    // OWNER FUNCTIONS
    // =========================================================================

    /**
     * @notice Owner can rescue reward tokens.
     * @param to Recipient address.
     * @param amount Amount of staking token to withdraw.
     */
    function withdrawRewards(address to, uint256 amount) external onlyOwner {
        IERC20(stakingController.stakingToken()).safeTransfer(to, amount);
    }

    /**
     * @notice Update the verification key hash used by Brevis proofs.
     * @param _vkHash New VK hash.
     */
    function setVkHash(bytes32 _vkHash) external onlyOwner {
        vkHash = _vkHash;
    }
}
