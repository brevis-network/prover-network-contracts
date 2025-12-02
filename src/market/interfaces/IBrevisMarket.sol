// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../pico/IPicoVerifier.sol";
import "../../staking/interfaces/IStakingController.sol";

/**
 * @title IBrevisMarket
 * @notice Interface for the decentralized proof marketplace using sealed-bid reverse auctions
 * @dev Uses reverse auction (procurement style) where provers bid lower fees to win
 */
interface IBrevisMarket {
    // =========================================================================
    // ENUMS
    // =========================================================================
    enum ReqStatus {
        Pending,
        Fulfilled,
        Refunded,
        Slashed
    }

    // =========================================================================
    // STRUCTS
    // =========================================================================

    struct FeeParams {
        uint96 maxFee; // maxFee to pay for the proof
        uint96 minStake; // provers must stake >= this to be eligible for bid
        uint64 deadline; // proof need to be submitted by this time in epoch seconds
    }

    struct ProofRequest {
        uint64 nonce; // allow re-submit same data
        bytes32 vk; // verify key for binary
        bytes32 publicValuesDigest; // sha256(publicValues) & bytes32(uint256((1 << 253) - 1)))
        string imgURL; // URL to ELF binary, can be empty if vk is already known to the prover network
        bytes inputData; // input data for the binary, can be empty if inputURL is provided
        string inputURL; // URL to input data, if inputData is not provided
        FeeParams fee;
    }

    struct Bidder {
        address prover;
        uint96 fee;
    }

    struct GlobalStats {
        uint64 totalRequests; // total proof requests made
        uint64 totalFulfilled; // total proof requests fulfilled
        uint256 totalFees; // total fees collected from requesters
    }

    struct ProverStats {
        uint64 bids; // total bids placed
        uint64 reveals; // total bids revealed
        uint64 requestsFulfilled; // total requests successfully fulfilled (proofs delivered)
        uint64 requestsRefunded; // total assigned requests refunded after deadline (missed by the winner)
        uint64 lastActiveAt; // timestamp of last tracked activity
        uint256 feeReceived; // total rewards (after protocol fee) sent to the prover
    }

    // =========================================================================
    // EVENTS
    // =========================================================================

    event NewRequest(bytes32 indexed reqid, ProofRequest req);
    event NewBid(bytes32 indexed reqid, address indexed prover, bytes32 bidHash);
    event BidRevealed(bytes32 indexed reqid, address indexed prover, uint256 fee);
    event ProofSubmitted(bytes32 indexed reqid, address indexed prover, uint256[8] proof, uint256 actualFee);
    event Refunded(bytes32 indexed reqid, address indexed requester, uint256 amount);
    event ProverSlashed(bytes32 indexed reqid, address indexed prover, uint256 slashAmount);
    event PicoVerifierUpdated(address indexed oldVerifier, address indexed newVerifier);
    event BiddingPhaseDurationUpdated(uint64 oldDuration, uint64 newDuration);
    event RevealPhaseDurationUpdated(uint64 oldDuration, uint64 newDuration);
    event MinMaxFeeUpdated(uint256 oldFee, uint256 newFee);
    event MaxMaxFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeTokenUpdated(address indexed oldToken, address indexed newToken);
    event SlashBpsUpdated(uint256 oldBps, uint256 newBps);
    event SlashWindowUpdated(uint256 oldWindow, uint256 newWindow);
    event ProtocolFeeBpsUpdated(uint256 oldBps, uint256 newBps);
    event ProtocolFeeWithdrawn(address indexed to, uint256 amount);
    event StatsReset(uint64 newEpochId, uint64 statsStartAt);
    event StatsEpochScheduled(uint64 scheduledStartAt);
    event StatsEpochPopped(uint64 poppedStartAt);
    event OvercommitBpsUpdated(uint256 oldBps, uint256 newBps);

