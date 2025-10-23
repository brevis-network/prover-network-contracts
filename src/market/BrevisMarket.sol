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

    // Stats-epoch metadata (start/end times). endAt = 0 means ongoing epoch.
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
    uint256 public protocolFeeBalance; // accumulated protocol fees

    // External contracts
    IPicoVerifier public picoVerifier; // address of the PicoVerifier contract
    IERC20 public feeToken; // ERC20 token used for fees

    // Core data structures
    mapping(bytes32 => ReqState) public requests; // proof req id -> state

    mapping(address => ProverStats) public proverStats; // prover address -> stats

    // Historical stats per stats-epoch: prover => epochId => stats snapshot
    // Populated lazily when a prover's window rolls over to a new epoch
    mapping(address => mapping(uint64 => ProverStats)) public proverStatsByEpoch;

    // Stats-epoch metadata history as an ordered array (epochId == index)
    StatsEpochInfo[] public statsEpochs;

    // Current epoch id (index into statsEpochs). Advanced lazily on activity.
    uint64 public statsEpochId;

    // Sum of minStake across all assigned-but-unfinalized requests per prover.
    // checking eligibility: required = req.minStake + assignedStake[prover] * overcommitBps / 10_000.
    mapping(address => uint256) public assignedStake;

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
            // Initialize stats epochs for direct deployments
            statsEpochs.push(StatsEpochInfo({startAt: uint64(block.timestamp), endAt: 0}));
            statsEpochId = 0;
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
        // Initialize stats epochs
        statsEpochs.push(StatsEpochInfo({startAt: uint64(block.timestamp), endAt: 0}));
        statsEpochId = 0;
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

        // Default reserve to 5%
        overcommitBps = 500;
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
        if (maxMaxFee > 0 && req.fee.maxFee > maxMaxFee) revert MarketMaxFeeTooHigh(req.fee.maxFee, maxMaxFee);

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
        uint256 requiredForBid = req.fee.minStake + ((assignedStake[prover] * overcommitBps) / BPS_DENOMINATOR);
        _requireProverEligible(prover, requiredForBid);

        // Track if this is a new bid (not overwriting existing)
        bool isNewBid = req.bids[prover] == bytes32(0);

        // Store the sealed bid under the effective prover address
        req.bids[prover] = bidHash;

        // Increment bid count only for new bids
        if (isNewBid) {
            req.bidCount++;
        }

        // Update prover activity stats
        proverStats[prover].bids += 1;
        proverStats[prover].lastActiveAt = uint64(block.timestamp);
        ProverStats storage epochStats = _epochStats(prover);
        epochStats.bids += 1;
        epochStats.lastActiveAt = uint64(block.timestamp);

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
        uint256 requiredForReveal = req.fee.minStake + ((assignedStake[prover] * overcommitBps) / BPS_DENOMINATOR);
        _requireProverEligible(prover, requiredForReveal);

        // Verify the revealed bid matches the hash
        bytes32 expectedHash = keccak256(abi.encodePacked(fee, nonce));
        if (req.bids[prover] != expectedHash) {
            revert MarketBidRevealMismatch(expectedHash, req.bids[prover]);
        }
        if (fee > req.fee.maxFee) revert MarketFeeExceedsMaximum(fee, req.fee.maxFee);

        // Update lowest and second lowest bidders
        _updateBidders(req, prover, fee);

        // Update prover activity stats
        proverStats[prover].reveals += 1;
        proverStats[prover].lastActiveAt = uint64(block.timestamp);
        ProverStats storage epochStats = _epochStats(prover);
        epochStats.reveals += 1;
        epochStats.lastActiveAt = uint64(block.timestamp);

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

        // Verify the proof
        picoVerifier.verifyPicoProof(req.vk, req.publicValuesDigest, proof);

        // Update request state
        req.proof = proof;
        req.status = ReqStatus.Fulfilled;
        // Release any reserved obligation for this request as it has been fulfilled successfully
        _releaseObligation(req);

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
            stakingController.addRewards(prover, proverReward);
            // Track rewards received by prover (lifetime and current stats-epoch)
            proverStats[prover].feeReceived += proverReward;
            _epochStats(prover).feeReceived += proverReward;
        }

        // Refund remaining fee to requester
        feeToken.safeTransfer(req.sender, req.fee.maxFee - actualFee);

        // Update prover performance stats: successful fulfillment only
        proverStats[prover].requestsFulfilled += 1;
        proverStats[prover].lastActiveAt = uint64(block.timestamp);
        ProverStats storage epochStats = _epochStats(prover);
        epochStats.requestsFulfilled += 1;
        epochStats.lastActiveAt = uint64(block.timestamp);

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
        // Release any reserved obligation tied to this request now that it is finalized by slashing
        _releaseObligation(req);
        emit ProverSlashed(reqid, req.winner.prover, slashAmount);
    }

    // =========================================================================
    // ADMIN FUNCTIONS
    // =========================================================================

    /**
     * @notice Update the PicoVerifier contract address
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
        address prevWinner = req.winner.prover;

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

        // Update wins to reflect current assigned winner
        address newWinner = req.winner.prover;
        if (newWinner != prevWinner) {
            // Adjust pending obligations on winner change
            _reassignObligation(req, prevWinner, newWinner);
            if (prevWinner != address(0)) {
                ProverStats storage sPrev = proverStats[prevWinner];
                if (sPrev.wins > 0) sPrev.wins -= 1;
                ProverStats storage wPrev = _epochStats(prevWinner);
                if (wPrev.wins > 0) wPrev.wins -= 1;
            }
            if (newWinner != address(0)) {
                ProverStats storage sNew = proverStats[newWinner];
                sNew.wins += 1;
                ProverStats storage wNew = _epochStats(newWinner);
                wNew.wins += 1;
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
        uint256 ms = req.fee.minStake;
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
            uint256 ms = req.fee.minStake;
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
    function scheduleStatsEpoch(uint64 startAt) external override onlyOwner {
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
    function popStatsEpoch() external override onlyOwner {
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
        return proverStats[prover];
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
        return (proverStatsByEpoch[prover][statsEpochId], statsEpochs[statsEpochId].startAt);
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
        return (proverStatsByEpoch[prover][epochId], statsEpochs[epochId].startAt, statsEpochs[epochId].endAt);
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
     * @notice Return the current epoch's stats storage for a prover
     */
    function _epochStats(address prover) internal view returns (ProverStats storage s) {
        return proverStatsByEpoch[prover][statsEpochId];
    }
}
