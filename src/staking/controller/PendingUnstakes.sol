// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../interfaces/IStakingController.sol";

/**
 * @title PendingUnstakes - Abstract contract for time-delayed unstaking with slashing
 * @notice Manages unstaking requests with time delays and slashing protection.
 *         Uses cumulative slashing scales to efficiently apply slashing to all pending requests.
 *         All operations are keyed by prover address for user-friendly interactions.
 */
abstract contract PendingUnstakes is IStakingController {
    using EnumerableSet for EnumerableSet.AddressSet;
    // =========================================================================
    // CONSTANTS
    // =========================================================================

    uint256 public constant BPS_DENOMINATOR = 10000; // 100.00%
    uint256 public constant MAX_PENDING_UNSTAKES = 10; // Maximum unstaking requests per staker per prover

    // Slashing protection thresholds
    uint256 public constant DEACTIVATION_SCALE = 4000; // 40% (soft threshold - triggers deactivation)
    uint256 public constant MIN_SCALE_FLOOR = 2000; // 20% (hard floor - cannot be crossed)

    // =========================================================================
    // STATE VARIABLES
    // =========================================================================

    // Configurable unstaking delay period in seconds
    uint256 public unstakeDelay;

    // Consolidated pending unstakes data per prover
    // StakingController initializeProver initializes slashingScale to BPS_DENOMINATOR
    mapping(address => ProverPendingUnstakes) pendingUnstakes;

    uint256 public totalUnstaking; // Total amount currently unstaking across all provers

    // =========================================================================
    // INTERNAL UNSTAKING FUNCTIONS
    // =========================================================================

    /**
     * @notice Processes an unstaking request and queues it for delayed release
     * @param prover The prover address the tokens came from
     * @param staker The staker who requested unstaking
     * @param amount The amount of tokens received for unstaking
     */
    function _receiveUnstake(address prover, address staker, uint256 amount) internal {
        if (amount == 0) revert ControllerZeroAmount();

        UnstakeRequest[] storage unstakeRequests = pendingUnstakes[prover].requests[staker];

        // Check pending unstakes limit per staker per prover
        if (unstakeRequests.length >= MAX_PENDING_UNSTAKES) {
            revert ControllerTooManyPendingUnstakes();
        }

        // If this is the staker's first request for this prover, add to stakers set
        if (unstakeRequests.length == 0) {
            pendingUnstakes[prover].stakers.add(staker);
        }

        // Add to pending requests
        uint256 requestTime = block.timestamp;
        unstakeRequests.push(
            UnstakeRequest({
                amount: amount,
                requestTime: requestTime,
                scaleSnapshot: pendingUnstakes[prover].slashingScale
            })
        );

        // Update prover total for slashing calculations
        pendingUnstakes[prover].totalUnstaking += amount;

        // Update global total unstaking
        totalUnstaking += amount;
    }

    /**
     * @notice Processes ready unstaking requests after delay period
     * @param prover The prover to complete unstaking from
     * @return assets The total amount of assets ready for transfer
     */
    function _completeUnstake(address prover) internal returns (uint256 assets) {
        address staker = msg.sender;
        UnstakeRequest[] storage unstakeRequests = pendingUnstakes[prover].requests[staker];

        if (unstakeRequests.length == 0) {
            revert ControllerNoUnstakeRequest();
        }

        uint256 completedCount = 0;
        uint256 slashingScale = pendingUnstakes[prover].slashingScale;

        // Process all ready requests (they're ordered by time)
        for (uint256 i = 0; i < unstakeRequests.length; i++) {
            UnstakeRequest storage request = unstakeRequests[i];

            // Check if request is ready
            if (block.timestamp >= request.requestTime + unstakeDelay) {
                // Calculate effective amount after slashing
                uint256 effectiveAmount =
                    _calculateEffectiveAmount(request.amount, request.scaleSnapshot, slashingScale);

                assets += effectiveAmount;
                completedCount++;
            } else {
                // Since array is ordered by time, no more requests will be ready
                break;
            }
        }

        if (completedCount == 0) {
            revert ControllerUnstakeNotReady();
        }

        // Update prover total unstaking (subtract effective amounts, not original)
        pendingUnstakes[prover].totalUnstaking -= assets;

        // Update global total unstaking (subtract effective amounts)
        totalUnstaking -= assets;

        // Remove completed requests - shift remaining elements to the front
        for (uint256 i = 0; i < unstakeRequests.length - completedCount; i++) {
            unstakeRequests[i] = unstakeRequests[i + completedCount];
        }

        // Remove the completed elements from the end
        for (uint256 i = 0; i < completedCount; i++) {
            unstakeRequests.pop();
        }

        // If staker has no more pending requests, remove from stakers set
        if (unstakeRequests.length == 0) {
            pendingUnstakes[prover].stakers.remove(staker);
        }

        return assets;
    }

    /**
     * @notice Slashes unstaking tokens proportionally for a prover
     * @param prover The prover to slash unstaking tokens for
     * @param bps The slashing percentage in basis points (e.g., 2000 = 20%)
     * @return slashedAmount The total amount of tokens slashed from unstaking pool
     * @return shouldDeactivate Whether the prover should be deactivated
     */
    function _slashUnstaking(address prover, uint256 bps)
        internal
        returns (uint256 slashedAmount, bool shouldDeactivate)
    {
        if (bps > BPS_DENOMINATOR) revert ControllerInvalidArg();

        // Calculate what the new scale would be after slashing
        uint256 oldScale = pendingUnstakes[prover].slashingScale;
        uint256 newScale = (oldScale * (BPS_DENOMINATOR - bps)) / BPS_DENOMINATOR;

        // Prevent slashing that would push scale below hard floor (20%)
        if (newScale < MIN_SCALE_FLOOR) {
            revert ControllerSlashTooHigh();
        }
        // Check if new scale triggers deactivation
        if (newScale < DEACTIVATION_SCALE) {
            shouldDeactivate = true;
        }

        // Update cumulative slashing scale to track prover's slashing history
        pendingUnstakes[prover].slashingScale = newScale;

        uint256 proverTotalUnstaking = pendingUnstakes[prover].totalUnstaking;
        if (proverTotalUnstaking == 0) {
            return (0, shouldDeactivate); // No unstaking tokens to slash, but scale is updated
        }

        // Keep totals aligned with the truncated slashing scale by recomputing the new total first
        pendingUnstakes[prover].totalUnstaking = (proverTotalUnstaking * newScale) / oldScale;
        slashedAmount = proverTotalUnstaking - pendingUnstakes[prover].totalUnstaking;
        if (slashedAmount == 0) {
            return (0, shouldDeactivate); // Nothing to slash
        }

        // Update global total unstaking (reduce by slashed amount)
        totalUnstaking -= slashedAmount;

        return (slashedAmount, shouldDeactivate);
    }

    /**
     * @notice Calculate the effective amount after applying all slashing since request creation
     * @dev Uses scale ratio between request snapshot and current scale to determine final amount
     * @param originalAmount The original unstake amount when request was made
     * @param requestScaleSnapshot The prover's slashing scale when request was created
     * @param currentSlashingScale The prover's current cumulative slashing scale
     * @return effectiveAmount The final amount after applying all intervening slashing events
     */
    function _calculateEffectiveAmount(
        uint256 originalAmount,
        uint256 requestScaleSnapshot,
        uint256 currentSlashingScale
    ) internal pure returns (uint256 effectiveAmount) {
        // Defensive checks - scales should be initialized when this is called, but ensure safety
        if (currentSlashingScale == 0) {
            currentSlashingScale = BPS_DENOMINATOR;
        }
        if (requestScaleSnapshot == 0) {
            requestScaleSnapshot = BPS_DENOMINATOR;
        }

        // Effective amount = original * (current_scale / snapshot_scale)
        return (originalAmount * currentSlashingScale) / requestScaleSnapshot;
    }

    // =========================================================================
    // EXTERNAL VIEW FUNCTIONS - UNSTAKING QUERIES
    // =========================================================================

    /**
     * @notice Get all pending unstake requests for a staker with a prover
     * @dev Returns complete request details including timestamps and slashing snapshots
     * @param prover The prover address to query
     * @param staker The staker address to query
     * @return requests Array of pending UnstakeRequest structures
     *
     * Returned Data:
     * - Original amounts (before slashing)
     * - Request timestamps for delay calculations
     * - Scale snapshots for effective amount calculations
     */
    function getPendingUnstakes(address prover, address staker)
        external
        view
        override
        returns (UnstakeRequest[] memory requests)
    {
        return pendingUnstakes[prover].requests[staker];
    }

    /**
     * @notice Get comprehensive unstaking information for a staker with a prover
     * @param prover The prover address to query
     * @param staker The staker address to query
     * @return totalAmount Total effective amount currently unstaking (post-slashing)
     * @return readyAmount Effective amount ready to be completed and withdrawn
     */
    function getUnstakingInfo(address prover, address staker)
        external
        view
        returns (uint256 totalAmount, uint256 readyAmount)
    {
        UnstakeRequest[] storage unstakeRequests = pendingUnstakes[prover].requests[staker];
        uint256 currentSlashingScale = pendingUnstakes[prover].slashingScale;

        for (uint256 i = 0; i < unstakeRequests.length; i++) {
            UnstakeRequest storage request = unstakeRequests[i];
            uint256 effectiveAmount =
                _calculateEffectiveAmount(request.amount, request.scaleSnapshot, currentSlashingScale);

            totalAmount += effectiveAmount;

            // Check if this request is ready for completion
            if (block.timestamp >= request.requestTime + unstakeDelay) {
                readyAmount += effectiveAmount;
            }
        }
    }

    /**
     * @notice Get total unstaking amount for a specific prover across all stakers
     * @param prover The prover address to query
     * @return totalAmount Total original amount unstaking from the prover
     */
    function getProverTotalUnstaking(address prover) external view override returns (uint256 totalAmount) {
        return pendingUnstakes[prover].totalUnstaking;
    }

    /**
     * @notice Get the cumulative slashing scale for a prover
     * @param prover The prover address to query
     * @return scale The current cumulative slashing scale in basis points (10000 = no slashing, 8000 = 20% slashed)
     */
    function getProverSlashingScale(address prover) external view override returns (uint256 scale) {
        return pendingUnstakes[prover].slashingScale;
    }

    /**
     * @notice Get all stakers who have pending unstakes for a specific prover
     * @param prover The prover address to query
     * @return stakers Array of staker addresses with pending unstakes
     */
    function getStakersWithPendingUnstakes(address prover) external view returns (address[] memory) {
        return pendingUnstakes[prover].stakers.values();
    }

    /**
     * @notice Get the number of stakers who have pending unstakes for a specific prover
     * @param prover The prover address to query
     * @return count The number of stakers with pending unstakes
     */
    function getStakersWithPendingUnstakesCount(address prover) external view returns (uint256) {
        return pendingUnstakes[prover].stakers.length();
    }

    /**
     * @notice Check if a staker has pending unstakes for a specific prover
     * @param prover The prover address to check
     * @param staker The staker address to check
     * @return hasUnstakes Whether the staker has pending unstakes for this prover
     */
    function stakerHasPendingUnstakes(address prover, address staker) external view returns (bool) {
        return pendingUnstakes[prover].stakers.contains(staker);
    }
}
