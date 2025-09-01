// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@security/access/AccessControl.sol";
import "../pico/IPicoVerifier.sol";
import "../staking/interfaces/IStakingController.sol";
import "./IBrevisMarket.sol";
import "./ProverSubmitters.sol";

/**
 * @title BrevisMarket
 * @notice Decentralized proof marketplace using sealed-bid reverse second-price auctions for ZK proof generation
 */
contract BrevisMarket is IBrevisMarket, ProverSubmitters, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================================================
    // STRUCTS & CONSTANTS
    // =========================================================================

    /// Internal struct to track the state of each proof request
    struct ReqState {
        ReqStatus status;
        uint64 timestamp; // req is recorded at this block time, needed for bid/reveal phase
        address sender; // msg.sender of requestProof
        FeeParams fee;
        // needed for verify
        bytes32 vk;
        bytes32 publicValuesDigest; // sha256(publicValues) & bytes32(uint256((1 << 253) - 1))
        mapping(address => bytes32) bids; // received sealed bids by provers
        uint256 bidCount; // number of bids submitted (to track if any bids were made)
        Bidder winner; // winning bidder (lowest fee)
        Bidder second; // second-lowest bidder (for reverse second-price auction - winner pays second-lowest bid)
        uint256[8] proof;
    }

    uint256 public constant MAX_DEADLINE_DURATION = 30 days; // maximum deadline duration from request time

    uint256 public constant BPS_DENOMINATOR = 10000; // 100.00%

    // =========================================================================
    // STORAGE
    // =========================================================================

    // Configuration parameters
    uint64 public biddingPhaseDuration; // duration of bidding phase in seconds
    uint64 public revealPhaseDuration; // duration of reveal phase in seconds
    uint256 public minMaxFee; // minimum maxFee for spam protection
    uint256 public slashBps; // slashing percentage for penalties in basis points
    uint256 public slashWindow; // time window for slashing after deadline (e.g., 7 days)
    uint256 public protocolFeeBps; // protocol fee percentage in basis points (0-10000)

    // Protocol treasury
    uint256 public protocolFeeBalance; // accumulated protocol fees

    // External contracts
    IPicoVerifier public picoVerifier; // address of the PicoVerifier contract
    IERC20 public feeToken; // ERC20 token used for fees

    // Core data structures
    mapping(bytes32 => ReqState) public requests; // proof req id -> state

    // Storage gap for future upgrades. Reserves 40 slots.
    uint256[40] private __gap;

    // =========================================================================
    // CONSTRUCTOR & INITIALIZATION
    // =========================================================================

    /**
     * @notice Constructor - can be used for both upgradeable and direct deployment
     * @dev For upgradeable: pass zero values and call init() later
     *      For direct: pass actual values for immediate initialization
     * @param _picoVerifier Address of the PicoVerifier contract for proof verification
     * @param _stakingController Address of the StakingController for prover eligibility
     * @param _biddingPhaseDuration Duration in seconds for the bidding phase
     * @param _revealPhaseDuration Duration in seconds for the reveal phase
     * @param _minMaxFee Minimum fee for spam protection
     */
    constructor(
        IPicoVerifier _picoVerifier,
        IStakingController _stakingController,
        uint64 _biddingPhaseDuration,
        uint64 _revealPhaseDuration,
        uint256 _minMaxFee
    ) {
        // Only initialize if non-zero values are provided (direct deployment)
        if (address(_picoVerifier) != address(0) && address(_stakingController) != address(0)) {
            _init(_picoVerifier, _stakingController, _biddingPhaseDuration, _revealPhaseDuration, _minMaxFee);
        }
        // For upgradeable deployment, pass zero addresses and call init() separately
    }
    /**
     * @notice Initialize the market contract for upgradeable deployment
     * @dev This function sets up the contract state after deployment
     * @param _picoVerifier Address of the PicoVerifier contract for proof verification
     * @param _stakingController Address of the StakingController for prover eligibility
     * @param _biddingPhaseDuration Duration in seconds for the bidding phase
     * @param _revealPhaseDuration Duration in seconds for the reveal phase
     * @param _minMaxFee Minimum fee for spam protection
     */

    function init(
        IPicoVerifier _picoVerifier,
        IStakingController _stakingController,
        uint64 _biddingPhaseDuration,
        uint64 _revealPhaseDuration,
        uint256 _minMaxFee
    ) external {
        _init(_picoVerifier, _stakingController, _biddingPhaseDuration, _revealPhaseDuration, _minMaxFee);
        initOwner(); // requires _owner == address(0), which is only possible when it's a delegateCall
    }

    /**
     * @notice Internal initialization logic shared by constructor and init function
     * @dev Sets up contract state and validates parameters.
     *      Only called once by either constructor or init function.
     * @param _picoVerifier Address of the PicoVerifier contract for proof verification
     * @param _stakingController Address of the StakingController for prover eligibility
     * @param _biddingPhaseDuration Duration in seconds for the bidding phase
     * @param _revealPhaseDuration Duration in seconds for the reveal phase
     * @param _minMaxFee Minimum fee for spam protection
     */
    function _init(
        IPicoVerifier _picoVerifier,
        IStakingController _stakingController,
        uint64 _biddingPhaseDuration,
        uint64 _revealPhaseDuration,
        uint256 _minMaxFee
    ) internal {
        if (_stakingController == IStakingController(address(0))) {
            revert MarketInvalidStakingController();
        }

        picoVerifier = _picoVerifier;
        stakingController = _stakingController;
        feeToken = stakingController.stakingToken();
        biddingPhaseDuration = _biddingPhaseDuration;
        revealPhaseDuration = _revealPhaseDuration;
        minMaxFee = _minMaxFee;

        // Approve unlimited tokens to staking controller for reward distribution
        feeToken.approve(address(stakingController), type(uint256).max);
    }

    // =========================================================================
    // PROOF REQUEST MANAGEMENT
    // =========================================================================

    /**
     * @notice Submit a proof request with fee payment
     * @dev Caller must have approved feeToken for req.fee.maxFee amount
     * @param req The proof request containing all necessary parameters
     */
    function requestProof(ProofRequest calldata req) external override {
        // Input validation
        if (req.fee.deadline <= block.timestamp) revert MarketDeadlineMustBeInFuture();
        if (req.fee.deadline > block.timestamp + MAX_DEADLINE_DURATION) {
            revert MarketDeadlineTooFar(req.fee.deadline, block.timestamp + MAX_DEADLINE_DURATION);
        }
        if (req.fee.deadline < block.timestamp + biddingPhaseDuration + revealPhaseDuration) {
            revert MarketDeadlineBeforeRevealPhaseEnd();
        }
        if (req.fee.maxFee < minMaxFee) revert MarketMaxFeeTooLow(req.fee.maxFee, minMaxFee);

        uint256 minSelfStake = stakingController.minSelfStake();
        if (req.fee.minStake < minSelfStake) {
            revert MarketMinStakeTooLow(req.fee.minStake, minSelfStake);
        }

        bytes32 reqid = keccak256(abi.encodePacked(req.nonce, req.vk, req.publicValuesDigest));

        ReqState storage reqState = requests[reqid];
        if (reqState.timestamp != 0) revert MarketRequestAlreadyExists(reqid);

        // Transfer the fee tokens from the caller to this contract
        feeToken.safeTransferFrom(msg.sender, address(this), req.fee.maxFee);

        reqState.status = ReqStatus.Pending;
        reqState.timestamp = uint64(block.timestamp);
        reqState.sender = msg.sender;
        reqState.fee = req.fee;
        reqState.vk = req.vk;
        reqState.publicValuesDigest = req.publicValuesDigest;

        emit NewRequest(reqid, req);
    }

    /**
     * @notice Submit a sealed bid for a proof request
     * @dev Can override previous bids during bidding phase
     * @param reqid The request ID to bid on
     * @param bidHash Keccak256 hash of (fee, nonce) - keeps bid secret until reveal
     */
    function bid(bytes32 reqid, bytes32 bidHash) external override {
        ReqState storage req = requests[reqid];

        // Validate request exists
        if (req.timestamp == 0) revert MarketRequestNotFound(reqid);

        // Ensure request is still pending (not fulfilled or refunded)
        if (req.status != ReqStatus.Pending) revert MarketInvalidRequestStatus(req.status);

        // Check we're still in bidding phase
        uint256 biddingEndTime = req.timestamp + biddingPhaseDuration;
        if (block.timestamp > biddingEndTime) revert MarketBiddingPhaseEnded(block.timestamp, biddingEndTime);

        // Get the effective prover (the prover the caller is acting on behalf of)
        address effectiveProver = _getEffectiveProver(msg.sender);
        // Check if effective prover is eligible (must meet minimum stake requirement)
        _requireProverEligible(effectiveProver, req.fee.minStake);

        // Track if this is a new bid (not overwriting existing)
        bool isNewBid = req.bids[effectiveProver] == bytes32(0);

        // Store the sealed bid under the effective prover address
        req.bids[effectiveProver] = bidHash;

        // Increment bid count only for new bids
        if (isNewBid) {
            req.bidCount++;
        }

        emit NewBid(reqid, effectiveProver, bidHash);
    }

    /**
     * @notice Reveal a previously submitted sealed bid
     * @dev Must be called during reveal phase with matching hash
     * @param reqid The request ID that was bid on
     * @param fee The actual fee amount that was hashed
     * @param nonce The nonce that was used in the hash
     */
    function reveal(bytes32 reqid, uint256 fee, uint256 nonce) external override {
        ReqState storage req = requests[reqid];

        // Validate request exists
        if (req.timestamp == 0) revert MarketRequestNotFound(reqid);

        // Ensure request is still pending (not fulfilled or refunded)
        if (req.status != ReqStatus.Pending) revert MarketInvalidRequestStatus(req.status);

        // Ensure we're in reveal phase
        uint256 biddingEndTime = req.timestamp + biddingPhaseDuration;
        if (block.timestamp <= biddingEndTime) revert MarketBiddingPhaseNotEnded(block.timestamp, biddingEndTime);

        uint256 revealEndTime = req.timestamp + biddingPhaseDuration + revealPhaseDuration;
        if (block.timestamp > revealEndTime) {
            revert MarketRevealPhaseEnded(block.timestamp, revealEndTime);
        }

        // Get the effective prover (the prover the caller is acting on behalf of)
        address effectiveProver = _getEffectiveProver(msg.sender);
        // Check if effective prover is still eligible during reveal (re-validate minimum stake requirement)
        _requireProverEligible(effectiveProver, req.fee.minStake);

        // Verify the revealed bid matches the hash
        bytes32 expectedHash = keccak256(abi.encodePacked(fee, nonce));
        if (req.bids[effectiveProver] != expectedHash) {
            revert MarketBidRevealMismatch(expectedHash, req.bids[effectiveProver]);
        }
        if (fee > req.fee.maxFee) revert MarketFeeExceedsMaximum(fee, req.fee.maxFee);

        // Update lowest and second lowest bidders
        _updateBidders(req, effectiveProver, fee);

        emit BidRevealed(reqid, effectiveProver, fee);
    }

    /**
     * @notice Submit proof for a request and claim payment
     * @dev Only winning bidder can submit, proof must be valid, deadline must not be passed
     * @param reqid The request ID to fulfill
     * @param proof The zk proof as uint256[8] array
     */
    function submitProof(bytes32 reqid, uint256[8] calldata proof) external override nonReentrant {
        ReqState storage req = requests[reqid];

        // Validate timing and authorization
        uint256 revealEndTime = req.timestamp + biddingPhaseDuration + revealPhaseDuration;
        if (block.timestamp <= revealEndTime) {
            revert MarketRevealPhaseNotEnded(block.timestamp, revealEndTime);
        }
        if (block.timestamp > req.fee.deadline) revert MarketDeadlinePassed(block.timestamp, req.fee.deadline);

        // Check if msg.sender is authorized to act on behalf of the winning prover
        if (!_isAuthorizedForProver(msg.sender, req.winner.prover)) {
            revert MarketNotExpectedProver(req.winner.prover, msg.sender);
        }

        if (req.status != ReqStatus.Pending) revert MarketInvalidRequestStatus(req.status);

        // Verify the proof
        picoVerifier.verifyPicoProof(req.vk, req.publicValuesDigest, proof);

        // Update request state
        req.proof = proof;
        req.status = ReqStatus.Fulfilled;

        // Calculate and distribute fees
        uint256 actualFee = req.second.fee; // Reverse second-price auction: winner pays second-lowest bid
        if (req.second.prover == address(0)) {
            // Only one bidder - use their bid
            actualFee = req.winner.fee;
        }

        // Calculate protocol fee
        uint256 protocolFee = (actualFee * protocolFeeBps) / BPS_DENOMINATOR;
        uint256 proverReward = actualFee - protocolFee;

        // Accumulate protocol fee
        if (protocolFee > 0) {
            protocolFeeBalance += protocolFee;
        }

        // Send remaining fee to staking controller as reward for the prover
        if (proverReward > 0) {
            stakingController.addRewards(req.winner.prover, proverReward);
        }

        // Refund remaining fee to requester
        feeToken.safeTransfer(req.sender, req.fee.maxFee - actualFee);

        emit ProofSubmitted(reqid, req.winner.prover, proof, actualFee);
    }

    /**
     * @notice Refund a request that cannot be fulfilled
     * @dev Can be called by anyone in these scenarios:
     *      1. After deadline passes without fulfillment
     *      2. After bidding phase ends with no bids submitted
     *      3. After reveal phase ends with no bids revealed (winner not set)
     * @param reqid The request ID to refund
     */
    function refund(bytes32 reqid) external override nonReentrant {
        ReqState storage req = requests[reqid];

        if (req.status != ReqStatus.Pending) revert MarketInvalidRequestStatus(req.status);

        uint256 biddingEndTime = req.timestamp + biddingPhaseDuration;
        uint256 revealEndTime = biddingEndTime + revealPhaseDuration;

        bool canRefund = false;

        if (block.timestamp > req.fee.deadline) {
            canRefund = true; // Case 1: Deadline has passed
        } else if (block.timestamp > biddingEndTime && req.bidCount == 0) {
            canRefund = true; // Case 2: Bidding phase ended with no bids submitted
        } else if (block.timestamp > revealEndTime && req.winner.prover == address(0)) {
            canRefund = true; // Case 3: Reveal phase ended with no winner (no bids revealed)
        }
        if (!canRefund) {
            revert MarketCannotRefundYet(block.timestamp, req.fee.deadline, biddingEndTime, revealEndTime);
        }

        req.status = ReqStatus.Refunded;
        feeToken.safeTransfer(req.sender, req.fee.maxFee);

        emit Refunded(reqid, req.sender, req.fee.maxFee);
    }

    /**
     * @notice Slash the assigned prover for failing to submit proof within deadline
     * @dev Can be called by anyone within slash window after deadline passes and refunded.
     * @param reqid The request ID for which to slash the assigned prover
     */
    function slash(bytes32 reqid) external override {
        ReqState storage req = requests[reqid];

        // Must be refunded state
        if (req.status != ReqStatus.Refunded) revert MarketInvalidRequestStatus(req.status);
        // Must be after deadline
        if (block.timestamp <= req.fee.deadline) revert MarketBeforeDeadline(block.timestamp, req.fee.deadline);
        // Must have an assigned prover to slash
        if (req.winner.prover == address(0)) revert MarketNoAssignedProverToSlash(reqid);
        // Must be within slash window
        if (block.timestamp > req.fee.deadline + slashWindow) {
            revert MarketSlashWindowExpired(block.timestamp, req.fee.deadline + slashWindow);
        }

        // Calculate slash amount
        uint256 slashAmount = (req.fee.minStake * slashBps) / BPS_DENOMINATOR;
        // Perform the slash
        stakingController.slashByAmount(req.winner.prover, slashAmount);
        // Update status to prevent double slashing
        req.status = ReqStatus.Slashed;
        emit ProverSlashed(reqid, req.winner.prover, slashAmount);
    }

    // =========================================================================
    // ADMIN FUNCTIONS
    // =========================================================================

    /**
     * @notice Update the PicoVerifier contract address
     * @dev Only owner can call this function
     * @param newVerifier The new PicoVerifier contract address
     */
    function setPicoVerifier(IPicoVerifier newVerifier) external override onlyOwner {
        if (address(newVerifier) == address(0)) revert MarketZeroAddress();
        IPicoVerifier oldVerifier = picoVerifier;
        picoVerifier = newVerifier;
        emit PicoVerifierUpdated(address(oldVerifier), address(newVerifier));
    }

    /**
     * @notice Update the bidding phase duration
     * @dev Only owner can call this function
     * @param newDuration New duration in seconds for bidding phase
     */
    function setBiddingPhaseDuration(uint64 newDuration) external override onlyOwner {
        uint64 oldDuration = biddingPhaseDuration;
        biddingPhaseDuration = newDuration;
        emit BiddingPhaseDurationUpdated(oldDuration, newDuration);
    }

    /**
     * @notice Update the reveal phase duration
     * @dev Only owner can call this function
     * @param newDuration New duration in seconds for reveal phase
     */
    function setRevealPhaseDuration(uint64 newDuration) external override onlyOwner {
        uint64 oldDuration = revealPhaseDuration;
        revealPhaseDuration = newDuration;
        emit RevealPhaseDurationUpdated(oldDuration, newDuration);
    }

    /**
     * @notice Update the minimum fee
     * @dev Only owner can call this function
     * @param newMinFee New minimum fee amount
     */
    function setMinMaxFee(uint256 newMinFee) external override onlyOwner {
        uint256 oldFee = minMaxFee;
        minMaxFee = newMinFee;
        emit MinMaxFeeUpdated(oldFee, newMinFee);
    }

    /**
     * @notice Update the slash percentage for penalizing non-performing provers
     * @dev Only owner can call this function
     * @param newBps New slash percentage in basis points (0-10000)
     */
    function setSlashBps(uint256 newBps) external override onlyOwner {
        if (newBps > BPS_DENOMINATOR) revert MarketInvalidSlashBps();
        uint256 oldBps = slashBps;
        slashBps = newBps;
        emit SlashBpsUpdated(oldBps, newBps);
    }

    /**
     * @notice Update the slash window duration
     * @dev Only owner can call this function
     * @param newWindow New slash window duration in seconds
     */
    function setSlashWindow(uint256 newWindow) external override onlyOwner {
        uint256 oldWindow = slashWindow;
        slashWindow = newWindow;
        emit SlashWindowUpdated(oldWindow, newWindow);
    }

    /**
     * @notice Update the protocol fee percentage
     * @dev Only owner can call this function
     * @param newBps New protocol fee percentage in basis points (0-10000)
     */
    function setProtocolFeeBps(uint256 newBps) external override onlyOwner {
        if (newBps > BPS_DENOMINATOR) revert MarketInvalidProtocolFeeBps();
        uint256 oldBps = protocolFeeBps;
        protocolFeeBps = newBps;
        emit ProtocolFeeBpsUpdated(oldBps, newBps);
    }

    /**
     * @notice Withdraw accumulated protocol fees
     * @dev Only owner can call this function
     * @param to Address to send the fees to
     */
    function withdrawProtocolFee(address to) external override onlyOwner {
        if (to == address(0)) revert MarketZeroAddress();
        if (protocolFeeBalance == 0) revert MarketNoProtocolFeeToWithdraw();

        uint256 amount = protocolFeeBalance;
        protocolFeeBalance = 0;

        feeToken.safeTransfer(to, amount);
        emit ProtocolFeeWithdrawn(to, amount);
    }

    // =========================================================================
    // REQUEST QUERY FUNCTIONS
    // =========================================================================

    /**
     * @notice Get complete request information
     * @param reqid The request ID to query
     * @return status Current request status (Pending/Fulfilled/Refunded)
     * @return timestamp Request creation timestamp
     * @return sender Original requester address
     * @return maxFee Maximum fee willing to pay
     * @return minStake Minimum stake required for bidders
     * @return deadline Proof submission deadline
     * @return vk Verification key
     * @return publicValuesDigest Public values hash
     */
    function getRequest(bytes32 reqid)
        external
        view
        override
        returns (
            ReqStatus status,
            uint64 timestamp,
            address sender,
            uint256 maxFee,
            uint256 minStake,
            uint64 deadline,
            bytes32 vk,
            bytes32 publicValuesDigest
        )
    {
        ReqState storage req = requests[reqid];
        return (
            req.status,
            req.timestamp,
            req.sender,
            req.fee.maxFee,
            req.fee.minStake,
            req.fee.deadline,
            req.vk,
            req.publicValuesDigest
        );
    }

    /**
     * @notice Get winning bidders for a request
     * @param reqid The request ID to query
     * @return winner Lowest bidder (winner) address
     * @return winnerFee Winning bid amount
     * @return secondPlace Second lowest bidder address
     * @return secondFee Second lowest bid amount
     */
    function getBidders(bytes32 reqid)
        external
        view
        override
        returns (address winner, uint256 winnerFee, address secondPlace, uint256 secondFee)
    {
        ReqState storage req = requests[reqid];
        return (req.winner.prover, req.winner.fee, req.second.prover, req.second.fee);
    }

    /**
     * @notice Get submitted proof for a fulfilled request
     * @param reqid The request ID to query
     * @return proof The submitted zk proof (returns empty array if not fulfilled)
     */
    function getProof(bytes32 reqid) external view override returns (uint256[8] memory proof) {
        return requests[reqid].proof;
    }

    /**
     * @notice Get sealed bid hash for a specific prover
     * @param reqid The request ID to query
     * @param prover The prover address to query
     * @return bidHash The sealed bid hash (empty if no bid submitted)
     */
    function getBidHash(bytes32 reqid, address prover) external view override returns (bytes32 bidHash) {
        return requests[reqid].bids[prover];
    }

    /**
     * @notice Get the protocol fee percentage and balance
     * @return feeBps Protocol fee percentage in basis points
     * @return balance Accumulated protocol fee balance
     */
    function getProtocolFeeInfo() external view override returns (uint256 feeBps, uint256 balance) {
        return (protocolFeeBps, protocolFeeBalance);
    }

    // =========================================================================
    // INTERNAL FUNCTIONS
    // =========================================================================

    /**
     * @notice Update the two lowest bidders for a request
     * @dev Maintains sorted order of winner and second-place bidders
     * @param req Storage reference to the request state
     * @param prover Address of the prover making the bid
     * @param fee Fee amount being bid
     */
    function _updateBidders(ReqState storage req, address prover, uint256 fee) internal {
        // If no bidders yet, or this is lower than current winner
        if (req.winner.prover == address(0) || fee < req.winner.fee) {
            // Move current winner to second place
            req.second = req.winner;
            // Set new winner
            req.winner = Bidder({prover: prover, fee: fee});
        }
        // If this is lower than second place (but not winner)
        else if (req.second.prover == address(0) || fee < req.second.fee) {
            req.second = Bidder({prover: prover, fee: fee});
        }
    }

    /**
     * @notice Internal utility to check if a prover meets eligibility requirements
     * @dev Validates prover's stake against minimum requirements
     * @param prover Address of the prover to check
     * @param minimumStake Minimum stake requirement for the request
     */
    function _requireProverEligible(address prover, uint256 minimumStake) internal view {
        (bool eligible, uint256 currentStake) = stakingController.isProverEligible(prover, minimumStake);
        if (!eligible) revert MarketProverNotEligible(prover, minimumStake, currentStake);
    }
}
