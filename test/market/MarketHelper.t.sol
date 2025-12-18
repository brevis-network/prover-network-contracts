// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/market/helpers/MarketHelper.sol";
import "../../src/market/BrevisMarket.sol";
import "../../src/market/interfaces/IBrevisMarket.sol";
import "../../src/token/WrappedNativeToken.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockVerifier.sol";
import "../mocks/MockStakingController.sol";

contract MarketHelperTest is Test {
    BrevisMarket public market;
    WrappedNativeToken public wrappedToken;
    MarketHelper public helper;
    MockERC20 public feeToken;
    MockVerifier public picoVerifier;
    MockStakingController public stakingController;

    address public owner = address(0x1);
    address public requester = address(0x2);
    address public prover1 = address(0x3);

    uint64 public constant BIDDING_DURATION = 1 hours;
    uint64 public constant REVEAL_DURATION = 30 minutes;
    uint96 public constant MIN_MAX_FEE = 1e12;
    uint96 public constant MAX_FEE = 1e18;
    uint96 public constant MIN_STAKE = 1e18;

    bytes32 public constant VK = keccak256("test_vk");
    bytes32 public constant PUBLIC_VALUES_DIGEST = keccak256("test_public_values");

    function setUp() public {
        // Deploy wrapped native token (will be used as fee token)
        wrappedToken = new WrappedNativeToken("Wrapped Native", "WNATIVE");

        // Deploy mock contracts
        picoVerifier = new MockVerifier();
        stakingController = new MockStakingController(IERC20(address(wrappedToken)));

        // Deploy BrevisMarket with wrapped token as fee token
        vm.prank(owner);
        market = new BrevisMarket(
            IPicoVerifier(address(picoVerifier)),
            IStakingController(address(stakingController)),
            BIDDING_DURATION,
            REVEAL_DURATION,
            MIN_MAX_FEE
        );

        // Deploy helper
        helper = new MarketHelper(address(market), payable(address(wrappedToken)));

        // Give test accounts some native tokens
        vm.deal(requester, 100 ether);
        vm.deal(prover1, 100 ether);

        // Setup prover eligibility
        stakingController.setProverStake(prover1, MIN_STAKE);
        stakingController.setProverEligible(prover1, true, MIN_STAKE);
    }

    function _createBasicRequest() internal view returns (IBrevisMarket.ProofRequest memory req) {
        req = IBrevisMarket.ProofRequest({
            nonce: 1,
            vk: VK,
            publicValuesDigest: PUBLIC_VALUES_DIGEST,
            imgURL: "",
            inputData: "",
            inputURL: "",
            version: 0,
            fee: IBrevisMarket.FeeParams({maxFee: MAX_FEE, minStake: MIN_STAKE, deadline: uint64(block.timestamp + 2 days)})
        });
    }

    function testRequestProofNative() public {
        IBrevisMarket.ProofRequest memory req = _createBasicRequest();
        bytes32 expectedReqid = keccak256(abi.encodePacked(req.nonce, req.vk, req.publicValuesDigest));

        uint256 balanceBefore = requester.balance;

        vm.prank(requester);
        bytes32 reqid = helper.requestProofNative{value: MAX_FEE}(req);

        // Verify reqid matches expected
        assertEq(reqid, expectedReqid, "Request ID should match");

        // Verify requester's balance decreased
        assertEq(requester.balance, balanceBefore - MAX_FEE, "Requester should have spent native tokens");

        // Verify request was created in market
        (IBrevisMarket.ReqStatus status,, address sender, uint256 maxFee,,,,,) = market.getRequest(reqid);
        assertEq(uint256(status), uint256(IBrevisMarket.ReqStatus.Pending), "Request should be pending");
        assertEq(sender, address(helper), "Helper should be the sender");
        assertEq(maxFee, MAX_FEE, "Max fee should match");

        // Verify owner is tracked in helper
        assertEq(helper.requestOwners(reqid), requester, "Requester should be tracked as owner");
    }

    function testRequestProofNativeRevertInsufficientValue() public {
        IBrevisMarket.ProofRequest memory req = _createBasicRequest();

        vm.prank(requester);
        vm.expectRevert(MarketHelper.MarketHelperInsufficientValue.selector);
        helper.requestProofNative{value: 0}(req);
    }

    function testRequestProofNativeRevertInvalidFeeAmount() public {
        IBrevisMarket.ProofRequest memory req = _createBasicRequest();

        vm.prank(requester);
        vm.expectRevert(MarketHelper.MarketHelperInvalidFeeAmount.selector);
        helper.requestProofNative{value: MAX_FEE / 2}(req);
    }

    function testRefundNativeAfterDeadline() public {
        // Create and submit request
        IBrevisMarket.ProofRequest memory req = _createBasicRequest();

        vm.prank(requester);
        bytes32 reqid = helper.requestProofNative{value: MAX_FEE}(req);

        // Fast forward past deadline
        vm.warp(req.fee.deadline + 1);

        // Refund and check balances
        uint256 balanceBefore = requester.balance;

        vm.prank(requester);
        uint256 refundAmount = helper.refundNative(reqid);

        assertEq(refundAmount, MAX_FEE, "Refund amount should equal max fee");
        assertEq(requester.balance, balanceBefore + MAX_FEE, "Requester should receive native tokens");

        // Verify request status is refunded
        (IBrevisMarket.ReqStatus status,,,,,,,,) = market.getRequest(reqid);
        assertEq(uint256(status), uint256(IBrevisMarket.ReqStatus.Refunded), "Request should be refunded");

        // Verify owner mapping is cleared
        assertEq(helper.requestOwners(reqid), address(0), "Owner should be cleared");
    }

    function testRefundNativeAfterBiddingPhaseWithNoBids() public {
        // Create and submit request
        IBrevisMarket.ProofRequest memory req = _createBasicRequest();

        vm.prank(requester);
        bytes32 reqid = helper.requestProofNative{value: MAX_FEE}(req);

        // Fast forward past bidding phase
        vm.warp(block.timestamp + BIDDING_DURATION + 1);

        // Refund should succeed (no bids submitted)
        uint256 balanceBefore = requester.balance;

        vm.prank(requester);
        uint256 refundAmount = helper.refundNative(reqid);

        assertEq(refundAmount, MAX_FEE, "Refund amount should equal max fee");
        assertEq(requester.balance, balanceBefore + MAX_FEE, "Requester should receive native tokens");
    }

    function testRefundNativeRevertUnauthorizedNonExistentRequest() public {
        bytes32 fakeReqid = keccak256("fake");

        vm.prank(requester);
        vm.expectRevert(MarketHelper.MarketHelperUnauthorized.selector);
        helper.refundNative(fakeReqid);
    }

    function testRefundNativeRevertUnauthorizedWrongHelper() public {
        // Create a request directly through market (not via helper)
        IBrevisMarket.ProofRequest memory req = _createBasicRequest();
        bytes32 reqid = keccak256(abi.encodePacked(req.nonce, req.vk, req.publicValuesDigest));

        // Wrap tokens and approve for direct request
        vm.startPrank(requester);
        wrappedToken.deposit{value: MAX_FEE}();
        wrappedToken.approve(address(market), MAX_FEE);
        market.requestProof(req);
        vm.stopPrank();

        // Try to refund via helper (should fail - helper is not the sender)
        vm.warp(req.fee.deadline + 1);

        vm.prank(requester);
        vm.expectRevert(MarketHelper.MarketHelperUnauthorized.selector);
        helper.refundNative(reqid);
    }

    function testRefundNativeCanBeCalledByAnyone() public {
        // Create and submit request
        IBrevisMarket.ProofRequest memory req = _createBasicRequest();

        vm.prank(requester);
        bytes32 reqid = helper.requestProofNative{value: MAX_FEE}(req);

        // Fast forward past deadline
        vm.warp(req.fee.deadline + 1);

        // Anyone can call refund, but tokens go to original owner
        uint256 requesterBalanceBefore = requester.balance;
        address anyone = address(0x9999);

        vm.prank(anyone);
        uint256 refundAmount = helper.refundNative(reqid);

        assertEq(refundAmount, MAX_FEE, "Refund amount should equal max fee");
        assertEq(requester.balance, requesterBalanceBefore + MAX_FEE, "Original owner should receive tokens");
    }

    function testMultipleRequestsAndRefunds() public {
        // Create multiple requests
        IBrevisMarket.ProofRequest memory req1 = _createBasicRequest();
        req1.nonce = 1;

        IBrevisMarket.ProofRequest memory req2 = _createBasicRequest();
        req2.nonce = 2;

        vm.startPrank(requester);
        bytes32 reqid1 = helper.requestProofNative{value: MAX_FEE}(req1);
        bytes32 reqid2 = helper.requestProofNative{value: MAX_FEE}(req2);
        vm.stopPrank();

        // Verify both are tracked
        assertEq(helper.requestOwners(reqid1), requester, "First request should be tracked");
        assertEq(helper.requestOwners(reqid2), requester, "Second request should be tracked");

        // Fast forward and refund both
        vm.warp(req1.fee.deadline + 1);

        uint256 balanceBefore = requester.balance;

        vm.startPrank(requester);
        helper.refundNative(reqid1);
        helper.refundNative(reqid2);
        vm.stopPrank();

        assertEq(requester.balance, balanceBefore + (MAX_FEE * 2), "Should receive both refunds");
    }

    function testRequestProofNativeEvent() public {
        IBrevisMarket.ProofRequest memory req = _createBasicRequest();
        bytes32 expectedReqid = keccak256(abi.encodePacked(req.nonce, req.vk, req.publicValuesDigest));

        vm.expectEmit(true, true, false, true);
        emit MarketHelper.NativeProofRequested(expectedReqid, requester, MAX_FEE);

        vm.prank(requester);
        helper.requestProofNative{value: MAX_FEE}(req);
    }

    function testRefundNativeEvent() public {
        // Create and submit request
        IBrevisMarket.ProofRequest memory req = _createBasicRequest();

        vm.prank(requester);
        bytes32 reqid = helper.requestProofNative{value: MAX_FEE}(req);

        // Fast forward past deadline
        vm.warp(req.fee.deadline + 1);

        vm.expectEmit(true, true, false, true);
        emit MarketHelper.NativeRefundReceived(reqid, requester, MAX_FEE);

        vm.prank(requester);
        helper.refundNative(reqid);
    }

    function testHelperReceiveFunction() public {
        // Send ETH directly to helper (should succeed)
        vm.deal(address(this), 1 ether);
        (bool success,) = address(helper).call{value: 1 ether}("");
        assertTrue(success, "Helper should accept ETH");
        assertEq(address(helper).balance, 1 ether, "Helper should hold ETH");
    }
}
