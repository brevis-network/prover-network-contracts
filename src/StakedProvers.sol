// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./access/AccessControl.sol";

/**
 * @title StakedProvers
 * @notice A staking contract that manages proof nodes and their delegated stakes
 * @dev This contract implements a delegation-based staking system where:
 *      - Provers can initialize themselves with minimum self-stake requirements
 *      - Users can delegate stakes to active provers
 *      - Rewards are distributed proportionally with commission to provers
 *      - Slashing affects all stakes proportionally through a global scale factor
 *      - Unstaking has a configurable delay period for security
 */
abstract contract StakedProvers is ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // === ENUMS ===
    enum ProverState {
        Null,
        Active,
        Retired
    }

    // === CONSTANTS and GLOBAL CONFIGURATION ===
    // Commission rates are expressed in basis points (1 bp = 0.01%)
    uint256 public constant COMMISSION_RATE_DENOMINATOR = 10000;

    // Slashing percentages are expressed in parts per million for higher precision
    uint256 public constant SLASH_FACTOR_DENOMINATOR = 1e6;

    // Base scale factor for mathematical precision in reward calculations
    uint256 public constant SCALE_FACTOR = 1e18;

    // Maximum number of pending unstake requests per staker per prover
    uint256 public constant MAX_PENDING_UNSTAKES = 10;

    // Configurable unstaking delay period (default: 7 days, max: 30 days)
    uint256 public UNSTAKE_DELAY = 7 days;

    address public brevToken; // ERC20 token used for both staking and rewards

    // Global minimum self-stake requirement for all provers
    uint256 public globalMinSelfStake;

    /**
     * @notice Core information for each prover in the network
     * @dev Uses a dual-share system: raw shares (pre-slash) and effective shares (post-slash)
     *      Raw shares remain constant until stake changes, while effective value fluctuates with slashing
     */
    struct ProverInfo {
        ProverState state; // Current state of the prover (Null, Active, Retired)
        uint256 minSelfStake; // Minimum self-stake required to accept delegations
        uint64 commissionRate; // Commission rate in basis points (0-10000, where 10000 = 100%)
        // === SHARE TRACKING ===
        uint256 totalRawShares; // Total raw shares across all stakers (invariant to slashing)
        uint256 scale; // Global scale factor for this prover (decreases with slashing)
        // === REWARD DISTRIBUTION ===
        uint256 accRewardPerRawShare; // Accumulated rewards per raw share (scaled by SCALE_FACTOR)
        uint256 pendingCommission; // Unclaimed commission rewards for the prover
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
        uint256 pendingRewards; // Accumulated but unclaimed staking rewards
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

    // === STORAGE ===
    mapping(address => ProverInfo) internal provers; // Prover address -> ProverInfo
    address[] public proverList; // Enumerable list of all registered provers
    EnumerableSet.AddressSet activeProvers; // Set of currently active provers

    // === EVENTS ===
    // Prover lifecycle events
    event ProverInitialized(address indexed prover, uint256 minSelfStake, uint64 commissionRate);
    event ProverDeactivated(address indexed prover);
    event ProverRetired(address indexed prover);

    // Staking lifecycle events
    event Staked(address indexed staker, address indexed prover, uint256 amount, uint256 mintedShares);
    event UnstakeRequested(address indexed staker, address indexed prover, uint256 amount, uint256 burnedShares);
    event UnstakeCompleted(address indexed staker, address indexed prover, uint256 amount);

    // Reward and slashing events
    event RewardsAdded(address indexed prover, uint256 amount, uint256 commission, uint256 distributed);
    event RewardsWithdrawn(address indexed staker, address indexed prover, uint256 amount);
    event ProverSlashed(address indexed prover, uint256 percentage, uint256 totalSlashed);

    // Administrative events
    event UnstakeDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event GlobalMinSelfStakeUpdated(uint256 oldMinStake, uint256 newMinStake);

    /**
     * @notice Constructor for direct deployment (non-upgradeable)
     * @dev Sets up the contract with immediate initialization.
     *      For upgradeable deployment, use the no-arg constructor and call init() instead.
     * @param _token ERC20 token used for both staking and rewards
     * @param _globalMinSelfStake Global minimum self-stake requirement for all provers
     */
    constructor(address _token, uint256 _globalMinSelfStake) {
        if (_token != address(0)) {
            brevToken = _token;
        }
        globalMinSelfStake = _globalMinSelfStake;
        // Note: Ownable constructor automatically sets msg.sender as owner
    }

    /**
     * @notice Initialize the staking contract for upgradeable deployment
     * @dev This function sets up the contract state after deployment.
     * @param _token ERC20 token address used for both staking and rewards
     * @param _globalMinSelfStake Global minimum self-stake requirement for all provers
     */
    function init(address _token, uint256 _globalMinSelfStake) external onlyOwner {
        initOwner();
        // Set the staking/reward token
        brevToken = _token;
        globalMinSelfStake = _globalMinSelfStake;
    }

    /**
     * @notice Modifier to ensure operations only occur on active provers
     * @param _prover Address of the prover to check
     */
    modifier onlyActiveProver(address _prover) {
        require(provers[_prover].state == ProverState.Active, "Prover not active");
        _;
    }

    // === SHARE CONVERSION HELPERS ===
    // These functions handle the conversion between raw shares and effective amounts
    // Raw shares remain constant until stake changes, while effective amounts change with slashing

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

    /**
     * @notice Initialize a new prover with staking parameters
     * @dev Algorithm:
     *      1. Validate prover is not already registered
     *      2. Validate commission rate is within bounds (0-100%)
     *      3. Initialize prover struct with default scale (1.0)
     *      4. Add to prover registry
     *      5. If minSelfStake > 0, automatically stake the minimum required amount
     * @param _minSelfStake Minimum tokens the prover must self-stake to accept delegations
     * @param _commissionRate Commission percentage in basis points (0-10000)
     */
    function initProver(uint256 _minSelfStake, uint64 _commissionRate) external {
        require(provers[msg.sender].state == ProverState.Null, "Prover already initialized");
        require(_commissionRate <= COMMISSION_RATE_DENOMINATOR, "Invalid commission rate");
        require(_minSelfStake > 0, "Minimum self stake must be positive");
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
        if (_minSelfStake > 0) {
            _stake(msg.sender, msg.sender, _minSelfStake);
        }

        emit ProverInitialized(msg.sender, _minSelfStake, _commissionRate);
    }

    /**
     * @notice Delegate stake to an active prover
     * @dev Public interface for staking - delegates to internal _stake function
     * @param _prover Address of the prover to stake with
     * @param _amount Amount of tokens to delegate
     */
    function stake(address _prover, uint256 _amount) external nonReentrant onlyActiveProver(_prover) {
        require(_amount > 0, "Amount must be positive");
        _stake(msg.sender, _prover, _amount);
    }

    /**
     * @notice Internal staking logic implementing reward accounting and share minting
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
     * @param _staker Address of the account providing the stake
     * @param _prover Address of the prover receiving the delegation
     * @param _amount Amount of tokens to stake
     */
    function _stake(address _staker, address _prover, uint256 _amount) internal {
        ProverInfo storage prover = provers[_prover];
        StakeInfo storage stakeInfo = prover.stakes[_staker];

        // Gate delegations when prover is below min self-stake
        // This ensures prover has skin in the game before accepting external delegations
        if (_staker != _prover && prover.minSelfStake > 0) {
            uint256 selfEffective = _effectiveAmount(_prover, _selfRawShares(_prover));
            require(selfEffective >= prover.minSelfStake, "Prover below min self-stake");
        }

        // Transfer tokens from staker to contract (fail early if insufficient balance/allowance)
        IERC20(brevToken).safeTransferFrom(_staker, address(this), _amount);

        // Convert amount to raw shares at current scale
        // This ensures fair share allocation regardless of slashing history
        uint256 newRawShares = _rawSharesFromAmount(_prover, _amount);

        // If this is a new staker, add them to the stakers set
        if (stakeInfo.rawShares == 0) {
            prover.stakers.add(_staker);
        }

        // === REWARD ACCOUNTING ===
        // Update pending rewards before changing stake to ensure accurate reward calculation
        uint256 accRewardPerRawShare = prover.accRewardPerRawShare;
        if (stakeInfo.rawShares > 0) {
            // Calculate accrued rewards since last update
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

        emit Staked(_staker, _prover, _amount, newRawShares);
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
    function requestUnstake(address _prover, uint256 _amount) external nonReentrant {
        require(_amount > 0, "Amount must be positive");
        require(provers[_prover].state != ProverState.Null, "Unknown prover");

        ProverInfo storage prover = provers[_prover];
        StakeInfo storage stakeInfo = prover.stakes[msg.sender];

        // Convert amount to raw shares for internal accounting
        uint256 rawSharesToUnstake = _rawSharesFromAmount(_prover, _amount);
        require(stakeInfo.rawShares >= rawSharesToUnstake, "Insufficient stake");
        require(stakeInfo.pendingUnstakes.length < MAX_PENDING_UNSTAKES, "Too many pending unstakes");

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

        emit UnstakeRequested(msg.sender, _prover, _amount, rawSharesToUnstake);
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
        require(totalEffectiveAmount > 0, "No tokens to withdraw");

        // Transfer total amount back to staker
        IERC20(brevToken).safeTransfer(msg.sender, totalEffectiveAmount);

        emit UnstakeCompleted(msg.sender, _prover, totalEffectiveAmount);
    }

    /**
     * @notice Slash a prover for invalid proof submission or malicious behavior
     * @dev Global Slashing Algorithm:
     *      1. Calculate remaining percentage after slashing
     *      2. Update global scale factor: newScale = oldScale * (1 - slashPercentage)
     *      3. This affects ALL stakes (active + pending unstake) proportionally
     *      4. Calculate total slashed amount for event emission
     *
     *      Key Properties:
     *      - All stakers are slashed proportionally regardless of when they staked
     *      - Pending unstakes are also subject to slashing (prevents exit to avoid punishment)
     *      - Scale factor creates efficient slashing without iterating over all stakers
     *      - Slashing is irreversible and affects future effective amounts immediately
     *
     * @param _prover The address of the prover to be slashed
     * @param _percentage The percentage of stake to slash (0-999999, where 1000000 = 100%)
     */
    function slash(address _prover, uint256 _percentage) internal {
        require(provers[_prover].state != ProverState.Null, "Unknown prover");
        require(_percentage < SLASH_FACTOR_DENOMINATOR, "Cannot slash 100%");

        ProverInfo storage prover = provers[_prover];

        // Calculate total effective stake before slashing (for event emission)
        uint256 totalEffectiveBefore = _getTotalEffectiveStake(_prover);

        // === GLOBAL SCALE UPDATE ===
        // Update the global scale factor to reflect the slash
        // This is the core slashing mechanism - affects both active stakes AND pending unbonds
        uint256 remainingFactor = SLASH_FACTOR_DENOMINATOR - _percentage;
        prover.scale = (prover.scale * remainingFactor) / SLASH_FACTOR_DENOMINATOR;

        // Calculate total slashed amount for event (active shares only for clarity)
        uint256 totalEffectiveAfter = _getTotalEffectiveStake(_prover);
        uint256 totalSlashed = totalEffectiveBefore - totalEffectiveAfter;

        emit ProverSlashed(_prover, _percentage, totalSlashed);
    }

    /**
     * @notice Distribute rewards to a prover and their stakers
     * @dev Reward Distribution Algorithm:
     *      1. Calculate commission for prover (commissionRate * totalRewards)
     *      2. Remaining rewards go to stakers proportionally
     *      3. Update accRewardPerRawShare for stakers using: newAcc = oldAcc + (stakersReward * SCALE_FACTOR) / totalRawShares
     *      4. If no stakers exist, prover gets all rewards as commission
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
    function addRewards(address _prover, uint256 _amount) internal {
        require(provers[_prover].state != ProverState.Null, "Unknown prover");
        if (_amount == 0) return;

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
            // Update accumulated reward per raw share for all stakers
            prover.accRewardPerRawShare += (stakersReward * SCALE_FACTOR) / prover.totalRawShares;
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

        ProverInfo storage prover = provers[_prover];
        StakeInfo storage stakeInfo = prover.stakes[msg.sender];

        uint256 payout = 0;

        // === STAKING REWARDS UPDATE ===
        // Update pending rewards for active stakes
        uint256 accRewardPerRawShare = prover.accRewardPerRawShare;
        if (stakeInfo.rawShares > 0) {
            // Calculate total accrued rewards for this staker
            uint256 accrued = (stakeInfo.rawShares * accRewardPerRawShare) / SCALE_FACTOR;
            // Calculate new rewards since last claim
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
        if (msg.sender == _prover && prover.pendingCommission > 0) {
            payout += prover.pendingCommission;
            prover.pendingCommission = 0;
        }

        require(payout > 0, "No rewards available");

        // Transfer rewards to caller
        IERC20(brevToken).safeTransfer(msg.sender, payout);

        emit RewardsWithdrawn(msg.sender, _prover, payout);
    }

    /**
     * @notice Admin function to deactivate a malicious or problematic prover
     * @dev Deactivation prevents new stakes but allows existing operations to continue
     *      Existing stakers can still unstake and withdraw rewards
     * @param _prover The address of the prover to deactivate
     */
    function deactivateProver(address _prover) external onlyOwner {
        require(provers[_prover].state != ProverState.Null, "Unknown prover");
        require(provers[_prover].state == ProverState.Active, "Prover already inactive");

        provers[_prover].state = ProverState.Retired;
        activeProvers.remove(_prover);
        emit ProverDeactivated(_prover);
    }

    /**
     * @notice Admin function to set the unstaking delay period
     * @dev Algorithm:
     *      1. Validate new delay is within reasonable bounds (≤ 30 days)
     *      2. Update the global UNSTAKE_DELAY variable
     *      3. Emit event for transparency
     *
     *      Security Considerations:
     *      - Delay protects against rapid exit during slashing events
     *      - Maximum 30 days prevents unreasonably long lock periods
     *      - Changes apply to new unstake requests only (existing requests use old delay)
     *
     * @param _newDelay The new unstake delay in seconds
     */
    function setUnstakeDelay(uint256 _newDelay) external onlyOwner {
        require(_newDelay <= 30 days, "Unstake delay too long");
        uint256 oldDelay = UNSTAKE_DELAY;
        UNSTAKE_DELAY = _newDelay;
        emit UnstakeDelayUpdated(oldDelay, _newDelay);
    }

    /**
     * @notice Set the global minimum self-stake requirement for all provers
     * @dev Only affects new prover registrations, not existing provers
     * @param _newGlobalMinSelfStake The new global minimum self-stake in token units
     */
    function setGlobalMinSelfStake(uint256 _newGlobalMinSelfStake) external onlyOwner {
        require(_newGlobalMinSelfStake > 0, "Global min self stake must be positive");
        uint256 oldMinStake = globalMinSelfStake;
        globalMinSelfStake = _newGlobalMinSelfStake;
        emit GlobalMinSelfStakeUpdated(oldMinStake, _newGlobalMinSelfStake);
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
        require(prover.state == ProverState.Active, "Already inactive");
        require(prover.totalRawShares == 0, "Active stakes remaining");
        require(prover.pendingCommission == 0, "Commission remaining");

        prover.state = ProverState.Retired;
        activeProvers.remove(_prover);
        emit ProverRetired(_prover);
    }

    // === VIEW FUNCTIONS ===
    // These functions provide read-only access to contract state for external consumers

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
        return (
            prover.state,
            prover.minSelfStake,
            prover.commissionRate,
            effectiveTotalStaked,
            selfEffective,
            prover.pendingCommission,
            prover.stakers.length()
        );
    }

    /**
     * @notice Get comprehensive stake information for a specific staker with a prover
     * @dev Calculates real-time pending rewards including live reward accumulation
     * @param _prover Address of the prover
     * @param _staker Address of the staker to query
     * @return amount Current effective stake amount (post-slashing)
     * @return totalPendingUnstake Total effective amount currently in unstaking process (post-slashing)
     * @return pendingUnstakeCount Number of pending unstake requests
     * @return pendingRewards Total pending rewards (staking rewards + commission if prover)
     */
    function getStakeInfo(address _prover, address _staker)
        external
        view
        returns (uint256 amount, uint256 totalPendingUnstake, uint256 pendingUnstakeCount, uint256 pendingRewards)
    {
        ProverInfo storage prover = provers[_prover];
        StakeInfo storage stakeInfo = prover.stakes[_staker];

        // Convert raw shares to effective amounts (subject to slashing)
        uint256 effectiveAmount = _effectiveAmount(_prover, stakeInfo.rawShares);

        // Calculate total pending unstake amount across all requests
        uint256 totalEffectivePendingUnstake = 0;
        for (uint256 i = 0; i < stakeInfo.pendingUnstakes.length; i++) {
            totalEffectivePendingUnstake += _effectiveAmount(_prover, stakeInfo.pendingUnstakes[i].rawShares);
        }

        // === REAL-TIME REWARD CALCULATION ===
        // Calculate total pending rewards with live accumulation
        uint256 stakingRewards = stakeInfo.pendingRewards;
        uint256 accRewardPerRawShare = prover.accRewardPerRawShare;

        // Add newly accrued staking rewards since last update
        if (stakeInfo.rawShares > 0) {
            uint256 accrued = (stakeInfo.rawShares * accRewardPerRawShare) / SCALE_FACTOR;
            uint256 delta = accrued >= stakeInfo.rewardDebt ? (accrued - stakeInfo.rewardDebt) : 0;
            stakingRewards += delta;
        }

        // Add commission if this is the prover making the query
        uint256 totalRewards = stakingRewards;
        if (_staker == _prover) {
            totalRewards += prover.pendingCommission;
        }

        return (effectiveAmount, totalEffectivePendingUnstake, stakeInfo.pendingUnstakes.length, totalRewards);
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
}
