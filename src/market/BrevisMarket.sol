// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@security/access/AccessControl.sol";
import "../pico/IPicoVerifier.sol";
import "../staking/interfaces/IStakingController.sol";
import "./interfaces/IBrevisMarket.sol";
import "./ProverSubmitters.sol";

/**
 * @title BrevisMarket
 * @notice Decentralized proof marketplace using sealed-bid reverse second-price auctions for ZK proof generation
 */
contract BrevisMarket is IBrevisMarket, ProverSubmitters, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    // =========================================================================
    // STRUCTS & CONSTANTS
    // =========================================================================

    // f6c9577ec051004416f650ed5cde59ebe31c63663b16e28b9da8cda95777240c
    bytes32 public constant EPOCH_UPDATER_ROLE = keccak256("EPOCH_UPDATER_ROLE");

    /// Internal struct to track the state of each proof request
    struct ReqState {
        ReqStatus status;
        uint64 timestamp; // req is recorded at this block time, needed for bid/reveal phase
        address sender; // msg.sender of requestProof
        FeeParams fee;
        bytes32 vk;
        bytes32 publicValuesDigest; // sha256(publicValues) & bytes32(uint256((1 << 253) - 1))
        uint32 version; // version of the verifier to use
        uint32 bidCount; // number of bids submitted (to track if any bids were made)
        mapping(address => bytes32) bids; // received sealed bids by provers
        Bidder winner; // winning bidder (lowest fee)
        Bidder second; // second-lowest bidder (for reverse second-price auction - winner pays second-lowest bid)
    }

    // Stats-epoch metadata (start/end times). endAt = 0 marks the tail (last scheduled) epoch.
    struct StatsEpochInfo {
        uint64 startAt;
        uint64 endAt;
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
    uint256 public maxMaxFee; // maximum maxFee to prevent excessive fees
    uint256 public slashBps; // slashing percentage for penalties in basis points
    uint256 public slashWindow; // time window for slashing after deadline (e.g., 7 days)
    uint256 public protocolFeeBps; // protocol fee percentage in basis points (0-10000)
    uint256 public overcommitBps; // reserve percentage applied to assignedStake when checking eligibility

    // Protocol treasury
    uint256 public cumulativeProtocolFee; // total protocol fees ever collected
    uint256 public withdrawnProtocolFee; // total protocol fees withdrawn

    // External contracts
    mapping(uint32 => IPicoVerifier) public picoVerifiers; // versioned PicoVerifier contracts
    IERC20 public feeToken; // ERC20 token used for fees

    // Core data structures
    mapping(bytes32 => ReqState) public override requests; // proof req id -> state

    // Unified cumulative global stats per epochId
    // Each entry holds cumulative counters since genesis (carried forward on first use per epoch, then mutated in-place)
    mapping(uint64 => GlobalStats) public globalStats;

    // Unified cumulative prover stats per epochId
    // Each entry holds cumulative counters since genesis.
    // For epoch N, the struct carries forward values from epoch N-1 on first use, then increments in-place.
    mapping(address => mapping(uint64 => ProverStats)) public proverStats;

    // Stats-epoch metadata history as an ordered array (epochId == index)
    StatsEpochInfo[] public statsEpochs;

    // Current epoch id (index into statsEpochs). Advanced lazily on activity.
    uint64 public statsEpochId;

    // Sum of minStake across all assigned-but-unfinalized requests per prover.
    // checking eligibility: required = req.minStake + assignedStake[prover] * overcommitBps / 10_000.
    mapping(address => uint256) public assignedStake;

    // Pending requests per prover and per sender for easy lookup
    mapping(address => EnumerableSet.Bytes32Set) internal proverPendingRequests;
    mapping(address => EnumerableSet.Bytes32Set) internal senderPendingRequests;

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
        if (address(_stakingController) == address(0)) {
            revert MarketInvalidStakingController();
        }

        picoVerifiers[0] = _picoVerifier;
        stakingController = _stakingController;
        feeToken = stakingController.stakingToken();
        biddingPhaseDuration = _biddingPhaseDuration;
        revealPhaseDuration = _revealPhaseDuration;
        minMaxFee = _minMaxFee;

        // Approve unlimited tokens to staking controller for reward distribution
        feeToken.approve(address(stakingController), type(uint256).max);

        // Default reserve to 5%
        overcommitBps = 500;

        // Initialize stats epochs
        statsEpochs.push(StatsEpochInfo({startAt: uint64(block.timestamp), endAt: 0}));
        statsEpochId = 0;
        _grantRole(EPOCH_UPDATER_ROLE, msg.sender);
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
        // Advance epoch id if any scheduled epoch start has passed
        _syncStatsEpochId();
        // Input validation
        if (req.fee.deadline <= block.timestamp) revert MarketDeadlineMustBeInFuture();
        if (req.fee.deadline > block.timestamp + MAX_DEADLINE_DURATION) {
            revert MarketDeadlineTooFar(req.fee.deadline, block.timestamp + MAX_DEADLINE_DURATION);
        }
        if (req.fee.deadline < block.timestamp + biddingPhaseDuration + revealPhaseDuration) {
            revert MarketDeadlineBeforeRevealPhaseEnd();
        }
        uint256 maxFee = uint256(req.fee.maxFee);
        if (maxFee < minMaxFee) revert MarketMaxFeeTooLow(maxFee, minMaxFee);
        if (maxMaxFee > 0 && maxFee > maxMaxFee) revert MarketMaxFeeTooHigh(maxFee, maxMaxFee);

        uint256 minSelfStake = stakingController.minSelfStake();
        uint256 minStake = uint256(req.fee.minStake);
        if (minStake < minSelfStake) {
            revert MarketMinStakeTooLow(minStake, minSelfStake);
        }

        bytes32 reqid = keccak256(abi.encodePacked(req.nonce, req.vk, req.publicValuesDigest));

        ReqState storage reqState = requests[reqid];
        if (reqState.timestamp != 0) revert MarketRequestAlreadyExists(reqid);
        if (address(picoVerifiers[req.version]) == address(0)) {
            revert MarketVerifierVersionNotSet(req.version);
        }

        // Transfer the fee tokens from the caller to this contract
        feeToken.safeTransferFrom(msg.sender, address(this), maxFee);

        reqState.status = ReqStatus.Pending;
        reqState.timestamp = uint64(block.timestamp);
        reqState.sender = msg.sender;
        reqState.fee = req.fee;
        reqState.vk = req.vk;
        reqState.publicValuesDigest = req.publicValuesDigest;
        reqState.version = req.version;

        // Update global stats: track total requests
        GlobalStats storage gs = _currentCumulativeGlobalStats();
        gs.totalRequests += 1;

        senderPendingRequests[msg.sender].add(reqid);

        emit NewRequest(reqid, req);
    }

    /**
     * @notice Submit a sealed bid for a proof request
     * @dev Can override previous bids during bidding phase
     * @param reqid The request ID to bid on
     * @param bidHash Commitment: keccak256(abi.encodePacked(reqid, prover, fee, nonce))
     */
    function bid(bytes32 reqid, bytes32 bidHash) external override {
        // Advance epoch id if any scheduled epoch start has passed
        _syncStatsEpochId();
        ReqState storage req = requests[reqid];

        // Validate request exists
        if (req.timestamp == 0) revert MarketRequestNotFound(reqid);

        // Ensure request is still pending (not fulfilled or refunded)
        if (req.status != ReqStatus.Pending) revert MarketInvalidRequestStatus(req.status);

        // Check we're still in bidding phase
        uint256 biddingEndTime = req.timestamp + biddingPhaseDuration;
        if (block.timestamp > biddingEndTime) revert MarketBiddingPhaseEnded(block.timestamp, biddingEndTime);

        // Get the effective prover (the prover the caller is acting on behalf of)
        address prover = _getEffectiveProver(msg.sender);
        // Check eligibility considering existing pending obligations
        uint256 requiredForBid = uint256(req.fee.minStake) + ((assignedStake[prover] * overcommitBps) / BPS_DENOMINATOR);
        _requireProverEligible(prover, requiredForBid);

        // Increment bid count only for new bids
        if (req.bids[prover] == bytes32(0)) {
            req.bidCount++;
        }

        // Store the sealed bid under the effective prover address
        req.bids[prover] = bidHash;

        // Update unified cumulative stats (carry over previous epoch on first touch)
        ProverStats storage s = _currentCumulativeStats(prover);
        s.bids += 1;
        s.lastActiveAt = uint64(block.timestamp);

        emit NewBid(reqid, prover, bidHash);
    }

    /**
     * @notice Reveal a previously submitted sealed bid
     * @dev Must be called during reveal phase with matching hash
     * @param reqid The request ID that was bid on
     * @param fee The actual fee amount that was hashed
     * @param nonce The nonce that was used in the hash
     */
    function reveal(bytes32 reqid, uint256 fee, uint256 nonce) external override {
        // Advance epoch id if any scheduled epoch start has passed
        _syncStatsEpochId();
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
        address prover = _getEffectiveProver(msg.sender);
        // Check eligibility considering existing pending obligations
        uint256 requiredForReveal =
            uint256(req.fee.minStake) + ((assignedStake[prover] * overcommitBps) / BPS_DENOMINATOR);
        _requireProverEligible(prover, requiredForReveal);

        // Verify the revealed bid matches the hash
        // Commitment binds to request id and effective prover to prevent hash-copy front-running
        bytes32 expectedHash = keccak256(abi.encodePacked(reqid, prover, fee, nonce));
        if (req.bids[prover] != expectedHash) {
            revert MarketBidRevealMismatch(expectedHash, req.bids[prover]);
        }
        if (fee > req.fee.maxFee) revert MarketFeeExceedsMaximum(fee, req.fee.maxFee);

        // Update lowest and second lowest bidders
        _updateBidders(reqid, prover, fee);

        // Update unified cumulative stats
        ProverStats storage s = _currentCumulativeStats(prover);
        s.reveals += 1;
        s.lastActiveAt = uint64(block.timestamp);

        emit BidRevealed(reqid, prover, fee);
    }

    /**
     * @notice Submit proof for a request and claim payment
     * @dev Only winning bidder can submit, proof must be valid, deadline must not be passed
     * @param reqid The request ID to fulfill
     * @param proof The zk proof as uint256[8] array
     */
    function submitProof(bytes32 reqid, uint256[8] calldata proof) external override nonReentrant {
        // Advance epoch id if any scheduled epoch start has passed
        _syncStatsEpochId();
        ReqState storage req = requests[reqid];

        // Validate timing and authorization
        uint256 revealEndTime = req.timestamp + biddingPhaseDuration + revealPhaseDuration;
        if (block.timestamp <= revealEndTime) {
            revert MarketRevealPhaseNotEnded(block.timestamp, revealEndTime);
        }
        if (block.timestamp > req.fee.deadline) revert MarketDeadlinePassed(block.timestamp, req.fee.deadline);

        // Check if msg.sender is authorized to act on behalf of the winning prover
        address prover = _getEffectiveProver(msg.sender);
        if (prover != req.winner.prover) revert MarketNotExpectedProver(req.winner.prover, msg.sender);

        if (req.status != ReqStatus.Pending) revert MarketInvalidRequestStatus(req.status);

        // Verify the proof against the configured verifier version
        IPicoVerifier verifier = picoVerifiers[req.version];
        if (address(verifier) == address(0)) revert MarketVerifierVersionNotSet(req.version);
        verifier.verifyPicoProof(req.vk, req.publicValuesDigest, proof);

        // Update request state. Proof data is emitted via event for off-chain indexing.
        req.status = ReqStatus.Fulfilled;
        // Release any reserved obligation for this request as it has been fulfilled successfully
        _releaseObligation(req);

        // Calculate and distribute fees
        uint256 actualFee = uint256(req.second.fee); // Reverse second-price auction: winner pays second-lowest bid
        if (req.second.prover == address(0)) {
            // Only one bidder - use their bid
            actualFee = uint256(req.winner.fee);
        }

        // Calculate protocol fee
        uint256 protocolFee = (actualFee * protocolFeeBps) / BPS_DENOMINATOR;
        uint256 proverReward = actualFee - protocolFee;

        // Accumulate protocol fee
        if (protocolFee > 0) {
            cumulativeProtocolFee += protocolFee;
        }

        // Send remaining fee to staking controller as reward for the prover
        if (proverReward > 0) {
            stakingController.addRewards(prover, proverReward);
            // Track rewards cumulatively
            ProverStats storage s = _currentCumulativeStats(prover);
            s.feeReceived += proverReward;
        }

        // Refund remaining fee to requester
        feeToken.safeTransfer(req.sender, uint256(req.fee.maxFee) - actualFee);

        // Update cumulative performance stats: successful fulfillment only
        ProverStats storage s2 = _currentCumulativeStats(prover);
        s2.requestsFulfilled += 1;
        s2.lastActiveAt = uint64(block.timestamp);

        // Update global stats: fulfilled count and total fees
        GlobalStats storage gs2 = _currentCumulativeGlobalStats();
        gs2.totalFulfilled += 1;
        gs2.totalFees += proverReward;

        proverPendingRequests[prover].remove(reqid);
        senderPendingRequests[req.sender].remove(reqid);

        emit ProofSubmitted(reqid, prover, proof, actualFee);
    }

    /**
     * @notice Refund a request that cannot be fulfilled
     * @dev Can be called by anyone in these scenarios:
     *      1. After deadline passes without fulfillment
     *      2. After bidding phase ends with no bids submitted
     *      3. After reveal phase ends with no bids revealed (winner not set)
     * @param reqid The request ID to refund
     */
    function refund(bytes32 reqid) public override nonReentrant {
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
        feeToken.safeTransfer(req.sender, uint256(req.fee.maxFee));
        // Release any reserved obligation tied to this request upon refund
        _releaseObligation(req);

        // If deadline passed and there was a final winner, count a missed assignment for that prover
        if (block.timestamp > req.fee.deadline && req.winner.prover != address(0)) {
            ProverStats storage sMiss = _currentCumulativeStats(req.winner.prover);
            sMiss.requestsRefunded += 1;
            proverPendingRequests[req.winner.prover].remove(reqid);
        }
        senderPendingRequests[req.sender].remove(reqid);

        emit Refunded(reqid, req.sender, req.fee.maxFee);
    }

    /**
     * @notice Batch refund multiple requests
     * @param reqids The array of request IDs to refund
     */
    function batchRefund(bytes32[] calldata reqids) external override {
        for (uint256 i = 0; i < reqids.length; i++) {
            refund(reqids[i]);
        }
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
        // Update status to prevent double slashing
        req.status = ReqStatus.Slashed;

        // Must be after deadline
        if (block.timestamp <= req.fee.deadline) revert MarketBeforeDeadline(block.timestamp, req.fee.deadline);
        // Must have an assigned prover to slash
        if (req.winner.prover == address(0)) revert MarketNoAssignedProverToSlash(reqid);
        // Must be within slash window
        if (block.timestamp > req.fee.deadline + slashWindow) {
            revert MarketSlashWindowExpired(block.timestamp, req.fee.deadline + slashWindow);
        }

        // Calculate slash amount
        uint256 slashAmount = (uint256(req.fee.minStake) * slashBps) / BPS_DENOMINATOR;
        // Perform the slash
        stakingController.slashByAmount(req.winner.prover, slashAmount);
        emit ProverSlashed(reqid, req.winner.prover, slashAmount);
    }

    // =========================================================================
    // ADMIN FUNCTIONS
    // =========================================================================

    /**
     * @notice Update the PicoVerifier implementation for a specific version
     * @param version The verifier version to update
     * @param newVerifier The new PicoVerifier contract address
     */
    function setPicoVerifier(uint32 version, IPicoVerifier newVerifier) external override onlyOwner {
        if (address(newVerifier) == address(0)) revert MarketZeroAddress();
        IPicoVerifier oldVerifier = picoVerifiers[version];
        picoVerifiers[version] = newVerifier;
        emit PicoVerifierUpdated(version, address(oldVerifier), address(newVerifier));
    }

    /**
     * @notice Update the bidding phase duration
     * @param newDuration New duration in seconds for bidding phase
     */
    function setBiddingPhaseDuration(uint64 newDuration) external override onlyOwner {
        uint64 oldDuration = biddingPhaseDuration;
        biddingPhaseDuration = newDuration;
        emit BiddingPhaseDurationUpdated(oldDuration, newDuration);
    }

    /**
     * @notice Update the reveal phase duration
     * @param newDuration New duration in seconds for reveal phase
     */
    function setRevealPhaseDuration(uint64 newDuration) external override onlyOwner {
        uint64 oldDuration = revealPhaseDuration;
        revealPhaseDuration = newDuration;
        emit RevealPhaseDurationUpdated(oldDuration, newDuration);
    }

    /**
     * @notice Update the minimum fee
     * @param newMinFee New minimum fee amount
     */
    function setMinMaxFee(uint256 newMinFee) external override onlyOwner {
        uint256 oldFee = minMaxFee;
        minMaxFee = newMinFee;
        emit MinMaxFeeUpdated(oldFee, newMinFee);
    }

    /**
     * @notice Update the maximum fee
     * @param newMaxFee New maximum fee amount
     */
    function setMaxMaxFee(uint256 newMaxFee) external override onlyOwner {
        uint256 oldFee = maxMaxFee;
        maxMaxFee = newMaxFee;
        emit MaxMaxFeeUpdated(oldFee, newMaxFee);
    }

    /**
     * @notice Update the slash percentage for penalizing non-performing provers
     * @param newBps New slash percentage in basis points (0-10000)
     */
    function setSlashBps(uint256 newBps) external override onlyOwner {
        if (newBps > BPS_DENOMINATOR) revert MarketInvalidBps();
        uint256 oldBps = slashBps;
        slashBps = newBps;
        emit SlashBpsUpdated(oldBps, newBps);
    }

    /**
     * @notice Update the slash window duration
     * @param newWindow New slash window duration in seconds
     */
    function setSlashWindow(uint256 newWindow) external override onlyOwner {
        uint256 oldWindow = slashWindow;
        slashWindow = newWindow;
        emit SlashWindowUpdated(oldWindow, newWindow);
    }

    /**
     * @notice Update the protocol fee percentage
     * @param newBps New protocol fee percentage in basis points (0-10000)
     */
    function setProtocolFeeBps(uint256 newBps) external override onlyOwner {
        if (newBps > BPS_DENOMINATOR) revert MarketInvalidBps();
        uint256 oldBps = protocolFeeBps;
        protocolFeeBps = newBps;
        emit ProtocolFeeBpsUpdated(oldBps, newBps);
    }

    /**
     * @notice Update the reserve basis points used for overcommitment checks
     * @param newBps New reserve percentage in basis points (0-10000)
     */
    function setOvercommitBps(uint256 newBps) external onlyOwner {
        if (newBps > BPS_DENOMINATOR) revert MarketInvalidBps();
        uint256 old = overcommitBps;
        overcommitBps = newBps;
        emit OvercommitBpsUpdated(old, newBps);
    }

    /**
     * @notice Withdraw accumulated protocol fees
     * @param to Address to send the fees to
     */
    function withdrawProtocolFee(address to) external override onlyOwner {
        if (to == address(0)) revert MarketZeroAddress();
        uint256 available = cumulativeProtocolFee - withdrawnProtocolFee;
        if (available == 0) revert MarketNoProtocolFeeToWithdraw();

        withdrawnProtocolFee = cumulativeProtocolFee;

        feeToken.safeTransfer(to, available);
        emit ProtocolFeeWithdrawn(to, available);
    }

    // =========================================================================
    // REQUEST QUERY FUNCTIONS
    // =========================================================================

    /**
     * @notice Get complete request information
     * @param reqid The request ID to query
     * @return status Current request status (Pending/Fulfilled/Refunded/Slashed)
     * @return timestamp Request creation timestamp
     * @return sender Original requester address
     * @return maxFee Maximum fee willing to pay
     * @return minStake Minimum stake required for bidders
     * @return deadline Proof submission deadline
     * @return vk Verification key commitment
     * @return publicValuesDigest Digest of public inputs tied to the proof
     * @return version Pico verifier version required to validate this request
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
            bytes32 publicValuesDigest,
            uint32 version
        )
    {
        ReqState storage req = requests[reqid];
        return (
            req.status,
            req.timestamp,
            req.sender,
            uint256(req.fee.maxFee),
            uint256(req.fee.minStake),
            req.fee.deadline,
            req.vk,
            req.publicValuesDigest,
            req.version
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
        return (req.winner.prover, uint256(req.winner.fee), req.second.prover, uint256(req.second.fee));
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
     * @return balance Available protocol fee balance (cumulative - withdrawn)
     */
    function getProtocolFeeInfo() external view override returns (uint256 feeBps, uint256 balance) {
        return (protocolFeeBps, cumulativeProtocolFee - withdrawnProtocolFee);
    }

    /**
     * @notice Get pending requests for a specific prover
     * @param prover The prover address to query
     * @return reqids Array of pending request IDs for the prover
     */
    function getProverPendingRequests(address prover) external view override returns (bytes32[] memory reqids) {
        EnumerableSet.Bytes32Set storage set = proverPendingRequests[prover];
        uint256 len = set.length();
        reqids = new bytes32[](len);
        for (uint256 i = 0; i < len; i++) {
            reqids[i] = set.at(i);
        }
    }

    /**
     * @notice Get pending requests for a specific sender
     * @param sender The sender address to query
     * @return reqids Array of pending request IDs for the sender
     */
    function getSenderPendingRequests(address sender) external view override returns (bytes32[] memory reqids) {
        EnumerableSet.Bytes32Set storage set = senderPendingRequests[sender];
        uint256 len = set.length();
        reqids = new bytes32[](len);
        for (uint256 i = 0; i < len; i++) {
            reqids[i] = set.at(i);
        }
    }

    // =========================================================================
    // INTERNAL FUNCTIONS
    // =========================================================================

    /**
     * @notice Update the two lowest bidders for a request
     * @dev Maintains sorted order of winner and second-place bidders
     * @param reqid The request ID to update
     * @param prover Address of the prover making the bid
     * @param fee Fee amount being bid
     */
    function _updateBidders(bytes32 reqid, address prover, uint256 fee) internal {
        ReqState storage req = requests[reqid];

        address prevWinner = req.winner.prover;
        uint96 fee96 = uint96(fee);

        // If no bidders yet, or this is lower than current winner
        if (req.winner.prover == address(0) || fee < uint256(req.winner.fee)) {
            // Move current winner to second place
            req.second = req.winner;
            // Set new winner
            req.winner = Bidder({prover: prover, fee: fee96});
        }
        // If this is lower than second place (but not winner)
        else if (req.second.prover == address(0) || fee < uint256(req.second.fee)) {
            req.second = Bidder({prover: prover, fee: fee96});
        }

        // Adjust pending obligations on winner change (no longer track instantaneous `wins`)
        address newWinner = req.winner.prover;
        if (newWinner != prevWinner) {
            _reassignObligation(req, prevWinner, newWinner);
            proverPendingRequests[prover].add(reqid);
            if (prevWinner != address(0)) {
                proverPendingRequests[prevWinner].remove(reqid);
            }
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

    /**
     * @notice Internal utility to reassign obligation on winner change
     * @param req Storage reference to the request state
     * @param prevWinner Address of the previous winner
     * @param newWinner Address of the new winner
     */
    function _reassignObligation(ReqState storage req, address prevWinner, address newWinner) internal {
        uint256 ms = uint256(req.fee.minStake);
        if (prevWinner != address(0)) {
            if (assignedStake[prevWinner] >= ms) {
                assignedStake[prevWinner] -= ms;
            } else {
                assignedStake[prevWinner] = 0;
            }
        }
        if (newWinner != address(0)) {
            assignedStake[newWinner] += ms;
        }
    }

    /**
     * @notice Internal utility to release obligation on request finalization
     * @param req Storage reference to the request state
     */
    function _releaseObligation(ReqState storage req) internal {
        address p = req.winner.prover;
        if (p != address(0)) {
            uint256 ms = uint256(req.fee.minStake);
            if (assignedStake[p] >= ms) {
                assignedStake[p] -= ms;
            } else {
                assignedStake[p] = 0;
            }
        }
    }

    // =========================================================================
    // STATS VIEW & ADMIN
    // =========================================================================

    /**
     * @notice Reset stats window start and bump epoch id
     * @param startAt New start timestamp (0 = now)
     */
    function scheduleStatsEpoch(uint64 startAt) external override onlyRole(EPOCH_UPDATER_ROLE) {
        uint64 s = startAt == 0 ? uint64(block.timestamp) : startAt;
        // Validate strictly increasing start times
        if (statsEpochs.length > 0) {
            uint64 lastStart = statsEpochs[statsEpochs.length - 1].startAt;
            if (s <= lastStart) revert MarketInvalidStatsEpochStart(lastStart, s);
            // Set previous epoch's endAt immediately to the new start (can be in the future)
            statsEpochs[statsEpochs.length - 1].endAt = s;
        }
        // Append new epoch with endAt unset (0)
        statsEpochs.push(StatsEpochInfo({startAt: s, endAt: 0}));
        emit StatsEpochScheduled(s);
        // If start is now or earlier (only possible when startAt==0 -> now), advance immediately
        if (s <= uint64(block.timestamp)) {
            _syncStatsEpochId();
        }
    }

    /**
     * @notice Pop the last scheduled stats-epoch if it has not started yet
     * @dev Restores the previous epoch's endAt to 0. Does not modify statsEpochId.
     */
    function popStatsEpoch() external override onlyRole(EPOCH_UPDATER_ROLE) {
        uint256 len = statsEpochs.length;
        // Must have at least two epochs to pop a future one; never remove the initial epoch
        if (len <= 1) revert MarketNoFutureEpochToPop();
        StatsEpochInfo memory last = statsEpochs[len - 1];
        // Only pop if the last epoch hasn't started yet
        if (last.startAt <= uint64(block.timestamp)) {
            revert MarketCannotPopStartedEpoch(last.startAt, uint64(block.timestamp));
        }
        // Restore previous epoch's endAt to 0 (ongoing or pending next future epoch)
        statsEpochs[len - 2].endAt = 0;
        // Remove the last epoch
        statsEpochs.pop();
        emit StatsEpochPopped(last.startAt);
    }

    /**
     * @notice Get lifetime (cumulative) stats for a prover
     */
    function getProverStatsTotal(address prover) external view override returns (ProverStats memory) {
        uint64 eid = statsEpochId;
        ProverStats memory cur = proverStats[prover][eid];
        if (eid == 0) return cur;
        // If current epoch snapshot hasn't been initialized for this prover, fall back to previous.
        // We use lastActiveAt value to detect an initialized snapshot.
        if (cur.lastActiveAt == 0) {
            return proverStats[prover][eid - 1];
        }
        return cur;
    }

    /**
     * @notice Get recent stats (current epoch) for a prover
     */
    function getProverRecentStats(address prover)
        external
        view
        override
        returns (ProverStats memory stats, uint64 startAt)
    {
        uint64 eid = statsEpochId;
        ProverStats memory cur = proverStats[prover][eid];
        ProverStats memory prev = eid > 0 ? proverStats[prover][eid - 1] : _zeroStats();
        return (_diffStats(cur, prev), statsEpochs[eid].startAt);
    }

    /**
     * @notice Get recent stats epoch info
     */
    function getRecentStatsInfo() external view override returns (uint64 startAt, uint64 epochId) {
        return (statsEpochs[statsEpochId].startAt, statsEpochId);
    }

    /**
     * @notice Get stats for a prover for a specific epoch id
     */
    function getProverStatsForStatsEpoch(address prover, uint64 epochId)
        external
        view
        override
        returns (ProverStats memory stats, uint64 startAt, uint64 endAt)
    {
        ProverStats memory cur = proverStats[prover][epochId];
        ProverStats memory prev = epochId > 0 ? proverStats[prover][epochId - 1] : _zeroStats();
        return (_diffStats(cur, prev), statsEpochs[epochId].startAt, statsEpochs[epochId].endAt);
    }

    /**
     * @notice Get lifetime (cumulative) global stats
     */
    function getGlobalStatsTotal() external view override returns (GlobalStats memory) {
        uint64 eid = statsEpochId;
        GlobalStats memory cur = globalStats[eid];
        if (eid == 0) return cur;
        // Use totalRequests value to detect an initialized snapshot
        if (cur.totalRequests == 0) {
            return globalStats[eid - 1];
        }
        return cur;
    }

    /**
     * @notice Get recent (current epoch) global stats and start time
     */
    function getGlobalRecentStats() external view override returns (GlobalStats memory stats, uint64 startAt) {
        uint64 eid = statsEpochId;
        GlobalStats memory cur = globalStats[eid];
        GlobalStats memory prev = eid > 0 ? globalStats[eid - 1] : _zeroGlobalStats();
        return (_diffGlobalStats(cur, prev), statsEpochs[eid].startAt);
    }

    /**
     * @notice Get global stats for a specific epoch id
     */
    function getGlobalStatsForStatsEpoch(uint64 epochId)
        external
        view
        override
        returns (GlobalStats memory stats, uint64 startAt, uint64 endAt)
    {
        GlobalStats memory cur = globalStats[epochId];
        GlobalStats memory prev = epochId > 0 ? globalStats[epochId - 1] : _zeroGlobalStats();
        return (_diffGlobalStats(cur, prev), statsEpochs[epochId].startAt, statsEpochs[epochId].endAt);
    }

    /**
     * @notice Get the number of scheduled stats-epochs
     */
    function statsEpochsLength() external view override returns (uint256) {
        return statsEpochs.length;
    }

    /**
     * @notice If a future epoch was scheduled and its start time has passed, roll over to the new epoch
     * @dev This is invoked lazily by stats-mutating functions (bid/reveal/submitProof)
     */
    function _syncStatsEpochId() internal {
        // If a future epoch has been appended and its start time has arrived, advance statsEpochId
        // Multiple scheduled epochs can be advanced in sequence if time has progressed far
        while (statsEpochId + 1 < statsEpochs.length) {
            uint64 nextStart = statsEpochs[statsEpochId + 1].startAt;
            if (uint64(block.timestamp) < nextStart) break;
            // Advance to next epoch. Note: previous epoch's endAt is set during scheduling.
            statsEpochId += 1;
            emit StatsReset(statsEpochId, statsEpochs[statsEpochId].startAt);
        }
    }

    /**
     * @notice Ensure the current epoch cumulative stats are initialized by carrying over previous epoch values
     */
    function _currentCumulativeStats(address prover) internal returns (ProverStats storage s) {
        uint64 eid = statsEpochId;
        s = proverStats[prover][eid];
        if (eid > 0 && s.lastActiveAt == 0) {
            ProverStats storage prev = proverStats[prover][eid - 1];
            // Copy forward if the previous snapshot was initialized.
            // Sentinel: prev.lastActiveAt != 0. See rationale in getProverStatsTotal.
            if (prev.lastActiveAt != 0) {
                s.bids = prev.bids;
                s.reveals = prev.reveals;
                s.requestsFulfilled = prev.requestsFulfilled;
                s.requestsRefunded = prev.requestsRefunded;
                s.feeReceived = prev.feeReceived;
                s.lastActiveAt = prev.lastActiveAt;
            }
        }
    }

    function _zeroStats() internal pure returns (ProverStats memory z) {
        return z;
    }

    function _diffStats(ProverStats memory cur, ProverStats memory prev) internal pure returns (ProverStats memory d) {
        d.bids = cur.bids >= prev.bids ? cur.bids - prev.bids : 0;
        d.reveals = cur.reveals >= prev.reveals ? cur.reveals - prev.reveals : 0;
        d.requestsFulfilled =
            cur.requestsFulfilled >= prev.requestsFulfilled ? cur.requestsFulfilled - prev.requestsFulfilled : 0;
        d.requestsRefunded =
            cur.requestsRefunded >= prev.requestsRefunded ? cur.requestsRefunded - prev.requestsRefunded : 0;
        d.feeReceived = cur.feeReceived >= prev.feeReceived ? cur.feeReceived - prev.feeReceived : 0;
        // lastActiveAt: show cur.lastActiveAt only if there was activity in the interval; else 0
        if (d.bids != 0 || d.reveals != 0 || d.requestsFulfilled != 0 || d.requestsRefunded != 0 || d.feeReceived != 0)
        {
            d.lastActiveAt = cur.lastActiveAt;
        } else {
            d.lastActiveAt = 0;
        }
    }

    // ===== Global stats helpers =====
    function _currentCumulativeGlobalStats() internal returns (GlobalStats storage s) {
        uint64 eid = statsEpochId;
        s = globalStats[eid];
        if (eid > 0 && s.totalRequests == 0 && s.totalFulfilled == 0 && s.totalFees == 0) {
            GlobalStats storage prev = globalStats[eid - 1];
            if (prev.totalRequests != 0 || prev.totalFulfilled != 0 || prev.totalFees != 0) {
                s.totalRequests = prev.totalRequests;
                s.totalFulfilled = prev.totalFulfilled;
                s.totalFees = prev.totalFees;
            }
        }
    }

    function _zeroGlobalStats() internal pure returns (GlobalStats memory z) {
        return z;
    }

    function _diffGlobalStats(GlobalStats memory cur, GlobalStats memory prev)
        internal
        pure
        returns (GlobalStats memory d)
    {
        d.totalRequests = cur.totalRequests >= prev.totalRequests ? cur.totalRequests - prev.totalRequests : 0;
        d.totalFulfilled = cur.totalFulfilled >= prev.totalFulfilled ? cur.totalFulfilled - prev.totalFulfilled : 0;
        d.totalFees = cur.totalFees >= prev.totalFees ? cur.totalFees - prev.totalFees : 0;
    }
}
