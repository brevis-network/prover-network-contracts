// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IStakingViewer.sol";
import "../interfaces/IStakingController.sol";
import "../interfaces/IProverVault.sol";

/**
 * @title StakingViewer
 * @notice Standalone, stateless read-only helper for efficient off-chain queries over staking data;
 *         it reduces frontend RPC round trips and keeps the core StakingController lean. New view
 *         features can be added by deploying a new viewer without upgrading the controller.
 */
contract StakingViewer is IStakingViewer {
    IStakingController public immutable stakingController;

    constructor(address _stakingController) {
        stakingController = IStakingController(_stakingController);
    }

    // =========================================================================
    // SYSTEM-WIDE VIEW FUNCTIONS
    // =========================================================================

    /**
     * @notice Get comprehensive system overview
     */
    function getSystemOverview() external view override returns (SystemOverview memory overview) {
        overview.totalVaultAssets = stakingController.getTotalVaultAssets();
        overview.totalActiveVaultAssets = stakingController.getTotalActiveProverVaultAssets();
        overview.totalProvers = stakingController.getProverCount();
        overview.activeProvers = stakingController.getActiveProverCount();
        overview.minSelfStake = stakingController.minSelfStake();
        overview.unstakeDelay = stakingController.unstakeDelay();
        overview.stakingToken = address(stakingController.stakingToken());

        // Calculate total unique stakers across all provers
        address[] memory allProvers = stakingController.getAllProvers();
        uint256 totalStakers = 0;
        for (uint256 i = 0; i < allProvers.length; i++) {
            (,,,, uint256 numStakers,,) = stakingController.getProverInfo(allProvers[i]);
            totalStakers += numStakers;
        }
        overview.totalStakers = totalStakers;
    }

    /**
     * @notice Get display information for all active provers
     */
    function getAllActiveProversInfo() external view override returns (ProverDisplayInfo[] memory proversInfo) {
        address[] memory activeProvers = stakingController.getActiveProvers();
        return _getProversDisplayInfo(activeProvers);
    }

    /**
     * @notice Get display information for specific provers
     */
    function getProversInfo(address[] calldata provers)
        external
        view
        override
        returns (ProverDisplayInfo[] memory proversInfo)
    {
        return _getProversDisplayInfo(provers);
    }

    /**
     * @notice Get top provers by total assets
     */
    function getTopProvers(uint256 limit) external view override returns (ProverDisplayInfo[] memory proversInfo) {
        address[] memory allProvers = stakingController.getAllProvers();
        ProverDisplayInfo[] memory allProversInfo = _getProversDisplayInfo(allProvers);

        // Sort by total assets (quicksort - O(n log n) average case)
        if (allProversInfo.length > 1) {
            _quickSort(allProversInfo, 0, int256(allProversInfo.length - 1));
        }

        // Return top `limit` provers
        uint256 resultLength = limit > allProversInfo.length ? allProversInfo.length : limit;
        proversInfo = new ProverDisplayInfo[](resultLength);
        for (uint256 i = 0; i < resultLength; i++) {
            proversInfo[i] = allProversInfo[i];
        }
    }

    // =========================================================================
    // PROVER-SPECIFIC VIEW FUNCTIONS
    // =========================================================================

    /**
     * @notice Get display information for a single prover
     */
    function getProverInfo(address prover) external view override returns (ProverDisplayInfo memory proverInfo) {
        address[] memory provers = new address[](1);
        provers[0] = prover;
        ProverDisplayInfo[] memory proversInfo = _getProversDisplayInfo(provers);
        proverInfo = proversInfo[0];
    }

    /**
     * @notice Convert shares to assets for a specific prover
     */
    function convertSharesToAssets(address prover, uint256 shares) external view override returns (uint256 assets) {
        address vault = stakingController.getProverVault(prover);
        if (vault != address(0)) {
            assets = IProverVault(vault).convertToAssets(shares);
        }
    }

    /**
     * @notice Convert assets to shares for a specific prover
     */
    function convertAssetsToShares(address prover, uint256 assets) external view override returns (uint256 shares) {
        address vault = stakingController.getProverVault(prover);
        if (vault != address(0)) {
            shares = IProverVault(vault).convertToShares(assets);
        }
    }

    // =========================================================================
    // USER-SPECIFIC VIEW FUNCTIONS
    // =========================================================================

    /**
     * @notice Get complete portfolio information for a user
     */
    function getUserPortfolio(address user) external view override returns (UserPortfolio memory portfolio) {
        // Get all provers and check which ones the user has stakes with
        address[] memory allProvers = stakingController.getAllProvers();
        UserStakeInfo[] memory tempStakes = new UserStakeInfo[](allProvers.length);
        uint256 actualStakeCount = 0;

        for (uint256 i = 0; i < allProvers.length; i++) {
            address prover = allProvers[i];
            uint256 shares = stakingController.getStakeInfo(prover, user);

            if (shares > 0 || stakingController.stakerHasPendingUnstakes(prover, user)) {
                UserStakeInfo memory stakeInfo = _getUserStakeInfo(prover, user);
                tempStakes[actualStakeCount] = stakeInfo;
                actualStakeCount++;

                // Accumulate totals
                portfolio.totalValue += stakeInfo.currentValue;
                portfolio.totalUnstaking += stakeInfo.totalUnstaking;
                portfolio.totalReadyToWithdraw += stakeInfo.readyToWithdraw;
            }
        }

        // Copy to appropriately sized array
        portfolio.stakes = new UserStakeInfo[](actualStakeCount);
        for (uint256 i = 0; i < actualStakeCount; i++) {
            portfolio.stakes[i] = tempStakes[i];
        }
    }

    /**
     * @notice Get user's stake information with specific provers
     */
    function getUserStakesWithProvers(address user, address[] calldata provers)
        external
        view
        override
        returns (UserStakeInfo[] memory stakesInfo)
    {
        stakesInfo = new UserStakeInfo[](provers.length);
        for (uint256 i = 0; i < provers.length; i++) {
            stakesInfo[i] = _getUserStakeInfo(provers[i], user);
        }
    }

    /**
     * @notice Get user's stake information with a specific prover
     */
    function getUserStakeWithProver(address user, address prover)
        external
        view
        override
        returns (UserStakeInfo memory stakeInfo)
    {
        stakeInfo = _getUserStakeInfo(prover, user);
    }

    /**
     * @notice Get user's ready-to-withdraw amounts across all provers
     */
    function getUserReadyWithdrawals(address user)
        external
        view
        override
        returns (address[] memory provers, uint256[] memory amounts, uint256 totalReady)
    {
        address[] memory allProvers = stakingController.getAllProvers();
        address[] memory tempProvers = new address[](allProvers.length);
        uint256[] memory tempAmounts = new uint256[](allProvers.length);
        uint256 count = 0;

        for (uint256 i = 0; i < allProvers.length; i++) {
            address prover = allProvers[i];
            (, uint256 readyAmount) = stakingController.getUnstakingInfo(prover, user);

            if (readyAmount > 0) {
                tempProvers[count] = prover;
                tempAmounts[count] = readyAmount;
                totalReady += readyAmount;
                count++;
            }
        }

        // Copy to appropriately sized arrays
        provers = new address[](count);
        amounts = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            provers[i] = tempProvers[i];
            amounts[i] = tempAmounts[i];
        }
    }

    // =========================================================================
    // BATCH CONVERSION FUNCTIONS
    // =========================================================================

    /**
     * @notice Convert multiple share amounts to assets for different provers
     */
    function batchConvertToAssets(address[] calldata provers, uint256[] calldata shares)
        external
        view
        override
        returns (uint256[] memory assets)
    {
        require(provers.length == shares.length, "Array length mismatch");

        assets = new uint256[](provers.length);
        for (uint256 i = 0; i < provers.length; i++) {
            address vault = stakingController.getProverVault(provers[i]);
            if (vault != address(0)) {
                assets[i] = IProverVault(vault).convertToAssets(shares[i]);
            }
        }
    }

    /**
     * @notice Convert multiple asset amounts to shares for different provers
     */
    function batchConvertToShares(address[] calldata provers, uint256[] calldata assets)
        external
        view
        override
        returns (uint256[] memory shares)
    {
        require(provers.length == assets.length, "Array length mismatch");

        shares = new uint256[](provers.length);
        for (uint256 i = 0; i < provers.length; i++) {
            address vault = stakingController.getProverVault(provers[i]);
            if (vault != address(0)) {
                shares[i] = IProverVault(vault).convertToShares(assets[i]);
            }
        }
    }

    /**
     * @notice Preview staking for multiple provers
     */
    function batchPreviewStake(address[] calldata provers, uint256[] calldata assets)
        external
        view
        override
        returns (uint256[] memory shares, bool[] memory eligible)
    {
        require(provers.length == assets.length, "Array length mismatch");

        shares = new uint256[](provers.length);
        eligible = new bool[](provers.length);

        for (uint256 i = 0; i < provers.length; i++) {
            address vault = stakingController.getProverVault(provers[i]);
            if (vault != address(0)) {
                shares[i] = IProverVault(vault).previewDeposit(assets[i]);
                eligible[i] = stakingController.getProverState(provers[i]) == IStakingController.ProverState.Active;
            }
        }
    }

    // =========================================================================
    // UTILITY FUNCTIONS
    // =========================================================================

    /**
     * @notice Get stakers count for multiple provers
     */
    function batchGetStakerCounts(address[] calldata provers)
        external
        view
        override
        returns (uint256[] memory stakerCounts)
    {
        stakerCounts = new uint256[](provers.length);
        for (uint256 i = 0; i < provers.length; i++) {
            (,,,, uint256 numStakers,,) = stakingController.getProverInfo(provers[i]);
            stakerCounts[i] = numStakers;
        }
    }

    // =========================================================================
    // INTERNAL HELPER FUNCTIONS
    // =========================================================================

    /**
     * @notice Internal function to get prover display info for an array of provers
     */
    function _getProversDisplayInfo(address[] memory provers)
        internal
        view
        returns (ProverDisplayInfo[] memory proversInfo)
    {
        proversInfo = new ProverDisplayInfo[](provers.length);

        for (uint256 i = 0; i < provers.length; i++) {
            proversInfo[i] = _getSingleProverDisplayInfo(provers[i]);
        }
    }

    /**
     * @notice Internal function to get display info for a single prover
     */
    function _getSingleProverDisplayInfo(address prover) internal view returns (ProverDisplayInfo memory info) {
        // Get basic prover info
        (
            IStakingController.ProverState state,
            address vault,
            uint64 defaultCommissionRate,
            uint256 pendingCommission,
            uint256 numStakers,
            uint64 joinedAt,
            string memory proverName
        ) = stakingController.getProverInfo(prover);

        // Set basic fields
        info.prover = prover;
        info.state = state;
        info.vault = vault;
        info.defaultCommissionRate = defaultCommissionRate;
        info.pendingCommission = pendingCommission;
        info.numStakers = numStakers;
        info.joinedAt = joinedAt;

        // Get and set asset information
        if (vault != address(0)) {
            IProverVault proverVault = IProverVault(vault);
            info.vaultAssets = proverVault.totalAssets();
            info.vaultShares = proverVault.totalSupply();
        }

        // Get and set additional metrics
        info.totalAssets = stakingController.getProverTotalAssets(prover);
        info.totalUnstaking = stakingController.getProverTotalUnstaking(prover);
        info.slashingScale = stakingController.getProverSlashingScale(prover);

        // Get and set commission rates
        (address[] memory sources, uint64[] memory rates) = stakingController.getCommissionRates(prover);
        info.commissionRates = new ProverCommissionInfo[](sources.length);
        for (uint256 j = 0; j < sources.length; j++) {
            info.commissionRates[j] = ProverCommissionInfo({source: sources[j], rate: rates[j]});
        }

        // Attach profile info (name via getProverInfo, iconUrl via getProverProfile)
        info.name = proverName;
        (, string memory iconUrl) = stakingController.getProverProfile(prover);
        info.iconUrl = iconUrl;
    }

    /**
     * @notice Internal function to get user stake info for a specific prover
     */
    function _getUserStakeInfo(address prover, address user) internal view returns (UserStakeInfo memory stakeInfo) {
        stakeInfo.prover = prover;
        stakeInfo.isProver = (prover == user);

        // Get share information
        stakeInfo.shares = stakingController.getStakeInfo(prover, user);

        // Convert shares to current value
        address vault = stakingController.getProverVault(prover);
        if (vault != address(0) && stakeInfo.shares > 0) {
            stakeInfo.currentValue = IProverVault(vault).convertToAssets(stakeInfo.shares);
        }

        // Get unstaking information
        (stakeInfo.totalUnstaking, stakeInfo.readyToWithdraw) = stakingController.getUnstakingInfo(prover, user);
        stakeInfo.pendingRequests = stakingController.getPendingUnstakes(prover, user);
    }

    /**
     * @notice Quicksort implementation for sorting provers by total assets (descending)
     */
    function _quickSort(ProverDisplayInfo[] memory arr, int256 left, int256 right) internal pure {
        if (left < right) {
            int256 pivotIndex = _partition(arr, left, right);
            _quickSort(arr, left, pivotIndex - 1);
            _quickSort(arr, pivotIndex + 1, right);
        }
    }

    /**
     * @notice Partition function for quicksort - sorts in descending order by totalAssets
     */
    function _partition(ProverDisplayInfo[] memory arr, int256 left, int256 right) internal pure returns (int256) {
        uint256 pivot = arr[uint256(right)].totalAssets;
        int256 i = left - 1;

        for (int256 j = left; j < right; j++) {
            // Sort in descending order (larger totalAssets first)
            if (arr[uint256(j)].totalAssets > pivot) {
                i++;
                // Swap elements
                ProverDisplayInfo memory tempElement = arr[uint256(i)];
                arr[uint256(i)] = arr[uint256(j)];
                arr[uint256(j)] = tempElement;
            }
        }

        // Place pivot in correct position
        ProverDisplayInfo memory pivotElement = arr[uint256(i + 1)];
        arr[uint256(i + 1)] = arr[uint256(right)];
        arr[uint256(right)] = pivotElement;

        return i + 1;
    }
}
