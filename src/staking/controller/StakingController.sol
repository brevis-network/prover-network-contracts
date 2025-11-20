// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import "@security/access/PauserControl.sol"; // PauserControl -> AccessControl -> Ownable
import "../interfaces/IStakingController.sol";
import "../interfaces/IVaultFactory.sol";
import "../interfaces/IProverVault.sol";
import "./PendingUnstakes.sol";

/**
 * @title StakingController
 * @notice Central controller for managing prover vaults and staking operations
 */
contract StakingController is IStakingController, ReentrancyGuard, PauserControl, PendingUnstakes {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    // =========================================================================
    // CONSTANTS
    // =========================================================================

    // 12b42e8a160f6064dc959c6f251e3af0750ad213dbecf573b4710d67d6c28e39
    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");

    // 77a8d217b4b31e7c722578c208f5ba9973f8291ae83d602d73c54039808746ae
    bytes32 public constant AUTHORIZED_PROVER_ROLE = keccak256("AUTHORIZED_PROVER_ROLE");

    // =========================================================================
    // STORAGE
    // =========================================================================

    IERC20 public stakingToken;
    IVaultFactory public vaultFactory;

    // Parameter storage
    uint256 public minSelfStake;
    uint256 public maxSlashBps;
    bool public requireAuthorization;

    // Core data structures
    mapping(address => ProverInfo) private _proverInfo;

    // Treasury pool for slashed assets
    uint256 public treasuryPool;

    // Prover enumeration
    EnumerableSet.AddressSet proverList; // Set list of all registered provers
    EnumerableSet.AddressSet activeProvers; // Set of currently active provers

    // Storage gap for future upgrades. Reserves 40 slots.
    uint256[40] private __gap;

    // =========================================================================
    // MODIFIERS
    // =========================================================================

    // Enforce authorization when flag enabled
    modifier onlyAuthorized() {
        if (requireAuthorization && !hasRole(AUTHORIZED_PROVER_ROLE, msg.sender)) {
            revert ControllerNotAuthorized();
        }
        _;
    }

    // =========================================================================
    // CONSTRUCTOR & INITIALIZATION
    // =========================================================================

    /**
     * @dev For upgradeable: pass zero values and call init() later
     *      For direct: pass actual values for immediate initialization
     */
    constructor(
        address _stakingToken,
        address _vaultFactory,
        uint256 _unstakeDelay,
        uint256 _minSelfStake,
        uint256 _maxSlashBps
    ) {
        // Only initialize if non-zero values are provided (direct deployment)
        if (_stakingToken != address(0) && _vaultFactory != address(0)) {
            _init(_stakingToken, _vaultFactory, _unstakeDelay, _minSelfStake, _maxSlashBps);
            // Note: Ownable constructor automatically sets msg.sender as owner
        }
        // For upgradeable deployment, pass zero addresses and call init() separately
    }

    /**
     * @notice Initialize the staking contract for upgradeable deployment
     * @dev This function sets up the contract state after deployment.
     */
    function init(
        address _stakingToken,
        address _vaultFactory,
        uint256 _unstakeDelay,
        uint256 _minSelfStake,
        uint256 _maxSlashBps
    ) external {
        _init(_stakingToken, _vaultFactory, _unstakeDelay, _minSelfStake, _maxSlashBps);
        initOwner(); // requires _owner == address(0), which is only possible when it's a delegateCall
    }

    /**
     * @notice Initialize the staking contract for upgradeable deployment
     * @dev Internal initialization logic shared by constructor and init function
     */
    function _init(
        address _stakingToken,
        address _vaultFactory,
        uint256 _unstakeDelay,
        uint256 _minSelfStake,
        uint256 _maxSlashBps
    ) internal {
        stakingToken = IERC20(_stakingToken);
        vaultFactory = IVaultFactory(_vaultFactory);
        unstakeDelay = _unstakeDelay;
        minSelfStake = _minSelfStake;
        maxSlashBps = _maxSlashBps;

        // Note: Slasher role will be set by owner after BrevisMarket deployment
    }

    // =========================================================================
    // PROVER MANAGEMENT
    // =========================================================================

    /**
     * @notice Initialize a new prover with vault deployment (caller becomes the prover)
     * @dev Prover must approve controller for at least `minSelfStake` before this function
     * @param defaultCommissionRate Default commission rate in basis points (0-10000), stored at address(0)
     * @return vault The address of the deployed vault
     */
    function initializeProver(uint64 defaultCommissionRate)
        external
        override
        onlyAuthorized
        whenNotPaused
        returns (address vault)
    {
        // Validate inputs
        if (defaultCommissionRate > BPS_DENOMINATOR) revert ControllerInvalidArg();

        // Check prover not already initialized
        address prover = msg.sender;
        if (_proverInfo[prover].state != ProverState.Null) revert ControllerProverAlreadyInitialized();

        // Deploy vault via factory
        vault = vaultFactory.createVault(address(stakingToken), prover, address(this));

        // Initialize prover slashing scale to 100% (10000 basis points)
        pendingUnstakes[prover].slashingScale = BPS_DENOMINATOR;

        // Store prover info
        // Initialize prover info
        ProverInfo storage info = _proverInfo[prover];
        info.state = ProverState.Active;
        info.vault = vault;
        info.commissionRates.set(address(0), defaultCommissionRate); // Store default rate at address(0)
        info.pendingCommission = 0;
        info.joinedAt = uint64(block.timestamp);

        // Add to prover enumeration
        proverList.add(prover);
        activeProvers.add(prover);

        // Ensure prover meets minimum self-stake requirement
        // Auto-stake minimum amount if configured (prover self-stakes)
        stake(prover, minSelfStake);

        // Emit ProverInitialized event
        emit ProverInitialized(prover, vault, defaultCommissionRate);

        // Return vault address
        return vault;
    }

    /**
     * @notice Deactivate a prover (admin only)
     */
    function deactivateProver(address prover) external override onlyOwner {
        _changeProverState(prover, ProverState.Deactivated);
    }

    /**
     * @notice Batch deactivate multiple provers (admin only)
     */
    function deactivateProvers(address[] calldata provers) external override onlyOwner {
        for (uint256 i = 0; i < provers.length; i++) {
            _changeProverState(provers[i], ProverState.Deactivated);
        }
    }

    /**
     * @notice Reactivate a prover (admin can reactivate from any state, prover can only self-reactivate from Deactivated)
     */
    function reactivateProver(address prover) public override {
        address caller = msg.sender;
        ProverInfo storage proverInfo = _proverInfo[prover];
        if (proverInfo.state == ProverState.Null) revert ControllerProverNotInitialized();

        bool isAdmin = caller == owner();
        bool isProver = caller == prover;

        // Validate caller permissions
        if (!isAdmin && !isProver) {
            revert ControllerOnlyProver();
        }

        // Provers can only self-reactivate from Deactivated state, not from Jailed
        if (!isAdmin && proverInfo.state == ProverState.Jailed) {
            revert ControllerOnlyAdmin();
        }

        // Check if prover meets minimum self-stake requirement for reactivation
        address vault = proverInfo.vault;
        uint256 proverShares = IProverVault(vault).balanceOf(prover);
        uint256 proverAssets = IProverVault(vault).convertToAssets(proverShares);

        // Check current committed stake (no need to subtract pending unstakes since they're handled separately)
        if (proverAssets < minSelfStake) {
            revert ControllerMinSelfStakeNotMet();
        }

        _changeProverState(prover, ProverState.Active);
    }

    /**
     * @notice Batch reactivate multiple provers (admin only)
     */
    function reactivateProvers(address[] calldata provers) external override {
        for (uint256 i = 0; i < provers.length; i++) {
            reactivateProver(provers[i]);
        }
    }

    /**
     * @notice Jail a prover (admin only)
     */
    function jailProver(address prover) external override onlyOwner {
        _changeProverState(prover, ProverState.Jailed);
    }

    /**
     * @notice Batch jail multiple provers (admin only)
     */
    function jailProvers(address[] calldata provers) external override onlyOwner {
        for (uint256 i = 0; i < provers.length; i++) {
            _changeProverState(provers[i], ProverState.Jailed);
        }
    }

    /**
     * @notice Retire and remove a prover from the system
     * @dev Can only retire a prover if their vault has no assets and they have no pending unstakes
     * @param prover The prover address to retire
     */
    function retireProver(address prover) public override {
        address caller = msg.sender;
        if (caller != owner() && caller != prover) {
            revert ControllerOnlyAdminOrProver();
        }

        // Validate prover exists
        ProverInfo storage proverInfo = _proverInfo[prover];
        if (proverInfo.state == ProverState.Null) revert ControllerProverNotInitialized();

        // Check that vault has no assets
        address vault = proverInfo.vault;
        uint256 vaultAssets = IProverVault(vault).totalAssets();
        if (vaultAssets > 0) revert ControllerCannotRetireProverWithAssets();

        // Check that prover has no pending unstakes
        uint256 totalUnstaking = pendingUnstakes[prover].totalUnstaking;
        if (totalUnstaking > 0) revert ControllerCannotRetireProverWithPendingUnstakes();

        // Check that prover has no pending commission
        if (proverInfo.pendingCommission > 0) revert ControllerCannotRetireProverWithPendingCommission();

        // Remove from enumeration sets
        proverList.remove(prover);
        activeProvers.remove(prover);

        // Clear commission rates before deleting prover info
        // Get all keys and remove them one by one
        address[] memory commissionSources = proverInfo.commissionRates.keys();
        for (uint256 i = 0; i < commissionSources.length; i++) {
            proverInfo.commissionRates.remove(commissionSources[i]);
        }

        // Completely delete the prover data structures
        // Note: stakers set should already be empty since totalAssets == 0
        delete _proverInfo[prover];
        delete pendingUnstakes[prover];

        // Emit event
        emit ProverRetired(prover);
    }

    /**
     * @notice Batch retire multiple provers at once (admin only)
     */
    function retireProvers(address[] calldata provers) external override {
        for (uint256 i = 0; i < provers.length; i++) {
            retireProver(provers[i]);
        }
    }

    /**
     * @notice Set or update the caller's prover display profile
     */
    function setProverProfile(string calldata name, string calldata iconUrl) external override {
        _setProverProfile(msg.sender, name, iconUrl);
    }

    /**
     * @notice Admin override to set a prover's display profile
     */
    function setProverProfileByAdmin(address prover, string calldata name, string calldata iconUrl)
        external
        override
        onlyOwner
    {
        _setProverProfile(prover, name, iconUrl);
    }

    function _setProverProfile(address prover, string calldata name, string calldata iconUrl) internal {
        ProverInfo storage p = _proverInfo[prover];
        if (p.state == ProverState.Null) revert ControllerProverNotInitialized();
        // Input caps: name <= 128 bytes, iconUrl <= 512 bytes
        if (bytes(name).length > 128) revert ControllerInvalidArg();
        if (bytes(iconUrl).length > 512) revert ControllerInvalidArg();
        p.name = name;
        p.iconUrl = iconUrl;
        emit ProverProfileUpdated(prover, name, iconUrl);
    }

    // =========================================================================
    // STAKING OPERATIONS
    // =========================================================================

    /**
     * @notice Stake tokens with a prover
     * @dev Transfers tokens from caller to the prover's vault and mints shares.
     *      Provers can always self-stake; delegators can only stake with active provers.
     * @param prover The prover address to stake with
     * @param amount The amount of tokens to stake
     * @return shares The number of vault shares minted to the caller
     */
    function stake(address prover, uint256 amount)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        if (amount == 0) revert ControllerZeroAmount();
        address staker = msg.sender;

        // Validate prover exists
        ProverInfo storage proverInfo = _proverInfo[prover];
        if (proverInfo.state == ProverState.Null) revert ControllerProverNotInitialized();

        // Check if prover can accept stakes (but allow prover self-staking always)
        if (staker != prover && !_isActive(prover)) {
            revert ControllerProverNotActive();
        }

        // Transfer assets from user to this controller
        stakingToken.safeTransferFrom(staker, address(this), amount);

        // Approve and deposit into prover's vault (set unlimited allowance once for gas efficiency)
        if (stakingToken.allowance(address(this), proverInfo.vault) < amount) {
            stakingToken.approve(proverInfo.vault, type(uint256).max);
        }
        shares = IProverVault(proverInfo.vault).deposit(amount, staker);

        // Update stake info for the receiver (inline bookkeeping)
        uint256 currentShares = proverInfo.shares[staker];

        // Add receiver to stakers set if this is their first stake
        if (currentShares == 0) {
            proverInfo.stakers.add(staker);
        }

        proverInfo.shares[staker] = currentShares + shares;

        // Emit event for tracking
        emit Staked(prover, staker, shares, amount);

        // Return shares received
        return shares;
    }

    /**
     * @notice Request to unstake shares from a prover's vault
     * @dev Key behaviors:
     *      - Shares are immediately burned from vault (stops earning rewards immediately)
     *      - Tokens remain slashable during unbonding period via Unstaking contract
     *      - Prover self-stake requirements enforced (can exit completely or maintain minimum)
     *      - Auto-deactivates prover if they completely exit their self-stake
     *
     * @dev IMPORTANT: Users must first approve this StakingController to spend their vault shares:
     *      `IERC20(vault).approve(address(stakingController), amount)`
     *      This is required because the controller calls `vault.redeem(shares, unstakingContract, staker)`
     *      where staker is the share owner, triggering ERC4626's allowance mechanism.
     *
     * @param prover The prover address to unstake from
     * @param shares Number of vault shares to unstake
     * @return amount The amount of tokens transferred to Unstaking contract
     */
    function requestUnstake(address prover, uint256 shares) external override nonReentrant returns (uint256 amount) {
        if (shares == 0) revert ControllerZeroAmount();
        address staker = msg.sender;

        // Validate prover exists and user has enough shares
        ProverInfo storage proverInfo = _proverInfo[prover];
        if (proverInfo.state == ProverState.Null) revert ControllerProverNotInitialized();

        uint256 stakerShares = proverInfo.shares[staker];
        if (shares > stakerShares) revert ControllerInsufficientShares();

        // Check MinSelfStake requirement if prover is unstaking
        if (staker == prover) {
            // Calculate assets that would remain after this unstake
            address vaultAddr = proverInfo.vault;
            uint256 proverShares = IProverVault(vaultAddr).balanceOf(prover);
            uint256 proverAssets = IProverVault(vaultAddr).convertToAssets(proverShares);
            uint256 unstakingAssets = IProverVault(vaultAddr).convertToAssets(shares);
            uint256 remainingAssets = proverAssets - unstakingAssets;

            // Allow going below MinSelfStake only if it results in zero self-stake (complete exit)
            if (remainingAssets > 0 && remainingAssets < minSelfStake) {
                revert ControllerMinSelfStakeNotMet();
            } else if (remainingAssets == 0 && proverInfo.state == ProverState.Active) {
                // Auto-deactivate prover immediately when they request complete exit
                _changeProverState(prover, ProverState.Deactivated);
            }
        }

        // Redeem shares from vault to this controller (for unstaking management)
        address vault = proverInfo.vault;
        amount = IProverVault(vault).redeem(shares, address(this), staker);

        // Update stake info (remove from active shares)
        proverInfo.shares[staker] = stakerShares - shares;

        // Remove owner from stakers set if they have no more shares
        if (proverInfo.shares[staker] == 0) {
            proverInfo.stakers.remove(staker);
        }

        // Add to internal unstaking system with delay tracking
        _receiveUnstake(prover, staker, amount);

        // Emit UnstakeRequested event
        emit UnstakeRequested(prover, staker, shares, amount);

        // Return assets sent to unstaking
        return amount;
    }

    /**
     * @notice Function to complete unstaking after delay period
     * @param prover The prover to complete unstaking from
     * @return amount The amount of tokens received by the user
     */
    function completeUnstake(address prover) external override whenNotPaused nonReentrant returns (uint256 amount) {
        amount = _completeUnstake(prover);
        if (amount > 0) {
            stakingToken.safeTransfer(msg.sender, amount);
        }
        emit UnstakeCompleted(prover, msg.sender, amount);
    }

    // =========================================================================
    // REWARD MANAGEMENT
    // =========================================================================

    /**
     * @notice Add rewards for a prover (splits commission and donates to vault)
     */
    function addRewards(address prover, uint256 amount)
        external
        override
        whenNotPaused
        nonReentrant
        returns (uint256 commission, uint256 toStakers)
    {
        // Validate prover is active
        ProverInfo storage proverInfo = _proverInfo[prover];
        if (proverInfo.state == ProverState.Null) revert ControllerProverNotInitialized();
        if (!_isActive(prover)) revert ControllerProverNotActive();

        // Transfer assets from caller
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        // Get commission rate for this source (msg.sender)
        uint256 commissionRate = getCommissionRate(prover, msg.sender);

        // Calculate commission split
        commission = (amount * commissionRate) / BPS_DENOMINATOR;
        toStakers = amount - commission;

        // Add commission to pending balance
        proverInfo.pendingCommission += commission;

        // Donate staker portion to vault (increases share price)
        if (toStakers > 0) {
            // Guard against donation windfall: require existing shares so first staker cannot capture prior donations
            if (IProverVault(proverInfo.vault).totalSupply() == 0) revert ControllerNoShares();
            // Donate assets directly to vault without minting shares (increases share price)
            // No approval required for a direct transfer
            stakingToken.safeTransfer(proverInfo.vault, toStakers);
        }

        // Emit RewardsAdded event with source
        emit RewardsAdded(prover, msg.sender, amount, commission, toStakers);

        // Return split amounts
        return (commission, toStakers);
    }

    /**
     * @notice Claim accumulated commission (only prover can call)
     */
    function claimCommission() external override whenNotPaused nonReentrant returns (uint256 amount) {
        address prover = msg.sender;
        // Validate caller is a registered prover
        ProverInfo storage proverInfo = _proverInfo[prover];
        if (proverInfo.state == ProverState.Null) revert ControllerProverNotInitialized();

        // Get pending commission amount
        amount = proverInfo.pendingCommission;
        if (amount == 0) return 0; // No commission to claim

        // Reset pending commission
        proverInfo.pendingCommission = 0;

        // Transfer commission to prover
        stakingToken.safeTransfer(prover, amount);

        // Emit CommissionClaimed event
        emit CommissionClaimed(prover, amount);

        // Return claimed amount
        return amount;
    }

    /**
     * @notice Set commission rate for a specific source (only prover can call)
     * @param source Source address (use address(0) for default rate)
     * @param newRate New commission rate in basis points
     */
    function setCommissionRate(address source, uint64 newRate) external override {
        address prover = msg.sender;
        // Validate caller is registered prover
        ProverInfo storage proverInfo = _proverInfo[prover];
        if (proverInfo.state == ProverState.Null) revert ControllerProverNotInitialized();

        // Validate new rate <= 100%
        if (newRate > BPS_DENOMINATOR) revert ControllerInvalidArg();

        // Get old rate for event (0 if not set)
        (, uint256 oldRate) = proverInfo.commissionRates.tryGet(source);

        // Update commission rate for the source
        proverInfo.commissionRates.set(source, newRate);

        // Emit CommissionRateUpdated event
        emit CommissionRateUpdated(prover, source, uint64(oldRate), newRate, false);
    }

    /**
     * @notice Reset commission rate for a specific source to use default rate (only prover can call)
     * @param source Source address to reset (cannot be address(0))
     */
    function resetCommissionRate(address source) external override {
        address prover = msg.sender;
        // Validate caller is registered prover
        ProverInfo storage proverInfo = _proverInfo[prover];
        if (proverInfo.state == ProverState.Null) revert ControllerProverNotInitialized();

        // Cannot reset default rate itself
        if (source == address(0)) revert ControllerInvalidArg();

        // Get old rate and default rate for event
        (, uint256 oldRate) = proverInfo.commissionRates.tryGet(source);
        (, uint256 defaultRate) = proverInfo.commissionRates.tryGet(address(0));

        // Remove custom rate (falls back to default)
        proverInfo.commissionRates.remove(source);

        // Emit CommissionRateUpdated event with useDefault = true
        emit CommissionRateUpdated(prover, source, uint64(oldRate), uint64(defaultRate), true);
    }

    // =========================================================================
    // SLASHING OPERATIONS
    // =========================================================================

    /**
     * @notice Slash a prover's vault (admin/slasher only)
     * @param prover The prover to slash
     * @param bps The percentage to slash (in basis points)
     * @return slashedAmount The amount of assets slashed
     */
    function slash(address prover, uint256 bps)
        external
        override
        whenNotPaused
        nonReentrant
        onlyRole(SLASHER_ROLE)
        returns (uint256 slashedAmount)
    {
        // Validate prover exists
        ProverInfo storage proverInfo = _proverInfo[prover];
        if (proverInfo.state == ProverState.Null) revert ControllerProverNotInitialized();

        // Validate bps <= MaxSlashBps
        if (bps > maxSlashBps) revert ControllerSlashTooHigh();

        return _executeSlash(prover, bps);
    }

    /**
     * @notice Slash a specific amount from a prover's total assets (admin/slasher only)
     * @dev Calculates the appropriate percentage based on total slashable assets
     * @param prover The prover to slash
     * @param amount The exact amount to slash
     * @return slashedAmount The actual amount of assets slashed (may be less if insufficient assets)
     */
    function slashByAmount(address prover, uint256 amount)
        external
        whenNotPaused
        nonReentrant
        onlyRole(SLASHER_ROLE)
        returns (uint256 slashedAmount)
    {
        // Validate prover exists
        ProverInfo storage proverInfo = _proverInfo[prover];
        if (proverInfo.state == ProverState.Null) revert ControllerProverNotInitialized();

        if (amount == 0) return 0;

        // Get total slashable assets using the public view function
        uint256 totalAssets = getProverTotalAssets(prover);
        if (totalAssets == 0) return 0;

        // Calculate the bps needed to slash the requested amount
        uint256 bps = (amount * BPS_DENOMINATOR) / totalAssets;

        // Cap bps to maxSlashBps
        if (bps > maxSlashBps) {
            bps = maxSlashBps;
        }

        return _executeSlash(prover, bps);
    }

    /**
     * @notice Internal function to execute slashing with a given percentage
     * @param prover The prover to slash
     * @param bps The slashing percentage in basis points
     * @return slashedAmount The total amount slashed
     */
    function _executeSlash(address prover, uint256 bps) internal returns (uint256 slashedAmount) {
        ProverInfo storage proverInfo = _proverInfo[prover];

        // First slash unstaking tokens proportionally
        (uint256 unstakingSlashed, bool shouldDeactivate) = _slashUnstaking(prover, bps);

        // Calculate vault slash amount from vault's total assets
        address vault = proverInfo.vault;
        uint256 vaultAssets = IProverVault(vault).totalAssets();
        uint256 vaultSlashedAmount = (vaultAssets * bps) / BPS_DENOMINATOR;
        // Ensure we don't slash more than what's available
        if (vaultSlashedAmount > vaultAssets) {
            vaultSlashedAmount = vaultAssets;
        }

        // Remove slashed assets from vault and transfer to this controller
        if (vaultSlashedAmount > 0) {
            IProverVault(vault).controllerSlash(vaultSlashedAmount, address(this));

            // Check if prover's self-stake fell below minimum after slashing
            if (proverInfo.state == ProverState.Active) {
                uint256 proverShares = IProverVault(vault).balanceOf(prover);
                uint256 proverAssets = IProverVault(vault).convertToAssets(proverShares);
                if (proverAssets < minSelfStake) {
                    // Should auto-deactivate prover if their self-stake fell below minimum due to slashing
                    shouldDeactivate = true;
                }
            }
        }

        if (shouldDeactivate) {
            // Auto-deactivate prover if slashing crossed deactivation threshold
            _changeProverState(prover, ProverState.Deactivated);
        }

        // Calculate total slashed amount
        slashedAmount = vaultSlashedAmount + unstakingSlashed;
        // Add slashed assets to treasury pool
        treasuryPool += slashedAmount;

        // Emit ProverSlashed event
        emit ProverSlashed(prover, slashedAmount, bps);

        // Return slashed amount
        return slashedAmount;
    }

    // =========================================================================
    // VAULT GATING (called by ProverVault)
    // =========================================================================

    /**
     * @notice Check maximum withdrawable assets for a user (excludes unbonding shares)
     */
    function maxWithdraw(address prover, address owner) external view override returns (uint256 amount) {
        address vault = vaultFactory.getVault(prover);
        if (vault == address(0)) return 0;

        // Get maximum redeemable shares and convert to assets
        uint256 maxRedeemableShares = this.maxRedeem(prover, owner);
        return IProverVault(vault).convertToAssets(maxRedeemableShares);
    }

    /**
     * @notice Check maximum redeemable shares for a user (normal vault shares only)
     */
    function maxRedeem(address prover, address owner) external view override returns (uint256 shares) {
        address vault = vaultFactory.getVault(prover);
        if (vault == address(0)) return 0;

        // Return all shares since unstaking is now handled by separate contract
        // Users can freely redeem their vault shares (standard ERC4626 behavior)
        return IProverVault(vault).balanceOf(owner);
    }

    /**
     * @notice Check maximum assets that can be deposited (pause, jail checks)
     */
    function maxDeposit(address prover, address receiver) external view override returns (uint256 amount) {
        address vault = vaultFactory.getVault(prover);
        if (vault == address(0)) return 0;

        // Get maximum mintable shares and convert to assets
        uint256 maxMintableShares = this.maxMint(prover, receiver);
        if (maxMintableShares == type(uint256).max) {
            return type(uint256).max;
        }
        return IProverVault(vault).convertToAssets(maxMintableShares);
    }

    /**
     * @notice Check maximum shares that can be minted (pause, jail checks)
     */
    function maxMint(address prover, address receiver) external view override returns (uint256 shares) {
        // Allow unlimited minting if receiver is the prover (self-staking)
        // or if prover is active and can accept stakes
        if (receiver == prover || _isActive(prover)) {
            return type(uint256).max;
        }

        // Otherwise, no minting allowed
        return 0;
    }

    /**
     * @notice Validate share transfer
     */
    function beforeShareTransfer(address prover, address from, uint256 shares) external view override {
        // Vault already enforced locked share limits; only enforce min self-stake policy here when prover transfers.
        address vault = vaultFactory.getVault(prover);
        if (from == prover && vault != address(0)) {
            uint256 proverShares = IProverVault(vault).balanceOf(prover);
            uint256 proverAssets = IProverVault(vault).convertToAssets(proverShares);
            // Assets being transferred
            uint256 transferAssets = IProverVault(vault).convertToAssets(shares);
            uint256 remainingAfter = proverAssets - transferAssets;
            if (remainingAfter > 0 && remainingAfter < minSelfStake) revert ControllerMinSelfStakeNotMet();
        }
    }

    /**
     * @notice Post-transfer accounting hook invoked by vault to sync controller state
     */
    function onShareTransfer(address prover, address from, address to, uint256 shares) external override {
        address vault = vaultFactory.getVault(prover);
        if (msg.sender != vault) revert ControllerOnlyVault();
        // Ignore mint and burn and no-op cases
        if (from == address(0) || to == address(0) || from == to || shares == 0) return;

        ProverInfo storage p = _proverInfo[prover];
        if (p.state == ProverState.Null) revert ControllerProverNotInitialized();

        // Sender bookkeeping
        uint256 fromShares = p.shares[from];
        if (fromShares < shares) revert ControllerShareAccountingMismatch();
        p.shares[from] = fromShares - shares;
        if (p.shares[from] == 0) p.stakers.remove(from);

        // Auto-deactivate prover if they transferred all their shares (complete exit)
        if (from == prover && p.shares[prover] == 0 && p.state == ProverState.Active) {
            _changeProverState(prover, ProverState.Deactivated);
        }

        // Receiver bookkeeping
        uint256 toShares = p.shares[to];
        if (toShares == 0) p.stakers.add(to);
        p.shares[to] = toShares + shares;
    }

    // =========================================================================
    // VIEW FUNCTIONS
    // =========================================================================

    /**
     * @notice Get prover information
     */
    function getProverInfo(address prover)
        external
        view
        override
        returns (
            ProverState state,
            address vault,
            uint64 defaultCommissionRate,
            uint256 pendingCommission,
            uint256 numStakers,
            uint64 joinedAt,
            string memory name
        )
    {
        ProverInfo storage proverInfo = _proverInfo[prover];
        (, uint256 defaultRate) = proverInfo.commissionRates.tryGet(address(0));
        return (
            proverInfo.state,
            proverInfo.vault,
            uint64(defaultRate),
            proverInfo.pendingCommission,
            proverInfo.stakers.length(),
            proverInfo.joinedAt,
            proverInfo.name
        );
    }

    /**
     * @notice Get all stakers for a specific prover
     */
    function getProverStakers(address prover) external view override returns (address[] memory stakers) {
        return _proverInfo[prover].stakers.values();
    }

    /**
     * @notice Get stake shares for a staker with a specific prover
     */
    function getStakeInfo(address prover, address staker) external view override returns (uint256 shares) {
        return _proverInfo[prover].shares[staker];
    }

    /**
     * @notice Check if a prover is eligible for work assignment
     * @dev Used by BrevisMarket to verify prover eligibility before assigning work.
     * @param prover Address of the prover to check
     * @param minimumVaultAssets Minimum total vault assets required for eligibility
     * @return eligible True if prover meets all requirements, false otherwise
     * @return currentVaultAssets Current total vault assets amount (for reference)
     */
    function isProverEligible(address prover, uint256 minimumVaultAssets)
        external
        view
        override
        returns (bool eligible, uint256 currentVaultAssets)
    {
        // Get current vault assets amount (always return for API consistency)
        currentVaultAssets = IProverVault(getProverVault(prover)).totalAssets();

        // Check if prover is active and meets minimum vault assets requirement
        eligible = _isActive(prover) && currentVaultAssets >= minimumVaultAssets;
    }

    /**
     * @notice Get current state of a prover
     */
    function getProverState(address prover) external view override returns (ProverState state) {
        return _proverInfo[prover].state;
    }

    /**
     * @notice Get the vault address for a prover
     */
    function getProverVault(address prover) public view override returns (address vault) {
        return vaultFactory.getVault(prover);
    }

    /**
     * @notice Get prover profile display fields
     */
    function getProverProfile(address prover)
        external
        view
        override
        returns (string memory name, string memory iconUrl)
    {
        ProverInfo storage p = _proverInfo[prover];
        return (p.name, p.iconUrl);
    }

    /**
     * @notice Get the list of all registered provers
     * @return provers Array of prover addresses (includes both active and inactive provers)
     */
    function getAllProvers() external view returns (address[] memory provers) {
        return proverList.values();
    }

    /**
     * @notice Get the list of currently active provers
     * @return provers Array of active prover addresses only
     */
    function getActiveProvers() external view returns (address[] memory provers) {
        return activeProvers.values();
    }

    /**
     * @notice Get the total number of registered provers
     * @return count Total number of provers (includes both active and inactive)
     */
    function getProverCount() external view returns (uint256 count) {
        return proverList.length();
    }

    /**
     * @notice Get the number of currently active provers
     * @return count Number of active provers only
     */
    function getActiveProverCount() external view returns (uint256 count) {
        return activeProvers.length();
    }

    /**
     * @notice Get total assets currently in all vaults (excluding unstaking assets in controller)
     * @return totalAssets Total vault assets across all provers
     */
    function getTotalVaultAssets() external view returns (uint256 totalAssets) {
        uint256 proverCount = proverList.length();

        for (uint256 i = 0; i < proverCount; i++) {
            address prover = proverList.at(i);
            address vault = _proverInfo[prover].vault;
            totalAssets += IProverVault(vault).totalAssets();
        }

        return totalAssets;
    }

    /**
     * @notice Get total assets in vaults of active provers only
     * @return totalAssets Total vault assets of active provers only
     */
    function getTotalActiveProverVaultAssets() external view returns (uint256 totalAssets) {
        uint256 activeCount = activeProvers.length();

        for (uint256 i = 0; i < activeCount; i++) {
            address prover = activeProvers.at(i);
            address vault = _proverInfo[prover].vault;
            totalAssets += IProverVault(vault).totalAssets();
        }

        return totalAssets;
    }

    /**
     * @notice Get commission rate for a specific source
     * @param prover The prover address
     * @param source The reward source address (use address(0) for default rate)
     * @return rate Commission rate in basis points (returns 0 if source not set and not default)
     */
    function getCommissionRate(address prover, address source) public view override returns (uint64 rate) {
        ProverInfo storage proverInfo = _proverInfo[prover];

        // Try to get rate for specific source
        (bool exists, uint256 sourceRate) = proverInfo.commissionRates.tryGet(source);
        if (exists) {
            return uint64(sourceRate);
        }

        // Fallback to default rate at address(0)
        (, uint256 defaultRate) = proverInfo.commissionRates.tryGet(address(0));
        return uint64(defaultRate);
    }

    /**
     * @notice Get all commission rates configured for a prover
     * @param prover The prover address
     * @return sources Array of source addresses (address(0) first for default rate, then custom rates)
     * @return rates Array of commission rates corresponding to each source (in basis points)
     */
    function getCommissionRates(address prover)
        external
        view
        override
        returns (address[] memory sources, uint64[] memory rates)
    {
        ProverInfo storage proverInfo = _proverInfo[prover];
        uint256 length = proverInfo.commissionRates.length();

        // Always include default rate, so total count equals length
        sources = new address[](length);
        rates = new uint64[](length);

        // First, get the default rate at address(0)
        (, uint256 defaultRate) = proverInfo.commissionRates.tryGet(address(0));
        sources[0] = address(0);
        rates[0] = uint64(defaultRate);

        // Then populate custom rates (skipping address(0) entries)
        uint256 index = 1;
        for (uint256 i = 0; i < length; i++) {
            (address source, uint256 rate) = proverInfo.commissionRates.at(i);
            if (source != address(0)) {
                sources[index] = source;
                rates[index] = uint64(rate);
                index++;
            }
        }
    }

    /**
     * @notice Get total slashable assets for a prover (vault + unstaking)
     * @param prover The prover address
     * @return totalAssets The total slashable assets (vault assets + pending unstaking assets)
     */
    function getProverTotalAssets(address prover) public view override returns (uint256 totalAssets) {
        // Validate prover exists
        ProverInfo storage proverInfo = _proverInfo[prover];
        if (proverInfo.state == ProverState.Null) return 0;

        // Calculate total slashable assets (vault + unstaking)
        address vault = proverInfo.vault;
        uint256 vaultAssets = IProverVault(vault).totalAssets();
        uint256 unstakingAssets = pendingUnstakes[prover].totalUnstaking;

        return vaultAssets + unstakingAssets;
    }

    // =========================================================================
    // INTERNAL HELPER FUNCTIONS
    // =========================================================================

    /**
     * @notice Internal helper to change prover state and emit event
     */
    function _changeProverState(address prover, ProverState newState) internal {
        ProverInfo storage info = _proverInfo[prover];
        if (info.state == ProverState.Null) revert ControllerProverNotInitialized();

        ProverState oldState = info.state;
        if (oldState == newState) return; // No change needed

        info.state = newState;

        // Update activeProvers set based on state changes
        if (newState == ProverState.Active) {
            activeProvers.add(prover);
        } else if (oldState == ProverState.Active) {
            activeProvers.remove(prover);
        }

        emit ProverStateChanged(prover, oldState, newState);
    }

    /**
     * @notice Check if prover is in active state
     * @param prover The prover address to check
     * @return isActive True if prover is in active state
     */
    function _isActive(address prover) internal view returns (bool isActive) {
        return _proverInfo[prover].state == ProverState.Active;
    }

    // =========================================================================
    // ADMIN FUNCTIONS
    // =========================================================================

    /**
     * @notice Set minimum self stake requirement (owner only)
     * @param value The new minimum self stake value
     * @dev Must be greater than zero
     */
    function setMinSelfStake(uint256 value) external override onlyOwner {
        if (value == 0) revert ControllerInvalidArg();
        uint256 oldValue = minSelfStake;
        minSelfStake = value;
        emit MinSelfStakeUpdated(oldValue, value);
    }

    /**
     * @notice Set maximum slash percentage (owner only)
     * @param value The new maximum slash percentage value (in basis points)
     * @dev Zero value disables all slashing (only bps=0 allowed)
     */
    function setMaxSlashBps(uint256 value) external override onlyOwner {
        if (value > BPS_DENOMINATOR) revert ControllerInvalidArg();
        uint256 oldValue = maxSlashBps;
        maxSlashBps = value;
        emit MaxSlashBpsUpdated(oldValue, value);
    }

    /**
     * @notice Update the unstake delay period (owner only)
     * @param newDelay The new unstake delay in seconds
     */
    function setUnstakeDelay(uint256 newDelay) external override onlyOwner {
        uint256 oldDelay = unstakeDelay;
        unstakeDelay = newDelay;
        emit UnstakeDelayUpdated(oldDelay, newDelay);
    }

    /**
     * @notice Toggle whether authorization (role gating) is required for initializing a prover
     * @param required True to enforce AUTHORIZED_PROVER_ROLE, false to allow open registration
     */
    function setRequireAuthorization(bool required) external override onlyOwner {
        requireAuthorization = required;
        emit RequireAuthorizationUpdated(required);
    }

    /**
     * @notice Withdraw from treasury pool (owner only)
     */
    function withdrawTreasury(address to, uint256 amount) external whenNotPaused onlyOwner {
        if (amount > treasuryPool) revert ControllerInsufficientTreasury();
        treasuryPool -= amount;
        stakingToken.safeTransfer(to, amount);
        emit TreasuryWithdrawn(to, amount);
    }

    /**
     * @notice Emergency recovery function for owner to recover tokens (owner only)
     * @param to The address to recover tokens to
     * @param amount The amount of tokens to recover
     */
    function emergencyRecover(address to, uint256 amount) external override whenPaused onlyOwner {
        stakingToken.transfer(to, amount);
        emit EmergencyRecovered(to, amount);
    }
}
