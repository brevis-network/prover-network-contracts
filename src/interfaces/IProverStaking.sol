// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

/**
 * @title IProverStaking
 * @notice Interface for the ProverStaking contract
 * @dev Defines all external and public functions for prover staking operations
 */
interface IProverStaking {
    // =========================================================================
    // TYPES & EVENTS
    // =========================================================================

    enum ProverState {
        Null,
        Active,
        Retired,
        Deactivated
    }

    /**
     * @notice Pending minSelfStake update information
     * @dev Tracks a pending decrease request with its details and timing
     */
    struct PendingMinSelfStakeUpdate {
        uint256 newMinSelfStake; // The new minSelfStake value being requested
        uint256 requestedTime; // Timestamp when the update was requested
    }

    // =========================================================================
    // EVENTS
    // =========================================================================

    event ProverInitialized(address indexed prover, uint256 minSelfStake, uint64 commissionRate);
    event ProverRetired(address indexed prover);
    event ProverDeactivated(address indexed prover);
    event ProverReactivated(address indexed prover);
    event ProverUnretired(address indexed prover);
    event MinSelfStakeUpdateRequested(address indexed prover, uint256 newMinSelfStake, uint256 requestTime);
    event MinSelfStakeUpdateCompleted(address indexed prover, uint256 newMinSelfStake);
    event MinSelfStakeUpdateCancelled(address indexed prover);
    event Staked(address indexed prover, address indexed staker, uint256 amount);
    event UnstakeRequested(address indexed prover, address indexed staker, uint256 amount, uint256 unstakeTime);
    event UnstakeCompleted(address indexed prover, address indexed staker, uint256 amount);
    event RewardsAdded(address indexed prover, uint256 amount, uint256 commission);
    event RewardsWithdrawn(address indexed prover, address indexed staker, uint256 stakingRewards, uint256 commission);
    event Slashed(address indexed prover, uint256 percentage, uint256 newScale);
    event CommissionRateUpdated(address indexed prover, uint64 newCommissionRate);
    event UnstakeDelayUpdated(uint256 newDelay);
    event MinSelfStakeDecreaseDelayUpdated(uint256 newDelay);
    event GlobalMinSelfStakeUpdated(uint256 newGlobalMinSelfStake);

    // =========================================================================
    // CONSTANTS
    // =========================================================================

    function COMMISSION_RATE_DENOMINATOR() external view returns (uint256);
    function SLASH_FACTOR_DENOMINATOR() external view returns (uint256);
    function SCALE_FACTOR() external view returns (uint256);
    function MAX_PENDING_UNSTAKES() external view returns (uint256);
    function SLASHER_ROLE() external view returns (bytes32);

    // =========================================================================
    // CONFIGURATION VARIABLES
    // =========================================================================

    function UNSTAKE_DELAY() external view returns (uint256);
    function minSelfStakeDecreaseDelay() external view returns (uint256);
    function brevToken() external view returns (address);
    function globalMinSelfStake() external view returns (uint256);

    // =========================================================================
    // INITIALIZATION
    // =========================================================================

    /**
     * @notice Initialize the staking contract with basic parameters
     * @param _token Address of the ERC20 token used for staking
     * @param _globalMinSelfStake Global minimum self-stake requirement for all provers
     */
    function init(address _token, uint256 _globalMinSelfStake) external;

    // =========================================================================
    // EXTERNAL/PUBLIC STATE-CHANGING FUNCTIONS
    // =========================================================================

    /**
     * @notice Initialize a new prover with staking parameters
     * @param _minSelfStake Minimum self-stake required for accepting delegations
     * @param _commissionRate Commission rate in basis points (0-10000)
     */
    function initProver(uint256 _minSelfStake, uint64 _commissionRate) external;

    /**
     * @notice Stake tokens with a specific prover
     * @param _prover Address of the prover to stake with
     * @param _amount Amount of tokens to stake
     */
    function stake(address _prover, uint256 _amount) external;

