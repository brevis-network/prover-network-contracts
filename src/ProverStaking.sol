// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./access/AccessControl.sol";
import "./interfaces/IProverRewards.sol";

// =============================================================
// Custom Errors (grouped by functional domain)
// =============================================================

// --- Global / Admin Configuration ---
error GlobalMinSelfStakeNotMet(); // Provided value below global min requirement
error InvalidArg(); // Generic invalid admin/user argument (delay too long, zero addr, etc.)

// --- Prover Lifecycle & State ---
error ProverNotRegistered(); // Prover struct not initialized
error InvalidProverState(); // Prover in unexpected state for operation
error MinSelfStakeNotMet(); // Prover's self effective stake < required min
error ActiveStakesRemain(); // Attempting lifecycle action while stakes remain
error CommissionRemain(); // Attempting lifecycle action while commission pending
error InvalidCommission(); // Commission rate > denominator (kept for backwards compatibility)
error InvalidScale(); // Invalid scale related parameter (generic guard)

// --- Staking / Unstaking Operations ---
error ZeroAmount(); // Amount parameter is zero
error InsufficientStake(); // Not enough stake/shares to perform action
error SelfStakeUnderflow(); // Prover trying to unstake more than self stake
error TooManyPendingUnstakes(); // Exceeded per-staker pending unstake requests
error NoReadyUnstakes(); // No matured pending unstakes exist

// --- Slashing / Treasury ---
error SlashTooHigh(); // Slash percentage > MAX_SLASH_PERCENTAGE
error ScaleTooLow(); // Resulting scale would breach hard floor
error TreasuryInsufficient(); // Treasury pool balance too low for withdrawal