    // Prover submitter management events
    event SubmitterRegistered(address indexed prover, address indexed submitter);
    event SubmitterUnregistered(address indexed prover, address indexed submitter);
    event SubmitterConsentUpdated(address indexed submitter, address indexed oldProver, address indexed newProver);

    // =========================================================================
    // ERRORS
    // =========================================================================

    error MarketInvalidRequestStatus(ReqStatus status);
    error MarketZeroAddress();
    error MarketInvalidBps();

    // Request errors
    error MarketDeadlineMustBeInFuture();
    error MarketDeadlineTooFar(uint256 deadline, uint256 maxAllowed);
    error MarketDeadlineBeforeRevealPhaseEnd();
    error MarketRequestAlreadyExists(bytes32 reqid);
    error MarketRequestNotFound(bytes32 reqid);
    error MarketMaxFeeTooLow(uint256 provided, uint256 minimum);
    error MarketMaxFeeTooHigh(uint256 provided, uint256 maximum);
    error MarketMinStakeTooLow(uint256 provided, uint256 minimum);

    // Bidding & reveal & submission & refund errors
    error MarketBiddingPhaseEnded(uint256 currentTime, uint256 biddingEndTime);
    error MarketBiddingPhaseNotEnded(uint256 currentTime, uint256 biddingEndTime);
    error MarketRevealPhaseEnded(uint256 currentTime, uint256 revealEndTime);
    error MarketRevealPhaseNotEnded(uint256 currentTime, uint256 revealEndTime);
    error MarketBidRevealMismatch(bytes32 expected, bytes32 actual);
    error MarketFeeExceedsMaximum(uint256 fee, uint256 maxFee);
    error MarketDeadlinePassed(uint256 currentTime, uint256 deadline);
    error MarketNotExpectedProver(address expected, address actual);
    error MarketProverNotEligible(address prover, uint256 requiredStake, uint256 actualStake);
    error MarketCannotRefundYet(uint256 currentTime, uint256 deadline, uint256 biddingEndTime, uint256 revealEndTime);

    // Slashing errors
    error MarketBeforeDeadline(uint256 currentTime, uint256 deadline);
    error MarketInvalidStakingController();
    error MarketSlashWindowExpired(uint256 currentTime, uint256 slashWindowEnd);
    error MarketNoAssignedProverToSlash(bytes32 reqid);

    // Admin errors
    error MarketNoProtocolFeeToWithdraw();
    error MarketInvalidStatsEpochStart(uint64 lastStartAt, uint64 newStartAt);
    error MarketNoFutureEpochToPop();
    error MarketCannotPopStartedEpoch(uint64 startAt, uint64 currentTime);

    // Prover submitter management errors
    error MarketCannotRegisterSelf();
    error MarketProverNotRegistered();
    error MarketSubmitterAlreadyRegistered(address submitter, address prover);
    error MarketSubmitterNotRegistered(address submitter);
    error MarketNotAuthorized();
    error MarketCannotRegisterProverAsSubmitter(address prover);
    error MarketSubmitterConsentRequired(address submitter);

    // =========================================================================
    // PROOF REQUEST MANAGEMENT
    // =========================================================================

    /**
     * @notice Submit a proof request with fee payment
     * @dev Uses reverse second-price auction: lowest bidder wins but pays second-lowest bid
     * @param req The proof request containing all necessary parameters
     * @dev Caller must have approved feeToken for req.fee.maxFee amount
     */
    function requestProof(ProofRequest calldata req) external;

    /**
     * @notice Submit a sealed bid for a proof request
     * @dev In reverse auction: lower fee bids have better chance of winning
     * @param reqid The request ID to bid on
     * @param bidHash Commitment: keccak256(abi.encodePacked(reqid, prover, fee, nonce))
     * @dev Can override previous bids during bidding phase
     */
    function bid(bytes32 reqid, bytes32 bidHash) external;

