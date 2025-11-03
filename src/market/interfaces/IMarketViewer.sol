// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IBrevisMarket.sol";

/**
 * @title IMarketViewer
 * @notice Read-only composite views for the Brevis proof marketplace optimized for frontend and indexers.
 * @dev This interface centralizes rich view structs and batched getters to keep the core market contract lean.
 * Frontends should prefer these helpers over stitching multiple low-level calls.
 */
interface IMarketViewer {
    // =========================================================================
    // TYPES
    // =========================================================================

    /**
     * @notice Complete request metadata for display
     * @dev Mirrors IBrevisMarket.getRequest outputs with the reqid included for convenience
     */
    struct RequestView {
        bytes32 reqid;
        IBrevisMarket.ReqStatus status;
        uint64 timestamp;
        address sender;
        uint256 maxFee;
        uint256 minStake;
        uint64 deadline;
        bytes32 vk;
        bytes32 publicValuesDigest;
    }

    /**
     * @notice Winning and second bidder summary for a request
     * @dev Reverse second-price auction: winner pays second-lowest bid
     */
    struct BiddersView {
        bytes32 reqid;
        address winner;
        uint256 winnerFee;
        address second;
        uint256 secondFee;
    }

    /**
     * @notice Pending list item with deadline and winner context
     * @dev isOverdue is true if now > deadline while status is still Pending
     */
    struct PendingItemView {
        bytes32 reqid;
        uint64 deadline;
        IBrevisMarket.ReqStatus status;
        address winner;
        bool isOverdue;
    }

    /**
     * @notice Comprehensive per-prover stats for UI
     * @dev successRateBps includes overdue pending in denominator by design
     */
    struct ProverStatsComposite {
        IBrevisMarket.ProverStats total;
        IBrevisMarket.ProverStats recent;
        uint64 recentStartAt;
        uint256 successRateBps; // 0–10000 (basis points)
        uint64 fulfilled;
        uint64 refunded;
        uint256 pendingCount;
        uint256 overdueCount;
    }

    /**
     * @notice System-wide stats composite for dashboards
     */
    struct GlobalStatsComposite {
        IBrevisMarket.GlobalStats total;
        IBrevisMarket.GlobalStats recent;
        uint64 recentStartAt;
    }

    // =========================================================================
    // BATCH GETTERS
    // =========================================================================

    /**
     * @notice Batch fetch request metadata for a list of reqids
     */
    function batchGetRequests(bytes32[] calldata reqids) external view returns (RequestView[] memory out);

    /**
     * @notice Batch fetch winner/second bidder info for requests
     */
    function batchGetBidders(bytes32[] calldata reqids) external view returns (BiddersView[] memory out);

    /**
     * @notice Batch fetch sealed bid hashes for a single request across provers
     */
    function batchGetBidHashes(bytes32 reqid, address[] calldata provers)
        external
        view
        returns (bytes32[] memory bidHashes);

    /**
     * @notice Batch fetch proofs (fulfilled requests)
     */
    function batchGetProofs(bytes32[] calldata reqids) external view returns (uint256[8][] memory proofs);

    // =========================================================================
    // PENDING LISTS, PAGINATION, OVERDUE
    // =========================================================================

    /**
     * @notice Number of pending requests currently assigned to a prover
     */
    function getProverPendingCount(address prover) external view returns (uint256 count);

    /**
     * @notice Number of pending requests created by a sender
     */
    function getSenderPendingCount(address sender) external view returns (uint256 count);

    /**
     * @notice Paginate the prover's pending requests
     * @return items Slice of pending items with deadline/winner
     * @return total Total pending count (for client-side pagination)
     */
    function getProverPendingSlice(address prover, uint256 offset, uint256 limit)
        external
        view
        returns (PendingItemView[] memory items, uint256 total);

    /**
     * @notice Paginate the sender's pending requests
     * @return items Slice of pending items with deadline/winner
     * @return total Total pending count (for client-side pagination)
     */
    function getSenderPendingSlice(address sender, uint256 offset, uint256 limit)
        external
        view
        returns (PendingItemView[] memory items, uint256 total);

    /**
     * @notice Count of overdue pending requests for a prover (now > deadline)
     */
    function getProverOverdueCount(address prover) external view returns (uint256 overdue);

    /**
     * @notice Count of overdue pending requests for a sender (now > deadline)
     */
    function getSenderOverdueCount(address sender) external view returns (uint256 overdue);

    /**
     * @notice All overdue pending request IDs for a prover
     */
    function getProverOverdueRequests(address prover) external view returns (bytes32[] memory reqids);

    /**
     * @notice All overdue pending request IDs for a sender
     */
    function getSenderOverdueRequests(address sender) external view returns (bytes32[] memory reqids);

    // =========================================================================
    // STATS COMPOSITES
    // =========================================================================

    /**
     * @notice Composite stats for a prover including a success rate suitable for UI
     * @dev successRateBps = fulfilled / (fulfilled + refunded + overduePending) in basis points (0–10000)
     */
    function getProverStatsComposite(address prover) external view returns (ProverStatsComposite memory v);

    /**
     * @notice Composite global stats suitable for dashboards
     */
    function getGlobalStatsComposite() external view returns (GlobalStatsComposite memory v);

    // =========================================================================
    // EPOCHS HELPERS
    // =========================================================================

    /**
     * @notice Paginate over stats epochs metadata
     * @return startAts Epoch start timestamps
     * @return endAts Epoch end timestamps (0 for tail epoch)
     * @return total Total number of epochs
     */
    function getStatsEpochsSlice(uint256 offset, uint256 limit)
        external
        view
        returns (uint64[] memory startAts, uint64[] memory endAts, uint256 total);
}
