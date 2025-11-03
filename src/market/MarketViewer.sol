// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IBrevisMarket.sol";
import "./interfaces/IMarketViewer.sol";

/// @title MarketViewer
/// @notice Read-only aggregator for BrevisMarket: batch getters, pending/overdue views, and composite stats
contract MarketViewer is IMarketViewer {
    IBrevisMarket public immutable brevisMarket;

    constructor(address _brevisMarketAddress) {
        brevisMarket = IBrevisMarket(_brevisMarketAddress);
    }

    // =========================================================================
    // BATCH GETTERS
    // =========================================================================

    function batchGetRequests(bytes32[] calldata reqids)
        external
        view
        returns (IMarketViewer.RequestView[] memory out)
    {
        uint256 n = reqids.length;
        out = new IMarketViewer.RequestView[](n);
        for (uint256 i = 0; i < n; i++) {
            (
                IBrevisMarket.ReqStatus status,
                uint64 timestamp,
                address sender,
                uint256 maxFee,
                uint256 minStake,
                uint64 deadline,
                bytes32 vk,
                bytes32 publicValuesDigest
            ) = brevisMarket.getRequest(reqids[i]);
            out[i] = IMarketViewer.RequestView({
                reqid: reqids[i],
                status: status,
                timestamp: timestamp,
                sender: sender,
                maxFee: maxFee,
                minStake: minStake,
                deadline: deadline,
                vk: vk,
                publicValuesDigest: publicValuesDigest
            });
        }
    }

    function batchGetBidders(bytes32[] calldata reqids)
        external
        view
        returns (IMarketViewer.BiddersView[] memory out)
    {
        uint256 n = reqids.length;
        out = new IMarketViewer.BiddersView[](n);
        for (uint256 i = 0; i < n; i++) {
            (address winner, uint256 winnerFee, address secondPlace, uint256 secondFee) =
                brevisMarket.getBidders(reqids[i]);
            out[i] = IMarketViewer.BiddersView({
                reqid: reqids[i],
                winner: winner,
                winnerFee: winnerFee,
                second: secondPlace,
                secondFee: secondFee
            });
        }
    }

    function batchGetBidHashes(bytes32 reqid, address[] calldata provers)
        external
        view
        returns (bytes32[] memory bidHashes)
    {
        uint256 n = provers.length;
        bidHashes = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            bidHashes[i] = brevisMarket.getBidHash(reqid, provers[i]);
        }
    }

    function batchGetProofs(bytes32[] calldata reqids) external view returns (uint256[8][] memory proofs) {
        uint256 n = reqids.length;
        proofs = new uint256[8][](n);
        for (uint256 i = 0; i < n; i++) {
            proofs[i] = brevisMarket.getProof(reqids[i]);
        }
    }

    // =========================================================================
    // PENDING LISTS, PAGINATION, OVERDUE
    // =========================================================================

    function getProverPendingCount(address prover) external view returns (uint64 count) {
        bytes32[] memory all = brevisMarket.getProverPendingRequests(prover);
        return uint64(all.length);
    }

    function getSenderPendingCount(address sender) external view returns (uint64 count) {
        bytes32[] memory all = brevisMarket.getSenderPendingRequests(sender);
        return uint64(all.length);
    }

    function getProverPendingRequests(address prover)
        external
        view
        returns (IMarketViewer.PendingItemView[] memory items)
    {
        bytes32[] memory all = brevisMarket.getProverPendingRequests(prover);
        return _pendingViews(all);
    }

    function getProverPendingRequests(address, /*prover*/ bytes32[] calldata reqids)
        external
        view
        returns (IMarketViewer.PendingItemView[] memory items)
    {
        return _pendingViews(reqids);
    }

    function getSenderPendingRequests(address sender)
        external
        view
        returns (IMarketViewer.PendingItemView[] memory items)
    {
        bytes32[] memory all = brevisMarket.getSenderPendingRequests(sender);
        return _pendingViews(all);
    }

    function getSenderPendingRequests(address, /*sender*/ bytes32[] calldata reqids)
        external
        view
        returns (IMarketViewer.PendingItemView[] memory items)
    {
        return _pendingViews(reqids);
    }

    function getProverOverdueCount(address prover) external view returns (uint64 overdue) {
        bytes32[] memory all = brevisMarket.getProverPendingRequests(prover);
        for (uint256 i = 0; i < all.length; i++) {
            (,,,,, uint64 deadline,,) = brevisMarket.getRequest(all[i]);
            // Items in proverPendingRequests are Pending by construction; still check deadline
            if (block.timestamp > deadline) overdue++;
        }
    }

    function getSenderOverdueCount(address sender) external view returns (uint64 overdue) {
        bytes32[] memory all = brevisMarket.getSenderPendingRequests(sender);
        for (uint256 i = 0; i < all.length; i++) {
            (,,,,, uint64 deadline,,) = brevisMarket.getRequest(all[i]);
            if (block.timestamp > deadline) overdue++;
        }
    }

    /**
     * @notice Get all overdue pending request IDs for a prover
     * @dev Overdue = current time > deadline; data sourced from prover's pending set
     */
    function getProverOverdueRequests(address prover) external view returns (bytes32[] memory reqids) {
        bytes32[] memory all = brevisMarket.getProverPendingRequests(prover);
        uint256 count;
        for (uint256 i = 0; i < all.length; i++) {
            (,,,,, uint64 deadline,,) = brevisMarket.getRequest(all[i]);
            if (block.timestamp > deadline) count++;
        }
        reqids = new bytes32[](count);
        uint256 j;
        for (uint256 i = 0; i < all.length; i++) {
            (,,,,, uint64 deadline,,) = brevisMarket.getRequest(all[i]);
            if (block.timestamp > deadline) {
                reqids[j++] = all[i];
            }
        }
    }

    /**
     * @notice Get all overdue pending request IDs for a sender
     * @dev Overdue = current time > deadline; data sourced from sender's pending set
     */
    function getSenderOverdueRequests(address sender) external view returns (bytes32[] memory reqids) {
        bytes32[] memory all = brevisMarket.getSenderPendingRequests(sender);
        uint256 count;
        for (uint256 i = 0; i < all.length; i++) {
            (,,,,, uint64 deadline,,) = brevisMarket.getRequest(all[i]);
            if (block.timestamp > deadline) count++;
        }
        reqids = new bytes32[](count);
        uint256 j;
        for (uint256 i = 0; i < all.length; i++) {
            (,,,,, uint64 deadline,,) = brevisMarket.getRequest(all[i]);
            if (block.timestamp > deadline) {
                reqids[j++] = all[i];
            }
        }
    }

    // =========================================================================
    // STATS COMPOSITES
    // =========================================================================

    function getProverStatsComposite(address prover)
        external
        view
        returns (IMarketViewer.ProverStatsComposite memory v)
    {
        v = _proverStatsComposite(prover);
    }

    function batchGetProverStatsComposite(address[] calldata provers)
        external
        view
        returns (IMarketViewer.ProverStatsComposite[] memory out)
    {
        uint256 n = provers.length;
        out = new IMarketViewer.ProverStatsComposite[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _proverStatsComposite(provers[i]);
        }
    }

    function getGlobalStatsComposite() external view returns (IMarketViewer.GlobalStatsComposite memory v) {
        (IBrevisMarket.GlobalStats memory recent, uint64 startAt) = brevisMarket.getGlobalRecentStats();
        IBrevisMarket.GlobalStats memory total = brevisMarket.getGlobalStatsTotal();
        v = IMarketViewer.GlobalStatsComposite({total: total, recent: recent, recentStartAt: startAt});
    }

    // =========================================================================
    // EPOCHS HELPERS
    // =========================================================================

    function getStatsEpochs() external view returns (uint64[] memory startAts, uint64[] memory endAts) {
        uint256 len = brevisMarket.statsEpochsLength();
        startAts = new uint64[](len);
        endAts = new uint64[](len);
        for (uint256 i = 0; i < len; i++) {
            (uint64 s, uint64 e) = brevisMarket.statsEpochs(i);
            startAts[i] = s;
            endAts[i] = e;
        }
    }

    function getStatsEpochs(uint64[] calldata epochIds)
        external
        view
        returns (uint64[] memory startAts, uint64[] memory endAts)
    {
        uint256 m = epochIds.length;
        startAts = new uint64[](m);
        endAts = new uint64[](m);
        for (uint256 i = 0; i < m; i++) {
            (uint64 s, uint64 e) = brevisMarket.statsEpochs(epochIds[i]);
            startAts[i] = s;
            endAts[i] = e;
        }
    }

    // =========================================================================
    // INTERNAL UTILITIES
    // =========================================================================

    function _pendingViews(bytes32[] memory reqids)
        internal
        view
        returns (IMarketViewer.PendingItemView[] memory items)
    {
        uint256 m = reqids.length;
        items = new IMarketViewer.PendingItemView[](m);
        for (uint256 i = 0; i < m; i++) {
            bytes32 reqid = reqids[i];
            (IBrevisMarket.ReqStatus status,,,,, uint64 deadline,,) = brevisMarket.getRequest(reqid);
            (address winner,,,) = brevisMarket.getBidders(reqid);
            items[i] = IMarketViewer.PendingItemView({
                reqid: reqid,
                deadline: deadline,
                status: status,
                winner: winner,
                isOverdue: (status == IBrevisMarket.ReqStatus.Pending && block.timestamp > deadline)
            });
        }
    }

    function _proverStatsComposite(address prover)
        internal
        view
        returns (IMarketViewer.ProverStatsComposite memory v)
    {
        (IBrevisMarket.ProverStats memory recent, uint64 startAt) = brevisMarket.getProverRecentStats(prover);
        IBrevisMarket.ProverStats memory total = brevisMarket.getProverStatsTotal(prover);
        uint64 fulfilled = total.requestsFulfilled;
        uint64 refunded = total.requestsRefunded;
        uint256 pendingCount256 = brevisMarket.getProverPendingRequests(prover).length;
        uint64 overdueCount64 = this.getProverOverdueCount(prover);
        uint256 denom = uint256(fulfilled) + uint256(refunded) + uint256(overdueCount64);
        uint64 rateWithOverdueBps = denom == 0 ? uint64(0) : uint64((uint256(fulfilled) * 10_000) / denom);
        v = IMarketViewer.ProverStatsComposite({
            total: total,
            recent: recent,
            recentStartAt: startAt,
            successRateBps: rateWithOverdueBps,
            fulfilled: fulfilled,
            refunded: refunded,
            pendingCount: uint64(pendingCount256),
            overdueCount: overdueCount64
        });
    }
}
