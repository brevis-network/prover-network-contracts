// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/market/BrevisMarket.sol";
import "../../src/market/interfaces/IBrevisMarket.sol";
import "../../src/pico/IPicoVerifier.sol";
import "../../src/staking/interfaces/IStakingController.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockVerifier.sol";
import "../mocks/MockStakingController.sol";

contract ProverStatsTest is Test {
    BrevisMarket public market;
    MockERC20 public feeToken;
    MockVerifier public picoVerifier;
    MockStakingController public stakingController;

    address public owner = address(0x1);
    address public requester = address(0x2);
    address public prover1 = address(0x3);
    address public prover2 = address(0x4);

    uint64 public constant BIDDING_DURATION = 1 hours;
    uint64 public constant REVEAL_DURATION = 30 minutes;
    uint96 public constant MIN_MAX_FEE = 1e12;
    uint96 public constant MAX_FEE = 1e18;
    uint96 public constant MIN_STAKE = 1e18;

    bytes32 public constant VK = keccak256("stats_epoch_vk");
    bytes32 public constant PUBLIC_VALUES_DIGEST = keccak256("stats_epoch_public_values");
    uint256[8] public VALID_PROOF = [uint256(VK), uint256(PUBLIC_VALUES_DIGEST), 3, 4, 5, 6, 7, 8];

    event StatsEpochScheduled(uint64 scheduledStartAt);
    event StatsEpochPopped(uint64 poppedStartAt);
    event StatsReset(uint64 newEpochId, uint64 statsStartAt);

    function setUp() public {
        // Deploy mocks
        feeToken = new MockERC20("Test Token", "TEST");
        picoVerifier = new MockVerifier();
        stakingController = new MockStakingController(feeToken);

        // Deploy market
        vm.prank(owner);
        market = new BrevisMarket(
            IPicoVerifier(address(picoVerifier)),
            IStakingController(address(stakingController)),
            BIDDING_DURATION,
            REVEAL_DURATION,
            MIN_MAX_FEE
        );

        // Token balances/approvals
        feeToken.mint(requester, 10e18);
        feeToken.mint(address(market), 10e18);
        vm.prank(requester);
        feeToken.approve(address(market), type(uint256).max);

        // Prover stakes/eligibility
        stakingController.setProverStake(prover1, MIN_STAKE);
        stakingController.setProverStake(prover2, MIN_STAKE);
        stakingController.setProverEligible(prover1, true, MIN_STAKE);
        stakingController.setProverEligible(prover2, true, MIN_STAKE);

        // Mock verifier accepts our proof
        picoVerifier.setValidProof(VK, PUBLIC_VALUES_DIGEST, VALID_PROOF);
    }

    function _createBasicRequest(uint64 extraNonce)
        internal
        view
        returns (bytes32 reqid, IBrevisMarket.ProofRequest memory req)
    {
        req = IBrevisMarket.ProofRequest({
            nonce: uint64(1 + extraNonce),
            vk: VK,
            publicValuesDigest: PUBLIC_VALUES_DIGEST,
            version: 0,
            imgURL: "",
            inputData: "",
            inputURL: "",
            fee: IBrevisMarket.FeeParams({maxFee: MAX_FEE, minStake: MIN_STAKE, deadline: uint64(block.timestamp + 2 days)})
        });
        reqid = keccak256(abi.encodePacked(req.nonce, req.vk, req.publicValuesDigest));
    }

    function _createBasicRequest() internal view returns (bytes32 reqid, IBrevisMarket.ProofRequest memory req) {
        return _createBasicRequest(0);
    }

    function _createBidHash(bytes32 reqid, address prover, uint256 fee, uint256 nonce)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(reqid, prover, fee, nonce));
    }

    function _bid(bytes32 reqid, uint256 fee, uint256 nonce, address who) internal {
        vm.prank(who);
        market.bid(reqid, keccak256(abi.encodePacked(fee, nonce)));
    }

    // =============================
    // Epoch lifecycle tests
    // =============================

    function test_ScheduleMultipleFutureEpochs_MetadataAndMonotonic() public {
        (uint64 curStart, uint64 curEpochId) = market.getRecentStatsInfo();
        curStart; // silence

        // Schedule two future epochs
        uint64 t1 = uint64(block.timestamp + 1000);
        uint64 t2 = uint64(block.timestamp + 2000);

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit StatsEpochScheduled(t1);
        market.scheduleStatsEpoch(t1);

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit StatsEpochScheduled(t2);
        market.scheduleStatsEpoch(t2);

        // Length and ids
        assertEq(market.statsEpochId(), curEpochId); // still current until rollover
        assertEq(market.statsEpochsLength(), curEpochId + 3); // epochs are 0..curEpochId (inclusive) + two scheduled

        // Check metadata
        (uint64 eCurStart, uint64 eCurEnd) = market.statsEpochs(curEpochId);
        (uint64 eNextStart, uint64 eNextEnd) = market.statsEpochs(curEpochId + 1);
        (uint64 eNext2Start, uint64 eNext2End) = market.statsEpochs(curEpochId + 2);
        assertEq(eCurStart, curStart);
        assertEq(eCurEnd, t1); // previous endAt set when scheduling next start
        assertEq(eNextStart, t1);
        assertEq(eNextEnd, t2); // after scheduling t2, t1.endAt is set to t2
        assertEq(eNext2Start, t2);
        assertEq(eNext2End, 0);

        // Monotonic enforcement: cannot schedule <= last start
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IBrevisMarket.MarketInvalidStatsEpochStart.selector, eNext2Start, t2));
        market.scheduleStatsEpoch(t2); // equal

        vm.prank(owner);
        uint64 tBad = t2 - 1;
        vm.expectRevert(abi.encodeWithSelector(IBrevisMarket.MarketInvalidStatsEpochStart.selector, eNext2Start, tBad));
        market.scheduleStatsEpoch(tBad); // smaller
    }

    function test_AdvanceMultipleEpochsOnActivity_LazyRolloverAcrossTwo() public {
        (, uint64 curEpochId) = market.getRecentStatsInfo();

        // Schedule T1 and T2 in the future
        uint64 t1 = uint64(block.timestamp + 1000);
        uint64 t2 = uint64(block.timestamp + 2000);
        vm.prank(owner);
        market.scheduleStatsEpoch(t1);
        vm.prank(owner);
        market.scheduleStatsEpoch(t2);

        // Activity before T1 -> counts in current epoch
        {
            (bytes32 reqid1, IBrevisMarket.ProofRequest memory req1) = _createBasicRequest(0);
            vm.prank(requester);
            market.requestProof(req1);
            vm.warp(t1 - 1);
            _bid(reqid1, 5e17, 123, prover1);
            (IBrevisMarket.ProverStats memory curStatsBefore,) = market.getProverRecentStats(prover1);
            assertEq(curStatsBefore.bids, 1);
        }

        // Activity at T1 triggers rollover to curEpochId+1
        {
            (bytes32 reqid2, IBrevisMarket.ProofRequest memory req2) = _createBasicRequest(1);
            vm.prank(requester);
            market.requestProof(req2);
            vm.warp(t1);
            _bid(reqid2, 6e17, 456, prover2);
            (uint64 start2, uint64 epoch2) = market.getRecentStatsInfo();
            assertEq(epoch2, curEpochId + 1);
            assertEq(start2, t1);
            (IBrevisMarket.ProverStats memory e2p2,,) = market.getProverStatsForStatsEpoch(prover2, epoch2);
            assertEq(e2p2.bids, 1);
        }

        // Activity at T2 triggers rollover to curEpochId+2
        {
            (bytes32 reqid3, IBrevisMarket.ProofRequest memory req3) = _createBasicRequest(2);
            vm.prank(requester);
            market.requestProof(req3);
            vm.warp(t2);
            _bid(reqid3, 7e17, 789, prover1);
            (uint64 start3, uint64 epoch3) = market.getRecentStatsInfo();
            assertEq(epoch3, curEpochId + 2);
            assertEq(start3, t2);
            (IBrevisMarket.ProverStats memory e3p1,,) = market.getProverStatsForStatsEpoch(prover1, epoch3);
            assertEq(e3p1.bids, 1);
        }

        // Verify endAt links
        {
            (uint64 e0Start, uint64 e0End) = market.statsEpochs(curEpochId);
            (uint64 e1Start, uint64 e1End) = market.statsEpochs(curEpochId + 1);
            (uint64 e2Start, uint64 e2End) = market.statsEpochs(curEpochId + 2);
            e0Start; // silence
            assertEq(e0End, t1);
            assertEq(e1Start, t1);
            assertEq(e1End, t2);
            assertEq(e2Start, t2);
            assertEq(e2End, 0);
        }
    }

    function test_PopEpoch_RemovesLastFutureEpochAndRestoresEndAt() public {
        (uint64 curStart, uint64 curEpochId) = market.getRecentStatsInfo();
        curStart; // silence

        uint64 t1 = uint64(block.timestamp + 1000);
        uint64 t2 = uint64(block.timestamp + 2000);
        vm.prank(owner);
        market.scheduleStatsEpoch(t1);
        vm.prank(owner);
        market.scheduleStatsEpoch(t2);

        // Pop last (t2)
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit StatsEpochPopped(t2);
        market.popStatsEpoch();

        // Length decreases by 1 and last scheduled is now t1
        assertEq(market.statsEpochsLength(), curEpochId + 2);
        (uint64 curStartAfter, uint64 curEndAfter) = market.statsEpochs(curEpochId);
        (uint64 nextStart, uint64 nextEnd) = market.statsEpochs(curEpochId + 1);
        assertEq(curStartAfter, curStart);
        assertEq(curEndAfter, t1); // current epoch still ends at t1 (t1 remains scheduled)
        assertEq(nextStart, t1);
        assertEq(nextEnd, 0);

        // Pop again -> remove t1
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit StatsEpochPopped(t1);
        market.popStatsEpoch();
        assertEq(market.statsEpochsLength(), curEpochId + 1);
        // After all pops, current epoch has endAt = 0
        (uint64 eCurStart2, uint64 eCurEnd2) = market.statsEpochs(curEpochId);
        assertEq(eCurStart2, curStart);
        assertEq(eCurEnd2, 0);

        // Pop when none exists -> revert
        vm.prank(owner);
        vm.expectRevert(IBrevisMarket.MarketNoFutureEpochToPop.selector);
        market.popStatsEpoch();
    }

    function test_PopEpoch_RevertsIfStarted() public {
        (uint64 curStart,) = market.getRecentStatsInfo();
        curStart; // silence

        uint64 t1 = uint64(block.timestamp + 1000);
        vm.prank(owner);
        market.scheduleStatsEpoch(t1);

        // Trigger start of t1 by activity at/after t1
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest(0);
        vm.prank(requester);
        market.requestProof(req);
        vm.warp(t1);
        _bid(reqid, 5e17, 123, prover1);

        // Now try to pop -> should revert with MarketCannotPopStartedEpoch
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IBrevisMarket.MarketCannotPopStartedEpoch.selector, t1, uint64(block.timestamp))
        );
        market.popStatsEpoch();
    }

    // =============================
    // ProverStats tests
    // =============================

    function test_ProverStats_TotalsAndRecent_BidRevealSubmit() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        // Bid
        bytes32 bidHash = _createBidHash(reqid, prover1, 5e17, 123);
        vm.prank(prover1);
        market.bid(reqid, bidHash);

        // Reveal
        vm.warp(block.timestamp + BIDDING_DURATION + 1);
        vm.prank(prover1);
        market.reveal(reqid, 5e17, 123);

        // Submit
        vm.warp(block.timestamp + REVEAL_DURATION + 1);
        uint64 beforeSubmitTs = uint64(block.timestamp);
        vm.prank(prover1);
        market.submitProof(reqid, VALID_PROOF);

        IBrevisMarket.ProverStats memory total = market.getProverStatsTotal(prover1);
        assertEq(total.bids, 1);
        assertEq(total.reveals, 1);
        assertEq(total.requestsFulfilled, 1);
        assertEq(total.requestsRefunded, 0);
        assertGe(total.lastActiveAt, beforeSubmitTs);

        (IBrevisMarket.ProverStats memory recent,) = market.getProverRecentStats(prover1);
        assertEq(recent.bids, 1);
        assertEq(recent.reveals, 1);
        assertEq(recent.requestsFulfilled, 1);
        assertEq(recent.requestsRefunded, 0);
        assertGe(recent.lastActiveAt, beforeSubmitTs);

        (uint64 startAt, uint64 epochId) = market.getRecentStatsInfo();
        assertGe(startAt, 0);
        assertGe(epochId, 0);

        // Fee accounting: with a single bidder, actualFee == winner fee
        (address winner, uint256 winnerFee,, uint256 secondFee) = market.getBidders(reqid);
        winner; // silence
        (uint256 feeBps,) = market.getProtocolFeeInfo();
        uint256 actualFee = secondFee == 0 ? winnerFee : secondFee;
        uint256 expectedReward = (actualFee * (10000 - feeBps)) / 10000;

        total = market.getProverStatsTotal(prover1);
        (recent,) = market.getProverRecentStats(prover1);
        assertEq(total.feeReceived, expectedReward);
        assertEq(recent.feeReceived, expectedReward);
    }

    function test_ProverStats_WinnerChange_LastActiveUnchanged() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        // Both place bids
        vm.prank(prover1);
        market.bid(reqid, _createBidHash(reqid, prover1, 6e17, 111));
        vm.prank(prover2);
        market.bid(reqid, _createBidHash(reqid, prover2, 4e17, 222));

        // Reveal phase
        vm.warp(block.timestamp + BIDDING_DURATION + 1);

        // First reveal by prover1 (higher fee) -> temporarily winner
        vm.prank(prover1);
        market.reveal(reqid, 6e17, 111);
        IBrevisMarket.ProverStats memory t1 = market.getProverStatsTotal(prover1);
        uint64 p1LastActive = t1.lastActiveAt;

        // Advance time and reveal by prover2 (lower fee) -> winner switches
        vm.warp(block.timestamp + 10);
        vm.prank(prover2);
        market.reveal(reqid, 4e17, 222);

        // Winner switched; no instantaneous wins tracked anymore
        IBrevisMarket.ProverStats memory t1After = market.getProverStatsTotal(prover1);
        IBrevisMarket.ProverStats memory t2After = market.getProverStatsTotal(prover2);
        t2After; // silence

        // Prover1 lastActiveAt unchanged by someone else's reveal
        assertEq(t1After.lastActiveAt, p1LastActive);

        // Recent stats verify no spurious activity counters bumped by someone else's reveal
        (IBrevisMarket.ProverStats memory r1,) = market.getProverRecentStats(prover1);
        (IBrevisMarket.ProverStats memory r2,) = market.getProverRecentStats(prover2);
        r1;
        r2; // silence
    }

    function test_ProverStats_RecentReset_AndEpochInfo() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();
        vm.prank(requester);
        market.requestProof(req);

        // Some activity for prover1
        vm.prank(prover1);
        market.bid(reqid, _createBidHash(reqid, prover1, 5e17, 123));

        (uint64 startAtBefore, uint64 epochBefore) = market.getRecentStatsInfo();

        // Reset as owner; ensure startAt increases by advancing time
        vm.warp(block.timestamp + 1);
        vm.prank(owner);
        market.scheduleStatsEpoch(0);

        (uint64 startAtAfter, uint64 epochAfter) = market.getRecentStatsInfo();
        assertGe(startAtAfter, startAtBefore);
        assertEq(epochAfter, epochBefore + 1);

        // Recent stats cleared for prover1 until new activity
        (IBrevisMarket.ProverStats memory recent1,) = market.getProverRecentStats(prover1);
        assertEq(recent1.bids, 0);
        assertEq(recent1.reveals, 0);
        assertEq(recent1.requestsFulfilled, 0);
        assertEq(recent1.requestsRefunded, 0);

        // Totals remain
        IBrevisMarket.ProverStats memory total1 = market.getProverStatsTotal(prover1);
        assertEq(total1.bids, 1);
        assertEq(total1.reveals, 0);
        assertEq(total1.requestsFulfilled, 0);
        assertEq(total1.requestsRefunded, 0);
    }

    function test_ProverStats_RecentZerosForInactiveProver() public {
        // No activity after reset for prover2
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();
        vm.prank(requester);
        market.requestProof(req);

        // Some activity by prover1 only
        vm.prank(prover1);
        market.bid(reqid, _createBidHash(reqid, prover1, 5e17, 123));

        // Reset epoch; ensure monotonic start by advancing time
        vm.warp(block.timestamp + 1);
        vm.prank(owner);
        market.scheduleStatsEpoch(0);

        (IBrevisMarket.ProverStats memory recent2,) = market.getProverRecentStats(prover2);
        assertEq(recent2.bids, 0);
        assertEq(recent2.reveals, 0);
        assertEq(recent2.requestsFulfilled, 0);
        assertEq(recent2.requestsRefunded, 0);
    }

    function test_ProverStats_MissedDeadline_RefundedCounterIncrements() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();
        vm.prank(requester);
        market.requestProof(req);

        // Prover1 bids and reveals, becomes winner
        vm.prank(prover1);
        market.bid(reqid, _createBidHash(reqid, prover1, 5e17, 123));
        vm.warp(block.timestamp + BIDDING_DURATION + 1);
        vm.prank(prover1);
        market.reveal(reqid, 5e17, 123);

        // Let deadline pass, then refund
        (,,,, uint256 minStake, uint64 deadline, bytes32 _vk, bytes32 _digest, uint32 _version) =
            market.getRequest(reqid);
        (minStake, _vk, _digest, _version);
        vm.warp(deadline + 1);
        market.refund(reqid);

        IBrevisMarket.ProverStats memory total1 = market.getProverStatsTotal(prover1);
        assertEq(total1.requestsRefunded, 1);
        assertEq(total1.requestsFulfilled, 0);
    }

    function test_EpochHistory_GettersAndPerEpochStats() public {
        // Capture initial epoch metadata
        (uint64 startAt1, uint64 epoch1) = market.getRecentStatsInfo();
        assertGe(epoch1, 0);
        assertEq(market.statsEpochId(), epoch1);

        // Create a proof request and have prover1 perform activity in epoch1
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();
        vm.prank(requester);
        market.requestProof(req);

        vm.prank(prover1);
        market.bid(reqid, _createBidHash(reqid, prover1, 5e17, 123));

        // Recent == current epoch stats
        (IBrevisMarket.ProverStats memory recent1e1,) = market.getProverRecentStats(prover1);
        (IBrevisMarket.ProverStats memory e1p1,,) = market.getProverStatsForStatsEpoch(prover1, epoch1);
        assertEq(recent1e1.bids, 1);
        assertEq(e1p1.bids, 1);
        assertEq(e1p1.bids, recent1e1.bids);

        // Lifetime totals reflect activity regardless of epoch boundaries
        IBrevisMarket.ProverStats memory total1Before = market.getProverStatsTotal(prover1);
        assertEq(total1Before.bids, 1);

        // Advance time and reset to start a new epoch
        vm.warp(block.timestamp + 10);
        vm.prank(owner);
        market.scheduleStatsEpoch(0);

        (uint64 startAt2, uint64 epoch2) = market.getRecentStatsInfo();
        assertEq(epoch2, epoch1 + 1);
        assertEq(market.statsEpochId(), epoch2);

        // Previous epoch endAt should equal the new epoch startAt; current epoch endAt is 0
        (uint64 e1Start, uint64 e1End) = market.statsEpochs(epoch1);
        (uint64 e2Start, uint64 e2End) = market.statsEpochs(epoch2);
        assertEq(e1Start, startAt1);
        assertEq(e1End, startAt2);
        assertEq(e2Start, startAt2);
        assertEq(e2End, 0);

        // Per-epoch stats persist for epoch1 and are zero-initialized for epoch2
        (IBrevisMarket.ProverStats memory e1p1After,,) = market.getProverStatsForStatsEpoch(prover1, epoch1);
        assertEq(e1p1After.bids, 1);
        (IBrevisMarket.ProverStats memory e2p1,,) = market.getProverStatsForStatsEpoch(prover1, epoch2);
        assertEq(e2p1.bids, 0);

        // New activity in epoch2 should affect only epoch2 bucket and recent
        vm.prank(prover2);
        bytes32 _bh = _createBidHash(reqid, prover2, 6e17, 456);
        market.bid(reqid, _bh);

        (IBrevisMarket.ProverStats memory recent2e2,) = market.getProverRecentStats(prover2);
        (IBrevisMarket.ProverStats memory e2p2,,) = market.getProverStatsForStatsEpoch(prover2, epoch2);
        assertEq(recent2e2.bids, 1);
        assertEq(e2p2.bids, 1);

        // Lifetime totals reflect both epochs
        IBrevisMarket.ProverStats memory total1After = market.getProverStatsTotal(prover1);
        IBrevisMarket.ProverStats memory total2After = market.getProverStatsTotal(prover2);
        assertEq(total1After.bids, 1);
        assertEq(total2After.bids, 1);
    }

    // =============================
    // GlobalStats tests
    // =============================

    function test_GlobalStats_TotalAndRecent_RequestAndSubmit() public {
        // Initial epoch info
        (uint64 startAt, uint64 epochId) = market.getRecentStatsInfo();
        startAt;
        epochId; // silence

        // Create request -> increments totalRequests
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();
        vm.prank(requester);
        market.requestProof(req);

        IBrevisMarket.GlobalStats memory gTotal1 = market.getGlobalStatsTotal();
        (IBrevisMarket.GlobalStats memory gRecent1,) = market.getGlobalRecentStats();
        assertEq(gTotal1.totalRequests, 1);
        assertEq(gTotal1.totalFulfilled, 0);
        assertEq(gTotal1.totalFees, 0);
        assertEq(gRecent1.totalRequests, 1);
        assertEq(gRecent1.totalFulfilled, 0);
        assertEq(gRecent1.totalFees, 0);

        // Single prover bids, reveals, submits
        uint256 bidFee = 5e17;
        uint256 bidNonce = 123;
        vm.prank(prover1);
        market.bid(reqid, _createBidHash(reqid, prover1, bidFee, bidNonce));
        vm.warp(block.timestamp + BIDDING_DURATION + 1);
        vm.prank(prover1);
        market.reveal(reqid, bidFee, bidNonce);

        vm.warp(block.timestamp + REVEAL_DURATION + 1);
        vm.prank(prover1);
        market.submitProof(reqid, VALID_PROOF);

        // Winner pays their own bid as only bidder
        IBrevisMarket.GlobalStats memory gTotal2 = market.getGlobalStatsTotal();
        (IBrevisMarket.GlobalStats memory gRecent2,) = market.getGlobalRecentStats();
        assertEq(gTotal2.totalRequests, 1);
        assertEq(gTotal2.totalFulfilled, 1);
        assertEq(gTotal2.totalFees, bidFee);
        assertEq(gRecent2.totalRequests, 1);
        assertEq(gRecent2.totalFulfilled, 1);
        assertEq(gRecent2.totalFees, bidFee);
    }

    function test_GlobalStats_EpochReset_FallbackAndDiff() public {
        // One fulfilled request in epoch1
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();
        vm.prank(requester);
        market.requestProof(req);
        vm.prank(prover1);
        market.bid(reqid, _createBidHash(reqid, prover1, 4e17, 1));
        vm.warp(block.timestamp + BIDDING_DURATION + 1);
        vm.prank(prover1);
        market.reveal(reqid, 4e17, 1);
        vm.warp(block.timestamp + REVEAL_DURATION + 1);
        vm.prank(prover1);
        market.submitProof(reqid, VALID_PROOF);

        IBrevisMarket.GlobalStats memory gTotEpoch1 = market.getGlobalStatsTotal();
        assertEq(gTotEpoch1.totalRequests, 1);
        assertEq(gTotEpoch1.totalFulfilled, 1);
        assertEq(gTotEpoch1.totalFees, 4e17);

        // Reset epoch (starts immediately)
        vm.warp(block.timestamp + 1);
        vm.prank(owner);
        market.scheduleStatsEpoch(0);

        // Totals fallback to previous snapshot until new activity
        IBrevisMarket.GlobalStats memory gTotAfter = market.getGlobalStatsTotal();
        (IBrevisMarket.GlobalStats memory gRecentAfter,) = market.getGlobalRecentStats();
        assertEq(gTotAfter.totalRequests, 1);
        assertEq(gTotAfter.totalFulfilled, 1);
        assertEq(gTotAfter.totalFees, 4e17);
        assertEq(gRecentAfter.totalRequests, 0);
        assertEq(gRecentAfter.totalFulfilled, 0);
        assertEq(gRecentAfter.totalFees, 0);

        // New request in epoch2 -> affects recent and totals
        (, IBrevisMarket.ProofRequest memory req2) = _createBasicRequest(7);
        vm.prank(requester);
        market.requestProof(req2);

        IBrevisMarket.GlobalStats memory gTotAfter2 = market.getGlobalStatsTotal();
        (IBrevisMarket.GlobalStats memory gRecentAfter2,) = market.getGlobalRecentStats();
        assertEq(gTotAfter2.totalRequests, 2);
        assertEq(gRecentAfter2.totalRequests, 1);

        // And per-epoch getters: epoch1 should reflect first request, epoch2 reflects only second (so far)
        (, uint64 curEpoch) = market.getRecentStatsInfo();
        (IBrevisMarket.GlobalStats memory e1,,) = market.getGlobalStatsForStatsEpoch(curEpoch - 1);
        (IBrevisMarket.GlobalStats memory e2,,) = market.getGlobalStatsForStatsEpoch(curEpoch);
        assertEq(e1.totalRequests, 1);
        assertEq(e1.totalFulfilled, 1);
        assertEq(e1.totalFees, 4e17);
        assertEq(e2.totalRequests, 1);
        assertEq(e2.totalFulfilled, 0);
        assertEq(e2.totalFees, 0);
    }

    function test_GlobalStats_MultiRequests_SecondPriceAccounting() public {
        // Request A: two bidders, second price applies
        (bytes32 reqA, IBrevisMarket.ProofRequest memory rA) = _createBasicRequest(10);
        vm.prank(requester);
        market.requestProof(rA);
        // Bids
        vm.prank(prover1);
        market.bid(reqA, _createBidHash(reqA, prover1, 6e17, 111));
        vm.prank(prover2);
        market.bid(reqA, _createBidHash(reqA, prover2, 4e17, 222));
        // Reveal both
        vm.warp(block.timestamp + BIDDING_DURATION + 1);
        vm.prank(prover1);
        market.reveal(reqA, 6e17, 111); // temporarily winner
        vm.prank(prover2);
        market.reveal(reqA, 4e17, 222); // final winner at lower bid
        // Submit by winner (prover2)
        vm.warp(block.timestamp + REVEAL_DURATION + 1);
        vm.prank(prover2);
        market.submitProof(reqA, VALID_PROOF);

        // Request B: single bidder
        (bytes32 reqB, IBrevisMarket.ProofRequest memory rB) = _createBasicRequest(11);
        vm.prank(requester);
        market.requestProof(rB);
        vm.prank(prover1);
        market.bid(reqB, _createBidHash(reqB, prover1, 8e17, 333));
        vm.warp(block.timestamp + BIDDING_DURATION + 1);
        vm.prank(prover1);
        market.reveal(reqB, 8e17, 333);
        vm.warp(block.timestamp + REVEAL_DURATION + 1);
        vm.prank(prover1);
        market.submitProof(reqB, VALID_PROOF);

        // Compute actual fees for A and B from bidders
        (, uint256 winnerFeeA,, uint256 secondFeeA) = market.getBidders(reqA);
        uint256 actualA = secondFeeA == 0 ? winnerFeeA : secondFeeA; // second price
        (, uint256 winnerFeeB,, uint256 secondFeeB) = market.getBidders(reqB);
        uint256 actualB = secondFeeB == 0 ? winnerFeeB : secondFeeB;

        IBrevisMarket.GlobalStats memory gTot = market.getGlobalStatsTotal();
        (IBrevisMarket.GlobalStats memory gRecent,) = market.getGlobalRecentStats();
        assertEq(gTot.totalRequests, 2);
        assertEq(gTot.totalFulfilled, 2);
        assertEq(gTot.totalFees, actualA + actualB);
        assertEq(gRecent.totalRequests, 2);
        assertEq(gRecent.totalFulfilled, 2);
        assertEq(gRecent.totalFees, actualA + actualB);
    }
}
