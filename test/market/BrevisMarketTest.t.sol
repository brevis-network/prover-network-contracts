// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/market/BrevisMarket.sol";
import "../../src/market/IBrevisMarket.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockVerifier.sol";
import "../mocks/MockStakingController.sol";
import "../utils/TestErrors.sol";

contract BrevisMarketTest is Test {
    BrevisMarket public market;
    MockERC20 public feeToken;
    MockVerifier public picoVerifier;
    MockStakingController public stakingController;

    address public owner = address(0x1);
    address public requester = address(0x2);
    address public prover1 = address(0x3);
    address public prover2 = address(0x4);
    address public prover3 = address(0x5);
    address public user1 = address(0x6);

    uint64 public constant BIDDING_DURATION = 1 hours;
    uint64 public constant REVEAL_DURATION = 30 minutes;
    uint256 public constant MIN_MAX_FEE = 1e12;
    uint256 public constant MAX_FEE = 1e18;
    uint256 public constant MIN_STAKE = 1e18;

    bytes32 public constant VK = keccak256("test_vk");
    bytes32 public constant PUBLIC_VALUES_DIGEST = keccak256("test_public_values");
    // For MockVerifier: proof[0] = VK, proof[1] = PUBLIC_VALUES_DIGEST
    uint256[8] public VALID_PROOF = [uint256(VK), uint256(PUBLIC_VALUES_DIGEST), 3, 4, 5, 6, 7, 8];

    event NewRequest(bytes32 indexed reqid, IBrevisMarket.ProofRequest req);
    event NewBid(bytes32 indexed reqid, address indexed prover, bytes32 bidHash);
    event BidRevealed(bytes32 indexed reqid, address indexed prover, uint256 fee);
    event ProofSubmitted(bytes32 indexed reqid, address indexed prover, uint256[8] proof, uint256 actualFee);
    event Refunded(bytes32 indexed reqid, address indexed requester, uint256 amount);

    function setUp() public {
        // Deploy mock contracts
        feeToken = new MockERC20("Test Token", "TEST");
        picoVerifier = new MockVerifier();
        stakingController = new MockStakingController(feeToken);

        // Deploy BrevisMarket
        vm.prank(owner);
        market = new BrevisMarket(
            IPicoVerifier(address(picoVerifier)),
            IStakingController(address(stakingController)),
            BIDDING_DURATION,
            REVEAL_DURATION,
            MIN_MAX_FEE
        );

        // Setup token balances
        feeToken.mint(requester, 10e18);
        feeToken.mint(address(market), 10e18); // For refunds

        // Setup prover stakes and eligibility
        stakingController.setProverStake(prover1, MIN_STAKE);
        stakingController.setProverStake(prover2, MIN_STAKE);
        stakingController.setProverStake(prover3, MIN_STAKE / 2); // Insufficient stake

        // Set prover eligibility (required for new MockStakingController)
        stakingController.setProverEligible(prover1, true, MIN_STAKE);
        stakingController.setProverEligible(prover2, true, MIN_STAKE);
        stakingController.setProverEligible(prover3, false, MIN_STAKE / 2); // Make prover3 ineligible due to insufficient stake

        // Configure mock verifier to accept our test proof
        picoVerifier.setValidProof(VK, PUBLIC_VALUES_DIGEST, VALID_PROOF);

        // Approve tokens
        vm.prank(requester);
        feeToken.approve(address(market), type(uint256).max);
    }

    function _createBasicRequest() internal view returns (bytes32 reqid, IBrevisMarket.ProofRequest memory req) {
        req = IBrevisMarket.ProofRequest({
            nonce: 1,
            vk: VK,
            publicValuesDigest: PUBLIC_VALUES_DIGEST,
            imgURL: "",
            inputData: "",
            inputURL: "",
            fee: IBrevisMarket.FeeParams({maxFee: MAX_FEE, minStake: MIN_STAKE, deadline: uint64(block.timestamp + 2 days)})
        });
        reqid = keccak256(abi.encodePacked(req.nonce, req.vk, req.publicValuesDigest));
    }

    function _createBidHash(uint256 fee, uint256 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(fee, nonce));
    }

    function test_RequestProof_Success() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.expectEmit(true, false, false, true);
        emit NewRequest(reqid, req);

        vm.prank(requester);
        market.requestProof(req);

        // Verify request was stored correctly
        (
            IBrevisMarket.ReqStatus status,
            uint64 timestamp,
            address sender,
            uint256 maxFee,
            uint256 minStake,
            uint64 deadline,
            bytes32 vk,
            bytes32 publicValuesDigest
        ) = market.getRequest(reqid);

        assertEq(uint256(status), uint256(IBrevisMarket.ReqStatus.Pending));
        assertEq(timestamp, block.timestamp);
        assertEq(sender, requester);
        assertEq(maxFee, MAX_FEE);
        assertEq(minStake, MIN_STAKE);
        assertEq(deadline, req.fee.deadline);
        assertEq(vk, VK);
        assertEq(publicValuesDigest, PUBLIC_VALUES_DIGEST);
    }

    function test_RequestProof_RevertDeadlineInPast() public {
        (, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();
        req.fee.deadline = uint64(block.timestamp - 1);

        vm.prank(requester);
        vm.expectRevert(IBrevisMarket.MarketDeadlineMustBeInFuture.selector);
        market.requestProof(req);
    }

    function test_RequestProof_RevertDeadlineTooFar() public {
        (, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();
        req.fee.deadline = uint64(block.timestamp + 31 days);

        vm.prank(requester);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBrevisMarket.MarketDeadlineTooFar.selector,
                req.fee.deadline,
                block.timestamp + market.MAX_DEADLINE_DURATION()
            )
        );
        market.requestProof(req);
    }

    function test_RequestProof_RevertMinFeeTooLow() public {
        (, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();
        req.fee.maxFee = MIN_MAX_FEE - 1;

        vm.prank(requester);
        vm.expectRevert(abi.encodeWithSelector(IBrevisMarket.MarketMaxFeeTooLow.selector, req.fee.maxFee, MIN_MAX_FEE));
        market.requestProof(req);
    }

    function test_RequestProof_RevertDeadlineBeforeRevealEnd() public {
        (, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();
        req.fee.deadline = uint64(block.timestamp + BIDDING_DURATION + REVEAL_DURATION - 1);

        vm.prank(requester);
        vm.expectRevert(IBrevisMarket.MarketDeadlineBeforeRevealPhaseEnd.selector);
        market.requestProof(req);
    }

    function test_Bid_Success() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        bytes32 bidHash = _createBidHash(5e17, 123);

        vm.expectEmit(true, true, false, true);
        emit NewBid(reqid, prover1, bidHash);

        vm.prank(prover1);
        market.bid(reqid, bidHash);

        // Verify bid was stored
        assertEq(market.getBidHash(reqid, prover1), bidHash);
    }

    function test_Bid_RevertRequestNotFound() public {
        bytes32 nonexistentReqid = keccak256("nonexistent");
        bytes32 bidHash = _createBidHash(5e17, 123);

        vm.prank(prover1);
        vm.expectRevert(abi.encodeWithSelector(IBrevisMarket.MarketRequestNotFound.selector, nonexistentReqid));
        market.bid(nonexistentReqid, bidHash);
    }

    function test_Bid_RevertBiddingPhaseEnded() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        // Fast forward past bidding phase
        vm.warp(block.timestamp + BIDDING_DURATION + 1);

        bytes32 bidHash = _createBidHash(5e17, 123);
        uint256 biddingEndTime = block.timestamp - 1; // Should be the actual end time

        vm.prank(prover1);
        vm.expectRevert(
            abi.encodeWithSelector(IBrevisMarket.MarketBiddingPhaseEnded.selector, block.timestamp, biddingEndTime)
        );
        market.bid(reqid, bidHash);
    }

    function test_Bid_RevertProverNotEligible() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        bytes32 bidHash = _createBidHash(5e17, 123);

        vm.prank(prover3); // Has insufficient stake
        vm.expectRevert(
            abi.encodeWithSelector(IBrevisMarket.MarketProverNotEligible.selector, prover3, MIN_STAKE, MIN_STAKE / 2)
        );
        market.bid(reqid, bidHash);
    }

    function test_Reveal_Success() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        uint256 fee = 5e17;
        uint256 nonce = 123;
        bytes32 bidHash = _createBidHash(fee, nonce);

        // Place bid
        vm.prank(prover1);
        market.bid(reqid, bidHash);

        // Fast forward to reveal phase
        vm.warp(block.timestamp + BIDDING_DURATION + 1);

        vm.expectEmit(true, true, false, true);
        emit BidRevealed(reqid, prover1, fee);

        vm.prank(prover1);
        market.reveal(reqid, fee, nonce);

        // Verify bidder was recorded as winner
        (address winner, uint256 winnerFee, address secondPlace, uint256 secondFee) = market.getBidders(reqid);
        assertEq(winner, prover1);
        assertEq(winnerFee, fee);
        assertEq(secondPlace, address(0));
        assertEq(secondFee, 0);
    }

    function test_Reveal_RevertBidRevealMismatch() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        uint256 fee = 5e17;
        uint256 nonce = 123;
        bytes32 bidHash = _createBidHash(fee, nonce);

        // Place bid
        vm.prank(prover1);
        market.bid(reqid, bidHash);

        // Fast forward to reveal phase
        vm.warp(block.timestamp + BIDDING_DURATION + 1);

        uint256 wrongFee = 6e17;
        bytes32 expectedHash = _createBidHash(wrongFee, nonce);

        vm.prank(prover1);
        vm.expectRevert(abi.encodeWithSelector(IBrevisMarket.MarketBidRevealMismatch.selector, expectedHash, bidHash));
        market.reveal(reqid, wrongFee, nonce);
    }

    function test_Reveal_RevertFeeExceedsMaximum() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        uint256 excessiveFee = MAX_FEE + 1;
        uint256 nonce = 123;
        bytes32 bidHash = _createBidHash(excessiveFee, nonce);

        // Place bid
        vm.prank(prover1);
        market.bid(reqid, bidHash);

        // Fast forward to reveal phase
        vm.warp(block.timestamp + BIDDING_DURATION + 1);

        vm.prank(prover1);
        vm.expectRevert(abi.encodeWithSelector(IBrevisMarket.MarketFeeExceedsMaximum.selector, excessiveFee, MAX_FEE));
        market.reveal(reqid, excessiveFee, nonce);
    }

    function test_FullAuctionFlow_SingleBidder() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        uint256 fee = 5e17;
        uint256 nonce = 123;
        bytes32 bidHash = _createBidHash(fee, nonce);

        // Place bid
        vm.prank(prover1);
        market.bid(reqid, bidHash);

        // Fast forward to reveal phase and reveal
        vm.warp(block.timestamp + BIDDING_DURATION + 1);
        vm.prank(prover1);
        market.reveal(reqid, fee, nonce);

        // Fast forward to proof submission phase
        vm.warp(block.timestamp + REVEAL_DURATION + 1);

        // In single bidder case, winner pays their own bid
        vm.expectEmit(true, true, false, true);
        emit ProofSubmitted(reqid, prover1, VALID_PROOF, fee);

        vm.prank(prover1);
        market.submitProof(reqid, VALID_PROOF);

        // Verify request is fulfilled
        (IBrevisMarket.ReqStatus status,,,,,,,) = market.getRequest(reqid);
        assertEq(uint256(status), uint256(IBrevisMarket.ReqStatus.Fulfilled));

        // Verify proof was stored
        uint256[8] memory storedProof = market.getProof(reqid);
        for (uint256 i = 0; i < 8; i++) {
            assertEq(storedProof[i], VALID_PROOF[i]);
        }
    }

    function test_FullAuctionFlow_MultipleBidders() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        uint256 fee1 = 6e17; // Higher fee (worse bid)
        uint256 fee2 = 4e17; // Lower fee (better bid)
        uint256 nonce1 = 123;
        uint256 nonce2 = 456;

        bytes32 bidHash1 = _createBidHash(fee1, nonce1);
        bytes32 bidHash2 = _createBidHash(fee2, nonce2);

        // Place bids
        vm.prank(prover1);
        market.bid(reqid, bidHash1);
        vm.prank(prover2);
        market.bid(reqid, bidHash2);

        // Fast forward to reveal phase and reveal both
        vm.warp(block.timestamp + BIDDING_DURATION + 1);
        vm.prank(prover1);
        market.reveal(reqid, fee1, nonce1);
        vm.prank(prover2);
        market.reveal(reqid, fee2, nonce2);

        // Verify bidders are ordered correctly (prover2 wins with lower fee)
        (address winner, uint256 winnerFee, address secondPlace, uint256 secondFee) = market.getBidders(reqid);
        assertEq(winner, prover2);
        assertEq(winnerFee, fee2);
        assertEq(secondPlace, prover1);
        assertEq(secondFee, fee1);

        // Fast forward to proof submission phase
        vm.warp(block.timestamp + REVEAL_DURATION + 1);

        // Winner pays second-lowest bid (reverse auction)
        vm.expectEmit(true, true, false, true);
        emit ProofSubmitted(reqid, prover2, VALID_PROOF, fee1);

        vm.prank(prover2);
        market.submitProof(reqid, VALID_PROOF);
    }

    function test_Refund_Success() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        // Fast forward past deadline
        vm.warp(req.fee.deadline + 1);

        uint256 requesterBalanceBefore = feeToken.balanceOf(requester);

        vm.expectEmit(true, true, false, true);
        emit Refunded(reqid, requester, MAX_FEE);

        market.refund(reqid);

        // Verify refund was processed
        (IBrevisMarket.ReqStatus status,,,,,,,) = market.getRequest(reqid);
        assertEq(uint256(status), uint256(IBrevisMarket.ReqStatus.Refunded));
        assertEq(feeToken.balanceOf(requester), requesterBalanceBefore + MAX_FEE);
    }

    // =============================
    // ProverStats tests
    // =============================

    function test_ProverStats_TotalsAndRecent_BidRevealSubmit() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        // Bid
        bytes32 bidHash = _createBidHash(5e17, 123);
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
        assertEq(total.wins, 1);
        assertEq(total.requestsFulfilled, 1);
        assertGe(total.lastActiveAt, beforeSubmitTs);

        (IBrevisMarket.ProverStats memory recent,) = market.getProverRecentStats(prover1);
        assertEq(recent.bids, 1);
        assertEq(recent.reveals, 1);
        assertEq(recent.wins, 1);
        assertEq(recent.requestsFulfilled, 1);
        assertGe(recent.lastActiveAt, beforeSubmitTs);

        (uint64 startAt, uint64 epochId) = market.getRecentStatsInfo();
        assertGe(startAt, 0);
        assertGe(epochId, 0);

        // Fee accounting: with a single bidder, actualFee == winner fee
        (address winner, uint256 winnerFee,, uint256 secondFee) = market.getBidders(reqid);
        // silence winner variable
        winner;
        // protocol fee bps default is likely 0 in this test suite; compute reward generically
        (uint256 feeBps,) = market.getProtocolFeeInfo();
        uint256 actualFee = secondFee == 0 ? winnerFee : secondFee;
        uint256 expectedReward = (actualFee * (10000 - feeBps)) / 10000;

        // total and recent should reflect the reward paid to the prover
        total = market.getProverStatsTotal(prover1);
        (recent,) = market.getProverRecentStats(prover1);
        assertEq(total.feeReceived, expectedReward);
        assertEq(recent.feeReceived, expectedReward);
    }

    function test_ProverStats_WinsMoveOnWinnerChange_LastActiveUnchanged() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        // Both place bids
        vm.prank(prover1);
        market.bid(reqid, _createBidHash(6e17, 111));
        vm.prank(prover2);
        market.bid(reqid, _createBidHash(4e17, 222));

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

        // Wins adjusted: prover1 back to 0, prover2 = 1
        IBrevisMarket.ProverStats memory t1After = market.getProverStatsTotal(prover1);
        IBrevisMarket.ProverStats memory t2After = market.getProverStatsTotal(prover2);
        assertEq(t1After.wins, 0);
        assertEq(t2After.wins, 1);

        // Prover1 lastActiveAt unchanged by someone else's reveal
        assertEq(t1After.lastActiveAt, p1LastActive);

        // Recent stats mirror totals
        (IBrevisMarket.ProverStats memory r1,) = market.getProverRecentStats(prover1);
        (IBrevisMarket.ProverStats memory r2,) = market.getProverRecentStats(prover2);
        assertEq(r1.wins, 0);
        assertEq(r2.wins, 1);
    }

    function test_ProverStats_RecentReset_AndEpochInfo() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();
        vm.prank(requester);
        market.requestProof(req);

        // Some activity for prover1
        vm.prank(prover1);
        market.bid(reqid, _createBidHash(5e17, 123));

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
        assertEq(recent1.wins, 0);
        assertEq(recent1.requestsFulfilled, 0);

        // Totals remain
        IBrevisMarket.ProverStats memory total1 = market.getProverStatsTotal(prover1);
        assertEq(total1.bids, 1);
        assertEq(total1.reveals, 0);
        assertEq(total1.wins, 0);
        assertEq(total1.requestsFulfilled, 0);
    }

    function test_ProverStats_RecentZerosForInactiveProver() public {
        // No activity after reset for prover2
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();
        vm.prank(requester);
        market.requestProof(req);

        // Some activity by prover1 only
        vm.prank(prover1);
        market.bid(reqid, _createBidHash(5e17, 123));

        // Reset epoch; ensure monotonic start by advancing time
        vm.warp(block.timestamp + 1);
        vm.prank(owner);
        market.scheduleStatsEpoch(0);

        (IBrevisMarket.ProverStats memory recent2,) = market.getProverRecentStats(prover2);
        assertEq(recent2.bids, 0);
        assertEq(recent2.reveals, 0);
        assertEq(recent2.wins, 0);
        assertEq(recent2.requestsFulfilled, 0);
    }

    function test_ProverStats_MissedDeadline_DerivedWinsMinusSubmissions() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();
        vm.prank(requester);
        market.requestProof(req);

        // Prover1 bids and reveals, becomes winner
        vm.prank(prover1);
        market.bid(reqid, _createBidHash(5e17, 123));
        vm.warp(block.timestamp + BIDDING_DURATION + 1);
        vm.prank(prover1);
        market.reveal(reqid, 5e17, 123);

        // Let deadline pass, then refund
        (,,,, uint256 minStake, uint64 deadline,,) = market.getRequest(reqid);
        // silence minStake warning
        minStake;
        vm.warp(deadline + 1);
        market.refund(reqid);

        IBrevisMarket.ProverStats memory total1 = market.getProverStatsTotal(prover1);
        assertEq(total1.wins, 1);
        assertEq(total1.requestsFulfilled, 0);
        // Derived missed = 1
        assertEq(uint256(total1.wins) - uint256(total1.requestsFulfilled), 1);
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
        market.bid(reqid, _createBidHash(5e17, 123));

        // Recent == current epoch stats
        (IBrevisMarket.ProverStats memory recent1e1,) = market.getProverRecentStats(prover1);
        IBrevisMarket.ProverStats memory e1p1 = market.getProverStatsForStatsEpoch(prover1, epoch1);
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
        IBrevisMarket.ProverStats memory e1p1After = market.getProverStatsForStatsEpoch(prover1, epoch1);
        assertEq(e1p1After.bids, 1);
        IBrevisMarket.ProverStats memory e2p1 = market.getProverStatsForStatsEpoch(prover1, epoch2);
        assertEq(e2p1.bids, 0);

        // New activity in epoch2 should affect only epoch2 bucket and recent
        vm.prank(prover2);
        market.bid(reqid, _createBidHash(6e17, 456));

        (IBrevisMarket.ProverStats memory recent2e2,) = market.getProverRecentStats(prover2);
        IBrevisMarket.ProverStats memory e2p2 = market.getProverStatsForStatsEpoch(prover2, epoch2);
        assertEq(recent2e2.bids, 1);
        assertEq(e2p2.bids, 1);

        // Lifetime totals reflect both epochs
        IBrevisMarket.ProverStats memory total1After = market.getProverStatsTotal(prover1);
        IBrevisMarket.ProverStats memory total2After = market.getProverStatsTotal(prover2);
        assertEq(total1After.bids, 1);
        assertEq(total2After.bids, 1);
    }

    function test_Refund_RevertBeforeDeadline() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        // Should fail with MarketCannotRefundYet since we're still in bidding phase with no early refund conditions met
        uint256 biddingEndTime = block.timestamp + BIDDING_DURATION;
        uint256 revealEndTime = biddingEndTime + REVEAL_DURATION;
        vm.expectRevert(
            abi.encodeWithSelector(
                IBrevisMarket.MarketCannotRefundYet.selector,
                block.timestamp,
                req.fee.deadline,
                biddingEndTime,
                revealEndTime
            )
        );
        market.refund(reqid);
    }

    function test_ResetStats_ScheduleFutureStart_RollsOverOnActivity() public {
        // Capture current epoch
        (uint64 startAt1, uint64 epoch1) = market.getRecentStatsInfo();
        startAt1;
        // Schedule next epoch in the future
        uint64 futureStart = uint64(block.timestamp + 1000);
        vm.prank(owner);
        market.scheduleStatsEpoch(futureStart);

        // Latest epoch id remains unchanged until activity at/after futureStart
        assertEq(market.statsEpochId(), epoch1);

        // The scheduled epoch metadata is visible at epoch1 + 1
        (uint64 scheduledStart, uint64 scheduledEnd) = market.statsEpochs(epoch1 + 1);
        assertEq(scheduledStart, futureStart);
        assertEq(scheduledEnd, 0);

        // Activity before futureStart counts toward current epoch (epoch1)
        (bytes32 reqid1, IBrevisMarket.ProofRequest memory req1) = _createBasicRequest();
        vm.prank(requester);
        market.requestProof(req1);

        vm.warp(futureStart - 1);
        vm.prank(prover1);
        market.bid(reqid1, _createBidHash(5e17, 123));

        IBrevisMarket.ProverStats memory e1p1 = market.getProverStatsForStatsEpoch(prover1, epoch1);
        assertEq(e1p1.bids, 1);
        IBrevisMarket.ProverStats memory e2p1Before = market.getProverStatsForStatsEpoch(prover1, epoch1 + 1);
        assertEq(e2p1Before.bids, 0);

        // Activity at or after futureStart triggers rollover; stats attributed to new epoch
        (bytes32 reqid2, IBrevisMarket.ProofRequest memory req2) = _createBasicRequest();
        // ensure distinct reqid from reqid1 by changing nonce
        req2.nonce = req2.nonce + 1;
        vm.prank(requester);
        market.requestProof(req2);

        vm.warp(futureStart);
        vm.prank(prover2);
        market.bid(reqid2, _createBidHash(6e17, 456));

        (uint64 startAt2, uint64 epoch2) = market.getRecentStatsInfo();
        assertEq(epoch2, epoch1 + 1);
        assertEq(startAt2, futureStart);

        IBrevisMarket.ProverStats memory e2p2 = market.getProverStatsForStatsEpoch(prover2, epoch2);
        assertEq(e2p2.bids, 1);
    }

    function test_AdminFunctions() public {
        // Test setMinMaxFee
        uint256 newMinFee = 2e12;
        vm.prank(owner);
        market.setMinMaxFee(newMinFee);
        assertEq(market.minMaxFee(), newMinFee);

        // Test setBiddingPhaseDuration
        uint64 newBiddingDuration = 2 hours;
        vm.prank(owner);
        market.setBiddingPhaseDuration(newBiddingDuration);
        assertEq(market.biddingPhaseDuration(), newBiddingDuration);

        // Test setRevealPhaseDuration
        uint64 newRevealDuration = 1 hours;
        vm.prank(owner);
        market.setRevealPhaseDuration(newRevealDuration);
        assertEq(market.revealPhaseDuration(), newRevealDuration);
    }

    function test_AdminFunctions_RevertNotOwner() public {
        vm.prank(address(0x999));
        vm.expectRevert(); // Should revert with access control error
        market.setMinMaxFee(2e12);
    }

    function test_ViewFunctions() public view {
        assertEq(market.MAX_DEADLINE_DURATION(), 30 days);
        assertEq(market.minMaxFee(), MIN_MAX_FEE);
        assertEq(market.biddingPhaseDuration(), BIDDING_DURATION);
        assertEq(market.revealPhaseDuration(), REVEAL_DURATION);
        assertEq(address(market.feeToken()), address(feeToken));
        assertEq(address(market.stakingController()), address(stakingController));
        assertEq(address(market.picoVerifier()), address(picoVerifier));
    }

    // =========================================================================
    // ADDITIONAL EDGE CASE TESTS
    // =========================================================================

    function test_SubmitProof_RevertEarlySubmission() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        uint256 requestTimestamp = block.timestamp;
        vm.prank(requester);
        market.requestProof(req);

        uint256 fee = 5e17;
        uint256 nonce = 123;
        bytes32 bidHash = _createBidHash(fee, nonce);

        // Place bid and reveal
        vm.prank(prover1);
        market.bid(reqid, bidHash);

        vm.warp(block.timestamp + BIDDING_DURATION + 1);
        vm.prank(prover1);
        market.reveal(reqid, fee, nonce);

        // Try to submit proof before reveal phase ends
        uint256 revealEndTime = requestTimestamp + BIDDING_DURATION + REVEAL_DURATION;
        vm.expectRevert(
            abi.encodeWithSelector(IBrevisMarket.MarketRevealPhaseNotEnded.selector, block.timestamp, revealEndTime)
        );
        vm.prank(prover1);
        market.submitProof(reqid, VALID_PROOF);
    }

    function test_Reveal_RevertAfterSubmitProof() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        uint256 fee = 5e17;
        uint256 nonce = 123;
        bytes32 bidHash = _createBidHash(fee, nonce);

        // Place bid and reveal
        vm.prank(prover1);
        market.bid(reqid, bidHash);

        vm.warp(block.timestamp + BIDDING_DURATION + 1);
        vm.prank(prover1);
        market.reveal(reqid, fee, nonce);

        // Submit proof
        vm.warp(block.timestamp + REVEAL_DURATION + 1);
        vm.prank(prover1);
        market.submitProof(reqid, VALID_PROOF);

        // Try to reveal after proof is submitted with a different bidder
        // This should fail because status is now Fulfilled
        uint256 fee2 = 4e17;
        uint256 nonce2 = 456;

        vm.prank(prover2);
        vm.expectRevert(
            abi.encodeWithSelector(IBrevisMarket.MarketInvalidRequestStatus.selector, IBrevisMarket.ReqStatus.Fulfilled)
        );
        market.reveal(reqid, fee2, nonce2);
    }

    function test_Reveal_RevertProverIneligibleAtRevealTime() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        uint256 fee = 5e17;
        uint256 nonce = 123;
        bytes32 bidHash = _createBidHash(fee, nonce);

        // Place bid while prover1 is eligible
        vm.prank(prover1);
        market.bid(reqid, bidHash);

        // Remove prover1's stake to make them ineligible
        stakingController.setProverStake(prover1, MIN_STAKE / 2);

        // Try to reveal when no longer eligible
        vm.warp(block.timestamp + BIDDING_DURATION + 1);
        vm.prank(prover1);
        vm.expectRevert(
            abi.encodeWithSelector(IBrevisMarket.MarketProverNotEligible.selector, prover1, MIN_STAKE, MIN_STAKE / 2)
        );
        market.reveal(reqid, fee, nonce);
    }

    function test_SameFeeRevealOrder() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        uint256 sameFee = 5e17;
        uint256 nonce1 = 123;
        uint256 nonce2 = 456;
        bytes32 bidHash1 = _createBidHash(sameFee, nonce1);
        bytes32 bidHash2 = _createBidHash(sameFee, nonce2);

        // Place bids
        vm.prank(prover1);
        market.bid(reqid, bidHash1);
        vm.prank(prover2);
        market.bid(reqid, bidHash2);

        // Reveal in order: prover1 first, prover2 second
        vm.warp(block.timestamp + BIDDING_DURATION + 1);
        vm.prank(prover1);
        market.reveal(reqid, sameFee, nonce1);
        vm.prank(prover2);
        market.reveal(reqid, sameFee, nonce2);

        // Winner should be prover1 (first to reveal among tied bids)
        (address winner, uint256 winnerFee, address secondPlace, uint256 secondFee) = market.getBidders(reqid);
        assertEq(winner, prover1);
        assertEq(winnerFee, sameFee);
        assertEq(secondPlace, prover2);
        assertEq(secondFee, sameFee);
    }

    function test_DeadlineExactlyAtRevealEnd() public {
        (, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();
        // Set deadline exactly at reveal phase end
        req.fee.deadline = uint64(block.timestamp + BIDDING_DURATION + REVEAL_DURATION);

        vm.prank(requester);
        // Should pass - deadline equals reveal end
        market.requestProof(req);

        bytes32 reqid = keccak256(abi.encodePacked(req.nonce, req.vk, req.publicValuesDigest));
        uint256 fee = 5e17;
        uint256 nonce = 123;
        bytes32 bidHash = _createBidHash(fee, nonce);

        // Place bid and reveal
        vm.prank(prover1);
        market.bid(reqid, bidHash);

        vm.warp(block.timestamp + BIDDING_DURATION + 1);
        vm.prank(prover1);
        market.reveal(reqid, fee, nonce);

        // At deadline, submitProof should fail (deadline passed)
        vm.warp(req.fee.deadline + 1);
        vm.prank(prover1);
        vm.expectRevert(
            abi.encodeWithSelector(IBrevisMarket.MarketDeadlinePassed.selector, block.timestamp, req.fee.deadline)
        );
        market.submitProof(reqid, VALID_PROOF);
    }

    function test_RefundWithUnrevealedBids() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        uint256 fee = 5e17;
        uint256 nonce = 123;
        bytes32 bidHash = _createBidHash(fee, nonce);

        // Place bid but don't reveal
        vm.prank(prover1);
        market.bid(reqid, bidHash);

        // Fast forward past deadline without revealing
        vm.warp(req.fee.deadline + 1);

        uint256 requesterBalanceBefore = feeToken.balanceOf(requester);

        // Should be able to refund
        market.refund(reqid);

        // Verify refund processed correctly
        (IBrevisMarket.ReqStatus status,,,,,,,) = market.getRequest(reqid);
        assertEq(uint256(status), uint256(IBrevisMarket.ReqStatus.Refunded));
        assertEq(feeToken.balanceOf(requester), requesterBalanceBefore + MAX_FEE);
    }

    function test_RefundWithNoBids() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        // No bids placed, fast forward past deadline
        vm.warp(req.fee.deadline + 1);

        uint256 requesterBalanceBefore = feeToken.balanceOf(requester);

        // Should be able to refund
        market.refund(reqid);

        // Verify refund processed correctly
        (IBrevisMarket.ReqStatus status,,,,,,,) = market.getRequest(reqid);
        assertEq(uint256(status), uint256(IBrevisMarket.ReqStatus.Refunded));
        assertEq(feeToken.balanceOf(requester), requesterBalanceBefore + MAX_FEE);
    }

    // =========================================================================
    // EARLY REFUND TESTS
    // =========================================================================

    function test_EarlyRefund_NoBidsAfterBiddingPhase() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        // Fast forward past bidding phase but before deadline
        vm.warp(block.timestamp + BIDDING_DURATION + 1);

        uint256 requesterBalanceBefore = feeToken.balanceOf(requester);

        vm.expectEmit(true, true, false, true);
        emit Refunded(reqid, requester, MAX_FEE);

        // Should be able to refund early since no bids were placed
        market.refund(reqid);

        // Verify refund processed correctly
        (IBrevisMarket.ReqStatus status,,,,,,,) = market.getRequest(reqid);
        assertEq(uint256(status), uint256(IBrevisMarket.ReqStatus.Refunded));
        assertEq(feeToken.balanceOf(requester), requesterBalanceBefore + MAX_FEE);
    }

    function test_EarlyRefund_BidsSubmittedButNoneRevealed() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        uint256 fee = 5e17;
        uint256 nonce = 123;
        bytes32 bidHash = _createBidHash(fee, nonce);

        // Place bid but don't reveal
        vm.prank(prover1);
        market.bid(reqid, bidHash);

        // Fast forward past reveal phase but before deadline
        vm.warp(block.timestamp + BIDDING_DURATION + REVEAL_DURATION + 1);

        uint256 requesterBalanceBefore = feeToken.balanceOf(requester);

        vm.expectEmit(true, true, false, true);
        emit Refunded(reqid, requester, MAX_FEE);

        // Should be able to refund early since no bids were revealed (no winner)
        market.refund(reqid);

        // Verify refund processed correctly
        (IBrevisMarket.ReqStatus status,,,,,,,) = market.getRequest(reqid);
        assertEq(uint256(status), uint256(IBrevisMarket.ReqStatus.Refunded));
        assertEq(feeToken.balanceOf(requester), requesterBalanceBefore + MAX_FEE);
    }

    function test_EarlyRefund_CannotRefundDuringBiddingPhase() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        // Try to refund during bidding phase (should fail)
        uint256 biddingEndTime = block.timestamp + BIDDING_DURATION;
        uint256 revealEndTime = biddingEndTime + REVEAL_DURATION;

        vm.expectRevert(
            abi.encodeWithSelector(
                IBrevisMarket.MarketCannotRefundYet.selector,
                block.timestamp,
                req.fee.deadline,
                biddingEndTime,
                revealEndTime
            )
        );
        market.refund(reqid);
    }

    function test_EarlyRefund_CannotRefundDuringRevealPhaseWithBids() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        uint256 requestTime = block.timestamp;
        uint256 fee = 5e17;
        uint256 nonce = 123;
        bytes32 bidHash = _createBidHash(fee, nonce);

        // Place bid
        vm.prank(prover1);
        market.bid(reqid, bidHash);

        // Fast forward to reveal phase but don't reveal
        vm.warp(requestTime + BIDDING_DURATION + 1);

        uint256 biddingEndTime = requestTime + BIDDING_DURATION;
        uint256 revealEndTime = requestTime + BIDDING_DURATION + REVEAL_DURATION;

        // Try to refund during reveal phase (should fail - still have time for reveals)
        vm.expectRevert(
            abi.encodeWithSelector(
                IBrevisMarket.MarketCannotRefundYet.selector,
                block.timestamp,
                req.fee.deadline,
                biddingEndTime,
                revealEndTime
            )
        );
        market.refund(reqid);
    }

    function test_EarlyRefund_CannotRefundWhenWinnerExists() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        uint256 requestTime = block.timestamp;
        uint256 fee = 5e17;
        uint256 nonce = 123;
        bytes32 bidHash = _createBidHash(fee, nonce);

        // Place and reveal bid (creates a winner)
        vm.prank(prover1);
        market.bid(reqid, bidHash);

        vm.warp(requestTime + BIDDING_DURATION + 1);
        vm.prank(prover1);
        market.reveal(reqid, fee, nonce);

        // Fast forward past reveal phase but before deadline
        vm.warp(requestTime + BIDDING_DURATION + REVEAL_DURATION + 1);

        uint256 biddingEndTime = requestTime + BIDDING_DURATION;
        uint256 revealEndTime = requestTime + BIDDING_DURATION + REVEAL_DURATION;

        // Should NOT be able to refund early since there's a winner
        vm.expectRevert(
            abi.encodeWithSelector(
                IBrevisMarket.MarketCannotRefundYet.selector,
                block.timestamp,
                req.fee.deadline,
                biddingEndTime,
                revealEndTime
            )
        );
        market.refund(reqid);
    }

    function test_EarlyRefund_TracksBidCountCorrectly() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        uint256 requestTime = block.timestamp;
        uint256 fee = 5e17;
        uint256 nonce = 123;
        bytes32 bidHash = _createBidHash(fee, nonce);

        // Place bid from prover1
        vm.prank(prover1);
        market.bid(reqid, bidHash);

        // Replace bid from same prover (should not increase count)
        bytes32 newBidHash = _createBidHash(4e17, 456);
        vm.prank(prover1);
        market.bid(reqid, newBidHash);

        // Add bid from different prover
        vm.prank(prover2);
        market.bid(reqid, bidHash);

        // Fast forward past bidding phase
        vm.warp(requestTime + BIDDING_DURATION + 1);

        // Should NOT be able to refund since we have 2 bids (from 2 provers)
        uint256 biddingEndTime = requestTime + BIDDING_DURATION;
        uint256 revealEndTime = requestTime + BIDDING_DURATION + REVEAL_DURATION;

        vm.expectRevert(
            abi.encodeWithSelector(
                IBrevisMarket.MarketCannotRefundYet.selector,
                block.timestamp,
                req.fee.deadline,
                biddingEndTime,
                revealEndTime
            )
        );
        market.refund(reqid);
    }

    function test_EarlyRefund_WorksWithMultipleBidsButNoReveals() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        uint256 fee = 5e17;
        uint256 nonce = 123;
        bytes32 bidHash = _createBidHash(fee, nonce);

        // Place bids from multiple provers
        vm.prank(prover1);
        market.bid(reqid, bidHash);
        vm.prank(prover2);
        market.bid(reqid, bidHash);

        // Fast forward past reveal phase without revealing any bids
        vm.warp(block.timestamp + BIDDING_DURATION + REVEAL_DURATION + 1);

        uint256 requesterBalanceBefore = feeToken.balanceOf(requester);

        // Should be able to refund since no winner was determined
        market.refund(reqid);

        // Verify refund processed correctly
        (IBrevisMarket.ReqStatus status,,,,,,,) = market.getRequest(reqid);
        assertEq(uint256(status), uint256(IBrevisMarket.ReqStatus.Refunded));
        assertEq(feeToken.balanceOf(requester), requesterBalanceBefore + MAX_FEE);
    }

    // =========================================================================
    // SLASH INTEGRATION TESTS
    // =========================================================================

    function test_RefundNoLongerSlashes() public {
        // Test that refund no longer performs slashing - it's now separated
        uint256 slashBps = 2000; // 20%
        uint256 slashWindow = 1 days;

        vm.startPrank(owner);
        market.setSlashBps(slashBps);
        market.setSlashWindow(slashWindow);
        vm.stopPrank();

        stakingController.setProverStake(prover1, MIN_STAKE * 2);

        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        _completeAuctionWithWinner(reqid, prover1, MAX_FEE / 2);

        // Fast forward past deadline but within slash window
        vm.warp(req.fee.deadline + 1);

        // Refund should NOT trigger slash anymore (it's separated)
        market.refund(reqid);

        // Verify no slash was called during refund
        assertFalse(stakingController.wasAnySlashCalled(), "Refund should no longer trigger slashing");

        // Verify refund worked correctly
        (IBrevisMarket.ReqStatus status,,,,,,,) = market.getRequest(reqid);
        assertEq(uint256(status), uint256(IBrevisMarket.ReqStatus.Refunded));
    }

    function test_Slash_usesRequestMinStakeNotProverAssets() public {
        // Setup: Test that slash calculation always uses req.fee.minStake regardless of prover's actual assets
        // This is the key behavior - slashing is based on the request's requirements, not prover's holdings
        uint256 slashBps = 2000; // 20%
        uint256 slashWindow = 1 days;

        vm.startPrank(owner);
        market.setSlashBps(slashBps);
        market.setSlashWindow(slashWindow);
        vm.stopPrank();

        // Set prover with assets much higher than the request's minStake
        stakingController.setProverStake(prover1, MIN_STAKE * 10); // 10x the minStake

        // Create a request with a specific minStake
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();
        // req.fee.minStake = MIN_STAKE (1e18)

        // Complete auction with prover1 as winner
        vm.prank(requester);
        market.requestProof(req);

        _completeAuctionWithWinner(reqid, prover1, MAX_FEE / 2);

        // Fast forward past deadline but within slash window
        vm.warp(req.fee.deadline + 1);

        // Refund first (no slashing)
        market.refund(reqid);

        // Expected slash should be based on req.fee.minStake (1e18), NOT prover's actual assets (10e18)
        // This shows the market uses the request's minStake parameter for slash calculation
        uint256 expectedSlashAmount = (req.fee.minStake * slashBps) / market.BPS_DENOMINATOR();
        // expectedSlashAmount = (1e18 * 2000) / 10000 = 0.2e18

        // Now call slash separately
        market.slash(reqid);

        // Verify slash was called with amount based on req.fee.minStake, not prover's actual assets
        assertTrue(
            stakingController.wasSlashByAmountCalled(prover1, expectedSlashAmount),
            "slashByAmount should use req.fee.minStake for calculation, not prover's actual assets"
        );
    }

    function test_Slash_onlyWithinSlashWindow() public {
        uint256 slashBps = 1000; // 10%
        uint256 slashWindow = 1 days;

        vm.startPrank(owner);
        market.setSlashBps(slashBps);
        market.setSlashWindow(slashWindow);
        vm.stopPrank();

        stakingController.setProverStake(prover1, MIN_STAKE * 2);

        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        _completeAuctionWithWinner(reqid, prover1, MAX_FEE / 2);

        // Fast forward past deadline AND slash window
        vm.warp(req.fee.deadline + slashWindow + 1);

        // Refund first
        market.refund(reqid);

        // Slash should revert (outside window)
        vm.expectRevert(
            abi.encodeWithSelector(
                IBrevisMarket.MarketSlashWindowExpired.selector, block.timestamp, req.fee.deadline + slashWindow
            )
        );
        market.slash(reqid);

        // Verify no slash was called
        assertFalse(stakingController.wasAnySlashCalled(), "No slash should occur outside slash window");
    }

    function test_Slash_noAssignedProver() public {
        uint256 slashBps = 1000; // 10%
        uint256 slashWindow = 1 days;

        vm.startPrank(owner);
        market.setSlashBps(slashBps);
        market.setSlashWindow(slashWindow);
        vm.stopPrank();

        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        // No bids placed - no assigned prover
        vm.warp(req.fee.deadline + 1);

        // Refund first
        market.refund(reqid);

        // Slash should revert (no assigned prover)
        vm.expectRevert(abi.encodeWithSelector(IBrevisMarket.MarketNoAssignedProverToSlash.selector, reqid));
        market.slash(reqid);

        // Verify no slash was called
        assertFalse(stakingController.wasAnySlashCalled(), "No slash should occur when no assigned prover");
    }

    function test_Slash_zeroSlashBps() public {
        uint256 slashBps = 0; // No slashing
        uint256 slashWindow = 1 days;

        vm.startPrank(owner);
        market.setSlashBps(slashBps);
        market.setSlashWindow(slashWindow);
        vm.stopPrank();

        stakingController.setProverStake(prover1, MIN_STAKE * 2);

        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        _completeAuctionWithWinner(reqid, prover1, MAX_FEE / 2);

        vm.warp(req.fee.deadline + 1);

        // Refund first
        market.refund(reqid);

        // Slash should call slashByAmount but with amount = 0 (due to slashBps = 0)
        market.slash(reqid);

        // Calculate expected slash amount (should be 0)
        uint256 expectedSlashAmount = (req.fee.minStake * slashBps) / market.BPS_DENOMINATOR(); // = 0

        // Verify slash was called with 0 amount
        assertTrue(
            stakingController.wasSlashByAmountCalled(prover1, expectedSlashAmount),
            "slashByAmount should be called with 0 amount when slashBps = 0"
        );
    }

    function test_Slash_integrationWithActualController() public {
        // This test would require integration with a real StakingController
        // For now, we rely on the mock to verify the integration pattern

        uint256 slashBps = 1500; // 15%
        uint256 slashWindow = 2 days;

        vm.startPrank(owner);
        market.setSlashBps(slashBps);
        market.setSlashWindow(slashWindow);
        vm.stopPrank();

        stakingController.setProverStake(prover1, MIN_STAKE * 3);

        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        _completeAuctionWithWinner(reqid, prover1, MAX_FEE / 3);

        vm.warp(req.fee.deadline + 1);

        // Refund first
        market.refund(reqid);

        // Then slash
        market.slash(reqid);

        // Calculate expected values
        uint256 expectedSlashAmount = (req.fee.minStake * slashBps) / market.BPS_DENOMINATOR();

        // Verify integration - mock should have received correct parameters
        assertTrue(
            stakingController.wasSlashByAmountCalled(prover1, expectedSlashAmount),
            "Integration should call slashByAmount correctly"
        );
    }

    function test_Slash_beforeDeadline() public {
        uint256 slashBps = 1000;
        uint256 slashWindow = 1 days;

        vm.startPrank(owner);
        market.setSlashBps(slashBps);
        market.setSlashWindow(slashWindow);
        vm.stopPrank();

        stakingController.setProverStake(prover1, MIN_STAKE * 2);

        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        _completeAuctionWithWinner(reqid, prover1, MAX_FEE / 2);

        // Try to slash before deadline passes - should fail because request needs to be refunded first
        vm.expectRevert(
            abi.encodeWithSelector(IBrevisMarket.MarketInvalidRequestStatus.selector, IBrevisMarket.ReqStatus.Pending)
        );
        market.slash(reqid);
    }

    function test_Slash_requiresRefundedStatus() public {
        uint256 slashBps = 1000;
        uint256 slashWindow = 1 days;

        vm.startPrank(owner);
        market.setSlashBps(slashBps);
        market.setSlashWindow(slashWindow);
        vm.stopPrank();

        stakingController.setProverStake(prover1, MIN_STAKE * 2);

        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        _completeAuctionWithWinner(reqid, prover1, MAX_FEE / 2);

        vm.warp(req.fee.deadline + 1);

        // Try to slash before refunding
        vm.expectRevert(
            abi.encodeWithSelector(IBrevisMarket.MarketInvalidRequestStatus.selector, IBrevisMarket.ReqStatus.Pending)
        );
        market.slash(reqid);
    }

    function test_Slash_emitsEvent() public {
        uint256 slashBps = 1500;
        uint256 slashWindow = 1 days;

        vm.startPrank(owner);
        market.setSlashBps(slashBps);
        market.setSlashWindow(slashWindow);
        vm.stopPrank();

        stakingController.setProverStake(prover1, MIN_STAKE * 2);

        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        _completeAuctionWithWinner(reqid, prover1, MAX_FEE / 2);

        vm.warp(req.fee.deadline + 1);

        // Refund first
        market.refund(reqid);

        // Calculate expected slash amount
        uint256 expectedSlashAmount = (req.fee.minStake * slashBps) / market.BPS_DENOMINATOR();

        // Expect event to be emitted
        vm.expectEmit(true, true, false, true);
        emit IBrevisMarket.ProverSlashed(reqid, prover1, expectedSlashAmount);

        // Slash
        market.slash(reqid);
    }

    function test_Slash_preventsDoubleSlashing() public {
        uint256 slashBps = 1500;
        uint256 slashWindow = 1 days;

        vm.startPrank(owner);
        market.setSlashBps(slashBps);
        market.setSlashWindow(slashWindow);
        vm.stopPrank();

        stakingController.setProverStake(prover1, MIN_STAKE * 2);

        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        _completeAuctionWithWinner(reqid, prover1, MAX_FEE / 2);

        vm.warp(req.fee.deadline + 1);

        // Refund first
        market.refund(reqid);

        // First slash should succeed
        market.slash(reqid);

        // Verify request is now in Slashed status
        (IBrevisMarket.ReqStatus status,,,,,,,) = market.getRequest(reqid);
        assertEq(uint256(status), uint256(IBrevisMarket.ReqStatus.Slashed));

        // Second slash attempt should fail with invalid status
        vm.expectRevert(
            abi.encodeWithSelector(IBrevisMarket.MarketInvalidRequestStatus.selector, IBrevisMarket.ReqStatus.Slashed)
        );
        market.slash(reqid);

        // Verify the original slash occurred correctly
        uint256 expectedSlashAmount = (req.fee.minStake * slashBps) / market.BPS_DENOMINATOR();
        assertTrue(
            stakingController.wasSlashByAmountCalled(prover1, expectedSlashAmount), "First slash should have occurred"
        );
    }

    // =========================================================================
    // HELPER FUNCTIONS FOR SLASH TESTS
    // =========================================================================

    function _completeAuctionWithWinner(bytes32 reqid, address winner, uint256 fee) internal {
        // Skip to reveal phase
        vm.warp(block.timestamp + BIDDING_DURATION + 1);

        // Submit and reveal winning bid
        bytes32 bidHash = keccak256(abi.encodePacked(fee, uint256(1)));

        // Go back to bidding phase to submit bid
        vm.warp(block.timestamp - BIDDING_DURATION - 1);

        vm.prank(winner);
        market.bid(reqid, bidHash);

        // Move to reveal phase
        vm.warp(block.timestamp + BIDDING_DURATION + 1);

        vm.prank(winner);
        market.reveal(reqid, fee, 1);
    }

    // =========================================================================
    // PROTOCOL FEE TESTS
    // =========================================================================

    function test_ProtocolFee_basicFunctionality() public {
        uint256 protocolFeeBps = 1000; // 10%
        uint256 expectedFee = MAX_FEE / 2; // prover1 wins with this fee

        // Set protocol fee
        vm.prank(owner);
        market.setProtocolFeeBps(protocolFeeBps);

        // Verify fee was set
        (uint256 feeBps, uint256 balance) = market.getProtocolFeeInfo();
        assertEq(feeBps, protocolFeeBps);
        assertEq(balance, 0);

        stakingController.setProverStake(prover1, MIN_STAKE * 2);

        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        _completeAuctionWithWinner(reqid, prover1, expectedFee);

        // Submit proof
        vm.warp(req.fee.deadline - 1);
        uint256[8] memory proof = VALID_PROOF;
        picoVerifier.setValidProof(req.vk, req.publicValuesDigest, proof);

        vm.prank(prover1);
        market.submitProof(reqid, proof);

        // Calculate expected protocol fee and prover reward
        uint256 expectedProtocolFee = (expectedFee * protocolFeeBps) / 10000;
        uint256 expectedProverReward = expectedFee - expectedProtocolFee;

        // Check protocol fee balance
        (, uint256 newBalance) = market.getProtocolFeeInfo();
        assertEq(newBalance, expectedProtocolFee);

        // Check that prover received the reduced reward
        assertTrue(
            stakingController.wasAddRewardsCalled(prover1, expectedProverReward),
            "Prover should receive reward minus protocol fee"
        );
    }

    function test_ProtocolFee_zeroFee() public {
        uint256 protocolFeeBps = 0; // 0%
        uint256 expectedFee = MAX_FEE / 2;

        // Set zero protocol fee
        vm.prank(owner);
        market.setProtocolFeeBps(protocolFeeBps);

        stakingController.setProverStake(prover1, MIN_STAKE * 2);

        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        _completeAuctionWithWinner(reqid, prover1, expectedFee);

        // Submit proof
        vm.warp(req.fee.deadline - 1);
        uint256[8] memory proof = VALID_PROOF;
        picoVerifier.setValidProof(req.vk, req.publicValuesDigest, proof);

        vm.prank(prover1);
        market.submitProof(reqid, proof);

        // Check no protocol fee was collected
        (, uint256 balance) = market.getProtocolFeeInfo();
        assertEq(balance, 0);

        // Check that prover received full reward
        assertTrue(
            stakingController.wasAddRewardsCalled(prover1, expectedFee),
            "Prover should receive full reward when protocol fee is 0"
        );
    }

    function test_ProtocolFee_maxFee() public {
        uint256 protocolFeeBps = 10000; // 100%
        uint256 expectedFee = MAX_FEE / 2;

        // Set maximum protocol fee
        vm.prank(owner);
        market.setProtocolFeeBps(protocolFeeBps);

        stakingController.setProverStake(prover1, MIN_STAKE * 2);

        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        _completeAuctionWithWinner(reqid, prover1, expectedFee);

        // Submit proof
        vm.warp(req.fee.deadline - 1);
        uint256[8] memory proof = VALID_PROOF;
        picoVerifier.setValidProof(req.vk, req.publicValuesDigest, proof);

        vm.prank(prover1);
        market.submitProof(reqid, proof);

        // Check all fee went to protocol
        (, uint256 balance) = market.getProtocolFeeInfo();
        assertEq(balance, expectedFee);

        // Check that prover received no reward
        assertFalse(
            stakingController.wasAnyAddRewardsCalled(), "No rewards should be distributed when protocol fee is 100%"
        );
    }

    function test_ProtocolFee_withdraw() public {
        uint256 protocolFeeBps = 2000; // 20%
        uint256 expectedFee = MAX_FEE / 2;

        // Set protocol fee and complete a transaction
        vm.prank(owner);
        market.setProtocolFeeBps(protocolFeeBps);

        stakingController.setProverStake(prover1, MIN_STAKE * 2);

        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        _completeAuctionWithWinner(reqid, prover1, expectedFee);

        vm.warp(req.fee.deadline - 1);
        uint256[8] memory proof = VALID_PROOF;
        picoVerifier.setValidProof(req.vk, req.publicValuesDigest, proof);

        vm.prank(prover1);
        market.submitProof(reqid, proof);

        uint256 expectedProtocolFee = (expectedFee * protocolFeeBps) / 10000;

        // Check protocol fee accumulated
        (, uint256 balance) = market.getProtocolFeeInfo();
        assertEq(balance, expectedProtocolFee);

        // Withdraw protocol fee
        address treasury = address(0x999);
        uint256 treasuryBalanceBefore = feeToken.balanceOf(treasury);

        vm.expectEmit(true, false, false, true);
        emit IBrevisMarket.ProtocolFeeWithdrawn(treasury, expectedProtocolFee);

        vm.prank(owner);
        market.withdrawProtocolFee(treasury);

        // Check treasury received the fee
        assertEq(feeToken.balanceOf(treasury), treasuryBalanceBefore + expectedProtocolFee);

        // Check protocol fee balance is now zero
        (, uint256 newBalance) = market.getProtocolFeeInfo();
        assertEq(newBalance, 0);
    }

    function test_ProtocolFee_withdrawZeroBalance() public {
        address treasury = address(0x999);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IBrevisMarket.MarketNoProtocolFeeToWithdraw.selector));
        market.withdrawProtocolFee(treasury);
    }

    function test_ProtocolFee_withdrawToZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IBrevisMarket.MarketZeroAddress.selector));
        market.withdrawProtocolFee(address(0));
    }

    function test_ProtocolFee_emitsEventOnUpdate() public {
        uint256 oldBps = 0;
        uint256 newBps = 1500;

        vm.expectEmit(false, false, false, true);
        emit IBrevisMarket.ProtocolFeeBpsUpdated(oldBps, newBps);

        vm.prank(owner);
        market.setProtocolFeeBps(newBps);
    }
}