    /**
     * @notice Reveal a previously submitted sealed bid
     * @dev Must be called during reveal phase with matching commitment
     *      Commitment format: keccak256(abi.encodePacked(reqid, prover, fee, nonce))
     * @param reqid The request ID that was bid on
     * @param fee The actual fee amount that was hashed
     * @param nonce The nonce that was used in the hash
     */
    function reveal(bytes32 reqid, uint256 fee, uint256 nonce) external;

    /**
     * @notice Submit proof for a request and claim payment
     * @dev Only winning bidder can submit, proof must be valid, deadline must not be passed
     * @param reqid The request ID to fulfill
     * @param proof The zk proof as uint256[8] array
     */
    function submitProof(bytes32 reqid, uint256[8] calldata proof) external;

    /**
     * @notice Refund a request that passed its deadline without fulfillment
     * @dev Can be called by anyone after deadline passes, returns maxFee to original requester
     * @param reqid The request ID to refund
     */
    function refund(bytes32 reqid) external;

    /**
     * @notice Batch refund multiple requests
     * @param reqids The array of request IDs to refund
     */
    function batchRefund(bytes32[] calldata reqids) external;

    /**
     * @notice Slash the assigned prover for failing to submit proof within deadline
     * @dev Can be called by anyone within slash window after deadline passes
     * @param reqid The request ID for which to slash the assigned prover
     */
    function slash(bytes32 reqid) external;

    // =========================================================================
    // ADMIN FUNCTIONS
    // =========================================================================

    /**
     * @notice Update the PicoVerifier contract address
     * @dev Only owner can call this function
     * @param newVerifier The new PicoVerifier contract address
     */
    function setPicoVerifier(IPicoVerifier newVerifier) external;

    /**
     * @notice Update the bidding phase duration
     * @dev Only owner can call this function
     * @param newDuration New duration in seconds for bidding phase
     */
    function setBiddingPhaseDuration(uint64 newDuration) external;

    /**
     * @notice Update the reveal phase duration
     * @dev Only owner can call this function
     * @param newDuration New duration in seconds for reveal phase
     */
    function setRevealPhaseDuration(uint64 newDuration) external;

    /**
     * @notice Update the minimum fee
     * @dev Only owner can call this function
     * @param newMinFee New minimum fee amount
     */
    function setMinMaxFee(uint256 newMinFee) external;

    /**
     * @notice Update the maximum fee
     * @dev Only owner can call this function
     * @param newMaxFee New maximum fee amount
     */
    function setMaxMaxFee(uint256 newMaxFee) external;

    /**
     * @notice Update the slash percentage for penalizing non-performing provers
     * @dev Only owner can call this function
     * @param newBps New slash percentage in basis points (0-10000)
     */
    function setSlashBps(uint256 newBps) external;

    /**
     * @notice Update the slash window duration
     * @dev Only owner can call this function
     * @param newWindow New slash window duration in seconds
     */
    function setSlashWindow(uint256 newWindow) external;

    /**
     * @notice Update the protocol fee percentage
     * @dev Only owner can call this function
     * @param newBps New protocol fee percentage in basis points (0-10000)
     */
    function setProtocolFeeBps(uint256 newBps) external;

    /**
     * @notice Update the overcommit protection basis points
     * @dev Only owner can call this function
     * @param newBps New overcommit basis points (0-10000)
     */
    function setOvercommitBps(uint256 newBps) external;

    /**
     * @notice Withdraw accumulated protocol fees
     * @dev Only owner can call this function
     * @param to Address to send the fees to
     */
    function withdrawProtocolFee(address to) external;

    // =========================================================================
    // VIEW FUNCTIONS
    // =========================================================================

    /**
     * @notice Get the current bidding phase duration
     * @return duration Duration in seconds
     */
    function biddingPhaseDuration() external view returns (uint64 duration);

    /**
     * @notice Get the current reveal phase duration
     * @return duration Duration in seconds
     */
    function revealPhaseDuration() external view returns (uint64 duration);

