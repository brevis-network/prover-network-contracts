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

        // Setup prover stakes
        stakingController.setProverStake(prover1, MIN_STAKE);
        stakingController.setProverStake(prover2, MIN_STAKE);
        stakingController.setProverStake(prover3, MIN_STAKE / 2); // Insufficient stake

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
            inputData: new bytes[](0),
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

    function test_Refund_RevertBeforeDeadline() public {
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _createBasicRequest();

        vm.prank(requester);
        market.requestProof(req);

        vm.expectRevert(
            abi.encodeWithSelector(IBrevisMarket.MarketBeforeDeadline.selector, block.timestamp, req.fee.deadline)
        );
        market.refund(reqid);
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
}
