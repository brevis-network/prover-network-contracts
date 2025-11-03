// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IBrevisMarket.sol";
import "./interfaces/IMarketViewer.sol";

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

    function getProverPendingCount(address prover) external view returns (uint256 count) {
        bytes32[] memory all = brevisMarket.getProverPendingRequests(prover);
        return all.length;
    }

    function getSenderPendingCount(address sender) external view returns (uint256 count) {
        bytes32[] memory all = brevisMarket.getSenderPendingRequests(sender);
        return all.length;
    }

    function getProverPendingSlice(address prover, uint256 offset, uint256 limit)
        external
        view
        returns (IMarketViewer.PendingItemView[] memory items, uint256 total)
    {
        bytes32[] memory all = brevisMarket.getProverPendingRequests(prover);
        total = all.length;
        (uint256 start, uint256 end) = _sliceBounds(total, offset, limit);
        uint256 m = end - start;
        items = new IMarketViewer.PendingItemView[](m);
        for (uint256 i = 0; i < m; i++) {
            bytes32 reqid = all[start + i];
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

    function getSenderPendingSlice(address sender, uint256 offset, uint256 limit)
        external
        view
        returns (IMarketViewer.PendingItemView[] memory items, uint256 total)
    {
        bytes32[] memory all = brevisMarket.getSenderPendingRequests(sender);
        total = all.length;
        (uint256 start, uint256 end) = _sliceBounds(total, offset, limit);
        uint256 m = end - start;
        items = new IMarketViewer.PendingItemView[](m);
        for (uint256 i = 0; i < m; i++) {
            bytes32 reqid = all[start + i];
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

    function getProverOverdueCount(address prover) external view returns (uint256 overdue) {
        bytes32[] memory all = brevisMarket.getProverPendingRequests(prover);
        for (uint256 i = 0; i < all.length; i++) {
            (,,,,, uint64 deadline,,) = brevisMarket.getRequest(all[i]);
            // Items in proverPendingRequests are Pending by construction; still check deadline
            if (block.timestamp > deadline) overdue++;
        }
    }

    function getSenderOverdueCount(address sender) external view returns (uint256 overdue) {
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
        (IBrevisMarket.ProverStats memory recent, uint64 startAt) = brevisMarket.getProverRecentStats(prover);
        IBrevisMarket.ProverStats memory total = brevisMarket.getProverStatsTotal(prover);
        uint64 fulfilled = total.requestsFulfilled;
        uint64 refunded = total.requestsRefunded;
        uint256 pendingCount = brevisMarket.getProverPendingRequests(prover).length;
        uint256 overdueCount = this.getProverOverdueCount(prover);
        uint256 denom = uint256(fulfilled) + uint256(refunded) + overdueCount;
        uint256 rateWithOverdueBps = denom == 0 ? 0 : (uint256(fulfilled) * 10_000) / denom;
        v = IMarketViewer.ProverStatsComposite({
            total: total,
            recent: recent,
            recentStartAt: startAt,
            successRateBps: rateWithOverdueBps,
            fulfilled: fulfilled,
            refunded: refunded,
            pendingCount: pendingCount,
            overdueCount: overdueCount
        });
    }

    function getGlobalStatsComposite() external view returns (IMarketViewer.GlobalStatsComposite memory v) {
        (IBrevisMarket.GlobalStats memory recent, uint64 startAt) = brevisMarket.getGlobalRecentStats();
        IBrevisMarket.GlobalStats memory total = brevisMarket.getGlobalStatsTotal();
        v = IMarketViewer.GlobalStatsComposite({total: total, recent: recent, recentStartAt: startAt});
    }

    // =========================================================================
    // EPOCHS HELPERS
    // =========================================================================

    function getStatsEpochsSlice(uint256 offset, uint256 limit)
        external
        view
        returns (uint64[] memory startAts, uint64[] memory endAts, uint256 total)
    {
        uint256 len = brevisMarket.statsEpochsLength();
        total = len;
        (uint256 start, uint256 end) = _sliceBounds(len, offset, limit);
        uint256 m = end - start;
        startAts = new uint64[](m);
        endAts = new uint64[](m);
        for (uint256 i = 0; i < m; i++) {
            (uint64 s, uint64 e) = brevisMarket.statsEpochs(start + i);
            startAts[i] = s;
            endAts[i] = e;
        }
    }

    // =========================================================================
    // INTERNAL UTILITIES
    // =========================================================================

    function _sliceBounds(uint256 total, uint256 offset, uint256 limit)
        internal
        pure
        returns (uint256 start, uint256 end)
    {
        if (offset > total) {
            return (total, total);
        }
        start = offset;
        end = limit == 0 ? total : (offset + limit > total ? total : offset + limit);
    }
}