    /**
     * @notice Get the PicoVerifier contract address
     * @return verifier The PicoVerifier contract address
     */
    function picoVerifier() external view returns (IPicoVerifier verifier);

    /**
     * @notice Get the fee token contract address
     * @return token The ERC20 fee token contract address
     */
    function feeToken() external view returns (IERC20 token);

    /**
     * @notice Get the StakingController contract address
     * @return controller The StakingController contract address
     */
    function stakingController() external view returns (IStakingController controller);

    /**
     * @notice Get the maximum deadline duration constant
     * @return duration Maximum deadline duration in seconds
     */
    function MAX_DEADLINE_DURATION() external view returns (uint256 duration);

    /**
     * @notice Get the minimum fee
     * @return fee Minimum fee amount
     */
    function minMaxFee() external view returns (uint256 fee);

    /**
     * @notice Get the protocol fee percentage and balance
     * @return feeBps Protocol fee percentage in basis points
     * @return balance Accumulated protocol fee balance
     */
    function getProtocolFeeInfo() external view returns (uint256 feeBps, uint256 balance);

    /**
     * @notice Get pending request IDs for a specific prover
     * @param prover The prover address to query
     * @return reqids Array of pending request IDs
     */
    function getProverPendingRequests(address prover) external view returns (bytes32[] memory reqids);

    /**
     * @notice Get pending request IDs for a specific sender
     * @param sender The sender address to query
     * @return reqids Array of pending request IDs
     */
    function getSenderPendingRequests(address sender) external view returns (bytes32[] memory reqids);

    // =========================================================================
    // REQUEST QUERY FUNCTIONS
    // =========================================================================

    /**
     * @notice Public getter for the requests mapping
     * @dev Mirrors the automatically generated public getter in the implementation.
     * @param reqid The request ID to query
     * @return status Current request status
     * @return timestamp Creation timestamp
     * @return sender Original requester
     * @return fee Fee parameters (maxFee, minStake, deadline)
     * @return vk Verification key
     * @return publicValuesDigest Public values hash
     * @return bidCount Number of sealed bids submitted
     * @return winner Current winner tuple (prover, fee)
     * @return second Current second-place tuple (prover, fee)
     */
    function requests(bytes32 reqid)
        external
        view
        returns (
            ReqStatus status,
            uint64 timestamp,
            address sender,
            FeeParams memory fee,
            bytes32 vk,
            bytes32 publicValuesDigest,
            uint64 bidCount,
            Bidder memory winner,
            Bidder memory second
        );

    /**
     * @notice Get basic request information
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
        returns (
            ReqStatus status,
            uint64 timestamp,
            address sender,
            uint256 maxFee,
            uint256 minStake,
            uint64 deadline,
            bytes32 vk,
            bytes32 publicValuesDigest
        );

    /**
     * @notice Get winning bidders for a request
     * @dev In reverse auction: winner = lowest bidder, actual payment = second-lowest bid
     * @param reqid The request ID to query
     * @return winner Lowest bidder (winner) address
     * @return winnerFee Winning bid amount (lowest bid)
     * @return secondPlace Second lowest bidder address
     * @return secondFee Second lowest bid amount (actual payment in reverse second-price auction)
     */
    function getBidders(bytes32 reqid)
        external
        view
        returns (address winner, uint256 winnerFee, address secondPlace, uint256 secondFee);

    /**
     * @notice Get sealed bid hash for a specific prover
     * @param reqid The request ID to query
     * @param prover The prover address to query
     * @return bidHash The sealed bid hash (empty if no bid submitted)
     */
    function getBidHash(bytes32 reqid, address prover) external view returns (bytes32 bidHash);

    // =========================================================================
    // PROVER SUBMITTER MANAGEMENT
    // =========================================================================

    /**
     * @notice Register a submitter address that can submit proofs on behalf of the prover
     * @dev Only the prover can register submitters for themselves
     * @param submitter The address to register as a submitter
     */
    function registerSubmitter(address submitter) external;

