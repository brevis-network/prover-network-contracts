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

    /// @notice Pending list item for a prover (winner not relevant). Overdue can be derived off-chain via now > deadline.
    struct ProverPendingItem {
        bytes32 reqid;
        uint64 deadline;
    }

    /// @notice Pending list item for a sender (includes winner). Overdue can be derived off-chain via now > deadline.
    struct SenderPendingItem {
        bytes32 reqid;
        uint64 deadline;
        address winner;
    }

    /**
     * @notice Comprehensive per-prover stats for UI
     * @dev successRateBps includes overdue pending in denominator by design
     */
    struct ProverStatsComposite {
        IBrevisMarket.ProverStats total;
        IBrevisMarket.ProverStats recent;
        uint64 recentStartAt;
        uint64 successRateBps; // 0–10000 (basis points)
        uint64 fulfilled;
        uint64 refunded;
        uint64 pendingCount;
        uint64 overdueCount;
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
    function getProverPendingCount(address prover) external view returns (uint64 count);

    /**
     * @notice Number of pending requests created by a sender
     */
    function getSenderPendingCount(address sender) external view returns (uint64 count);

    /**
     * @notice Get all pending items for a prover with deadline & overdue info
     */
    function getProverPendingRequests(address prover) external view returns (ProverPendingItem[] memory items);

    /**
     * @notice Get all pending items for a sender with deadline, winner & overdue info
     */
    function getSenderPendingRequests(address sender) external view returns (SenderPendingItem[] memory items);

    /**
     * @notice Count of overdue pending requests for a prover (now > deadline)
     */
    function getProverOverdueCount(address prover) external view returns (uint64 overdue);

    /**
     * @notice Count of overdue pending requests for a sender (now > deadline)
     */
    function getSenderOverdueCount(address sender) external view returns (uint64 overdue);

    /**
     * @notice All overdue pending request IDs for a prover
     */
    function getProverOverdueRequests(address prover) external view returns (bytes32[] memory reqids);

    /**
     * @notice All overdue pending request IDs for a sender
     */
    function getSenderOverdueRequests(address sender) external view returns (bytes32[] memory reqids);

    /**
     * @notice All refundable request IDs for a sender
     * @dev Includes all scenarios where `refund(reqid)` can be called
     */
    function getSenderRefundableRequests(address sender) external view returns (bytes32[] memory reqids);

    // =========================================================================
    // STATS COMPOSITES
    // =========================================================================

    /**
     * @notice Composite stats for a prover including a success rate
     * @dev successRateBps = fulfilled / (fulfilled + refunded + overdueCount) in basis points (0–10000)
     */
    function getProverStatsComposite(address prover) external view returns (ProverStatsComposite memory v);

    /**
     * @notice Batch composite stats for a list of provers
     * @dev Mirrors getProverStatsComposite but returns an array matching the input order
     */
    function batchGetProverStatsComposite(address[] calldata provers)
        external
        view
        returns (ProverStatsComposite[] memory out);

    /**
     * @notice Composite global stats suitable for dashboards
     */
    function getGlobalStatsComposite() external view returns (GlobalStatsComposite memory v);

    // =========================================================================
    // EPOCHS HELPERS
    // =========================================================================

    /**
     * @notice Get all stats epochs metadata (start/end timestamps)
     */
    function getStatsEpochs() external view returns (uint64[] memory startAts, uint64[] memory endAts);

    /**
     * @notice Get epoch metadata for selected epochIds
     */
    function getStatsEpochs(uint64[] calldata epochIds)
        external
        view
        returns (uint64[] memory startAts, uint64[] memory endAts);
}
