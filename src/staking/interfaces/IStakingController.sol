// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

/**
 * @title IStakingController
 * @notice Interface for the central controller that orchestrates vault operations
 */
interface IStakingController {
    // =========================================================================
    // ENUMS & STRUCTS
    // =========================================================================

    enum ProverState {
        Null,
        Active,
        Deactivated,
        Jailed
    }

    struct ProverInfo {
        ProverState state;
        address vault; // Dedicated ERC4626 vault address
        mapping(address => uint256) shares; // Individual stake shares per staker
        EnumerableSet.AddressSet stakers; // Set of stakers with active stakes
        uint256 pendingCommission; // Accumulated commission waiting to be claimed
        // Map of reward source to commission rate in basis points (0-10000). address(0) = default rate
        EnumerableMap.AddressToUintMap commissionRates;
        uint64 joinedAt; // Timestamp when the prover joined (initialized)
        // Profile fields (display-only, editable by prover/admin)
        string name; // <= 128 bytes
        string iconUrl; // <= 512 bytes
    }

    struct ProverPendingUnstakes {
        uint256 totalUnstaking; // Total unstaking tokens per prover
        uint256 slashingScale; // Cumulative slashing scale remaining (basis points, starts at 10000)
        mapping(address => UnstakeRequest[]) requests; // staker => UnstakeRequest[]
        EnumerableSet.AddressSet stakers; // Set of all stakers with pending unstakes
    }

    struct UnstakeRequest {
        uint256 amount; // Original token amount when requested
        uint256 requestTime; // Timestamp when unstake was requested
        uint256 scaleSnapshot; // Slashing scale snapshot when request was made
    }

    // =========================================================================
    // EVENTS
    // =========================================================================

    event ProverInitialized(address indexed prover, address indexed vault, uint64 defaultCommissionRate);
    event Staked(address indexed prover, address indexed staker, uint256 shares, uint256 amount);
    event UnstakeRequested(address indexed prover, address indexed staker, uint256 shares, uint256 amount);
    event UnstakeCompleted(address indexed prover, address indexed staker, uint256 amount);
    event UnstakeDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event RewardsAdded(
        address indexed prover, address indexed source, uint256 amount, uint256 commission, uint256 toStakers
    );
    event ProverSlashed(address indexed prover, uint256 amount, uint256 bps);
    event ProverStateChanged(address indexed prover, ProverState oldState, ProverState newState);
    event ProverRetired(address indexed prover);
    event CommissionClaimed(address indexed prover, uint256 amount);
    event CommissionRateUpdated(
        address indexed prover, address indexed source, uint64 oldRate, uint64 newRate, bool useDefault
    );
    event TreasuryWithdrawn(address indexed to, uint256 amount);
    event MinSelfStakeUpdated(uint256 oldValue, uint256 newValue);
    event MaxSlashBpsUpdated(uint256 oldValue, uint256 newValue);
    event RequireAuthorizationUpdated(bool required);
    event EmergencyRecovered(address to, uint256 amount);
    event ProverProfileUpdated(address indexed prover, string name, string iconUrl);

    // =========================================================================
    // ERRORS
    // =========================================================================

    error ControllerOnlyProver();
    error ControllerOnlyAdmin();
    error ControllerNotAuthorized();
    error ControllerProverNotInitialized();
    error ControllerProverAlreadyInitialized();
    error ControllerProverNotActive();
    error ControllerInsufficientShares();
    error ControllerNoShares();
    error ControllerMinSelfStakeNotMet();
    error ControllerOnlyVault();
    error ControllerShareAccountingMismatch();
    error ControllerInsufficientTreasury();
    error ControllerSlashTooHigh();
    error ControllerCannotRetireProverWithAssets();
    error ControllerCannotRetireProverWithPendingUnstakes();
    error ControllerInvalidArg();

    // Unstaking errors
    error ControllerNoUnstakeRequest();
    error ControllerUnstakeNotReady();
    error ControllerTooManyPendingUnstakes();
    error ControllerZeroAmount();

    // =========================================================================
    // PROVER MANAGEMENT
    // =========================================================================

    /**
     * @notice Initialize a new prover with vault deployment (caller becomes the prover)
     * @param defaultCommissionRate Default commission rate in basis points (0-10000), stored at address(0)
     * @return vault The address of the deployed vault
     */
    function initializeProver(uint64 defaultCommissionRate) external returns (address vault);

    /**
     * @notice Deactivate a prover (admin only)
     * @param prover The prover to deactivate
     */
    function deactivateProver(address prover) external;

    /**
     * @notice Deactivate multiple provers at once (admin only)
     * @param provers The list of provers to deactivate
     */
    function deactivateProvers(address[] calldata provers) external;

    /**
     * @notice Reactivate a deactivated prover (admin or prover can call)
     * @param prover The prover to reactivate
     */
    function reactivateProver(address prover) external;

