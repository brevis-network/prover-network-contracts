// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/market/BrevisMarket.sol";
import "../../src/market/MarketViewer.sol";
import "../../src/market/interfaces/IBrevisMarket.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockVerifier.sol";
import "../mocks/MockStakingController.sol";

contract MarketViewerTest is Test {
    BrevisMarket public market;
    MarketViewer public viewer;
    MockERC20 public feeToken;
    MockVerifier public picoVerifier;
    MockStakingController public stakingController;

    address public owner = address(0x1);
    address public requester = address(0x2);
    address public prover1 = address(0x3);
    address public prover2 = address(0x4);

    uint64 public constant BIDDING_DURATION = 1 hours;
    uint64 public constant REVEAL_DURATION = 30 minutes;
    uint256 public constant MIN_MAX_FEE = 1e12;
    uint256 public constant MAX_FEE = 1e18;
    uint256 public constant MIN_STAKE = 1e18;

    bytes32 public constant VK = keccak256("test_vk");
    bytes32 public constant PUBLIC_VALUES_DIGEST = keccak256("test_public_values");
    // For MockVerifier: proof[0] = VK, proof[1] = PUBLIC_VALUES_DIGEST
    uint256[8] public VALID_PROOF = [uint256(VK), uint256(PUBLIC_VALUES_DIGEST), 3, 4, 5, 6, 7, 8];

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

        // Deploy viewer
        viewer = new MarketViewer(address(market));

        // Setup balances and approvals
        feeToken.mint(requester, 100e18);
        feeToken.mint(address(market), 100e18);
        vm.prank(requester);
        feeToken.approve(address(market), type(uint256).max);

        // Stakes & eligibility
        stakingController.setProverStake(prover1, MIN_STAKE);
        stakingController.setProverStake(prover2, MIN_STAKE);
        stakingController.setProverEligible(prover1, true, MIN_STAKE);
        stakingController.setProverEligible(prover2, true, MIN_STAKE);

        // Valid proof
        picoVerifier.setValidProof(VK, PUBLIC_VALUES_DIGEST, VALID_PROOF);
    }

    function _createRequest(uint64 deadlineDelta)
        internal
        view
        returns (bytes32 reqid, IBrevisMarket.ProofRequest memory req)
    {
        req = IBrevisMarket.ProofRequest({
            nonce: uint64(uint256(keccak256(abi.encodePacked(block.timestamp, deadlineDelta)))),
            vk: VK,
            publicValuesDigest: PUBLIC_VALUES_DIGEST,
            imgURL: "",
            inputData: "",
            inputURL: "",
            fee: IBrevisMarket.FeeParams({
                maxFee: MAX_FEE,
                minStake: MIN_STAKE,
                deadline: uint64(block.timestamp + deadlineDelta)
            })
        });
        reqid = keccak256(abi.encodePacked(req.nonce, req.vk, req.publicValuesDigest));
    }

    function _bid(bytes32 reqid, address prover, uint256 fee, uint256 nonce) internal {
        vm.prank(prover);
        market.bid(reqid, keccak256(abi.encodePacked(reqid, prover, fee, nonce)));
    }

    function _reveal(bytes32 reqid, address prover, uint256 fee, uint256 nonce) internal {
        vm.prank(prover);
        market.reveal(reqid, fee, nonce);
    }

    function _requestAndAuction(uint64 deadlineDelta, uint256 fee1, uint256 fee2)
        internal
        returns (bytes32 reqid, IBrevisMarket.ProofRequest memory req)
    {
        (reqid, req) = _createRequest(deadlineDelta);
        vm.prank(requester);
        market.requestProof(req);

        // Bidding phase
        _bid(reqid, prover1, fee1, 111);
        _bid(reqid, prover2, fee2, 222);

        // Move to reveal phase
        vm.warp(block.timestamp + BIDDING_DURATION + 1);
        _reveal(reqid, prover1, fee1, 111);
        _reveal(reqid, prover2, fee2, 222);
    }

    function test_BatchGetters_And_Proofs() public {
        // Create request with comfortable deadline
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) = _requestAndAuction(2 days, 10, 20);

        // Batch request info
        IMarketViewer.RequestView[] memory rv = viewer.batchGetRequests(_asReqids(reqid));
        assertEq(rv.length, 1);
        assertEq(rv[0].reqid, reqid);
        assertEq(uint256(rv[0].status), uint256(IBrevisMarket.ReqStatus.Pending));
        assertEq(rv[0].sender, requester);
        assertEq(rv[0].deadline, req.fee.deadline);

        // Bidders
        IMarketViewer.BiddersView[] memory bv = viewer.batchGetBidders(_asReqids(reqid));
        assertEq(bv.length, 1);
        assertEq(bv[0].reqid, reqid);
        assertEq(bv[0].winner, prover1); // fee 10 < 20
        assertEq(bv[0].winnerFee, 10);
        assertEq(bv[0].second, prover2);
        assertEq(bv[0].secondFee, 20);

        // Bid hashes
        address[] memory provers = new address[](2);
        provers[0] = prover1;
        provers[1] = prover2;
        bytes32[] memory hashes = viewer.batchGetBidHashes(reqid, provers);
        assertEq(hashes.length, 2);
        assertEq(hashes[0], keccak256(abi.encodePacked(reqid, prover1, uint256(10), uint256(111))));
        assertEq(hashes[1], keccak256(abi.encodePacked(reqid, prover2, uint256(20), uint256(222))));

        // No proof yet
        uint256[8][] memory proofs = viewer.batchGetProofs(_asReqids(reqid));
        assertEq(proofs.length, 1);
        assertEq(proofs[0][0], 0);

        // Submit proof after reveal but before deadline
        vm.warp(block.timestamp + REVEAL_DURATION + 1);
        vm.prank(prover1);
        market.submitProof(reqid, VALID_PROOF);

        proofs = viewer.batchGetProofs(_asReqids(reqid));
        assertEq(proofs[0][0], VALID_PROOF[0]);
        assertEq(proofs[0][1], VALID_PROOF[1]);
    }

    function test_PendingSlices_And_Overdue() public {
        // Create a request with minimal allowed deadline (just after reveal)
        uint64 minDeadlineDelta = BIDDING_DURATION + REVEAL_DURATION + 1;
        (bytes32 reqid,) = _requestAndAuction(minDeadlineDelta, 10, 20);

        // Before deadline, pending but not overdue
        IMarketViewer.ProverPendingItem[] memory items = viewer.getProverPendingRequests(prover1);
        assertEq(items.length, 1);
        assertEq(items.length, 1);
        assertEq(items[0].reqid, reqid);
        // winner is not part of ProverPendingItem; check via sender list instead below
        assertEq(items[0].isOverdue, false);

        // Advance past deadline: still pending, now overdue
        // Fetch sender pending to inspect winner and to warm any caches; also validates sender path type
        (uint256 totalSender, IMarketViewer.SenderPendingItem[] memory sItems) = _noopAndGetSenderPending(requester);
        assertEq(totalSender, 1);
        assertEq(sItems.length, 1);
        assertEq(sItems[0].reqid, reqid);
        assertEq(sItems[0].winner, prover1);
        vm.warp(items[0].deadline + 1);

        items = viewer.getProverPendingRequests(prover1);
        assertEq(items.length, 1);
        assertEq(items[0].isOverdue, true);

        // Overdue counts and ids
        assertEq(viewer.getProverOverdueCount(prover1), 1);
        assertEq(viewer.getSenderOverdueCount(requester), 1);

        bytes32[] memory proverOverdue = viewer.getProverOverdueRequests(prover1);
        assertEq(proverOverdue.length, 1);
        assertEq(proverOverdue[0], reqid);

        bytes32[] memory senderOverdue = viewer.getSenderOverdueRequests(requester);
        assertEq(senderOverdue.length, 1);
        assertEq(senderOverdue[0], reqid);
    }

    function test_ProverStatsComposite_SuccessRate_WithOverdue() public {
        // A: fulfilled (winner = prover1)
        (bytes32 reqA,) = _requestAndAuction(2 days, 10, 20);
        vm.warp(block.timestamp + REVEAL_DURATION + 1);
        vm.prank(prover1);
        market.submitProof(reqA, VALID_PROOF);

        // Increase prover1 stake to satisfy overcommit requirements for concurrent assignments
        stakingController.setProverStake(prover1, 2 * MIN_STAKE);
        stakingController.setProverEligible(prover1, true, 2 * MIN_STAKE);

        // B: refunded after deadline (winner = prover1)
        (bytes32 reqB,) = _requestAndAuction(2 days, 5, 20);
        // Warp past deadline and refund
        (,,,,, uint64 deadline,,) = market.getRequest(reqB);
        vm.warp(deadline + 1);
        market.refund(reqB);

        // C: overdue pending (winner = prover1), do not refund yet
        // deadline just after reveal; warp to overdue after
        uint64 minDeadlineDelta = BIDDING_DURATION + REVEAL_DURATION + 1;
        (bytes32 reqC,) = _requestAndAuction(minDeadlineDelta, 7, 20);
        (,,,,, uint64 deadlineC,,) = market.getRequest(reqC);
        vm.warp(deadlineC + 1);

        // Composite
        IMarketViewer.ProverStatsComposite memory comp = viewer.getProverStatsComposite(prover1);
        assertEq(comp.fulfilled, 1);
        assertEq(comp.refunded, 1);
        assertEq(comp.pendingCount, 1);
        assertEq(comp.overdueCount, 1);

        // successRateBps = 1 / (1 + 1 + 1) = 0.3333 → 3333 bps
        assertEq(comp.successRateBps, 3333);
        // Sanity: totals from market
        IBrevisMarket.ProverStats memory total = market.getProverStatsTotal(prover1);
        assertEq(total.requestsFulfilled, 1);
        assertEq(total.requestsRefunded, 1);
    }

    // Helpers
    function _asReqids(bytes32 reqid) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](1);
        arr[0] = reqid;
    }

    function _noopAndGetSenderPending(address sender)
        internal
        view
        returns (uint256 total, IMarketViewer.SenderPendingItem[] memory items)
    {
        items = viewer.getSenderPendingRequests(sender);
        total = items.length;
    }

    function test_SenderRefundable_PastDeadline() public {
        // Create a request with minimal allowed deadline (just after reveal)
        uint64 minDeadlineDelta = BIDDING_DURATION + REVEAL_DURATION + 1;
        (bytes32 reqid,) = _requestAndAuction(minDeadlineDelta, 7, 20);

        // Warp past deadline (no proof submitted)
        (,,,,, uint64 deadline,,) = market.getRequest(reqid);
        vm.warp(deadline + 1);

        // Refundable because now > deadline
        bytes32[] memory ids = viewer.getSenderRefundableRequests(requester);
        assertEq(ids.length, 1);
        assertEq(ids[0], reqid);
    }

    function test_SenderRefundable_NoBidsAfterBiddingEnd() public {
        // Create a request with long deadline; submit no bids
        uint64 start = uint64(block.timestamp);
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) =
            _createRequest(BIDDING_DURATION + REVEAL_DURATION + 1 days);
        vm.prank(requester);
        market.requestProof(req);

        // Advance to just after bidding phase end but before reveal end and deadline
        vm.warp(uint256(start) + BIDDING_DURATION + 1);

        // Refundable because bidding ended and bidCount == 0
        bytes32[] memory ids = viewer.getSenderRefundableRequests(requester);
        assertEq(ids.length, 1);
        assertEq(ids[0], reqid);
    }

    function test_SenderRefundable_NoWinnerAfterRevealEnd() public {
        // Create a request with long deadline; place bids but don't reveal
        uint64 start = uint64(block.timestamp);
        (bytes32 reqid, IBrevisMarket.ProofRequest memory req) =
            _createRequest(BIDDING_DURATION + REVEAL_DURATION + 1 days);
        vm.prank(requester);
        market.requestProof(req);

        // Bidding phase: sealed bids submitted
        _bid(reqid, prover1, 10, 111);
        _bid(reqid, prover2, 20, 222);

        // Move past reveal phase without any reveal
        vm.warp(uint256(start) + BIDDING_DURATION + REVEAL_DURATION + 2);

        // Refundable because reveal ended and no winner (no reveals)
        bytes32[] memory ids = viewer.getSenderRefundableRequests(requester);
        assertEq(ids.length, 1);
        assertEq(ids[0], reqid);
    }
}
