// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IStakingController.sol";

/**
 * @title IStakingViewer
 * @notice Interface for the StakingViewer contract that provides unified view functions for frontend
 */
interface IStakingViewer {
    // =========================================================================
    // EVENTS
    // =========================================================================

    /**
     * @notice Emitted when a prover updates their display profile
     */
    event ProverProfileUpdated(address indexed prover, string name, string iconUrl);

    // =========================================================================
    // STRUCTS FOR BATCH OPERATIONS
    // =========================================================================

    struct ProverDisplayInfo {
        address prover;
        IStakingController.ProverState state;
        address vault;
        uint256 vaultAssets;
        uint256 vaultShares;
        uint256 totalAssets;
        uint256 totalUnstaking;
        uint256 numStakers;
        uint64 joinedAt;
        uint256 slashingScale;
        uint256 pendingCommission;
        uint64 defaultCommissionRate;
        ProverCommissionInfo[] commissionRates;
        // Profile fields for explorer display
        string name;
        string iconUrl;
        uint64 profileLastUpdated;
    }

    struct UserStakeInfo {
        address prover;
        uint256 shares;
        uint256 currentValue;
        uint256 totalUnstaking;
        uint256 readyToWithdraw;
        IStakingController.UnstakeRequest[] pendingRequests;
        bool isProver;
    }

    struct UserPortfolio {
        uint256 totalValue;
        uint256 totalUnstaking;
        uint256 totalReadyToWithdraw;
        UserStakeInfo[] stakes;
    }

    struct SystemOverview {
        uint256 totalVaultAssets;
        uint256 totalActiveVaultAssets;
        uint256 totalProvers;
        uint256 activeProvers;
        uint256 totalStakers;
        uint256 minSelfStake;
        uint256 unstakeDelay;
        address stakingToken;
    }

    struct ProverCommissionInfo {
        address source;
        uint64 rate;
    }

    // =========================================================================
    // SYSTEM-WIDE VIEW FUNCTIONS
    // =========================================================================

    /**
     * @notice Get comprehensive system overview
     * @return overview Complete system statistics
     */
    function getSystemOverview() external view returns (SystemOverview memory overview);

    /**
     * @notice Get display information for all active provers
     * @return proversInfo Array of prover display information
     */
    function getAllActiveProversInfo() external view returns (ProverDisplayInfo[] memory proversInfo);

    /**
     * @notice Get display information for specific provers
     * @param provers Array of prover addresses
     * @return proversInfo Array of prover display information
     */
    function getProversInfo(address[] calldata provers)
        external
        view
        returns (ProverDisplayInfo[] memory proversInfo);

    /**
     * @notice Get top provers by total assets
     * @param limit Maximum number of provers to return
     * @return proversInfo Array of top provers sorted by total assets (descending)
     */
    function getTopProvers(uint256 limit) external view returns (ProverDisplayInfo[] memory proversInfo);

    // =========================================================================
    // PROVER-SPECIFIC VIEW FUNCTIONS
    // =========================================================================

    /**
     * @notice Get display information for a single prover
     * @param prover The prover address
     * @return proverInfo Prover display information
     */
    function getProverInfo(address prover) external view returns (ProverDisplayInfo memory proverInfo);

    /**
     * @notice Convert shares to assets for a specific prover
     * @param prover The prover address
     * @param shares Amount of shares to convert
     * @return assets Current asset value of the shares
     */
    function convertSharesToAssets(address prover, uint256 shares) external view returns (uint256 assets);

    /**
     * @notice Convert assets to shares for a specific prover
     * @param prover The prover address
     * @param assets Amount of assets to convert
     * @return shares Current share equivalent of the assets
     */
    function convertAssetsToShares(address prover, uint256 assets) external view returns (uint256 shares);

    // =========================================================================
    // USER-SPECIFIC VIEW FUNCTIONS
    // =========================================================================

    /**
     * @notice Get complete portfolio information for a user
     * @param user The user address
     * @return portfolio Complete user portfolio with all stakes and unstaking info
     */
    function getUserPortfolio(address user) external view returns (UserPortfolio memory portfolio);

    /**
     * @notice Get user's stake information with specific provers
     * @param user The user address
     * @param provers Array of prover addresses
     * @return stakesInfo Array of user stake information for each prover
     */
    function getUserStakesWithProvers(address user, address[] calldata provers)
        external
        view
        returns (UserStakeInfo[] memory stakesInfo);

    /**
     * @notice Get user's stake information with a specific prover
     * @param user The user address
     * @param prover The prover address
     * @return stakeInfo User stake information for the prover
     */
    function getUserStakeWithProver(address user, address prover)
        external
        view
        returns (UserStakeInfo memory stakeInfo);

    /**
     * @notice Get user's ready-to-withdraw amounts across all provers
     * @param user The user address
     * @return provers Array of prover addresses with ready withdrawals
     * @return amounts Array of ready-to-withdraw amounts per prover
     * @return totalReady Total amount ready to withdraw across all provers
     */
    function getUserReadyWithdrawals(address user)
        external
        view
        returns (address[] memory provers, uint256[] memory amounts, uint256 totalReady);

    // =========================================================================
    // BATCH CONVERSION FUNCTIONS
    // =========================================================================

    /**
     * @notice Convert multiple share amounts to assets for different provers
     * @param provers Array of prover addresses
     * @param shares Array of share amounts (same length as provers)
     * @return assets Array of asset values
     */
    function batchConvertToAssets(address[] calldata provers, uint256[] calldata shares)
        external
        view
        returns (uint256[] memory assets);

    /**
     * @notice Convert multiple asset amounts to shares for different provers
     * @param provers Array of prover addresses
     * @param assets Array of asset amounts (same length as provers)
     * @return shares Array of share amounts
     */
    function batchConvertToShares(address[] calldata provers, uint256[] calldata assets)
        external
        view
        returns (uint256[] memory shares);

    /**
     * @notice Preview staking for multiple provers
     * @param provers Array of prover addresses
     * @param assets Array of asset amounts to stake (same length as provers)
     * @return shares Array of shares that would be received
     * @return eligible Array of whether each prover can accept stakes
     */
    function batchPreviewStake(address[] calldata provers, uint256[] calldata assets)
        external
        view
        returns (uint256[] memory shares, bool[] memory eligible);

    // =========================================================================
    // UTILITY FUNCTIONS
    // =========================================================================

    /**
     * @notice Get stakers count for multiple provers
     * @param provers Array of prover addresses
     * @return stakerCounts Array of staker counts for each prover
     */
    function batchGetStakerCounts(address[] calldata provers) external view returns (uint256[] memory stakerCounts);

    // =========================================================================
    // WRITE APIS - PROVER PROFILE
    // =========================================================================

    /**
     * @notice Set or update the caller's prover display profile
     * @dev Only callable by a registered prover
     */
    function setProverProfile(string calldata name, string calldata iconUrl) external;

    /**
     * @notice Admin override to set a prover's display profile
     * @dev Only callable by contract owner/admin
     */
    function setProverProfileByAdmin(address prover, string calldata name, string calldata iconUrl) external;
}