    /**
     * @notice Unregister a submitter address
     * @dev Only the prover can unregister their own submitters
     * @param submitter The address to unregister
     */
    function unregisterSubmitter(address submitter) external;

    /**
     * @notice Get the prover address for a given submitter
     * @param submitter The submitter address
     * @return prover The prover address, or address(0) if not registered
     */
    function submitterToProver(address submitter) external view returns (address prover);

    /**
     * @notice Get all registered submitters for a prover
     * @param prover The prover address
     * @return submitters Array of submitter addresses
     */
    function getSubmittersForProver(address prover) external view returns (address[] memory submitters);

    /**
     * @notice Set consent to be registered as a submitter by a specific prover
     * @param prover The prover address to grant consent to, or address(0) to revoke consent
     */
    function setSubmitterConsent(address prover) external;

    // =========================================================================
    // STATS VIEW & ADMIN
    // =========================================================================

    /**
     * @notice Schedule or start a new stats-epoch
     * @param startAt New epoch start timestamp (0 = now). Must be strictly greater than the last scheduled start.
     */
    function scheduleStatsEpoch(uint64 startAt) external;

    /**
     * @notice Pop the most recently scheduled stats-epoch if it has not started yet
     * @dev Only affects the last appended epoch; restores previous epoch's endAt to 0
     */
    function popStatsEpoch() external;

    /**
     * @notice Get lifetime (cumulative) stats for a prover
     */
    function getProverStatsTotal(address prover) external view returns (ProverStats memory);

    /**
     * @notice Get recent (since last reset) stats for a prover
     * @return stats Recent stats for the prover
     * @return startAt Timestamp when the recent stats epoch started
     */
    function getProverRecentStats(address prover) external view returns (ProverStats memory stats, uint64 startAt);

    /**
     * @notice Get current recent stats epoch metadata
     * @return startAt Epoch start timestamp
     * @return epochId Current epoch identifier
     */
    function getRecentStatsInfo() external view returns (uint64 startAt, uint64 epochId);

    /**
     * @notice Current epoch id (index into statsEpochs)
     * @dev Mirrors the public variable in the implementation for interface-only access
     */
    function statsEpochId() external view returns (uint64 epochId);

    /**
     * @notice Get stats-epoch metadata by index
     * @dev Mirrors the public array getter in the implementation for interface-only access
     * @param index Epoch index
     * @return startAt Epoch start timestamp
     * @return endAt Epoch end timestamp; 0 indicates the tail (last scheduled) epoch
     */
    function statsEpochs(uint256 index) external view returns (uint64 startAt, uint64 endAt);

    /**
     * @notice Get the number of scheduled epochs
     */
    function statsEpochsLength() external view returns (uint256);

    /**
     * @notice Get a prover's stats for a specific epoch along with epoch start/end
     * @return stats Prover's stats in the epoch
     * @return startAt Epoch start timestamp
     * @return endAt Epoch end timestamp; 0 indicates the tail (last scheduled) epoch
     */
    function getProverStatsForStatsEpoch(address prover, uint64 epochId)
        external
        view
        returns (ProverStats memory stats, uint64 startAt, uint64 endAt);

    // =========================================================================
    // GLOBAL STATS VIEW
    // =========================================================================

    /**
     * @notice Get lifetime (cumulative) global stats across all provers
     */
    function getGlobalStatsTotal() external view returns (GlobalStats memory);

    /**
     * @notice Get recent (current epoch) global stats and its start time
     */
    function getGlobalRecentStats() external view returns (GlobalStats memory stats, uint64 startAt);

    /**
     * @notice Get global stats for a specific epoch id along with epoch metadata
     */
    function getGlobalStatsForStatsEpoch(uint64 epochId)
        external
        view
        returns (GlobalStats memory stats, uint64 startAt, uint64 endAt);
}