    /*
     * @notice Batch reactivate multiple provers (admin only)
     * @param provers The list of provers to reactivate
     */
    function reactivateProvers(address[] calldata provers) external;

    /**
     * @notice Jail a prover (admin only)
     * @param prover The prover to jail (can be reactivated later)
     */
    function jailProver(address prover) external;

    /**
     * @notice Jail multiple provers (admin only)
     * @param provers The list of provers to jail
     */
    function jailProvers(address[] calldata provers) external;

    /**
     * @notice Retire and remove a prover from the system (admin only)
     * @dev Can only retire a prover if their vault has no assets and they have no pending unstakes
     * @param prover The prover address to retire
     */
    function retireProver(address prover) external;

    /**
     * @notice Batch retire multiple provers at once (admin only)
     * @param provers The list of provers to retire
     */
    function retireProvers(address[] calldata provers) external;

    /**
     * @notice Set or update the caller's prover display profile
     * @dev Only callable by a registered prover
     * @param name Display name (<= 128 bytes recommended)
     * @param iconUrl Icon URL (<= 512 bytes recommended)
     */
    function setProverProfile(string calldata name, string calldata iconUrl) external;

    /**
     * @notice Admin override to set a prover's display profile
     * @param prover Prover address to update
     * @param name Display name (<= 128 bytes recommended)
     * @param iconUrl Icon URL (<= 512 bytes recommended)
     */
    function setProverProfileByAdmin(address prover, string calldata name, string calldata iconUrl) external;

    // =========================================================================
    // STAKING OPERATIONS
    // =========================================================================

    /**
     * @notice Convenience function to stake with a prover
     * @param prover The prover to stake with
     * @param amount The amount of tokens to stake
     * @return shares The number of vault shares received
     */
    function stake(address prover, uint256 amount) external returns (uint256 shares);

    /**
     * @notice Request to unstake shares (immediately redeems and sends to Unstaking contract)
     * @param prover The prover to unstake from
     * @param shares The number of shares to unstake
     * @return amount The amount of tokens sent to Unstaking contract
     */
    function requestUnstake(address prover, uint256 shares) external returns (uint256 amount);

    /**
     * @notice Complete unstaking after delay period
     * @param prover The prover to complete unstaking from
     * @return amount The amount of tokens received by the user
     */
    function completeUnstake(address prover) external returns (uint256 amount);

    // =========================================================================
    // REWARD & COMMISSION
    // =========================================================================

    /**
     * @notice Add rewards for a prover (splits commission and donates to vault)
     * @dev CRITICAL: Must check vault.totalSupply() > 0 to prevent donation windfalls
     * @param prover The prover to reward
     * @param amount The total reward amount
     * @return commission The commission paid to prover
     * @return toStakers The amount sent to stakers via vault
     */
    function addRewards(address prover, uint256 amount) external returns (uint256 commission, uint256 toStakers);

    /**
     * @notice Claim accumulated commission (only prover can call)
     * @dev Uses accrual + claim model - commission accumulates and must be explicitly claimed
     * @return amount The commission amount claimed
     */
    function claimCommission() external returns (uint256 amount);

    /**
     * @notice Set commission rate for a specific source (only prover can call)
     * @param source Source address (use address(0) for default rate)
     * @param newRate New commission rate in basis points
     */
    function setCommissionRate(address source, uint64 newRate) external;

    /**
     * @notice Reset commission rate for a specific source to use default rate (only prover can call)
     * @param source Source address to reset (cannot be address(0))
     */
    function resetCommissionRate(address source) external;

    // =========================================================================
    // SLASHING
    // =========================================================================

    /**
     * @notice Slash a prover by a percentage of total slashable assets (admin/slasher only)
     * @param prover The prover to slash
     * @param bps Slashing percentage in basis points (0 – 10000); must be <= maxSlashBps
     * @return slashedAmount Total assets removed (vault portion + pending unstake portion)
     */
    function slash(address prover, uint256 bps) external returns (uint256 slashedAmount);

    /**
     * @notice Slash an absolute amount from a prover's total slashable assets (admin/slasher only)
     * @dev Converts the requested absolute amount into an equivalent percentage:
     *      Derived percentage = (requestedAmount / totalSlashable) * BPS_DENOMINATOR
     *      Caps the derived percentage at maxSlashBps (so actual slashed may be < requested)
     * @param prover The prover to slash
     * @param amount Requested absolute amount to remove (in underlying asset units)
     * @return slashedAmount Actual amount removed (may be lower due to cap, rounding, or insufficient assets)
     */
    function slashByAmount(address prover, uint256 amount) external returns (uint256 slashedAmount);

    // =========================================================================
    // VIEW FUNCTIONS - PROVER INFO
    // =========================================================================