/**
 * @title ProverStaking
 * @notice A staking contract that manages proof nodes and their delegated stakes
 * @dev This contract implements a delegation-based staking system where:
 *      - Provers can initialize themselves with minimum self-stake requirements
 *      - Users can delegate stakes to active provers
 *      - Slashing affects all stakes proportionally through a global scale factor
 *      - Unstaking has a configurable delay period for security
 *      - Rewards are handled by a separate ProverRewards contract for security isolation
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

    enum ParamName {
        UnstakeDelay,
        GlobalMinSelfStake,
        MaxSlashPercentage
    }

    // Commission rates are expressed in basis points (1 bp = 0.01%)
    uint256 public constant COMMISSION_RATE_DENOMINATOR = 10000;

    // Slashing percentages are expressed in parts per million for higher precision
    uint256 public constant SLASH_FACTOR_DENOMINATOR = 1e6;

    // Base scale factor for mathematical precision in reward calculations
    uint256 public constant SCALE_FACTOR = 1e18;

    // Soft / operational threshold (20% = 2e17): crossing this DEACTIVATION_SCALE deactivates the prover,
    // but further slashing is still allowed down to the MIN_SCALE_FLOOR (hard floor). Once a slash
    // would push scale below the hard floor (10%), the slash reverts to avoid pathological
    // raw share inflation and precision loss.
    uint256 public constant DEACTIVATION_SCALE = 2e17; // 20% (soft threshold – triggers deactivation)
    uint256 public constant MIN_SCALE_FLOOR = 1e17; // 10% (hard invariant – cannot be crossed)

    // Maximum number of pending unstake requests per staker per prover
    uint256 public constant MAX_PENDING_UNSTAKES = 10;

    // Access control role for slashing operations
    // 12b42e8a160f6064dc959c6f251e3af0750ad213dbecf573b4710d67d6c28e39
    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");

    /**
     * @notice Core information for each prover in the network
     * @dev Uses a dual-share system: raw shares (pre-slash) and effective shares (post-slash)
     *      Raw shares remain constant until stake changes, while effective value fluctuates with slashing
     *      Reward accounting is handled by ProverRewards contract
     */
    struct ProverInfo {
        ProverState state; // Current state of the prover (Null, Active, Retired, Deactivated)
        uint256 minSelfStake; // Minimum self-stake required to accept delegations
        uint256 totalRawShares; // Total raw shares across all stakers (invariant to slashing)
        uint256 scale; // Global scale factor for this prover (decreases with slashing)
        mapping(address => StakeInfo) stakes; // Individual stake information per staker
        EnumerableSet.AddressSet stakers; // Set of all stakers for this prover
    }

    /**
     * @notice Individual stake information for each staker-prover pair
     * @dev Tracks active stakes and pending unstake operations
     *      Reward accounting is handled by ProverRewards contract
     */
    struct StakeInfo {
        uint256 rawShares; // Raw shares owned (before applying scale factor)
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

    // =========================================================================
    // STORAGE
    // =========================================================================

    // Unified global parameters mapping
    mapping(ParamName => uint256) public globalParams;

    address public stakingToken; // ERC20 token used for staking (renamed from brevToken)

    // Global pool of slashed tokens available for treasury withdrawal
    uint256 public treasuryPool;

    // ProverRewards contract for reward distribution
    IProverRewards public proverRewards;

    mapping(address => ProverInfo) internal provers; // Prover address -> ProverInfo
    address[] public proverList; // Enumerable list of all registered provers
    EnumerableSet.AddressSet activeProvers; // Set of currently active provers

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
    event MinSelfStakeUpdated(address indexed prover, uint256 newMinSelfStake);
    event ProverRewardsContractUpdated(address indexed newContract);

    // Staking lifecycle events
    event Staked(address indexed staker, address indexed prover, uint256 amount, uint256 mintedShares);
    event UnstakeRequested(address indexed staker, address indexed prover, uint256 amount, uint256 rawSharesToUnstake);
    event UnstakeCompleted(address indexed staker, address indexed prover, uint256 amount);

    // Slashing events
    event ProverSlashed(address indexed prover, uint256 percentage, uint256 totalSlashed);
    event TreasuryPoolWithdrawn(address indexed to, uint256 amount);

    // Administrative events
    event GlobalParamUpdated(ParamName indexed param, uint256 newValue);

    // =========================================================================
    // CONSTRUCTOR & INITIALIZATION
    // =========================================================================

    /**
     * @notice Constructor for direct deployment (non-upgradeable)
     * @dev Initializes the contract with staking token and global minimum self-stake.
     *      For upgradeable deployment, use the no-arg constructor and call init() instead.
     * @param _stakingToken ERC20 token address for staking
     * @param _globalMinSelfStakeAmount Global minimum self-stake requirement for all provers
     */
    constructor(address _stakingToken, uint256 _globalMinSelfStakeAmount) {
        _init(_stakingToken, _globalMinSelfStakeAmount);
        // Note: Ownable constructor automatically sets msg.sender as owner
    }

    /**
     * @notice Initialize the staking contract for upgradeable deployment
     * @dev This function sets up the contract state after deployment.
     * @param _stakingToken ERC20 token address used for staking
     * @param _globalMinSelfStakeAmount Global minimum self-stake requirement for all provers
     */
    function init(address _stakingToken, uint256 _globalMinSelfStakeAmount) external {
        _init(_stakingToken, _globalMinSelfStakeAmount);
        initOwner();
    }

    /**
     * @notice Initialize the staking contract for upgradeable deployment
     *         Internal initialization logic shared by constructor and init function
     * @param _stakingToken ERC20 token address for staking
     * @param _globalMinSelfStakeAmount Global minimum self-stake requirement for all provers
     */
    function _init(address _stakingToken, uint256 _globalMinSelfStakeAmount) private {
        stakingToken = _stakingToken;

        // Initialize global parameters with default values
        globalParams[ParamName.UnstakeDelay] = 7 days;
        globalParams[ParamName.GlobalMinSelfStake] = _globalMinSelfStakeAmount;
        globalParams[ParamName.MaxSlashPercentage] = 500000; // 50% (500,000 parts per million)
    }

    // =========================================================================
    // EXTERNAL FUNCTIONS (STATE-CHANGING)
    // =========================================================================

    /**
     * @notice Initialize a new prover and self-stake with a minimum amount
     * @param _minSelfStake Minimum tokens the prover must self-stake to accept delegations
     * @param _commissionRate Commission percentage in basis points (0-10000) - used for ProverRewards contract
     */
    function initProver(uint256 _minSelfStake, uint64 _commissionRate) external {
        if (provers[msg.sender].state != ProverState.Null) revert InvalidProverState();
        if (_commissionRate > COMMISSION_RATE_DENOMINATOR) revert InvalidCommission();
        if (_minSelfStake < _globalMinSelfStake()) revert GlobalMinSelfStakeNotMet();

        ProverInfo storage prover = provers[msg.sender];
        prover.state = ProverState.Active;
        prover.minSelfStake = _minSelfStake;
        prover.scale = SCALE_FACTOR; // Initialize scale to 1.0 (no slashing yet)

        // Register prover in global mappings
        proverList.push(msg.sender);
        activeProvers.add(msg.sender);

        // Initialize prover rewards if rewards contract is set
        if (address(proverRewards) != address(0)) {
            proverRewards.initProverRewards(msg.sender, _commissionRate);
        }

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
     *      4. Update reward accounting via ProverRewards contract (if set)
     *      5. Mint new raw shares and update totals
     *      6. Update reward debt via ProverRewards contract (if set)
     *
     *      Self-staking is always allowed regardless of prover state
     * @param _prover Address of the prover to stake with
     * @param _amount Amount of tokens to delegate
     */
    function stake(address _prover, uint256 _amount) public nonReentrant {
        if (_amount == 0) revert ZeroAmount();
        if (provers[_prover].state == ProverState.Null) revert ProverNotRegistered();

        ProverInfo storage prover = provers[_prover];
        StakeInfo storage stakeInfo = prover.stakes[msg.sender];

        // Delegation-specific validations (only apply to external delegations, not self-staking)
        if (msg.sender != _prover) {
            // Only allow delegation to active provers, but always allow self-staking
            if (prover.state != ProverState.Active) revert InvalidProverState();

            // Gate delegations when prover is below min self-stake
            // This ensures prover has skin in the game before accepting external delegations
            uint256 selfEffective = _effectiveAmount(_prover, _selfRawShares(_prover));
            if (selfEffective < prover.minSelfStake) revert MinSelfStakeNotMet();
        }

        // Transfer tokens from staker to contract (fail early if insufficient balance/allowance)
        IERC20(stakingToken).safeTransferFrom(msg.sender, address(this), _amount);

        // Convert amount to raw shares at current scale
        // This ensures fair share allocation regardless of slashing history
        uint256 newRawShares = _rawSharesFromAmount(_prover, _amount);

        // If this is a new staker, add them to the stakers set
        if (stakeInfo.rawShares == 0) {
            prover.stakers.add(msg.sender);
        }

        // === REWARD ACCOUNTING === (via ProverRewards contract if set)
        if (address(proverRewards) != address(0)) {
            proverRewards.settleStakerRewards(_prover, msg.sender, stakeInfo.rawShares);
        }

        // === SHARE MINTING ===
        // Update stake amount (in raw shares) - follows CEI (Checks-Effects-Interactions) pattern
        stakeInfo.rawShares += newRawShares;
        prover.totalRawShares += newRawShares;

        // === UPDATE REWARD DEBT === (via ProverRewards contract if set)
        if (address(proverRewards) != address(0)) {
            proverRewards.updateStakerRewardDebt(_prover, msg.sender, stakeInfo.rawShares);
        }

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
        if (_amount == 0) revert ZeroAmount();
        if (provers[_prover].state == ProverState.Null) revert ProverNotRegistered();

        ProverInfo storage prover = provers[_prover];
        StakeInfo storage stakeInfo = prover.stakes[msg.sender];
        if (stakeInfo.pendingUnstakes.length >= MAX_PENDING_UNSTAKES) revert TooManyPendingUnstakes();

        // Convert amount to raw shares for internal accounting
        uint256 rawSharesToUnstake = _rawSharesFromAmount(_prover, _amount);
        if (stakeInfo.rawShares < rawSharesToUnstake) revert InsufficientStake();

        // === PROVER SELF-STAKE VALIDATION ===
        // For prover's self stake, ensure minimum self stake is maintained
        // EXCEPTION: Allow going to zero (complete exit) even if below minimum
        if (msg.sender == _prover) {
            uint256 currentSelfRawShares = _selfRawShares(_prover);
            if (currentSelfRawShares < rawSharesToUnstake) revert SelfStakeUnderflow();
            uint256 remainingEffective = _effectiveAmount(_prover, currentSelfRawShares - rawSharesToUnstake);

            // Allow going below minSelfStake only if it results in zero self-stake (complete exit)
            if (remainingEffective > 0) {
                if (remainingEffective < prover.minSelfStake) revert MinSelfStakeNotMet();
            }
        }

        // === REWARD ACCOUNTING === (via ProverRewards contract if set)
        if (address(proverRewards) != address(0)) {
            proverRewards.settleStakerRewards(_prover, msg.sender, stakeInfo.rawShares);
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

        // === UPDATE REWARD DEBT === (via ProverRewards contract if set)
        if (address(proverRewards) != address(0)) {
            proverRewards.updateStakerRewardDebt(_prover, msg.sender, stakeInfo.rawShares);
        }

        emit UnstakeRequested(msg.sender, _prover, _amount, rawSharesToUnstake);
    }

    /**
     * @notice Request unstaking for all staked tokens with a prover
     * @dev Convenience function to avoid rounding surprises when trying to unstake everything.
     *      Calculates the current effective amount and delegates to requestUnstake for consistency.
     * @param _prover Address of the prover to unstake all tokens from
     */
    function requestUnstakeAll(address _prover) external {
        if (provers[_prover].state == ProverState.Null) revert ProverNotRegistered();

        ProverInfo storage prover = provers[_prover];
        StakeInfo storage stakeInfo = prover.stakes[msg.sender];

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

        uint256 totalEffectiveAmount = 0;
        uint256 completedCount = 0;

        // Process unstakes from the beginning (chronological order)
        // Once we hit a request that's not ready, all following requests will also not be ready
        for (uint256 i = 0; i < stakeInfo.pendingUnstakes.length; i++) {
            PendingUnstake storage unstakeRequest = stakeInfo.pendingUnstakes[i];

            // Check if this request meets the delay requirement
            if (block.timestamp >= unstakeRequest.unstakeTime + _unstakeDelay()) {
                // Calculate effective amount for this request
                uint256 effectiveAmount = _effectiveAmount(_prover, unstakeRequest.rawShares);
                totalEffectiveAmount += effectiveAmount;
                completedCount++;
            } else {
                // This request is not ready, and neither will any subsequent ones
                break;
            }
        }

        if (completedCount == 0) revert NoReadyUnstakes();

        // Remove all completed requests from the beginning of the array
        // Shift remaining elements to the front
        for (uint256 i = 0; i < stakeInfo.pendingUnstakes.length - completedCount; i++) {
            stakeInfo.pendingUnstakes[i] = stakeInfo.pendingUnstakes[i + completedCount];
        }
        // Remove the completed elements from the end
        for (uint256 i = 0; i < completedCount; i++) {
            stakeInfo.pendingUnstakes.pop();
        }

        if (totalEffectiveAmount > 0) {
            IERC20(stakingToken).safeTransfer(msg.sender, totalEffectiveAmount);
        }

        emit UnstakeCompleted(msg.sender, _prover, totalEffectiveAmount);
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
     * @param _percentage The percentage of stake to slash (0 to configured max slash percentage)
     */
    function slash(address _prover, uint256 _percentage) external onlyRole(SLASHER_ROLE) {
        if (provers[_prover].state == ProverState.Null) revert ProverNotRegistered();
        if (_percentage > _maxSlashPercentage()) revert SlashTooHigh();

        ProverInfo storage prover = provers[_prover];

        // Calculate total effective stake before slashing (for event emission)
        uint256 totalEffectiveBefore = _getTotalEffectiveStake(_prover);

        // === GLOBAL SCALE UPDATE WITH DUAL THRESHOLDS ===
        // Compute prospective new scale after this slash.
        uint256 remainingFactor = SLASH_FACTOR_DENOMINATOR - _percentage;
        uint256 newScale = (prover.scale * remainingFactor) / SLASH_FACTOR_DENOMINATOR;

        // Hard stop: do not allow scale to reach or drop below MIN_SCALE_FLOOR.
        if (newScale <= MIN_SCALE_FLOOR) revert ScaleTooLow();

        // Apply new scale.
        prover.scale = newScale;

        // === TREASURY POOL ACCOUNTING ===
        // Calculate total slashed amount and add to treasury pool
        uint256 totalEffectiveAfter = _getTotalEffectiveStake(_prover);
        uint256 totalSlashed = totalEffectiveBefore - totalEffectiveAfter;
        treasuryPool += totalSlashed;

        // === AUTO-DEACTIVATION CHECK ===
        // If scale at or below DEACTIVATION_SCALE, deactivate (but allow future slashes until hard floor).
        if (prover.scale <= DEACTIVATION_SCALE && prover.state == ProverState.Active) {
            prover.state = ProverState.Deactivated;
            activeProvers.remove(_prover);
            emit ProverDeactivated(_prover);
        }

        emit ProverSlashed(_prover, _percentage, totalSlashed);
    }

    /**
     * @notice Allow a prover to voluntarily retire (self-initiated retirement)
     * @dev Provers can retire themselves when they have no active stakes or pending rewards
     */
    function retireProver() external {
        if (provers[msg.sender].state == ProverState.Null) revert ProverNotRegistered();
        _retireProver(msg.sender);
    }

    /**
     * @notice Admin function to force retire a prover (admin-initiated retirement)
     * @dev Allows admin to retire inactive provers for cleanup
     * @param _prover The address of the prover to retire
     */
    function retireProver(address _prover) external onlyOwner {
        if (provers[_prover].state == ProverState.Null) revert ProverNotRegistered();
        _retireProver(_prover);
    }

    /**
     * @notice Allow a retired prover to unretire and return to active status
     * @dev Retired provers can unretire themselves, but must already meet minimum self-stake requirements
     *      The prover should self-stake while retired before calling this function
     */
    function unretireProver() external {
        if (provers[msg.sender].state != ProverState.Retired) revert InvalidProverState();

        ProverInfo storage prover = provers[msg.sender];

        // Verify prover meets minimum self-stake requirements before unretiring
        uint256 selfEffective = _effectiveAmount(msg.sender, _selfRawShares(msg.sender));
        if (selfEffective < prover.minSelfStake) revert MinSelfStakeNotMet();
        if (selfEffective < _globalMinSelfStake()) revert GlobalMinSelfStakeNotMet();

        // Reset slashing scale for fresh start
        prover.scale = SCALE_FACTOR;

        // Recompute effective stake (not stored inline since unused post-reset)
        _getTotalEffectiveStake(msg.sender);

        // Unretire as active prover
        prover.state = ProverState.Active;
        activeProvers.add(msg.sender);

        emit ProverUnretired(msg.sender);
    }

    /**
     * @notice Update minimum self-stake requirement for a prover
     * @dev All updates are now effective immediately since provers can exit anytime via unstaking
     * @param _newMinSelfStake New minimum self-stake amount in token units
     */
    function updateMinSelfStake(uint256 _newMinSelfStake) external {
        if (provers[msg.sender].state == ProverState.Null) revert ProverNotRegistered();
        if (_newMinSelfStake < _globalMinSelfStake()) revert GlobalMinSelfStakeNotMet();

        // Apply the update immediately - no delay needed
        _applyMinSelfStakeUpdate(msg.sender, _newMinSelfStake);
    }

    // =========================================================================
    // EXTERNAL FUNCTIONS (ADMIN ONLY)
    // =========================================================================

    /**
     * @notice Admin function to set the ProverRewards contract
     * @param _proverRewards Address of the ProverRewards contract
     */
    function setProverRewardsContract(address _proverRewards) external onlyOwner {
        proverRewards = IProverRewards(_proverRewards);
        emit ProverRewardsContractUpdated(_proverRewards);
    }

    /**
     * @notice Unified admin function to set global parameters
     * @param _param The parameter to update
     * @param _value The new value for the parameter
     */
    function setGlobalParam(ParamName _param, uint256 _value) external onlyOwner {
        globalParams[_param] = _value;
        emit GlobalParamUpdated(_param, _value);
    }

    /**
     * @notice Admin function to deactivate a malicious or problematic prover
     * @dev Deactivation prevents new stakes but allows existing operations to continue
     *      Existing stakers can still unstake and withdraw rewards
     * @param _prover The address of the prover to deactivate
     */
    function deactivateProver(address _prover) external onlyOwner {
        if (provers[_prover].state != ProverState.Active) revert InvalidProverState();

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
        if (provers[_prover].state != ProverState.Deactivated) revert InvalidProverState();

        ProverInfo storage prover = provers[_prover];

        // Check if prover still meets minimum self-stake requirements
        uint256 selfEffective = _effectiveAmount(_prover, _selfRawShares(_prover));
        if (selfEffective < prover.minSelfStake) revert MinSelfStakeNotMet();
        if (selfEffective < _globalMinSelfStake()) revert GlobalMinSelfStakeNotMet();

        prover.state = ProverState.Active;
        activeProvers.add(_prover);

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
        if (_to == address(0)) revert InvalidArg();
        if (_amount == 0) revert ZeroAmount();
        if (_amount > treasuryPool) revert TreasuryInsufficient();

        // Update treasury pool accounting
        treasuryPool -= _amount;

        // Transfer tokens to recipient
        IERC20(stakingToken).safeTransfer(_to, _amount);

        emit TreasuryPoolWithdrawn(_to, _amount);
    }

    // =========================================================================
    // EXTERNAL VIEW FUNCTIONS
    // =========================================================================

    /**
     * @notice Get detailed prover information including self-stake data
     * @param _prover Address of the prover to query
     * @return state Current state of the prover (Null, Active, Retired, Deactivated)
     * @return minSelfStake Minimum self-stake required for accepting delegations
     * @return totalStaked Total effective stake from all stakers (post-slashing)
     * @return selfEffectiveStake Prover's own effective stake amount (post-slashing)
     * @return stakerCount Number of active stakers (excluding zero-balance stakers)
     */
    function getProverInfo(address _prover)
        external
        view
        returns (
            ProverState state,
            uint256 minSelfStake,
            uint256 totalStaked,
            uint256 selfEffectiveStake,
            uint256 stakerCount
        )
    {
        ProverInfo storage prover = provers[_prover];
        uint256 effectiveTotalStaked = _getTotalEffectiveStake(_prover);
        uint256 selfEffective = _effectiveAmount(_prover, _selfRawShares(_prover));
        return (prover.state, prover.minSelfStake, effectiveTotalStaked, selfEffective, prover.stakers.length());
    }

    /**
     * @notice Get comprehensive stake information for a specific staker with a prover
     * @dev Calculates real-time pending rewards via ProverRewards contract if available
     * @param _prover Address of the prover
     * @param _staker Address of the staker to query
     * @return amount Current effective stake amount (post-slashing)
     * @return totalPendingUnstake Total effective amount currently in unstaking process (post-slashing)
     * @return pendingUnstakeCount Number of pending unstake requests
     * @return pendingRewards Total pending rewards (from ProverRewards contract if available)
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

        // Calculate pending rewards via ProverRewards contract if available
        if (address(proverRewards) != address(0)) {
            pendingRewards = proverRewards.calculateTotalPendingRewards(_prover, _staker);
        } else {
            pendingRewards = 0;
        }
    }

    /**
     * @notice Check if a prover is registered (interface for ProverRewards)
     * @param _prover Address of the prover
     * @return True if prover is registered
     */
    function isProverRegistered(address _prover) external view returns (bool) {
        return provers[_prover].state != ProverState.Null;
    }

    /**
     * @notice Get total raw shares for a prover (interface for ProverRewards)
     * @param _prover Address of the prover
     * @return Total raw shares
     */
    function getTotalRawShares(address _prover) external view returns (uint256) {
        return provers[_prover].totalRawShares;
    }

    /**
     * @notice Get raw shares for a specific staker (interface for ProverRewards)
     * @param _prover Address of the prover
     * @param _staker Address of the staker
     * @return Raw shares owned by the staker
     */
    function getStakerRawShares(address _prover, address _staker) external view returns (uint256) {
        return provers[_prover].stakes[_staker].rawShares;
    }

    /**
     * @notice Get prover state (interface for ProverRewards)
     * @param _prover Address of the prover
     * @return Current state of the prover
     */
    function getProverState(address _prover) external view returns (ProverState) {
        return provers[_prover].state;
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

        if (_requestIndex >= stakeInfo.pendingUnstakes.length) revert InvalidArg();

        PendingUnstake storage unstakeRequest = stakeInfo.pendingUnstakes[_requestIndex];
        uint256 effectiveAmount = _effectiveAmount(_prover, unstakeRequest.rawShares);
        bool canComplete = block.timestamp >= unstakeRequest.unstakeTime + _unstakeDelay();

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
        if (prover.minSelfStake < _globalMinSelfStake()) {
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
     * @return stakersCount Number of active stakers (from EnumerableSet)
     */
    function getProverInternals(address _prover)
        external
        view
        returns (uint256 totalRawShares, uint256 scale, uint256 stakersCount)
    {
        ProverInfo storage prover = provers[_prover];
        return (prover.totalRawShares, prover.scale, prover.stakers.length());
    }

    /**
     * @notice Get internal stake information for a specific staker with a prover
     * @dev Provides access to low-level stake data including raw shares
     * @param _prover Address of the prover
     * @param _staker Address of the staker to query
     * @return rawShares Raw shares owned by the staker (before applying scale factor)
     * @return totalPendingUnstakeRaw Total raw shares currently in unstaking process across all requests
     */
    function getStakeInternals(address _prover, address _staker)
        external
        view
        returns (uint256 rawShares, uint256 totalPendingUnstakeRaw)
    {
        ProverInfo storage prover = provers[_prover];
        StakeInfo storage stakeInfo = prover.stakes[_staker];

        // Calculate total pending unstake raw shares across all requests
        uint256 totalPendingRawShares = 0;
        for (uint256 i = 0; i < stakeInfo.pendingUnstakes.length; i++) {
            totalPendingRawShares += stakeInfo.pendingUnstakes[i].rawShares;
        }

        return (stakeInfo.rawShares, totalPendingRawShares);
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

    // =========================================================================
    // INTERNAL FUNCTIONS (STATE-CHANGING)
    // =========================================================================

    /**
     * @notice Internal function to handle prover retirement logic
     * @dev Retirement Requirements (ensures clean state):
     *      1. Prover must be inactive (no new stakes accepted)
     *      2. No active stakes remaining (totalRawShares = 0)
     *      3. No pending commission rewards (checked via ProverRewards contract if set)
     *
     *      This ensures all economic relationships are settled before retirement
     *
     * @param _prover The address of the prover to retire
     */
    function _retireProver(address _prover) internal {
        ProverInfo storage prover = provers[_prover];
        if (!(prover.state == ProverState.Active || prover.state == ProverState.Deactivated)) {
            revert InvalidProverState();
        }
        if (prover.totalRawShares != 0) revert ActiveStakesRemain();

        // Check for pending commission in ProverRewards contract if set
        if (address(proverRewards) != address(0)) {
            (, uint256 pendingCommission,) = proverRewards.getProverRewardInfo(_prover);
            if (pendingCommission != 0) revert CommissionRemain();
        }

        prover.state = ProverState.Retired;
        activeProvers.remove(_prover);
        emit ProverRetired(_prover);
    }

    /**
     * @notice Internal function to apply minSelfStake update
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
        if (prover.scale == 0) revert InvalidScale();
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

    // =========================================================================
    // INTERNAL HELPER FUNCTIONS FOR PARAMETER ACCESS
    // =========================================================================

    /**
     * @notice Get current unstake delay
     * @return Current unstake delay in seconds
     */
    function _unstakeDelay() internal view returns (uint256) {
        return globalParams[ParamName.UnstakeDelay];
    }

    /**
     * @notice Get current global minimum self stake
     * @return Current global minimum self stake
     */
    function _globalMinSelfStake() internal view returns (uint256) {
        return globalParams[ParamName.GlobalMinSelfStake];
    }

    /**
     * @notice Get current max slash percentage
     * @return Current max slash percentage in parts per million
     */
    function _maxSlashPercentage() internal view returns (uint256) {
        return globalParams[ParamName.MaxSlashPercentage];
    }
}
