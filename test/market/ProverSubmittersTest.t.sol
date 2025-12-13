// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/market/BrevisMarket.sol";
import "../../src/market/interfaces/IBrevisMarket.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockVerifier.sol";
import "../mocks/MockStakingController.sol";
import "../utils/TestErrors.sol";

contract ProverSubmittersTest is Test {
    BrevisMarket public market;
    MockERC20 public feeToken;
    MockVerifier public picoVerifier;
    MockStakingController public stakingController;

    address public owner = address(0x1);
    address public prover1 = address(0x2);
    address public prover2 = address(0x3);
    address public submitter1 = address(0x4);
    address public submitter2 = address(0x5);
    address public submitter3 = address(0x6);
    address public unregisteredAddress = address(0x7);
    address public requester = address(0x8);

    uint64 public constant BIDDING_DURATION = 1 hours;
    uint64 public constant REVEAL_DURATION = 30 minutes;
    uint96 public constant MIN_MAX_FEE = 1e12;
    uint96 public constant MAX_FEE = 1e18;
    uint96 public constant MIN_STAKE = 1e18;

    // Events
    event SubmitterConsentUpdated(address indexed submitter, address indexed oldProver, address indexed newProver);
    event SubmitterRegistered(address indexed prover, address indexed submitter);
    event SubmitterUnregistered(address indexed prover, address indexed submitter);
    event NewBid(bytes32 indexed reqid, address indexed prover, bytes32 bidHash);
    event BidRevealed(bytes32 indexed reqid, address indexed prover, uint256 fee);
    event ProofSubmitted(bytes32 indexed reqid, address indexed prover, uint256[8] proof, uint256 actualFee);

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

        // Setup provers in staking controller
        stakingController.setProverState(prover1, IStakingController.ProverState.Active);
        stakingController.setProverState(prover2, IStakingController.ProverState.Active);
        stakingController.setProverEligible(prover1, true, MIN_STAKE);
        stakingController.setProverEligible(prover2, true, MIN_STAKE);

        // Fund submitters for potential transactions
        vm.deal(submitter1, 1 ether);
        vm.deal(submitter2, 1 ether);
        vm.deal(submitter3, 1 ether);
    }

    // =======================================================================
    // CONSENT MANAGEMENT TESTS
    // =======================================================================

    function test_setSubmitterConsent_GrantConsent() public {
        vm.expectEmit(true, true, true, true);
        emit SubmitterConsentUpdated(submitter1, address(0), prover1);

        vm.prank(submitter1);
        market.setSubmitterConsent(prover1);

        assertEq(market.submitterConsent(submitter1), prover1);
    }

    function test_setSubmitterConsent_RevokeConsent() public {
        // First grant consent
        vm.prank(submitter1);
        market.setSubmitterConsent(prover1);

        // Then revoke it
        vm.expectEmit(true, true, true, true);
        emit SubmitterConsentUpdated(submitter1, prover1, address(0));

        vm.prank(submitter1);
        market.setSubmitterConsent(address(0));

        assertEq(market.submitterConsent(submitter1), address(0));
    }

    function test_setSubmitterConsent_ChangeConsent() public {
        // First grant consent to prover1
        vm.prank(submitter1);
        market.setSubmitterConsent(prover1);

        // Then change to prover2
        vm.expectEmit(true, true, true, true);
        emit SubmitterConsentUpdated(submitter1, prover1, prover2);

        vm.prank(submitter1);
        market.setSubmitterConsent(prover2);

        assertEq(market.submitterConsent(submitter1), prover2);
    }

    function test_setSubmitterConsent_CannotRegisterSelf() public {
        vm.expectRevert(IBrevisMarket.MarketCannotRegisterSelf.selector);
        vm.prank(prover1);
        market.setSubmitterConsent(prover1);
    }

    // =======================================================================
    // SUBMITTER REGISTRATION TESTS
    // =======================================================================

    function test_registerSubmitter_Success() public {
        // Grant consent first
        vm.prank(submitter1);
        market.setSubmitterConsent(prover1);

        // Register submitter
        vm.expectEmit(true, true, true, true);
        emit SubmitterRegistered(prover1, submitter1);

        vm.prank(prover1);
        market.registerSubmitter(submitter1);

        // Verify registration
        assertEq(market.submitterToProver(submitter1), prover1);
        address[] memory submitters = market.getSubmittersForProver(prover1);
        assertEq(submitters.length, 1);
        assertEq(submitters[0], submitter1);
    }

    function test_registerSubmitter_RequiresConsent() public {
        vm.expectRevert(abi.encodeWithSelector(IBrevisMarket.MarketSubmitterConsentRequired.selector, submitter1));
        vm.prank(prover1);
        market.registerSubmitter(submitter1);
    }

    function test_registerSubmitter_RequiresRegisteredProver() public {
        // Grant consent first
        vm.prank(submitter1);
        market.setSubmitterConsent(unregisteredAddress);

        vm.expectRevert(IBrevisMarket.MarketProverNotRegistered.selector);
        vm.prank(unregisteredAddress);
        market.registerSubmitter(submitter1);
    }

    function test_registerSubmitter_CannotRegisterZeroAddress() public {
        vm.expectRevert(IBrevisMarket.MarketZeroAddress.selector);
        vm.prank(prover1);
        market.registerSubmitter(address(0));
    }

    function test_registerSubmitter_CannotRegisterSelf() public {
        // Prover grants consent to themselves (should fail in setSubmitterConsent)
        vm.expectRevert(IBrevisMarket.MarketCannotRegisterSelf.selector);
        vm.prank(prover1);
        market.registerSubmitter(prover1);
    }

    function test_registerSubmitter_CannotRegisterExistingProver() public {
        // Try to register prover2 as a submitter for prover1
        vm.prank(prover2);
        market.setSubmitterConsent(prover1);

        vm.expectRevert(abi.encodeWithSelector(IBrevisMarket.MarketCannotRegisterProverAsSubmitter.selector, prover2));
        vm.prank(prover1);
        market.registerSubmitter(prover2);
    }

    function test_registerSubmitter_CannotRegisterToMultipleProvers() public {
        // Setup: submitter1 consents to prover1 and gets registered
        vm.prank(submitter1);
        market.setSubmitterConsent(prover1);
        vm.prank(prover1);
        market.registerSubmitter(submitter1);

        // submitter1 changes consent to prover2
        vm.prank(submitter1);
        market.setSubmitterConsent(prover2);

        // prover2 tries to register submitter1 (should fail because already registered to prover1)
        vm.expectRevert(
            abi.encodeWithSelector(IBrevisMarket.MarketSubmitterAlreadyRegistered.selector, submitter1, prover1)
        );
        vm.prank(prover2);
        market.registerSubmitter(submitter1);
    }

    function test_registerSubmitter_MultipleSubmittersPerProver() public {
        // Grant consents
        vm.prank(submitter1);
        market.setSubmitterConsent(prover1);
        vm.prank(submitter2);
        market.setSubmitterConsent(prover1);

        // Register both submitters
        vm.prank(prover1);
        market.registerSubmitter(submitter1);
        vm.prank(prover1);
        market.registerSubmitter(submitter2);

        // Verify both registrations
        assertEq(market.submitterToProver(submitter1), prover1);
        assertEq(market.submitterToProver(submitter2), prover1);

        address[] memory submitters = market.getSubmittersForProver(prover1);
        assertEq(submitters.length, 2);
        // Order may vary due to EnumerableSet
        assertTrue(
            (submitters[0] == submitter1 && submitters[1] == submitter2)
                || (submitters[0] == submitter2 && submitters[1] == submitter1)
        );
    }

    // =======================================================================
    // SUBMITTER UNREGISTRATION TESTS
    // =======================================================================

    function test_unregisterSubmitter_Success() public {
        // Setup: register submitter first
        vm.prank(submitter1);
        market.setSubmitterConsent(prover1);
        vm.prank(prover1);
        market.registerSubmitter(submitter1);

        // Unregister
        vm.expectEmit(true, true, true, true);
        emit SubmitterUnregistered(prover1, submitter1);

        vm.prank(prover1);
        market.unregisterSubmitter(submitter1);

        // Verify unregistration
        assertEq(market.submitterToProver(submitter1), address(0));
        address[] memory submitters = market.getSubmittersForProver(prover1);
        assertEq(submitters.length, 0);
    }

    function test_unregisterSubmitter_RequiresProverOwnership() public {
        // Setup: register submitter to prover1
        vm.prank(submitter1);
        market.setSubmitterConsent(prover1);
        vm.prank(prover1);
        market.registerSubmitter(submitter1);

        // Try to unregister from wrong prover
        vm.expectRevert(IBrevisMarket.MarketNotAuthorized.selector);
        vm.prank(prover2);
        market.unregisterSubmitter(submitter1);
    }

    function test_unregisterSubmitter_NotRegistered() public {
        vm.expectRevert(abi.encodeWithSelector(IBrevisMarket.MarketSubmitterNotRegistered.selector, submitter1));
        vm.prank(prover1);
        market.unregisterSubmitter(submitter1);
    }

    function test_submitterCanUnregisterSelf() public {
        // Setup: register submitter first
        vm.prank(submitter1);
        market.setSubmitterConsent(prover1);
        vm.prank(prover1);
        market.registerSubmitter(submitter1);

        // Submitter unregisters themselves (no argument version)
        vm.expectEmit(true, true, true, true);
        emit SubmitterUnregistered(prover1, submitter1);

        vm.prank(submitter1);
        market.unregisterSubmitter(); // No argument - self unregister

        // Verify unregistration
        assertEq(market.submitterToProver(submitter1), address(0));
        address[] memory submitters = market.getSubmittersForProver(prover1);
        assertEq(submitters.length, 0);
    }

    function test_submitterSelfUnregister_NotRegistered() public {
        vm.expectRevert(abi.encodeWithSelector(IBrevisMarket.MarketSubmitterNotRegistered.selector, submitter1));
        vm.prank(submitter1);
        market.unregisterSubmitter(); // Try to self-unregister when not registered
    }

    // =======================================================================
    // BATCH OPERATIONS TESTS
    // =======================================================================

    function test_registerSubmitters_BatchSuccess() public {
        // Setup: grant consent from multiple submitters
        vm.prank(submitter1);
        market.setSubmitterConsent(prover1);
        vm.prank(submitter2);
        market.setSubmitterConsent(prover1);

        // Batch register
        address[] memory submitters = new address[](2);
        submitters[0] = submitter1;
        submitters[1] = submitter2;

        vm.expectEmit(true, true, true, true);
        emit SubmitterRegistered(prover1, submitter1);
        vm.expectEmit(true, true, true, true);
        emit SubmitterRegistered(prover1, submitter2);

        vm.prank(prover1);
        market.registerSubmitters(submitters);

        // Verify both registrations
        assertEq(market.submitterToProver(submitter1), prover1);
        assertEq(market.submitterToProver(submitter2), prover1);
        address[] memory registeredSubmitters = market.getSubmittersForProver(prover1);
        assertEq(registeredSubmitters.length, 2);
    }

    function test_unregisterSubmitters_BatchSuccess() public {
        // Setup: register multiple submitters
        vm.prank(submitter1);
        market.setSubmitterConsent(prover1);
        vm.prank(submitter2);
        market.setSubmitterConsent(prover1);
        vm.prank(prover1);
        market.registerSubmitter(submitter1);
        vm.prank(prover1);
        market.registerSubmitter(submitter2);

        // Batch unregister
        address[] memory submitters = new address[](2);
        submitters[0] = submitter1;
        submitters[1] = submitter2;

        vm.expectEmit(true, true, true, true);
        emit SubmitterUnregistered(prover1, submitter1);
        vm.expectEmit(true, true, true, true);
        emit SubmitterUnregistered(prover1, submitter2);

        vm.prank(prover1);
        market.unregisterSubmitters(submitters);

        // Verify both unregistrations
        assertEq(market.submitterToProver(submitter1), address(0));
        assertEq(market.submitterToProver(submitter2), address(0));
        address[] memory registeredSubmitters = market.getSubmittersForProver(prover1);
        assertEq(registeredSubmitters.length, 0);
    }

    // =======================================================================
    // MARKETPLACE INTEGRATION TESTS
    // =======================================================================

    function test_submitterCanBidOnBehalfOfProver() public {
        // Setup: register submitter
        vm.prank(submitter1);
        market.setSubmitterConsent(prover1);
        vm.prank(prover1);
        market.registerSubmitter(submitter1);

        // Create a request
        bytes32 reqid = _createProofRequest();
        bytes32 bidHash = keccak256(abi.encodePacked(reqid, prover1, uint256(1e17), uint256(123)));

        // Submitter bids on behalf of prover1
        vm.expectEmit(true, true, true, true);
        emit NewBid(reqid, prover1, bidHash);

        vm.prank(submitter1);
        market.bid(reqid, bidHash);

        // Verify bid is stored under prover1
        assertEq(market.getBidHash(reqid, prover1), bidHash);
    }

    function test_submitterCanRevealOnBehalfOfProver() public {
        // Setup: register submitter and place bid
        vm.prank(submitter1);
        market.setSubmitterConsent(prover1);
        vm.prank(prover1);
        market.registerSubmitter(submitter1);

        bytes32 reqid = _createProofRequest();
        uint256 fee = 1e17;
        uint256 nonce = 123;
        bytes32 bidHash = keccak256(abi.encodePacked(reqid, prover1, fee, nonce));

        vm.prank(submitter1);
        market.bid(reqid, bidHash);

        // Move to reveal phase
        vm.warp(block.timestamp + BIDDING_DURATION + 1);

        // Submitter reveals on behalf of prover1
        vm.expectEmit(true, true, true, true);
        emit BidRevealed(reqid, prover1, fee);

        vm.prank(submitter1);
        market.reveal(reqid, fee, nonce);
    }

    function test_submitterCanSubmitProofOnBehalfOfProver() public {
        // Setup: complete auction process
        vm.prank(submitter1);
        market.setSubmitterConsent(prover1);
        vm.prank(prover1);
        market.registerSubmitter(submitter1);

        bytes32 reqid = _createProofRequest();
        uint256 fee = 1e17;
        uint256 nonce = 123;
        bytes32 bidHash = keccak256(abi.encodePacked(reqid, prover1, fee, nonce));

        // Bid and reveal
        vm.prank(submitter1);
        market.bid(reqid, bidHash);

        vm.warp(block.timestamp + BIDDING_DURATION + 1);
        vm.prank(submitter1);
        market.reveal(reqid, fee, nonce);

        // Move to proof submission phase
        vm.warp(block.timestamp + REVEAL_DURATION + 1);

        // Create valid proof
        bytes32 vk = keccak256("test_vk");
        bytes32 publicValuesDigest = keccak256("test_public_values");
        uint256[8] memory proof = [uint256(vk), uint256(publicValuesDigest), 3, 4, 5, 6, 7, 8];

        // Set up the proof as valid in MockVerifier
        picoVerifier.setValidProof(vk, publicValuesDigest, proof);

        // Submitter submits proof on behalf of prover1
        vm.expectEmit(true, true, true, true);
        emit ProofSubmitted(reqid, prover1, proof, fee); // Event should emit the effective prover, not submitter

        vm.prank(submitter1);
        market.submitProof(reqid, proof);
    }

    function test_unregisteredSubmitterCannotBid() public {
        bytes32 reqid = _createProofRequest();
        bytes32 bidHash = keccak256(abi.encodePacked(reqid, prover1, uint256(1e17), uint256(123)));

        // Unregistered address tries to bid (will bid as themselves, but they're not a prover)
        vm.expectRevert();
        vm.prank(unregisteredAddress);
        market.bid(reqid, bidHash);
    }

    function test_revokedSubmitterCannotBid() public {
        // Setup and then revoke
        vm.prank(submitter1);
        market.setSubmitterConsent(prover1);
        vm.prank(prover1);
        market.registerSubmitter(submitter1);
        vm.prank(prover1);
        market.unregisterSubmitter(submitter1);

        bytes32 reqid = _createProofRequest();
        bytes32 bidHash = keccak256(abi.encodePacked(reqid, prover1, uint256(1e17), uint256(123)));

        // Revoked submitter tries to bid (will bid as themselves, but they're not a prover)
        vm.expectRevert();
        vm.prank(submitter1);
        market.bid(reqid, bidHash);
    }

    // =======================================================================
    // HELPER FUNCTIONS
    // =======================================================================

    function _createProofRequest() internal returns (bytes32 reqid) {
        // Setup requester with funds
        feeToken.mint(requester, MAX_FEE);
        vm.prank(requester);
        feeToken.approve(address(market), MAX_FEE);

        IBrevisMarket.ProofRequest memory req = IBrevisMarket.ProofRequest({
            nonce: 1,
            vk: keccak256("test_vk"),
            publicValuesDigest: keccak256("test_public_values"),
            imgURL: "",
            inputData: "",
            inputURL: "",
            version: 0,
            fee: IBrevisMarket.FeeParams({maxFee: MAX_FEE, minStake: MIN_STAKE, deadline: uint64(block.timestamp + 1 days)})
        });

        reqid = keccak256(abi.encodePacked(req.nonce, req.vk, req.publicValuesDigest));

        vm.prank(requester);
        market.requestProof(req);

        return reqid;
    }

    // =======================================================================
    // HELPER FUNCTION TESTS
    // =======================================================================

    function test_getEffectiveProver_DirectProver() public {
        // Test internal function through public behavior
        bytes32 reqid = _createProofRequest();
        bytes32 bidHash = keccak256(abi.encodePacked(reqid, prover1, uint256(1e17), uint256(123)));

        // Direct prover bids
        vm.prank(prover1);
        market.bid(reqid, bidHash);

        // Verify bid is stored under prover1 (meaning _getEffectiveProver returned prover1)
        assertEq(market.getBidHash(reqid, prover1), bidHash);
    }

    function test_getEffectiveProver_RegisteredSubmitter() public {
        // Setup submitter
        vm.prank(submitter1);
        market.setSubmitterConsent(prover1);
        vm.prank(prover1);
        market.registerSubmitter(submitter1);

        bytes32 reqid = _createProofRequest();
        bytes32 bidHash = keccak256(abi.encodePacked(uint256(1e17), uint256(123)));

        // Submitter bids
        vm.prank(submitter1);
        market.bid(reqid, bidHash);

        // Verify bid is stored under prover1 (meaning _getEffectiveProver returned prover1 for submitter1)
        assertEq(market.getBidHash(reqid, prover1), bidHash);
    }

    // =======================================================================
    // EDGE CASE TESTS
    // =======================================================================

    function test_multipleConsecutiveRegistrations() public {
        // Grant consent
        vm.prank(submitter1);
        market.setSubmitterConsent(prover1);

        // Register
        vm.prank(prover1);
        market.registerSubmitter(submitter1);

        // Try to register again (should not revert but not change state)
        vm.prank(prover1);
        market.registerSubmitter(submitter1);

        // Verify still registered once
        address[] memory submitters = market.getSubmittersForProver(prover1);
        assertEq(submitters.length, 1);
        assertEq(submitters[0], submitter1);
    }

    function test_consentWithoutRegistration() public {
        // Grant consent but don't register
        vm.prank(submitter1);
        market.setSubmitterConsent(prover1);

        // Submitter should not be able to act on behalf of prover
        bytes32 reqid = _createProofRequest();
        bytes32 bidHash = keccak256(abi.encodePacked(uint256(1e17), uint256(123)));

        // This will fail because submitter1 is not a prover and not registered
        vm.expectRevert();
        vm.prank(submitter1);
        market.bid(reqid, bidHash);
    }
}