    /**
     * @notice Get the staking token address
     * @return token The staking token contract address
     */
    function stakingToken() external view returns (IERC20 token);

    /**
     * @notice Get prover information
     * @param prover The prover address
     * @return state The current prover state
     * @return vault The vault address for this prover
     * @return defaultCommissionRate Default commission rate in basis points (0-10000)
     * @return pendingCommission Accumulated commission waiting to be claimed
     * @return numStakers Number of stakers for this prover
     * @return joinedAt Timestamp when the prover joined
     */
    function getProverInfo(address prover)
        external
        view
        returns (
            ProverState state,
            address vault,
            uint64 defaultCommissionRate,
            uint256 pendingCommission,
            uint256 numStakers,
            uint64 joinedAt,
            string memory name
        );

    /**
     * @notice Get prover profile display fields
     * @param prover The prover address
     * @return name Prover display name
     * @return iconUrl Prover icon URL
     */
    function getProverProfile(address prover) external view returns (string memory name, string memory iconUrl);

    /**
     * @notice Get current state of a prover
     * @param prover The prover address
     * @return state The current prover state
     */
    function getProverState(address prover) external view returns (ProverState state);

    /**
     * @notice Get the vault address for a prover
     * @param prover The prover address
     * @return vault The vault address
     */
    function getProverVault(address prover) external view returns (address vault);

    /**
     * @notice Get total slashable assets for a prover (vault + unstaking)
     * @param prover The prover address
     * @return totalAssets The total slashable assets (vault assets + pending unstaking assets)
     */
    function getProverTotalAssets(address prover) external view returns (uint256 totalAssets);

    /**
     * @notice Get the list of all registered provers
     * @return provers Array of prover addresses (includes both active and inactive provers)
     */
    function getAllProvers() external view returns (address[] memory provers);

    /**
     * @notice Get the list of currently active provers
     * @return provers Array of active prover addresses only
     */
    function getActiveProvers() external view returns (address[] memory provers);

    /**
     * @notice Get the total number of registered provers
     * @return count Total number of provers (includes both active and inactive)
     */
    function getProverCount() external view returns (uint256 count);

    /**
     * @notice Get the number of currently active provers
     * @return count Number of active provers only
     */
    function getActiveProverCount() external view returns (uint256 count);

    /**
     * @notice Get total assets currently in all vaults (excluding unstaking assets in controller)
     * @return totalAssets Total vault assets across all provers
     */
    function getTotalVaultAssets() external view returns (uint256 totalAssets);

    /**
     * @notice Get total assets in vaults of active provers only
     * @return totalAssets Total vault assets of active provers only
     */
    function getTotalActiveProverVaultAssets() external view returns (uint256 totalAssets);

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
        returns (bool eligible, uint256 currentVaultAssets);

    /**
     * @notice Get commission rate for a specific source
     * @param prover The prover address
     * @param source The reward source address (use address(0) for default rate)
     * @return rate Commission rate in basis points (returns 0 if source not set and not default)
     */
    function getCommissionRate(address prover, address source) external view returns (uint64 rate);

    /**
     * @notice Get all commission rates configured for a prover
     * @param prover The prover address
     * @return sources Array of source addresses (address(0) first for default rate, then custom rates)
     * @return rates Array of commission rates corresponding to each source (in basis points)
     */
    function getCommissionRates(address prover)
        external
        view
        returns (address[] memory sources, uint64[] memory rates);

    /**
     * @notice Get the minimum self-stake amount to become a prover
     * @return amount The minimum self-stake amount
     */
    function minSelfStake() external view returns (uint256 amount);

    /**
     * @notice Get the maximum slash percentage for a prover
     * @return bps The maximum slash percentage (in basis points)
     */
    function maxSlashBps() external view returns (uint256 bps);

    /**
     * @notice Get the unstake delay period
     * @return delay The unstake delay in seconds
     */
    function unstakeDelay() external view returns (uint256 delay);

    // =========================================================================
    // VIEW FUNCTIONS - STAKING INFO
    // =========================================================================

    /**
     * @notice Get all stakers for a specific prover
     * @param prover The prover address
     * @return stakers Array of staker addresses
     */
    function getProverStakers(address prover) external view returns (address[] memory stakers);

    /**
     * @notice Get stake shares for a staker with a specific prover
     * @param prover The prover address
     * @param staker The staker address
     * @return shares The number of shares owned by the staker
     */
    function getStakeInfo(address prover, address staker) external view returns (uint256 shares);

    /**
     * @notice Get all pending unstake requests for a staker with a prover
     * @param prover The prover address
     * @param staker The staker address
     * @return requests Array of pending unstake requests
     */
    function getPendingUnstakes(address prover, address staker)
        external
        view
        returns (UnstakeRequest[] memory requests);

