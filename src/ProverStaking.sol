// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./access/AccessControl.sol";

/**
 * @title ProverStaking
 * @notice A staking contract that manages proof nodes and their delegated stakes
 * @dev This contract implements a delegation-based staking system where:
 *      - Provers can initialize themselves with minimum self-stake requirements
 *      - Users can delegate stakes to active provers
 *      - Rewards are distributed proportionally with commission to provers
 *      - Slashing affects all stakes proportionally through a global scale factor
 *      - Unstaking has a configurable delay period for security
 */
contract ProverStaking is ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // =========================================================================
    // TYPES & CONSTANTS
    // =========================================================================

    enum ProverState {
        Null,
        Active,
        Retired,
        Deactivated
    }

    // Commission rates are expressed in basis points (1 bp = 0.01%)
    uint256 public constant COMMISSION_RATE_DENOMINATOR = 10000;

    // Slashing percentages are expressed in parts per million for higher precision
    uint256 public constant SLASH_FACTOR_DENOMINATOR = 1e6;

    // Maximum single slash percentage (50% = 500,000 parts per million)
    uint256 public constant MAX_SLASH_PERCENTAGE = 500000; // 50%

    // Base scale factor for mathematical precision in reward calculations
    uint256 public constant SCALE_FACTOR = 1e18;

    // Soft / operational threshold (20% = 2e17): crossing this DEACTIVATION_SCALE deactivates the prover,
    // but further slashing is still allowed down to the MIN_SCALE_FLOOR (hard floor). Once a slash
    // would push scale below the hard floor (10%), the slash reverts to avoid pathological
    // raw share inflation and precision loss.
    uint256 public constant DEACTIVATION_SCALE = 2e17; // 20% (soft threshold – triggers deactivation)
    uint256 public constant MIN_SCALE_FLOOR = DEACTIVATION_SCALE / 2; // 10% (hard invariant – cannot be crossed)

    // Maximum number of pending unstake requests per staker per prover
    uint256 public constant MAX_PENDING_UNSTAKES = 10;

    // Access control role for slashing operations
    // 12b42e8a160f6064dc959c6f251e3af0750ad213dbecf573b4710d67d6c28e39
    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");

    /**
     * @notice Core information for each prover in the network
     * @dev Uses a dual-share system: raw shares (pre-slash) and effective shares (post-slash)
     *      Raw shares remain constant until stake changes, while effective value fluctuates with slashing
     */
    struct ProverInfo {
        ProverState state; // Current state of the prover (Null, Active, Retired)
        uint64 commissionRate; // Commission rate in basis points (0-10000, where 10000 = 100%)
        uint256 minSelfStake; // Minimum self-stake required to accept delegations
        // === SHARE TRACKING ===
        uint256 totalRawShares; // Total raw shares across all stakers (invariant to slashing)
        uint256 scale; // Global scale factor for this prover (decreases with slashing)
        // === REWARD DISTRIBUTION ===
        uint256 accRewardPerRawShare; // Accumulated rewards per raw share (scaled by SCALE_FACTOR)
        uint256 pendingCommission; // Unclaimed commission rewards for the prover
        // === STREAMING EMISSION TRACKING ===
        uint256 rewardDebtEff; // Effective stake × globalAccPerEff at last settlement (prevents double-claiming)
        // === MIN SELF STAKE UPDATE ===
        PendingMinSelfStakeUpdate pendingMinSelfStakeUpdate; // Pending minSelfStake decrease (empty if no pending update)
        // === STAKER DATA ===
        mapping(address => StakeInfo) stakes; // Individual stake information per staker
        EnumerableSet.AddressSet stakers; // Set of all stakers for this prover
    }

    /**
     * @notice Individual stake information for each staker-prover pair
     * @dev Tracks both active stakes and pending unstake operations
     */
    struct StakeInfo {
        uint256 rawShares; // Raw shares owned (before applying scale factor)
        uint256 rewardDebt; // Tracks already-accounted rewards to prevent double-claiming
        uint256 pendingRewards; // Accumulated but unclaimed rewards (both proof and streaming)
        // === UNSTAKING DATA ===
        PendingUnstake[] pendingUnstakes; // Array of pending unstake requests
    }

    /**
     * @notice Individual pending unstake request
     * @dev Tracks a single unstake request with its amount and timing
     */
    struct PendingUnstake {
        uint256 rawShares; // Raw shares in this unstake request
        uint256 unstakeTime; // Timestamp when this unstake was initiated
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
    // STORAGE
    // =========================================================================

    // Configurable unstaking delay period (default: 7 days, max: 30 days)
    uint256 public UNSTAKE_DELAY = 7 days;

    // Configurable delay for decreasing minSelfStake (default: 7 days, max: 30 days)
    uint256 public minSelfStakeDecreaseDelay = 7 days;

    address public brevToken; // ERC20 token used for both staking and rewards

    // Global minimum self-stake requirement for all provers
    uint256 public globalMinSelfStake;

    // Global pool of slashed tokens available for treasury withdrawal
    uint256 public treasuryPool;

    mapping(address => ProverInfo) internal provers; // Prover address -> ProverInfo
    address[] public proverList; // Enumerable list of all registered provers
    EnumerableSet.AddressSet activeProvers; // Set of currently active provers

    // === GLOBAL STREAMING REWARDS ===
    uint256 public globalRatePerSec; // Tokens per second distributed globally based on effective stake
    uint256 public globalEmissionBudget; // Total tokens available for streaming distribution
    uint256 public globalAccPerEff; // Global accumulator: total rewards distributed per unit of effective stake (scaled)
    uint256 public lastGlobalTime; // Timestamp of last global streaming update
    uint256 public totalEffectiveActive; // Total effective stake across all active provers (cached)

    // =========================================================================
    // EVENTS
    // =========================================================================

    // Prover lifecycle events
    event ProverInitialized(address indexed prover, uint256 minSelfStake, uint64 commissionRate);
    event ProverDeactivated(address indexed prover);
    event ProverRetired(address indexed prover);
    event ProverUnretired(address indexed prover);
    event ProverReactivated(address indexed prover);

    // Prover configuration events
    event MinSelfStakeUpdateRequested(address indexed prover, uint256 newMinSelfStake, uint256 requestTime);
    event MinSelfStakeUpdated(address indexed prover, uint256 newMinSelfStake);
    event CommissionRateUpdated(address indexed prover, uint64 oldCommissionRate, uint64 newCommissionRate);

    // Staking lifecycle events
    event Staked(address indexed staker, address indexed prover, uint256 amount, uint256 mintedShares);
    event UnstakeRequested(address indexed staker, address indexed prover, uint256 amount, uint256 rawSharesToUnstake);
    event UnstakeCompleted(address indexed staker, address indexed prover, uint256 amount);

    // Reward and slashing events
    event RewardsAdded(address indexed prover, uint256 amount, uint256 commission, uint256 distributed);
    event RewardsWithdrawn(address indexed staker, address indexed prover, uint256 amount);
    event ProverSlashed(address indexed prover, uint256 percentage, uint256 totalSlashed);
    event TreasuryPoolWithdrawn(address indexed to, uint256 amount);

    // Administrative events
    event UnstakeDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event MinSelfStakeDecreaseDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event GlobalMinSelfStakeUpdated(uint256 oldMinStake, uint256 newMinStake);

    // Emission events
    event GlobalRateUpdated(uint256 oldRate, uint256 newRate);
    event StreamingRewardsSettled(address indexed prover, uint256 totalOwed, uint256 commission, uint256 distributed);
    event StreamingRewardsWithdrawn(address indexed staker, address indexed prover, uint256 amount);
    event StreamingRateUpdated(uint256 oldRate, uint256 newRate);
    event StreamingBudgetAdded(uint256 amount, uint256 newTotal);

    // =========================================================================
    // CONSTRUCTOR & INITIALIZATION
    // =========================================================================

    /**
     * @notice Constructor for direct deployment (non-upgradeable)
     * @dev Initializes the contract with token and global minimum self-stake.
     *      For upgradeable deployment, use the no-arg constructor and call init() instead.
     * @param _token ERC20 token address for staking and rewards
     * @param _globalMinSelfStake Global minimum self-stake requirement for all provers
     */
    constructor(address _token, uint256 _globalMinSelfStake) {
        _init(_token, _globalMinSelfStake);
        // Note: Ownable constructor automatically sets msg.sender as owner
    }

    /**
     * @notice Initialize the staking contract for upgradeable deployment
     * @dev This function sets up the contract state after deployment.
     * @param _token ERC20 token address used for both staking and rewards
     * @param _globalMinSelfStake Global minimum self-stake requirement for all provers
     */
    function init(address _token, uint256 _globalMinSelfStake) external {
        _init(_token, _globalMinSelfStake);
        initOwner();
    }

    /**
     * @notice Initialize the staking contract for upgradeable deployment
     * /**
     * @notice Internal initialization logic shared by constructor and init function
     * @param _token ERC20 token address for staking and rewards
     * @param _globalMinSelfStake Global minimum self-stake requirement for all provers
     */
    function _init(address _token, uint256 _globalMinSelfStake) private {
        require(_globalMinSelfStake > 0, "Global min self stake must be positive");
        brevToken = _token;
        globalMinSelfStake = _globalMinSelfStake;
        lastGlobalTime = block.timestamp;
    }

    // =========================================================================
    // EXTERNAL FUNCTIONS (STATE-CHANGING)
    // =========================================================================

    /**
     * @notice Initialize a new prover and self-stake with a minimum amount
     * @param _minSelfStake Minimum tokens the prover must self-stake to accept delegations
     * @param _commissionRate Commission percentage in basis points (0-10000)
     */
    function initProver(uint256 _minSelfStake, uint64 _commissionRate) external {
        require(provers[msg.sender].state == ProverState.Null, "Prover already initialized");
        require(_commissionRate <= COMMISSION_RATE_DENOMINATOR, "Invalid commission rate");
        require(_minSelfStake >= globalMinSelfStake, "Below global minimum self stake");

        ProverInfo storage prover = provers[msg.sender];
        prover.state = ProverState.Active;
        prover.minSelfStake = _minSelfStake;
        prover.commissionRate = _commissionRate;
        prover.scale = SCALE_FACTOR; // Initialize scale to 1.0 (no slashing yet)

        // Register prover in global mappings
        proverList.push(msg.sender);
        activeProvers.add(msg.sender);

        // Prover must stake at least the minimum self stake to accept delegations
        stake(msg.sender, _minSelfStake);

        emit ProverInitialized(msg.sender, _minSelfStake, _commissionRate);
    }

    /**
     * @notice Delegate stake to a prover
     * @dev Algorithm:
     *      1. Validate prover meets minimum self-stake for new delegations
     *      2. Transfer tokens from staker to contract
     *      3. Convert amount to raw shares using current scale
     *      4. Update reward accounting (settle pending rewards before share change)
     *      5. Mint new raw shares and update totals
     *      6. Update reward debt to current accumulated rewards
     *
     *      Reward Accounting Algorithm:
     *      - pendingRewards += (currentShares * accRewardPerRawShare / SCALE_FACTOR) - rewardDebt
     *      - rewardDebt = newShares * accRewardPerRawShare / SCALE_FACTOR
     *
     *      Self-staking is always allowed regardless of prover state
     * @param _prover Address of the prover to stake with
     * @param _amount Amount of tokens to delegate
     */
    function stake(address _prover, uint256 _amount) public nonReentrant {
        require(_amount > 0, "Amount must be positive");
        require(provers[_prover].state != ProverState.Null, "Unknown prover");

        ProverInfo storage prover = provers[_prover];
        StakeInfo storage stakeInfo = prover.stakes[msg.sender];

        // Delegation-specific validations (only apply to external delegations, not self-staking)
        if (msg.sender != _prover) {
            // Only allow delegation to active provers, but always allow self-staking
            require(prover.state == ProverState.Active, "Prover not active");

            // Gate delegations when prover is below min self-stake
            // This ensures prover has skin in the game before accepting external delegations
            uint256 selfEffective = _effectiveAmount(_prover, _selfRawShares(_prover));
            require(selfEffective >= prover.minSelfStake, "Prover below min self-stake");
        }

        // Transfer tokens from staker to contract (fail early if insufficient balance/allowance)
        IERC20(brevToken).safeTransferFrom(msg.sender, address(this), _amount);

        // Calculate old effective stake for update tracking
        uint256 oldEffectiveStake = _getTotalEffectiveStake(_prover);

        // Update global streaming and settle prover before changing stake (piggyback principle)
        _updateGlobalStreaming();
        _settleProverStreaming(_prover);

        // Convert amount to raw shares at current scale
        // This ensures fair share allocation regardless of slashing history
        uint256 newRawShares = _rawSharesFromAmount(_prover, _amount);

        // If this is a new staker, add them to the stakers set
        if (stakeInfo.rawShares == 0) {
            prover.stakers.add(msg.sender);
        }

        // === REWARD ACCOUNTING ===
        // Update pending rewards before changing stake to ensure accurate reward calculation
        uint256 accRewardPerRawShare = prover.accRewardPerRawShare;
        if (stakeInfo.rawShares > 0) {
            // Calculate accrued proof rewards since last update
            uint256 accrued = (stakeInfo.rawShares * accRewardPerRawShare) / SCALE_FACTOR;
            uint256 delta = accrued - stakeInfo.rewardDebt;
            if (delta > 0) {
                stakeInfo.pendingRewards += delta;
            }
        }

        // === SHARE MINTING ===
        // Update stake amount (in raw shares) - follows CEI (Checks-Effects-Interactions) pattern
        stakeInfo.rawShares += newRawShares;
        prover.totalRawShares += newRawShares;

        // Update reward debt based on new raw shares to prevent double-claiming
        stakeInfo.rewardDebt = (stakeInfo.rawShares * accRewardPerRawShare) / SCALE_FACTOR;

        // Update total effective active stake for streaming calculations
        uint256 newEffectiveStake = _getTotalEffectiveStake(_prover);

        // === STREAMING DEBT RESET ===
        // Reset streaming debt to prevent accounting drift with new effective stake
        if (prover.state == ProverState.Active && newEffectiveStake > 0) {
            prover.rewardDebtEff = (newEffectiveStake * globalAccPerEff) / SCALE_FACTOR;
        }

        _updateTotalEffectiveActive(_prover, oldEffectiveStake, newEffectiveStake);

        emit Staked(msg.sender, _prover, _amount, newRawShares);
    }

    /**
     * @notice Request unstaking for a portion of staked tokens
     * @dev Algorithm:
     *      1. Validate unstake amount
     *      2. Enforce minimum self-stake requirements for provers
     *      3. Update reward accounting before share changes
     *      4. Burn raw shares from active stake
     *      5. Add new pending unstake request to queue
     *      6. Update staker tracking if stake becomes zero
     *
     *      Security Features:
     *      - Multiple unstake requests allowed per staker (up to MAX_PENDING_UNSTAKES)
     *      - Provers must maintain minimum self-stake unless exiting completely
     *      - Shares subject to slashing during unstaking period
     *      - Works for both active and retired provers (allows exit after deactivation)
     *
     * @param _prover Address of the prover to unstake from
     * @param _amount Amount of tokens to unstake (effective amount)
     */
    function requestUnstake(address _prover, uint256 _amount) public {
        require(_amount > 0, "Amount must be positive");
        require(provers[_prover].state != ProverState.Null, "Unknown prover");

        ProverInfo storage prover = provers[_prover];
        StakeInfo storage stakeInfo = prover.stakes[msg.sender];

        // Convert amount to raw shares for internal accounting
        uint256 rawSharesToUnstake = _rawSharesFromAmount(_prover, _amount);
        require(stakeInfo.rawShares >= rawSharesToUnstake, "Insufficient stake");
        require(stakeInfo.pendingUnstakes.length < MAX_PENDING_UNSTAKES, "Too many pending unstakes");

        // Calculate old effective stake for update tracking
        uint256 oldEffectiveStake = _getTotalEffectiveStake(_prover);

        // Update global streaming rewards before changing stake (piggyback principle)
        if (globalRatePerSec > 0) {
            _updateGlobalStreaming();
            _settleProverStreaming(_prover);
        }

        // === PROVER SELF-STAKE VALIDATION ===
        // For prover's self stake, ensure minimum self stake is maintained
        // EXCEPTION: Allow going to zero (complete exit) even if below minimum
        if (msg.sender == _prover) {
            uint256 currentSelfRawShares = _selfRawShares(_prover);
            require(currentSelfRawShares >= rawSharesToUnstake, "Self-stake underflow");
            uint256 remainingEffective = _effectiveAmount(_prover, currentSelfRawShares - rawSharesToUnstake);

            // Allow going below minSelfStake only if it results in zero self-stake (complete exit)
            if (remainingEffective > 0) {
                require(remainingEffective >= prover.minSelfStake, "Below minimum self stake");
            }
        }

        // === REWARD ACCOUNTING ===
        // Update pending rewards before changing stake
        uint256 accRewardPerRawShare = prover.accRewardPerRawShare;
        if (stakeInfo.rawShares > 0) {
            // Update proof rewards
            uint256 accrued = (stakeInfo.rawShares * accRewardPerRawShare) / SCALE_FACTOR;
            uint256 delta = accrued - stakeInfo.rewardDebt;
            if (delta > 0) {
                stakeInfo.pendingRewards += delta;
            }
        }

        // === SHARE BURNING ===
        // Update stake amount (in raw shares) - CEI ordering
        stakeInfo.rawShares -= rawSharesToUnstake;
        prover.totalRawShares -= rawSharesToUnstake;

        // If staker's active stake is now zero, remove them from the stakers set
        if (stakeInfo.rawShares == 0) {
            prover.stakers.remove(msg.sender);
        }

        // === UNSTAKING QUEUE ===
        // Add new pending unstake request
        stakeInfo.pendingUnstakes.push(PendingUnstake({rawShares: rawSharesToUnstake, unstakeTime: block.timestamp}));

        // Update reward debt based on new raw shares
        stakeInfo.rewardDebt = (stakeInfo.rawShares * accRewardPerRawShare) / SCALE_FACTOR;

        // Update total effective active stake for streaming calculations
        uint256 newEffectiveStake = _getTotalEffectiveStake(_prover);

        // === STREAMING DEBT RESET ===
        // Reset streaming debt to prevent accounting drift with new effective stake
        if (prover.state == ProverState.Active && newEffectiveStake > 0) {
            prover.rewardDebtEff = (newEffectiveStake * globalAccPerEff) / SCALE_FACTOR;
        }

        _updateTotalEffectiveActive(_prover, oldEffectiveStake, newEffectiveStake);

        emit UnstakeRequested(msg.sender, _prover, _amount, rawSharesToUnstake);
    }

    /**
     * @notice Request unstaking for all staked tokens with a prover
     * @dev Convenience function to avoid rounding surprises when trying to unstake everything.
     *      Calculates the current effective amount and delegates to requestUnstake for consistency.
     * @param _prover Address of the prover to unstake all tokens from
     */
    function requestUnstakeAll(address _prover) external {
        require(provers[_prover].state != ProverState.Null, "Unknown prover");

        ProverInfo storage prover = provers[_prover];
        StakeInfo storage stakeInfo = prover.stakes[msg.sender];

        require(stakeInfo.rawShares > 0, "No active stake to unstake");

        // Calculate current effective amount for all raw shares
        uint256 effectiveAmount = _effectiveAmount(_prover, stakeInfo.rawShares);

        // Delegate to requestUnstake to handle all the logic consistently
        requestUnstake(_prover, effectiveAmount);
    }

    /**
     * @notice Complete all eligible unstaking requests and withdraw tokens
     * @dev Algorithm:
     *      1. Iterate through all pending unstake requests
     *      2. Identify requests that meet the delay requirement
     *      3. Calculate total effective amount across all eligible requests
     *      4. Remove completed requests from the queue
     *      5. Transfer total amount to staker
     *
     *      Security Features:
     *      - Time-based protection with configurable delay
     *      - Shares remain subject to slashing until completion
     *      - Exchange rate protection (shares worth may change)
     *      - Processes all eligible requests in one transaction for efficiency
     *
     * @param _prover Address of the prover to complete unstaking from
     */
    function completeUnstake(address _prover) external nonReentrant {
        StakeInfo storage stakeInfo = provers[_prover].stakes[msg.sender];

        require(stakeInfo.pendingUnstakes.length > 0, "No pending unstakes");

        uint256 totalEffectiveAmount = 0;
        uint256 completedCount = 0;

        // Process unstakes from the beginning (chronological order)
        // Once we hit a request that's not ready, all following requests will also not be ready
        for (uint256 i = 0; i < stakeInfo.pendingUnstakes.length; i++) {
            PendingUnstake storage unstakeRequest = stakeInfo.pendingUnstakes[i];

            // Check if this request meets the delay requirement
            if (block.timestamp >= unstakeRequest.unstakeTime + UNSTAKE_DELAY) {
                // Calculate effective amount for this request
                uint256 effectiveAmount = _effectiveAmount(_prover, unstakeRequest.rawShares);
                totalEffectiveAmount += effectiveAmount;
                completedCount++;
            } else {
                // This request is not ready, and neither will any subsequent ones
                break;
            }
        }

        // Remove all completed requests from the beginning of the array
        if (completedCount > 0) {
            // Shift remaining elements to the front
            for (uint256 i = 0; i < stakeInfo.pendingUnstakes.length - completedCount; i++) {
                stakeInfo.pendingUnstakes[i] = stakeInfo.pendingUnstakes[i + completedCount];
            }
            // Remove the completed elements from the end
            for (uint256 i = 0; i < completedCount; i++) {
                stakeInfo.pendingUnstakes.pop();
            }
        }

        require(completedCount > 0, "No unstakes ready for completion");

        if (totalEffectiveAmount > 0) {
            IERC20(brevToken).safeTransfer(msg.sender, totalEffectiveAmount);
        }

        emit UnstakeCompleted(msg.sender, _prover, totalEffectiveAmount);
    }

    /**
     * @notice Distribute rewards to a prover and their stakers
     * @dev Reward Distribution Algorithm:
     *      1. Transfer tokens from sender to this contract
     *      2. Calculate commission for prover (commissionRate * totalRewards)
     *      3. Remaining rewards go to stakers proportionally
     *      4. Update accRewardPerRawShare for stakers using: newAcc = oldAcc + (stakersReward * SCALE_FACTOR) / totalRawShares
     *      5. If no stakers exist, prover gets all rewards as commission
     *
     *      Mathematical Properties:
     *      - Rewards are distributed per raw share, not effective shares
     *      - This ensures fair distribution regardless of slashing history
     *      - accRewardPerRawShare is scaled by SCALE_FACTOR for precision
     *      - Stakers claim rewards based on: (rawShares * accRewardPerRawShare / SCALE_FACTOR) - rewardDebt
     *
     * @param _prover The address of the prover receiving rewards
     * @param _amount Total amount of tokens to distribute as rewards
     */
    function addRewards(address _prover, uint256 _amount) external nonReentrant {
        require(provers[_prover].state != ProverState.Null, "Unknown prover");
        if (_amount == 0) return;

        // Transfer tokens from sender to this contract
        IERC20(brevToken).safeTransferFrom(msg.sender, address(this), _amount);

        ProverInfo storage prover = provers[_prover];

        // === COMMISSION CALCULATION ===
        // Calculate commission for prover (always paid regardless of staker count)
        uint256 commission = (_amount * prover.commissionRate) / COMMISSION_RATE_DENOMINATOR;
        uint256 stakersReward = _amount - commission;

        // Always credit commission to prover
        prover.pendingCommission += commission;

        if (prover.totalRawShares == 0) {
            // === NO STAKERS CASE ===
            // No stakers exist, prover gets all remaining rewards as commission
            prover.pendingCommission += stakersReward;
            emit RewardsAdded(_prover, _amount, _amount, 0);
        } else {
            // === STAKER REWARD DISTRIBUTION ===
            // Distribute remaining rewards proportionally to all stakers (including prover if self-staked)
            // Calculate accumulator delta and ensure dimensional consistency for dust accounting
            uint256 deltaAcc = (stakersReward * SCALE_FACTOR) / prover.totalRawShares;
            uint256 distributed = (deltaAcc * prover.totalRawShares) / SCALE_FACTOR; // tokens actually distributed
            uint256 dust = stakersReward - distributed; // tokens

            prover.accRewardPerRawShare += deltaAcc;

            // Add dust from rounding errors to treasury pool (in token units)
            if (dust > 0) {
                treasuryPool += dust;
            }

            emit RewardsAdded(_prover, _amount, commission, stakersReward);
        }
    }

    /**
     * @notice Withdraw accumulated rewards for a staker or prover
     * @dev Reward Withdrawal Algorithm:
     *      1. Update pending staking rewards: pendingRewards += (rawShares * accRewardPerRawShare / SCALE_FACTOR) - rewardDebt
     *      2. Update rewardDebt to current accumulated amount to prevent double-claiming
     *      3. If caller is the prover, add pending commission to payout
     *      4. Transfer total payout to caller
     *
     *      Security Features:
     *      - rewardDebt prevents double-claiming of rewards
     *      - All reward calculations are done in raw shares for fairness
     *      - Commission is separate from staking rewards
     *
     * @param _prover The address of the prover to withdraw rewards from
     */
    function withdrawRewards(address _prover) external nonReentrant {
        require(provers[_prover].state != ProverState.Null, "Unknown prover");

        // Update global streaming rewards before withdrawal (piggyback principle)
        if (globalRatePerSec > 0) {
            _updateGlobalStreaming();
            _settleProverStreaming(_prover);
        }

        ProverInfo storage prover = provers[_prover];
        StakeInfo storage stakeInfo = prover.stakes[msg.sender];

        uint256 payout = 0;

        // === STAKING REWARDS UPDATE ===
        // Update pending rewards for active stakes
        uint256 accRewardPerRawShare = prover.accRewardPerRawShare;
        if (stakeInfo.rawShares > 0) {
            // Calculate total accrued proof rewards for this staker
            uint256 accrued = (stakeInfo.rawShares * accRewardPerRawShare) / SCALE_FACTOR;
            // Calculate new proof rewards since last claim
            uint256 delta = accrued - stakeInfo.rewardDebt;
            if (delta > 0) {
                stakeInfo.pendingRewards += delta;
            }
            // Update reward debt to prevent double-claiming
            stakeInfo.rewardDebt = accrued;
        }

        // === PAYOUT CALCULATION ===
        // Add accumulated staking rewards to payout
        if (stakeInfo.pendingRewards > 0) {
            payout += stakeInfo.pendingRewards;
            stakeInfo.pendingRewards = 0;
        }

        // Add commission if this is the prover
        if (msg.sender == _prover) {
            if (prover.pendingCommission > 0) {
                payout += prover.pendingCommission;
                prover.pendingCommission = 0;
            }
        }

        require(payout > 0, "No rewards available");

        // Transfer rewards to caller
        IERC20(brevToken).safeTransfer(msg.sender, payout);

        emit RewardsWithdrawn(msg.sender, _prover, payout);
    }

    /**
     * @notice Slash a prover for invalid proof submission or malicious behavior
     * @dev Simplified Slashing Algorithm:
     *      1. Enforce maximum slash percentage per operation
     *      2. Update global scale factor: newScale = oldScale * (1 - slashPercentage)
     *      3. Auto-deactivate prover if scale drops below minimum threshold
     *      4. This affects ALL stakes (active + pending unstake) proportionally
     *
     *      Key Properties:
     *      - Maximum single slash is capped
     *      - Severely slashed provers get automatically deactivated
     *      - Scale factor creates efficient slashing without iterating over all stakers
     *      - System remains functional - no liveness issues with scale approaching zero
     *
     * @param _prover The address of the prover to be slashed
     * @param _percentage The percentage of stake to slash (0 to MAX_SLASH_PERCENTAGE)
     */
    function slash(address _prover, uint256 _percentage) external onlyRole(SLASHER_ROLE) {
        require(provers[_prover].state != ProverState.Null, "Unknown prover");
        require(_percentage < SLASH_FACTOR_DENOMINATOR, "Cannot slash 100%");
        require(_percentage <= MAX_SLASH_PERCENTAGE, "Slash percentage too high");

        ProverInfo storage prover = provers[_prover];

        // === STREAMING SETTLEMENT ===
        // Update global streaming and settle prover before changing effective stake
        if (globalRatePerSec > 0) {
            _updateGlobalStreaming();
            _settleProverStreaming(_prover);
        }

        // Calculate total effective stake before slashing (for event emission)
        uint256 totalEffectiveBefore = _getTotalEffectiveStake(_prover);

        // === GLOBAL SCALE UPDATE WITH DUAL THRESHOLDS ===
        // Compute prospective new scale after this slash.
        uint256 remainingFactor = SLASH_FACTOR_DENOMINATOR - _percentage;
        uint256 newScale = (prover.scale * remainingFactor) / SLASH_FACTOR_DENOMINATOR;

        // Hard stop: do not allow scale to reach or drop below MIN_SCALE_FLOOR.
        require(newScale > MIN_SCALE_FLOOR, "Scale too low");

        // Apply new scale.
        prover.scale = newScale;

        // === TREASURY POOL ACCOUNTING ===
        // Calculate total slashed amount and add to treasury pool
        uint256 totalEffectiveAfter = _getTotalEffectiveStake(_prover);
        uint256 totalSlashed = totalEffectiveBefore - totalEffectiveAfter;
        treasuryPool += totalSlashed;

        // === STREAMING DEBT RESET ===
        // Reset streaming debt to prevent accounting drift with new effective stake
        if (prover.state == ProverState.Active && totalEffectiveAfter > 0) {
            prover.rewardDebtEff = (totalEffectiveAfter * globalAccPerEff) / SCALE_FACTOR;
        }

        // === AUTO-DEACTIVATION CHECK ===
        // If scale at or below DEACTIVATION_SCALE, deactivate (but allow future slashes until hard floor).
        if (prover.scale <= DEACTIVATION_SCALE && prover.state == ProverState.Active) {
            prover.state = ProverState.Deactivated;
            activeProvers.remove(_prover);
            emit ProverDeactivated(_prover);
        }

        // Update total effective active stake for streaming calculations
        _updateTotalEffectiveActive(_prover, totalEffectiveBefore, totalEffectiveAfter);

        emit ProverSlashed(_prover, _percentage, totalSlashed);
    }

    /**
     * @notice Allow a prover to voluntarily retire (self-initiated retirement)
     * @dev Provers can retire themselves when they have no active stakes or pending rewards
     */
    function retireProver() external {
        require(provers[msg.sender].state != ProverState.Null, "Not a prover");
        _retireProver(msg.sender);
    }

    /**
     * @notice Admin function to force retire a prover (admin-initiated retirement)
     * @dev Allows admin to retire inactive provers for cleanup
     * @param _prover The address of the prover to retire
     */
    function retireProver(address _prover) external onlyOwner {
        require(provers[_prover].state != ProverState.Null, "Unknown prover");
        _retireProver(_prover);
    }

    /**
     * @notice Allow a retired prover to unretire and return to active status
     * @dev Retired provers can unretire themselves, but must already meet minimum self-stake requirements
     *      The prover should self-stake while retired before calling this function
     */
    function unretireProver() external {
        require(provers[msg.sender].state == ProverState.Retired, "Prover not retired");

        ProverInfo storage prover = provers[msg.sender];

        // Verify prover meets minimum self-stake requirements before unretiring
        uint256 selfEffective = _effectiveAmount(msg.sender, _selfRawShares(msg.sender));
        require(selfEffective >= prover.minSelfStake, "Must meet min self-stake before unretiring");
        require(selfEffective >= globalMinSelfStake, "Must meet global min self-stake before unretiring");

        // Reset slashing scale for fresh start
        prover.scale = SCALE_FACTOR;

        // Update total effective active stake (add this prover back)
        uint256 newEffectiveStake = _getTotalEffectiveStake(msg.sender);

        // === STREAMING DEBT RESET ===
        // Initialize streaming debt for newly active prover
        if (newEffectiveStake > 0) {
            // Update global streaming before setting baseline
            if (globalRatePerSec > 0) {
                _updateGlobalStreaming();
            }
            prover.rewardDebtEff = (newEffectiveStake * globalAccPerEff) / SCALE_FACTOR;
        }

        _updateTotalEffectiveActive(msg.sender, 0, newEffectiveStake);

        // Unretire as active prover
        prover.state = ProverState.Active;
        activeProvers.add(msg.sender);

        emit ProverUnretired(msg.sender);
    }

    /**
     * @notice Update minimum self-stake requirement for a prover
     * @dev Rules:
     *      1. Must meet global minimum self-stake requirement
     *      2. Increases are effective immediately (strengthens requirements)
     *      3. Updates in retired state are effective immediately (not accepting delegations)
     *      4. Decreases in active/deactivated states require delay (security protection)
     * @param _newMinSelfStake New minimum self-stake amount in token units
     */
    function updateMinSelfStake(uint256 _newMinSelfStake) external {
        require(provers[msg.sender].state != ProverState.Null, "Not a prover");
        require(_newMinSelfStake >= globalMinSelfStake, "Below global minimum self stake");

        ProverInfo storage prover = provers[msg.sender];
        uint256 currentMinSelfStake = prover.minSelfStake;
        require(_newMinSelfStake != currentMinSelfStake, "No change in minSelfStake");

        if (_newMinSelfStake > currentMinSelfStake) {
            // === INCREASE: EFFECTIVE IMMEDIATELY ===
            // Increases strengthen requirements, so they're safe to apply immediately
            _applyMinSelfStakeUpdate(msg.sender, _newMinSelfStake);
        } else if (prover.state == ProverState.Retired) {
            // === RETIRED STATE: EFFECTIVE IMMEDIATELY ===
            // Retired provers aren't accepting new delegations, so decreases are safe
            _applyMinSelfStakeUpdate(msg.sender, _newMinSelfStake);
        } else {
            // === DECREASE IN ACTIVE/DEACTIVATED: DELAYED ===
            // Decreases could enable rapid exit, so require delay for security
            prover.pendingMinSelfStakeUpdate.newMinSelfStake = _newMinSelfStake;
            prover.pendingMinSelfStakeUpdate.requestedTime = block.timestamp;

            emit MinSelfStakeUpdateRequested(msg.sender, _newMinSelfStake, block.timestamp);
        }
    }

    /**
     * @notice Complete a pending minSelfStake decrease after the delay period
     * @dev Only callable by the prover after the delay period has passed
     */
    function completeMinSelfStakeUpdate() external {
        require(provers[msg.sender].state != ProverState.Null, "Not a prover");

        ProverInfo storage prover = provers[msg.sender];
        require(prover.pendingMinSelfStakeUpdate.newMinSelfStake > 0, "No pending minSelfStake update");

        // Calculate effective time based on current delay setting
        uint256 effectiveTime = prover.pendingMinSelfStakeUpdate.requestedTime + minSelfStakeDecreaseDelay;
        require(block.timestamp >= effectiveTime, "Update delay not yet passed");

        uint256 newMinSelfStake = prover.pendingMinSelfStakeUpdate.newMinSelfStake;

        // Clear pending update
        prover.pendingMinSelfStakeUpdate.newMinSelfStake = 0;
        prover.pendingMinSelfStakeUpdate.requestedTime = 0;

        // Apply the update
        _applyMinSelfStakeUpdate(msg.sender, newMinSelfStake);
    }

    /**
     * @notice Update commission rate for a prover
     * @param _newCommissionRate New commission rate in basis points (0-10000, where 10000 = 100%)
     */
    function updateCommissionRate(uint64 _newCommissionRate) external {
        require(provers[msg.sender].state != ProverState.Null, "Not a prover");
        require(_newCommissionRate <= COMMISSION_RATE_DENOMINATOR, "Invalid commission rate");

        ProverInfo storage prover = provers[msg.sender];
        uint64 oldCommissionRate = prover.commissionRate;
        require(_newCommissionRate != oldCommissionRate, "No change in commission rate");

        // Update commission rate immediately
        prover.commissionRate = _newCommissionRate;

        emit CommissionRateUpdated(msg.sender, oldCommissionRate, _newCommissionRate);
    }

    /**
     * @notice Public function to manually update global streaming (keeper function)
     * @dev Optional - system works via lazy updates during normal operations
     */
    function updateGlobalStreaming() external {
        _updateGlobalStreaming();
    }

    /**
     * @notice Manually settle streaming rewards for a specific prover
     * @dev Public function for manual settlement without other state changes
     * @param _prover Address of the prover to settle
     */
    function settleProverStreaming(address _prover) external {
        _updateGlobalStreaming();
        _settleProverStreaming(_prover);
    }

    /**
     * @notice Add tokens to the global streaming budget
     * @dev Tokens are transferred from caller to contract - anyone can fund the budget
     * @param _amount Amount of tokens to add to the streaming budget
     */
    function addStreamingBudget(uint256 _amount) external {
        require(_amount > 0, "Amount must be positive");

        // Transfer tokens from caller to contract
        IERC20(brevToken).safeTransferFrom(msg.sender, address(this), _amount);

        globalEmissionBudget += _amount;

        emit StreamingBudgetAdded(_amount, globalEmissionBudget);
    }

    // =========================================================================
    // EXTERNAL FUNCTIONS (ADMIN ONLY)
    // =========================================================================

    /**
     * @notice Admin function to set the unstaking delay period
     * @param _newDelay The new unstake delay in seconds
     */
    function setUnstakeDelay(uint256 _newDelay) external onlyOwner {
        require(_newDelay <= 30 days, "Unstake delay too long");
        uint256 oldDelay = UNSTAKE_DELAY;
        UNSTAKE_DELAY = _newDelay;
        emit UnstakeDelayUpdated(oldDelay, _newDelay);
    }

    /**
     * @notice Admin function to set the minSelfStake decrease delay period
     * @param _newDelay The new minSelfStake decrease delay in seconds
     */
    function setMinSelfStakeDecreaseDelay(uint256 _newDelay) external onlyOwner {
        require(_newDelay <= 30 days, "MinSelfStake decrease delay too long");
        uint256 oldDelay = minSelfStakeDecreaseDelay;
        minSelfStakeDecreaseDelay = _newDelay;
        emit MinSelfStakeDecreaseDelayUpdated(oldDelay, _newDelay);
    }

    /**
     * @notice Set the global minimum self-stake requirement for all provers
     * @param _newGlobalMinSelfStake The new global minimum self-stake in token units
     */
    function setGlobalMinSelfStake(uint256 _newGlobalMinSelfStake) external onlyOwner {
        require(_newGlobalMinSelfStake > 0, "Global min self stake must be positive");
        uint256 oldMinStake = globalMinSelfStake;
        globalMinSelfStake = _newGlobalMinSelfStake;
        emit GlobalMinSelfStakeUpdated(oldMinStake, _newGlobalMinSelfStake);
    }

    /**
     * @notice Admin function to deactivate a malicious or problematic prover
     * @dev Deactivation prevents new stakes but allows existing operations to continue
     *      Existing stakers can still unstake and withdraw rewards
     * @param _prover The address of the prover to deactivate
     */
    function deactivateProver(address _prover) external onlyOwner {
        require(provers[_prover].state == ProverState.Active, "Prover already inactive");

        // Finalize streaming to 'now' and settle this prover before leaving Active
        _updateGlobalStreaming();
        _settleProverStreaming(_prover);

        // Calculate current effective stake before deactivation
        uint256 currentEffectiveStake = _getTotalEffectiveStake(_prover);

        // Update total effective active stake (remove this prover) BEFORE changing state
        totalEffectiveActive -= currentEffectiveStake;

        provers[_prover].state = ProverState.Deactivated;
        activeProvers.remove(_prover);

        emit ProverDeactivated(_prover);
    }

    /**
     * @notice Admin function to reactivate a deactivated prover
     * @dev Allows admin to reactivate previously deactivated provers
     * @param _prover The address of the prover to reactivate
     */
    function reactivateProver(address _prover) external onlyOwner {
        require(provers[_prover].state == ProverState.Deactivated, "Prover not deactivated");

        ProverInfo storage prover = provers[_prover];

        // Bring global index current
        _updateGlobalStreaming();

        // Check if prover still meets minimum self-stake requirements
        uint256 selfEffective = _effectiveAmount(_prover, _selfRawShares(_prover));
        require(selfEffective >= prover.minSelfStake, "Prover below min self-stake");
        require(selfEffective >= globalMinSelfStake, "Prover below global min self-stake");

        prover.state = ProverState.Active;
        activeProvers.add(_prover);

        // Update total effective active stake (add this prover back)
        uint256 currentEffectiveStake = _getTotalEffectiveStake(_prover);

        // === CLOSE INTERVAL BEFORE DENOMINATOR CHANGE ===
        // Update global streaming again before changing totalEffectiveActive denominator
        if (globalRatePerSec > 0) {
            _updateGlobalStreaming();
        }

        // Baseline future accrual to current global index
        prover.rewardDebtEff = (currentEffectiveStake * globalAccPerEff) / SCALE_FACTOR;

        // Add this prover's stake back to active total
        totalEffectiveActive += currentEffectiveStake;

        emit ProverReactivated(_prover);
    }

    /**
     * @notice Admin function to withdraw slashed tokens from the treasury pool
     * @dev Allows treasury to claim tokens that were slashed from all provers.
     *      These tokens represent the difference between what stakers can withdraw
     *      and what tokens are held in the contract.
     * @param _to The address to send the slashed tokens to
     * @param _amount The amount of tokens to withdraw from the treasury pool
     */
    function withdrawFromTreasuryPool(address _to, uint256 _amount) external onlyOwner {
        require(_to != address(0), "Invalid recipient");
        require(_amount > 0, "Amount must be positive");
        require(_amount <= treasuryPool, "Insufficient treasury pool balance");

        // Update treasury pool accounting
        treasuryPool -= _amount;

        // Transfer tokens to recipient
        IERC20(brevToken).safeTransfer(_to, _amount);

        emit TreasuryPoolWithdrawn(_to, _amount);
    }

    /**
     * @notice Set the global streaming rate for all active provers
     * @dev Only callable by owner to control token distribution
     * @param _newRatePerSec New streaming rate in tokens per second
     */
    function setGlobalRatePerSec(uint256 _newRatePerSec) external onlyOwner {
        // Update global accumulator before changing rate
        if (globalRatePerSec > 0) {
            _updateGlobalStreaming();
        }

        uint256 oldRate = globalRatePerSec;
        globalRatePerSec = _newRatePerSec;

        emit StreamingRateUpdated(oldRate, _newRatePerSec);
    }

    /**
     * @notice Emergency function to pause streaming by setting rate to zero
     * @dev Can be called by owner in emergency situations
     */
    function pauseStreaming() external onlyOwner {
        if (globalRatePerSec > 0) {
            _updateGlobalStreaming(); // Final update before pause
            uint256 oldRate = globalRatePerSec;
            globalRatePerSec = 0;
            emit StreamingRateUpdated(oldRate, 0);
        }
    }

    // =========================================================================
    // EXTERNAL VIEW FUNCTIONS
    // =========================================================================

    /**
     * @notice Get basic prover information
     * @param _prover Address of the prover to query
     * @return state Current state of the prover (Null, Active, Retired)
     * @return minSelfStake Minimum self-stake required for accepting delegations
     * @return commissionRate Commission rate in basis points (0-10000)
     * @return totalStaked Total effective stake amount (post-slashing)
     * @return stakersCount Number of active stakers (excluding zero-balance stakers)
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
        )
    {
        ProverInfo storage prover = provers[_prover];
        uint256 effectiveTotalStaked = _getTotalEffectiveStake(_prover);
        return (prover.state, prover.minSelfStake, prover.commissionRate, effectiveTotalStaked, prover.stakers.length());
    }

    /**
     * @notice Get detailed prover information including self-stake and commission data
     * @param _prover Address of the prover to query
     * @return state Current state of the prover (Null, Active, Retired)
     * @return minSelfStake Minimum self-stake required for accepting delegations
     * @return commissionRate Commission rate in basis points (0-10000)
     * @return totalStaked Total effective stake from all stakers (post-slashing)
     * @return selfEffectiveStake Prover's own effective stake amount (post-slashing)
     * @return pendingCommission Unclaimed commission rewards for the prover
     * @return stakerCount Number of active stakers (excluding zero-balance stakers)
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
        )
    {
        ProverInfo storage prover = provers[_prover];
        uint256 effectiveTotalStaked = _getTotalEffectiveStake(_prover);
        uint256 selfEffective = _effectiveAmount(_prover, _selfRawShares(_prover));
        uint256 totalCommission = prover.pendingCommission;
        return (
            prover.state,
            prover.minSelfStake,
            prover.commissionRate,
            effectiveTotalStaked,
            selfEffective,
            totalCommission,
            prover.stakers.length()
        );
    }

    /**
     * @notice Get comprehensive stake information for a specific staker with a prover
     * @dev Calculates real-time pending rewards including live reward accumulation (proof + emission)
     * @param _prover Address of the prover
     * @param _staker Address of the staker to query
     * @return amount Current effective stake amount (post-slashing)
     * @return totalPendingUnstake Total effective amount currently in unstaking process (post-slashing)
     * @return pendingUnstakeCount Number of pending unstake requests
     * @return pendingRewards Total pending rewards (proof + streaming rewards + commission if prover)
     */
    function getStakeInfo(address _prover, address _staker)
        external
        view
        returns (uint256 amount, uint256 totalPendingUnstake, uint256 pendingUnstakeCount, uint256 pendingRewards)
    {
        ProverInfo storage prover = provers[_prover];
        StakeInfo storage stakeInfo = prover.stakes[_staker];

        // Convert raw shares to effective amounts (subject to slashing)
        amount = _effectiveAmount(_prover, stakeInfo.rawShares);

        // Calculate total pending unstake amount across all requests
        for (uint256 i = 0; i < stakeInfo.pendingUnstakes.length; i++) {
            totalPendingUnstake += _effectiveAmount(_prover, stakeInfo.pendingUnstakes[i].rawShares);
        }
        pendingUnstakeCount = stakeInfo.pendingUnstakes.length;

        // Calculate pending rewards
        pendingRewards = _calculateTotalPendingRewards(_prover, _staker);
    }

    /**
     * @notice Calculate total pending rewards for a staker (internal helper to avoid stack too deep)
     * @param _prover Address of the prover
     * @param _staker Address of the staker
     * @return Total pending rewards including proof rewards, streaming rewards, and commission
     */
    function _calculateTotalPendingRewards(address _prover, address _staker) internal view returns (uint256) {
        ProverInfo storage prover = provers[_prover];
        StakeInfo storage stakeInfo = prover.stakes[_staker];

        uint256 totalRewards = stakeInfo.pendingRewards;

        if (stakeInfo.rawShares > 0) {
            // Add accrued proof rewards
            uint256 accrued = (stakeInfo.rawShares * prover.accRewardPerRawShare) / SCALE_FACTOR;
            if (accrued >= stakeInfo.rewardDebt) {
                totalRewards += (accrued - stakeInfo.rewardDebt);
            }

            // Note: Streaming rewards are now settled directly to pendingRewards
            // via _settleProverStreaming, so no need for live calculation here
        }

        // Add any pending commission if this is the prover
        if (_staker == _prover) {
            totalRewards += prover.pendingCommission;
        }

        return totalRewards;
    }

    /**
     * @notice Get details about a specific pending unstake request
     * @dev Returns information about a single pending unstake request by index
     * @param _prover Address of the prover
     * @param _staker Address of the staker to query
     * @param _requestIndex Index of the pending unstake request (0-based)
     * @return amount Effective amount of this unstake request (post-slashing)
     * @return rawShares Raw shares of this unstake request
     * @return unstakeTime Timestamp when this unstake was initiated
     * @return isReady Whether this unstake request can be completed now
     */
    function getPendingUnstakeInfo(address _prover, address _staker, uint256 _requestIndex)
        external
        view
        returns (uint256 amount, uint256 rawShares, uint256 unstakeTime, bool isReady)
    {
        StakeInfo storage stakeInfo = provers[_prover].stakes[_staker];

        require(_requestIndex < stakeInfo.pendingUnstakes.length, "Invalid request index");

        PendingUnstake storage unstakeRequest = stakeInfo.pendingUnstakes[_requestIndex];
        uint256 effectiveAmount = _effectiveAmount(_prover, unstakeRequest.rawShares);
        bool canComplete = block.timestamp >= unstakeRequest.unstakeTime + UNSTAKE_DELAY;

        return (effectiveAmount, unstakeRequest.rawShares, unstakeRequest.unstakeTime, canComplete);
    }

    /**
     * @notice Get the list of all registered provers
     * @return Array of prover addresses (includes both active and inactive provers)
     */
    function getAllProvers() external view returns (address[] memory) {
        return proverList;
    }

    /**
     * @notice Get the list of currently active provers
     * @return Array of active prover addresses only
     */
    function activeProverList() external view returns (address[] memory) {
        return activeProvers.values();
    }

    /**
     * @notice Get the list of all stakers for a specific prover
     * @param _prover Address of the prover to query
     * @return Array of staker addresses for the prover
     */
    function getProverStakers(address _prover) external view returns (address[] memory) {
        return provers[_prover].stakers.values();
    }

    /**
     * @notice Check if a prover is eligible for work assignment
     * @dev Used by BrevisMarket to verify prover eligibility before assigning work.
     * @param _prover Address of the prover to check
     * @param _minimumTotalStake Minimum total effective stake required for eligibility
     * @return eligible True if prover meets all requirements, false otherwise
     * @return currentTotalStake Current total effective stake amount (for reference)
     */
    function isProverEligible(address _prover, uint256 _minimumTotalStake)
        external
        view
        returns (bool eligible, uint256 currentTotalStake)
    {
        ProverInfo storage prover = provers[_prover];

        // Always calculate current total effective stake for consistent API
        currentTotalStake = _getTotalEffectiveStake(_prover);

        // Check if prover is active
        if (prover.state != ProverState.Active) {
            return (false, currentTotalStake);
        }

        // Check if prover meets global minimum self-stake requirement
        if (prover.minSelfStake < globalMinSelfStake) {
            return (false, currentTotalStake);
        }

        // Check if total stake meets the required threshold
        if (currentTotalStake < _minimumTotalStake) {
            return (false, currentTotalStake);
        }

        // Verify prover actually meets their own minimum self-stake requirement
        uint256 selfEffectiveStake = _effectiveAmount(_prover, _selfRawShares(_prover));
        if (selfEffectiveStake < prover.minSelfStake) {
            return (false, currentTotalStake);
        }

        return (true, currentTotalStake);
    }

    /**
     * @notice Get internal prover state for debugging and monitoring
     * @dev Provides access to low-level prover data that's normally internal
     * @param _prover Address of the prover to query
     * @return totalRawShares Total raw shares across all stakers (invariant to slashing)
     * @return scale Current scale factor for this prover (SCALE_FACTOR = 1.0, decreases with slashing)
     * @return accRewardPerRawShare Accumulated rewards per raw share (scaled by SCALE_FACTOR)
     * @return stakersCount Number of active stakers (from EnumerableSet)
     */
    function getProverInternals(address _prover)
        external
        view
        returns (uint256 totalRawShares, uint256 scale, uint256 accRewardPerRawShare, uint256 stakersCount)
    {
        ProverInfo storage prover = provers[_prover];
        return (prover.totalRawShares, prover.scale, prover.accRewardPerRawShare, prover.stakers.length());
    }

    /**
     * @notice Get internal stake information for a specific staker with a prover
     * @dev Provides access to low-level stake data including raw shares and reward debt
     * @param _prover Address of the prover
     * @param _staker Address of the staker to query
     * @return rawShares Raw shares owned by the staker (before applying scale factor)
     * @return rewardDebt Tracks already-accounted rewards to prevent double-claiming
     * @return pendingRewards Accumulated but unclaimed staking rewards
     * @return totalPendingUnstakeRaw Total raw shares currently in unstaking process across all requests
     */
    function getStakeInternals(address _prover, address _staker)
        external
        view
        returns (uint256 rawShares, uint256 rewardDebt, uint256 pendingRewards, uint256 totalPendingUnstakeRaw)
    {
        ProverInfo storage prover = provers[_prover];
        StakeInfo storage stakeInfo = prover.stakes[_staker];

        // Calculate total pending unstake raw shares across all requests
        uint256 totalPendingRawShares = 0;
        for (uint256 i = 0; i < stakeInfo.pendingUnstakes.length; i++) {
            totalPendingRawShares += stakeInfo.pendingUnstakes[i].rawShares;
        }

        return (stakeInfo.rawShares, stakeInfo.rewardDebt, stakeInfo.pendingRewards, totalPendingRawShares);
    }

    /**
     * @notice Get pending minSelfStake update information for a prover
     * @dev Returns information about any pending minSelfStake decrease
     * @param _prover Address of the prover to query
     * @return hasPendingUpdate Whether there is a pending minSelfStake update
     * @return pendingMinSelfStake The pending new minSelfStake value (0 if no pending update)
     * @return effectiveTime When the pending update can be completed (calculated with current delay)
     * @return isReady Whether the pending update can be completed now
     */
    function getPendingMinSelfStakeUpdate(address _prover)
        external
        view
        returns (bool hasPendingUpdate, uint256 pendingMinSelfStake, uint256 effectiveTime, bool isReady)
    {
        ProverInfo storage prover = provers[_prover];

        hasPendingUpdate = prover.pendingMinSelfStakeUpdate.newMinSelfStake > 0;
        pendingMinSelfStake = prover.pendingMinSelfStakeUpdate.newMinSelfStake;

        if (hasPendingUpdate) {
            // Calculate effective time based on current delay setting
            effectiveTime = prover.pendingMinSelfStakeUpdate.requestedTime + minSelfStakeDecreaseDelay;
            isReady = block.timestamp >= effectiveTime;
        } else {
            effectiveTime = 0;
            isReady = false;
        }

        return (hasPendingUpdate, pendingMinSelfStake, effectiveTime, isReady);
    }

    /**
     * @notice Get treasury pool information
     * @dev Returns the total amount of slashed tokens and reward dust available for withdrawal by treasury
     * @return treasuryPoolBalance Amount of slashed tokens and accumulated reward dust in the treasury pool
     */
    function getTreasuryPool() external view returns (uint256 treasuryPoolBalance) {
        return treasuryPool;
    }

    /**
     * @notice Get global streaming system information
     * @dev Returns current streaming configuration and state
     * @return ratePerSec Current global streaming rate (tokens per second)
     * @return budgetBalance Available tokens in streaming budget
     * @return globalAccumulatorPerEff Current global accumulator per effective stake
     * @return totalEffStake Total effective stake across all active provers
     * @return lastUpdate Timestamp of last global streaming update
     */
    function getStreamingInfo()
        external
        view
        returns (
            uint256 ratePerSec,
            uint256 budgetBalance,
            uint256 globalAccumulatorPerEff,
            uint256 totalEffStake,
            uint256 lastUpdate
        )
    {
        return (globalRatePerSec, globalEmissionBudget, globalAccPerEff, totalEffectiveActive, lastGlobalTime);
    }

    /**
     * @notice Get total pending rewards for a staker (including streaming rewards)
     * @dev Helper function to calculate total pending rewards including live streaming accumulation
     * @param _prover Address of the prover
     * @param _staker Address of the staker
     * @return Total pending rewards (proof + streaming + commission if applicable)
     */
    function getPendingRewards(address _prover, address _staker) external view returns (uint256) {
        return _calculateTotalPendingRewards(_prover, _staker);
    }

    /**
     * @notice Get pending streaming rewards for a prover (without settling)
     * @dev View function that calculates what would be owed if settled now
     *      Only Active provers earn streaming rewards - inactive provers return zero
     * @param _prover Address of the prover to query
     * @return pendingTotal Total pending streaming rewards for this prover
     * @return pendingCommission Commission portion of pending rewards
     * @return pendingStakers Staker portion of pending rewards
     */
    function getPendingStreamingRewards(address _prover)
        external
        view
        returns (uint256 pendingTotal, uint256 pendingCommission, uint256 pendingStakers)
    {
        // Only Active provers earn streaming rewards (matches _settleProverStreaming behavior)
        ProverInfo storage prover = provers[_prover];
        if (prover.state != ProverState.Active) {
            return (0, 0, 0);
        }

        if (globalRatePerSec == 0 || totalEffectiveActive == 0) {
            return (0, 0, 0);
        }

        uint256 effectiveStake = _getTotalEffectiveStake(_prover);
        if (effectiveStake == 0) {
            return (0, 0, 0);
        }

        // Calculate what global accumulator would be after update
        uint256 timeElapsed = block.timestamp - lastGlobalTime;
        uint256 totalRewards = globalRatePerSec * timeElapsed;
        if (totalRewards > globalEmissionBudget) {
            totalRewards = globalEmissionBudget;
        }

        uint256 projectedGlobalAcc = globalAccPerEff;
        if (totalRewards > 0) {
            projectedGlobalAcc += (totalRewards * SCALE_FACTOR) / totalEffectiveActive;
        }

        // Calculate what would be owed to this prover
        uint256 totalOwed = (effectiveStake * projectedGlobalAcc) / SCALE_FACTOR;
        pendingTotal = totalOwed - prover.rewardDebtEff;

        if (pendingTotal > 0) {
            pendingCommission = (pendingTotal * prover.commissionRate) / COMMISSION_RATE_DENOMINATOR;
            pendingStakers = pendingTotal - pendingCommission;
        }
    }

    // =========================================================================
    // INTERNAL FUNCTIONS (STREAMING SYSTEM)
    // =========================================================================

    /**
     * @notice Update global streaming accumulator based on elapsed time
     * @dev O(1) operation - updates single global state regardless of number of provers
     *      Implements lazy accrual - only updates when system is "touched"
     */
    function _updateGlobalStreaming() internal {
        if (globalRatePerSec == 0 || totalEffectiveActive == 0) {
            lastGlobalTime = block.timestamp;
            return;
        }

        uint256 timeElapsed = block.timestamp - lastGlobalTime;
        if (timeElapsed == 0) return; // Already updated this block

        // Calculate total rewards to distribute based on time elapsed
        uint256 totalRewards = globalRatePerSec * timeElapsed;

        // Cap by available budget
        if (totalRewards > globalEmissionBudget) {
            totalRewards = globalEmissionBudget;
        }

        if (totalRewards > 0) {
            // Update global accumulator: rewards per unit of effective stake
            // Scale by SCALE_FACTOR for precision
            globalAccPerEff += (totalRewards * SCALE_FACTOR) / totalEffectiveActive;

            // Deduct from budget
            globalEmissionBudget -= totalRewards;
        }

        lastGlobalTime = block.timestamp;
    }

    /**
     * @notice Settle streaming rewards for a specific prover (internal)
     * @dev Calculates owed rewards and distributes them via commission structure
     *      Uses the global accumulator approach for O(1) efficiency
     * @param _prover Address of the prover to settle
     */
    function _settleProverStreaming(address _prover) internal {
        ProverInfo storage prover = provers[_prover];
        if (prover.state != ProverState.Active) return;

        uint256 effectiveStake = _getTotalEffectiveStake(_prover);
        if (effectiveStake == 0) return;

        // Calculate total owed based on global accumulator
        uint256 totalOwed = (effectiveStake * globalAccPerEff) / SCALE_FACTOR;

        // Prevent underflow - only proceed if there are new rewards
        if (totalOwed <= prover.rewardDebtEff) return;

        uint256 newDebt = totalOwed - prover.rewardDebtEff;

        if (newDebt == 0) return;

        // Split into commission and staker rewards
        uint256 commission = (newDebt * prover.commissionRate) / COMMISSION_RATE_DENOMINATOR;
        uint256 stakersReward = newDebt - commission;

        // Commission is always direct to prover
        prover.pendingCommission += commission;

        // **O(1) staker distribution** via accumulator (identical to addRewards path)
        if (prover.totalRawShares == 0) {
            // No stakers: route staker portion to commission (policy matches addRewards)
            prover.pendingCommission += stakersReward;
        } else {
            prover.accRewardPerRawShare += (stakersReward * SCALE_FACTOR) / prover.totalRawShares;
        }

        // Update reward debt to current baseline
        prover.rewardDebtEff = totalOwed;

        emit StreamingRewardsSettled(_prover, newDebt, commission, stakersReward);
    }

    /**
     * @notice Update total effective active stake when prover states change
     * @dev Maintains cached total for O(1) global streaming calculations
     * @param _prover Address of the prover whose stake changed
     * @param _oldEffective Previous effective stake amount
     * @param _newEffective New effective stake amount
     */
    function _updateTotalEffectiveActive(address _prover, uint256 _oldEffective, uint256 _newEffective) internal {
        ProverInfo storage prover = provers[_prover];

        if (prover.state == ProverState.Active) {
            // Active prover - update total
            totalEffectiveActive = totalEffectiveActive - _oldEffective + _newEffective;
        } else {
            // Inactive prover - their stake is not part of totalEffectiveActive
            // No update needed as they don't contribute to the active total
        }
    }

    // =========================================================================
    // INTERNAL FUNCTIONS (STATE-CHANGING)
    // =========================================================================

    /**
     * @notice Internal function to handle prover retirement logic
     * @dev Retirement Requirements (ensures clean state):
     *      1. Prover must be inactive (no new stakes accepted)
     *      2. No active stakes remaining (totalRawShares = 0)
     *      3. No pending commission rewards
     *
     *      This ensures all economic relationships are settled before retirement
     *
     * @param _prover The address of the prover to retire
     */
    function _retireProver(address _prover) internal {
        ProverInfo storage prover = provers[_prover];
        require(
            prover.state == ProverState.Active || prover.state == ProverState.Deactivated,
            "Cannot retire from current state"
        );
        require(prover.totalRawShares == 0, "Active stakes remaining");
        require(prover.pendingCommission == 0, "Commission remaining");

        // === CLOSE INTERVAL BEFORE DENOMINATOR CHANGE ===
        // Update global streaming before changing totalEffectiveActive (even if zero)
        if (globalRatePerSec > 0) {
            _updateGlobalStreaming();
        }

        // Update total effective active stake (remove this prover)
        uint256 currentEffectiveStake = _getTotalEffectiveStake(_prover);
        _updateTotalEffectiveActive(_prover, currentEffectiveStake, 0);

        prover.state = ProverState.Retired;
        activeProvers.remove(_prover);
        emit ProverRetired(_prover);
    }

    /**
     * @notice Internal function to apply minSelfStake update
     * @dev Validates that the prover still meets the new requirement before applying
     * @param _prover The address of the prover
     * @param _newMinSelfStake The new minimum self-stake amount
     */
    function _applyMinSelfStakeUpdate(address _prover, uint256 _newMinSelfStake) internal {
        ProverInfo storage prover = provers[_prover];

        // Update the minSelfStake
        prover.minSelfStake = _newMinSelfStake;

        emit MinSelfStakeUpdated(_prover, _newMinSelfStake);
    }

    // =========================================================================
    // INTERNAL HELPERS (VIEW/PURE)
    // =========================================================================

    /**
     * @notice Converts raw shares to effective token amount after applying scale factor
     * @dev Formula: effectiveAmount = (rawShares * currentScale) / SCALE_FACTOR
     *      When scale < SCALE_FACTOR, it means slashing has occurred
     * @param _prover Prover address (each prover has independent scale)
     * @param _rawShares Number of raw shares to convert
     * @return Effective token amount (post-slashing value)
     */
    function _effectiveAmount(address _prover, uint256 _rawShares) internal view returns (uint256) {
        ProverInfo storage prover = provers[_prover];
        return (_rawShares * prover.scale) / SCALE_FACTOR;
    }

    /**
     * @notice Converts token amount to raw shares using current scale factor
     * @dev Formula: rawShares = (amount * SCALE_FACTOR) / currentScale
     *      This ensures new stakes get proportional raw shares regardless of slashing history
     * @param _prover Prover address (each prover has independent scale)
     * @param _amount Token amount to convert to raw shares
     * @return Number of raw shares equivalent to the given amount
     */
    function _rawSharesFromAmount(address _prover, uint256 _amount) internal view returns (uint256) {
        ProverInfo storage prover = provers[_prover];
        require(prover.scale > 0, "Invalid scale");
        return (_amount * SCALE_FACTOR) / prover.scale;
    }

    /**
     * @notice Gets total effective stake for a prover (all stakers combined, post-slashing)
     * @param _prover Prover address
     * @return Total effective stake amount
     */
    function _getTotalEffectiveStake(address _prover) internal view returns (uint256) {
        ProverInfo storage prover = provers[_prover];
        return _effectiveAmount(_prover, prover.totalRawShares);
    }

    /**
     * @notice Gets the prover's self-stake in raw shares
     * @param _prover Prover address
     * @return Raw shares owned by the prover themselves
     */
    function _selfRawShares(address _prover) internal view returns (uint256) {
        ProverInfo storage prover = provers[_prover];
        return prover.stakes[_prover].rawShares;
    }
}
