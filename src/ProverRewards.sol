// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./access/AccessControl.sol";
import "./interfaces/IProverStaking.sol";

// =============================================================
// Custom Errors
// =============================================================

error RewardsProverNotRegistered();
error NoRewards();
error RewardsInvalidCommission();
error RewardsZeroAmount();

/**
 * @title ProverRewards
 * @notice Manages reward distribution and withdrawal for provers and stakers
 * @dev This contract handles:
 *      - Reward distribution with commission to provers
 *      - Reward withdrawal for stakers and provers
 *      - Commission rate management
 *      - Dust accumulation handling
 */
contract ProverRewards is ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;

    // =========================================================================
    // CONSTANTS
    // =========================================================================

    // Commission rates are expressed in basis points (1 bp = 0.01%)
    uint256 public constant COMMISSION_RATE_DENOMINATOR = 10000;

    // Base scale factor for mathematical precision in reward calculations
    uint256 public constant SCALE_FACTOR = 1e18;

    // =========================================================================
    // STORAGE
    // =========================================================================

    // External contracts
    IProverStaking public immutable proverStaking;
    address public immutable rewardToken;

    // Global pool of reward dust from rounding errors
    uint256 public dustPool;

    // Prover-specific reward data
    mapping(address => ProverRewardInfo) internal proverRewards;

    // Staker-specific reward data: prover => staker => RewardInfo
    mapping(address => mapping(address => StakerRewardInfo)) internal stakerRewards;

    /**
     * @notice Reward information for each prover
     */
    struct ProverRewardInfo {
        uint64 commissionRate; // Commission rate in basis points (0-10000)
        uint256 accRewardPerRawShare; // Accumulated rewards per raw share (scaled by SCALE_FACTOR)
        uint256 pendingCommission; // Unclaimed commission rewards for the prover
    }

    /**
     * @notice Reward information for each staker-prover pair
     */
    struct StakerRewardInfo {
        uint256 rewardDebt; // Tracks already-accounted rewards to prevent double-claiming
        uint256 pendingRewards; // Accumulated but unclaimed rewards
    }

    // =========================================================================
    // EVENTS
    // =========================================================================

    event CommissionRateUpdated(address indexed prover, uint64 oldCommissionRate, uint64 newCommissionRate);
    event RewardsAdded(address indexed prover, uint256 amount, uint256 commission, uint256 distributed);
    event RewardsWithdrawn(address indexed staker, address indexed prover, uint256 amount);
    event DustPoolWithdrawn(address indexed to, uint256 amount);

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    /**
     * @notice Constructor
     * @param _proverStaking Address of the ProverStaking contract
     * @param _rewardToken Address of the reward token (can be same as staking token)
     */
    constructor(address _proverStaking, address _rewardToken) {
        proverStaking = IProverStaking(_proverStaking);
        rewardToken = _rewardToken;
    }

    /**
     * @notice Initialize the rewards contract for upgradeable deployment
     * @param _proverStaking Address of the ProverStaking contract
     * @param _rewardToken Address of the reward token
     */
    function init(address _proverStaking, address _rewardToken) external {
        // Implementation for upgradeable version if needed
        initOwner();
    }

    // =========================================================================
    // EXTERNAL FUNCTIONS (STATE-CHANGING)
    // =========================================================================

    /**
     * @notice Initialize reward tracking for a new prover
     * @dev Called by ProverStaking when a prover is initialized
     * @param _prover Address of the prover
     * @param _commissionRate Initial commission rate in basis points
     */
    function initProverRewards(address _prover, uint64 _commissionRate) external {
        // Only ProverStaking contract can initialize prover rewards
        require(msg.sender == address(proverStaking), "Only staking contract");
        if (_commissionRate > COMMISSION_RATE_DENOMINATOR) revert RewardsInvalidCommission();

        ProverRewardInfo storage rewardInfo = proverRewards[_prover];
        rewardInfo.commissionRate = _commissionRate;
        // accRewardPerRawShare and pendingCommission start at 0
    }

    /**
     * @notice Update commission rate for a prover
     * @param _newCommissionRate New commission rate in basis points (0-10000, where 10000 = 100%)
     */
    function updateCommissionRate(uint64 _newCommissionRate) external {
        // Verify prover is registered in staking contract
        if (!proverStaking.isProverRegistered(msg.sender)) revert RewardsProverNotRegistered();
        if (_newCommissionRate > COMMISSION_RATE_DENOMINATOR) revert RewardsInvalidCommission();

        ProverRewardInfo storage rewardInfo = proverRewards[msg.sender];
        uint64 oldCommissionRate = rewardInfo.commissionRate;

        // Update commission rate immediately
        rewardInfo.commissionRate = _newCommissionRate;

        emit CommissionRateUpdated(msg.sender, oldCommissionRate, _newCommissionRate);
    }

    /**
     * @notice Distribute rewards to a prover and their stakers
     * @dev Reward Distribution Algorithm:
     *      1. Transfer tokens from sender to this contract
     *      2. Calculate commission for prover (commissionRate * totalRewards)
     *      3. Remaining rewards go to stakers proportionally
     *      4. Update accRewardPerRawShare for stakers using: newAcc = oldAcc + (stakersReward * SCALE_FACTOR) / totalRawShares
     *      5. If no stakers exist, prover gets all rewards as commission
     * @param _prover The address of the prover receiving rewards
     * @param _amount Total amount of tokens to distribute as rewards
     */
    function addRewards(address _prover, uint256 _amount) external nonReentrant {
        if (!proverStaking.isProverRegistered(_prover)) revert RewardsProverNotRegistered();
        if (_amount == 0) return;

        // Transfer tokens from sender to this contract
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), _amount);

        ProverRewardInfo storage rewardInfo = proverRewards[_prover];

        // === COMMISSION CALCULATION ===
        // Calculate commission for prover (always paid regardless of staker count)
        uint256 commission = (_amount * rewardInfo.commissionRate) / COMMISSION_RATE_DENOMINATOR;
        uint256 stakersReward = _amount - commission;

        // Always credit commission to prover
        rewardInfo.pendingCommission += commission;

        // Get total raw shares from staking contract
        uint256 totalRawShares = proverStaking.getTotalRawShares(_prover);

        if (totalRawShares == 0) {
            // === NO STAKERS CASE ===
            // No stakers exist, prover gets all remaining rewards as commission
            rewardInfo.pendingCommission += stakersReward;
            emit RewardsAdded(_prover, _amount, _amount, 0);
        } else {
            // === STAKER REWARD DISTRIBUTION ===
            // Distribute remaining rewards proportionally to all stakers (including prover if self-staked)
            // Calculate accumulator delta and ensure dimensional consistency for dust accounting
            uint256 deltaAcc = (stakersReward * SCALE_FACTOR) / totalRawShares;
            uint256 distributed = (deltaAcc * totalRawShares) / SCALE_FACTOR; // tokens actually distributed
            uint256 dust = stakersReward - distributed; // tokens

            rewardInfo.accRewardPerRawShare += deltaAcc;

            // Add dust from rounding errors to dust pool (in token units)
            if (dust > 0) {
                dustPool += dust;
            }

            emit RewardsAdded(_prover, _amount, commission, stakersReward);
        }
    }

    /**
     * @notice Settle proof rewards for a staker before their shares change
     * @dev Called by ProverStaking before stake/unstake operations
     * @param _prover Address of the prover
     * @param _staker Address of the staker
     * @param _rawShares Current raw shares of the staker
     * @return accRewardPerRawShare Current accumulated reward per raw share
     */
    function settleStakerRewards(address _prover, address _staker, uint256 _rawShares)
        external
        returns (uint256 accRewardPerRawShare)
    {
        // Only ProverStaking contract can settle rewards
        require(msg.sender == address(proverStaking), "Only staking contract");

        ProverRewardInfo storage rewardInfo = proverRewards[_prover];
        StakerRewardInfo storage stakerInfo = stakerRewards[_prover][_staker];

        accRewardPerRawShare = rewardInfo.accRewardPerRawShare;

        if (_rawShares == 0) return accRewardPerRawShare;

        uint256 accrued = (_rawShares * accRewardPerRawShare) / SCALE_FACTOR;
        uint256 prevDebt = stakerInfo.rewardDebt;

        if (accrued > prevDebt) {
            stakerInfo.pendingRewards += (accrued - prevDebt);
        }

        // Note: rewardDebt will be updated by updateStakerRewardDebt after shares change
        return accRewardPerRawShare;
    }

    /**
     * @notice Update staker's reward debt after share changes
     * @dev Called by ProverStaking after stake/unstake operations
     * @param _prover Address of the prover
     * @param _staker Address of the staker
     * @param _newRawShares New raw shares of the staker
     */
    function updateStakerRewardDebt(address _prover, address _staker, uint256 _newRawShares) external {
        // Only ProverStaking contract can update reward debt
        require(msg.sender == address(proverStaking), "Only staking contract");

        ProverRewardInfo storage rewardInfo = proverRewards[_prover];
        StakerRewardInfo storage stakerInfo = stakerRewards[_prover][_staker];

        // Update reward debt based on new raw shares to prevent double-claiming
        stakerInfo.rewardDebt = (_newRawShares * rewardInfo.accRewardPerRawShare) / SCALE_FACTOR;
    }

    /**
     * @notice Withdraw accumulated rewards for a staker or prover
     * @param _prover The address of the prover to withdraw rewards from
     */
    function withdrawRewards(address _prover) external nonReentrant {
        if (!proverStaking.isProverRegistered(_prover)) revert RewardsProverNotRegistered();

        ProverRewardInfo storage rewardInfo = proverRewards[_prover];
        StakerRewardInfo storage stakerInfo = stakerRewards[_prover][msg.sender];

        uint256 payout = 0;

        // === STAKING REWARDS UPDATE ===
        // Get current raw shares from staking contract
        uint256 currentRawShares = proverStaking.getStakerRawShares(_prover, msg.sender);

        if (currentRawShares > 0) {
            // Calculate total accrued proof rewards for this staker
            uint256 accrued = (currentRawShares * rewardInfo.accRewardPerRawShare) / SCALE_FACTOR;
            // Calculate new proof rewards since last claim
            uint256 delta = accrued - stakerInfo.rewardDebt;
            if (delta > 0) {
                stakerInfo.pendingRewards += delta;
            }
            // Update reward debt to prevent double-claiming
            stakerInfo.rewardDebt = accrued;
        }

        // === PAYOUT CALCULATION ===
        // Add accumulated staking rewards to payout
        if (stakerInfo.pendingRewards > 0) {
            payout += stakerInfo.pendingRewards;
            stakerInfo.pendingRewards = 0;
        }

        // Add commission if this is the prover
        if (msg.sender == _prover) {
            if (rewardInfo.pendingCommission > 0) {
                payout += rewardInfo.pendingCommission;
                rewardInfo.pendingCommission = 0;
            }
        }

        if (payout == 0) revert NoRewards();

        // Transfer rewards to caller
        IERC20(rewardToken).safeTransfer(msg.sender, payout);

        emit RewardsWithdrawn(msg.sender, _prover, payout);
    }

    // =========================================================================
    // EXTERNAL FUNCTIONS (ADMIN ONLY)
    // =========================================================================

    /**
     * @notice Admin function to withdraw accumulated dust from rounding errors
     * @param _to The address to send the dust to
     * @param _amount The amount of dust to withdraw
     */
    function withdrawFromDustPool(address _to, uint256 _amount) external onlyOwner {
        require(_to != address(0), "Invalid address");
        if (_amount == 0) revert RewardsZeroAmount();
        require(_amount <= dustPool, "Insufficient dust pool");

        // Update dust pool accounting
        dustPool -= _amount;

        // Transfer tokens to recipient
        IERC20(rewardToken).safeTransfer(_to, _amount);

        emit DustPoolWithdrawn(_to, _amount);
    }

    // =========================================================================
    // EXTERNAL VIEW FUNCTIONS
    // =========================================================================

    /**
     * @notice Get prover reward information
     * @param _prover Address of the prover to query
     * @return commissionRate Commission rate in basis points
     * @return pendingCommission Unclaimed commission rewards
     * @return accRewardPerRawShare Accumulated rewards per raw share
     */
    function getProverRewardInfo(address _prover)
        external
        view
        returns (uint64 commissionRate, uint256 pendingCommission, uint256 accRewardPerRawShare)
    {
        ProverRewardInfo storage rewardInfo = proverRewards[_prover];
        return (rewardInfo.commissionRate, rewardInfo.pendingCommission, rewardInfo.accRewardPerRawShare);
    }

    /**
     * @notice Get staker reward information
     * @param _prover Address of the prover
     * @param _staker Address of the staker
     * @return pendingRewards Total pending rewards for the staker
     * @return rewardDebt Current reward debt
     */
    function getStakerRewardInfo(address _prover, address _staker)
        external
        view
        returns (uint256 pendingRewards, uint256 rewardDebt)
    {
        StakerRewardInfo storage stakerInfo = stakerRewards[_prover][_staker];

        // Calculate current pending rewards including accrued rewards
        uint256 totalPendingRewards = stakerInfo.pendingRewards;

        // Get current raw shares from staking contract
        uint256 currentRawShares = proverStaking.getStakerRawShares(_prover, _staker);

        if (currentRawShares > 0) {
            ProverRewardInfo storage rewardInfo = proverRewards[_prover];
            uint256 accrued = (currentRawShares * rewardInfo.accRewardPerRawShare) / SCALE_FACTOR;
            if (accrued >= stakerInfo.rewardDebt) {
                totalPendingRewards += (accrued - stakerInfo.rewardDebt);
            }
        }

        return (totalPendingRewards, stakerInfo.rewardDebt);
    }

    /**
     * @notice Calculate total pending rewards for a staker including commission if applicable
     * @param _prover Address of the prover
     * @param _staker Address of the staker
     * @return Total pending rewards including commission
     */
    function calculateTotalPendingRewards(address _prover, address _staker) external view returns (uint256) {
        (uint256 pendingRewards,) = this.getStakerRewardInfo(_prover, _staker);

        // Add commission if this is the prover
        if (_staker == _prover) {
            ProverRewardInfo storage rewardInfo = proverRewards[_prover];
            pendingRewards += rewardInfo.pendingCommission;
        }

        return pendingRewards;
    }

    /**
     * @notice Get dust pool balance
     * @return Current dust pool balance
     */
    function getDustPool() external view returns (uint256) {
        return dustPool;
    }
}