    /**
     * @notice Get comprehensive unstaking information for a staker with a prover
     * @param prover The prover address
     * @param staker The staker address
     * @return totalAmount Total effective amount currently unstaking (post-slashing)
     * @return readyAmount Effective amount ready to be completed and withdrawn
     */
    function getUnstakingInfo(address prover, address staker)
        external
        view
        returns (uint256 totalAmount, uint256 readyAmount);

    /**
     * @notice Get total unstaking amount for a specific prover
     * @param prover The prover address
     * @return totalAmount Total amount unstaking from the prover
     */
    function getProverTotalUnstaking(address prover) external view returns (uint256 totalAmount);

    /**
     * @notice Get the cumulative slashing scale for a prover
     * @param prover The prover address
     * @return scale The current cumulative slashing scale in basis points (10000 = no slashing, 8000 = 20% slashed)
     */
    function getProverSlashingScale(address prover) external view returns (uint256 scale);

    /**
     * @notice Get all stakers with pending unstakes for a prover
     * @param prover The prover address
     * @return stakers Array of staker addresses with pending unstakes
     */
    function getStakersWithPendingUnstakes(address prover) external view returns (address[] memory stakers);

    /**
     * @notice Get count of stakers with pending unstakes for a prover
     * @param prover The prover address
     * @return count Number of stakers with pending unstakes
     */
    function getStakersWithPendingUnstakesCount(address prover) external view returns (uint256 count);

    /**
     * @notice Check if a staker has pending unstakes with a prover
     * @param prover The prover address
     * @param staker The staker address
     * @return hasPending True if staker has pending unstakes with the prover
     */
    function stakerHasPendingUnstakes(address prover, address staker) external view returns (bool hasPending);

    // =========================================================================
    // VAULT INTEGRATION (called by ProverVault)
    // =========================================================================

    /**
     * @notice Check maximum withdrawable assets for a user (excludes locked shares)
     * @param prover The prover vault
     * @param owner The share owner
     * @return amount Maximum amount that can be withdrawn
     */
    function maxWithdraw(address prover, address owner) external view returns (uint256 amount);

    /**
     * @notice Check maximum redeemable shares for a user (excludes locked shares)
     * @param prover The prover vault
     * @param owner The share owner
     * @return shares Maximum shares that can be redeemed
     */
    function maxRedeem(address prover, address owner) external view returns (uint256 shares);

    /**
     * @notice Check maximum assets that can be deposited (pause, jail checks)
     * @param prover The prover vault
     * @param receiver The address receiving shares
     * @return amount Maximum amount that can be deposited
     */
    function maxDeposit(address prover, address receiver) external view returns (uint256 amount);

    /**
     * @notice Check maximum shares that can be minted (pause, jail checks)
     * @param prover The prover vault
     * @param receiver The address receiving shares
     * @return shares Maximum shares that can be minted
     */
    function maxMint(address prover, address receiver) external view returns (uint256 shares);

    /**
     * @notice Validate share transfer
     * @param prover The prover vault
     * @param from The address transferring shares
     * @param shares The amount of shares being transferred
     */
    function beforeShareTransfer(address prover, address from, uint256 shares) external view;

    /**
     * @notice Accounting hook invoked by the vault AFTER a successful ERC20 share transfer
     * @dev Must only be callable by the vault for the given prover
     * @param prover The prover address whose vault executed the transfer
     * @param from Sender of the shares
     * @param to Receiver of the shares
     * @param shares Number of shares transferred
     */
    function onShareTransfer(address prover, address from, address to, uint256 shares) external;

    // =========================================================================
    // ADMIN FUNCTIONS
    // =========================================================================

    /**
     * @notice Set minimum self stake requirement (admin only)
     * @param value The new minimum self stake value
     */
    function setMinSelfStake(uint256 value) external;

    /**
     * @notice Set maximum slash percentage (admin only)
     * @param value The new maximum slash percentage value (in basis points)
     */
    function setMaxSlashBps(uint256 value) external;

    /**
     * @notice Toggle whether authorization (role gating) is required for initializing a prover (admin only)
     * @param required True to enforce AUTHORIZED_PROVER_ROLE, false to allow open registration
     */
    function setRequireAuthorization(bool required) external;

    /**
     * @notice Update the unstake delay period (admin only)
     * @param newDelay The new unstake delay in seconds
     */
    function setUnstakeDelay(uint256 newDelay) external;

    /**
     * @notice Withdraw treasury funds (admin only)
     * @param to The address to withdraw funds to
     * @param amount The amount to withdraw
     */
    function withdrawTreasury(address to, uint256 amount) external;

    /**
     * @notice Emergency recovery function for admin to recover tokens (admin only)
     * @param to The address to recover tokens to
     * @param amount The amount of tokens to recover
     */
    function emergencyRecover(address to, uint256 amount) external;
}