    /**
     * @notice Request to unstake tokens from a prover
     * @param _prover Address of the prover to unstake from
     * @param _amount Amount of tokens to unstake
     */
    function requestUnstake(address _prover, uint256 _amount) external;

    /**
     * @notice Complete pending unstake requests for a prover
     * @param _prover Address of the prover to complete unstaking from
     */
    function completeUnstake(address _prover) external;

    /**
     * @notice Add rewards for a specific prover
     * @param _prover Address of the prover to add rewards for
     * @param _amount Amount of rewards to add
     */
    function addRewards(address _prover, uint256 _amount) external;

    /**
     * @notice Withdraw accumulated rewards from a prover
     * @param _prover Address of the prover to withdraw rewards from
     */
    function withdrawRewards(address _prover) external;

    /**
     * @notice Slash a prover for malicious behavior
     * @param _prover Address of the prover to slash
     * @param _percentage Slashing percentage in parts per million
     */
    function slash(address _prover, uint256 _percentage) external;

    /**
     * @notice Retire as a prover (prover-initiated retirement)
     */
    function retireProver() external;

    /**
     * @notice Admin function to force retire a prover
     * @param _prover Address of the prover to retire
     */
    function retireProver(address _prover) external;

    /**
     * @notice Unretire a previously retired prover
     */
    function unretireProver() external;

    /**
     * @notice Update minimum self-stake requirement
     * @param _newMinSelfStake New minimum self-stake amount
     */
    function updateMinSelfStake(uint256 _newMinSelfStake) external;

    /**
     * @notice Complete a pending minimum self-stake update
     */
    function completeMinSelfStakeUpdate() external;

    /**
     * @notice Update commission rate
     * @param _newCommissionRate New commission rate in basis points
     */
    function updateCommissionRate(uint64 _newCommissionRate) external;

    // =========================================================================
    // EXTERNAL/PUBLIC VIEW FUNCTIONS
    // =========================================================================

    /**
     * @notice Get basic prover information
     * @param _prover Address of the prover to query
     * @return state Current state of the prover
     * @return minSelfStake Minimum self-stake required
     * @return commissionRate Commission rate in basis points
     * @return totalStaked Total effective stake from all stakers
     * @return stakersCount Number of active stakers
     */
    function getProverInfo(address _prover)
        external
        view
        returns (
            ProverState state,
            uint256 minSelfStake,
            uint64 commissionRate,
            uint256 totalStaked,
            uint256 stakersCount
        );

    /**
     * @notice Get detailed prover information
     * @param _prover Address of the prover to query
     * @return state Current state of the prover
     * @return minSelfStake Minimum self-stake required
     * @return commissionRate Commission rate in basis points
     * @return totalStaked Total effective stake from all stakers
     * @return selfEffectiveStake Prover's own effective stake amount
     * @return pendingCommission Unclaimed commission rewards
     * @return stakerCount Number of active stakers
     */
    function getProverDetails(address _prover)
        external
        view
        returns (
            ProverState state,
            uint256 minSelfStake,
            uint64 commissionRate,
            uint256 totalStaked,
            uint256 selfEffectiveStake,
            uint256 pendingCommission,
            uint256 stakerCount
        );

    /**
     * @notice Get comprehensive stake information for a specific staker
     * @param _prover Address of the prover
     * @param _staker Address of the staker to query
     * @return amount Current effective stake amount
     * @return totalPendingUnstake Total effective amount in unstaking process
     * @return pendingUnstakeCount Number of pending unstake requests
     * @return pendingRewards Total pending rewards
     */
    function getStakeInfo(address _prover, address _staker)
        external
        view
        returns (uint256 amount, uint256 totalPendingUnstake, uint256 pendingUnstakeCount, uint256 pendingRewards);

    /**
     * @notice Get details about a specific pending unstake request
     * @param _prover Address of the prover
     * @param _staker Address of the staker to query
     * @param _requestIndex Index of the pending unstake request
     * @return amount Effective amount of this unstake request
     * @return rawShares Raw shares of this unstake request
     * @return unstakeTime Timestamp when this unstake was initiated
     * @return isReady Whether this unstake request can be completed
     */
    function getPendingUnstakeInfo(address _prover, address _staker, uint256 _requestIndex)
        external
        view
        returns (uint256 amount, uint256 rawShares, uint256 unstakeTime, bool isReady);

    /**
     * @notice Get the list of all registered provers
     * @return Array of prover addresses
     */
    function getAllProvers() external view returns (address[] memory);

    /**
     * @notice Get the list of currently active provers
     * @return Array of active prover addresses
     */
    function activeProverList() external view returns (address[] memory);

    /**
     * @notice Get the list of all stakers for a specific prover
     * @param _prover Address of the prover to query
     * @return Array of staker addresses
     */
    function getProverStakers(address _prover) external view returns (address[] memory);

    /**
     * @notice Check if a prover is eligible for work assignment
     * @param _prover Address of the prover to check
     * @param _minimumTotalStake Minimum total effective stake required
     * @return eligible True if prover meets all requirements
     * @return currentTotalStake Current total effective stake amount
     */
    function isProverEligible(address _prover, uint256 _minimumTotalStake)
        external
        view
        returns (bool eligible, uint256 currentTotalStake);

    /**
     * @notice Get internal prover state for debugging and monitoring
     * @param _prover Address of the prover to query
     * @return totalRawShares Total raw shares across all stakers
     * @return scale Current scale factor for this prover
     * @return accRewardPerRawShare Accumulated rewards per raw share
     * @return stakersCount Number of active stakers
     */
    function getProverInternals(address _prover)
        external
        view
        returns (uint256 totalRawShares, uint256 scale, uint256 accRewardPerRawShare, uint256 stakersCount);

    /**
     * @notice Get internal stake state for debugging and monitoring
     * @param _prover Address of the prover
     * @param _staker Address of the staker to query
     * @return rawShares Raw shares owned by the staker
     * @return rewardDebt Current reward debt for calculation
     * @return pendingRewards Accumulated but unclaimed rewards
     * @return pendingUnstakeCount Number of pending unstake requests
     */
    function getStakeInternals(address _prover, address _staker)
        external
        view
        returns (uint256 rawShares, uint256 rewardDebt, uint256 pendingRewards, uint256 pendingUnstakeCount);

    /**
     * @notice Get pending minimum self-stake update information
     * @param _prover Address of the prover to query
     * @return hasPendingUpdate Whether there's a pending update
     * @return pendingUpdate The pending update details
     */
    function getPendingMinSelfStakeUpdate(address _prover)
        external
        view
        returns (bool hasPendingUpdate, PendingMinSelfStakeUpdate memory pendingUpdate);

    // =========================================================================
    // ADMIN FUNCTIONS
    // =========================================================================

    /**
     * @notice Set the unstaking delay period
     * @param _newDelay New delay period in seconds
     */
    function setUnstakeDelay(uint256 _newDelay) external;

    /**
     * @notice Set the minimum self-stake decrease delay period
     * @param _newDelay New delay period in seconds
     */
    function setMinSelfStakeDecreaseDelay(uint256 _newDelay) external;

    /**
     * @notice Set the global minimum self-stake requirement
     * @param _newGlobalMinSelfStake New global minimum self-stake amount
     */
    function setGlobalMinSelfStake(uint256 _newGlobalMinSelfStake) external;

    /**
     * @notice Deactivate a malicious or problematic prover
     * @param _prover Address of the prover to deactivate
     */
    function deactivateProver(address _prover) external;

    /**
     * @notice Reactivate a deactivated prover
     * @param _prover Address of the prover to reactivate
     */
    function reactivateProver(address _prover) external;
}
