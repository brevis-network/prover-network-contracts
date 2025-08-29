// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../pico/IPicoVerifier.sol";
import "../staking/interfaces/IStakingController.sol";

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
        Refunded
    }

    // =========================================================================
    // STRUCTS
    // =========================================================================

    struct FeeParams {
        uint256 maxFee; // maxFee to pay for the proof
        uint256 minStake; // provers must stake >= this to be eligible for bid
        uint64 deadline; // proof need to be submitted by this time in epoch seconds
    }

    struct ProofRequest {
        uint64 nonce; // allow re-submit same data
        bytes32 vk; // verify key for binary
        bytes32 publicValuesDigest; // sha256(publicValues) & bytes32(uint256((1 << 253) - 1)))
        string imgURL; // URL to ELF binary, can be empty if vk is already known to the prover network
        bytes[] inputData; // input data for the binary, can be empty if inputURL is provided
        string inputURL; // URL to input data, if inputData is not provided
        FeeParams fee;
    }

    struct Bidder {
        address prover;
        uint256 fee;
    }

    // =========================================================================
    // EVENTS
    // =========================================================================

    event NewRequest(bytes32 indexed reqid, ProofRequest req);
    event NewBid(bytes32 indexed reqid, address indexed prover, bytes32 bidHash);
    event BidRevealed(bytes32 indexed reqid, address indexed prover, uint256 fee);
    event ProofSubmitted(bytes32 indexed reqid, address indexed prover, uint256[8] proof, uint256 actualFee);
    event Refunded(bytes32 indexed reqid, address indexed requester, uint256 amount);
    event PicoVerifierUpdated(address indexed oldVerifier, address indexed newVerifier);
    event BiddingPhaseDurationUpdated(uint64 oldDuration, uint64 newDuration);
    event RevealPhaseDurationUpdated(uint64 oldDuration, uint64 newDuration);
    event MinMaxFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeTokenUpdated(address indexed oldToken, address indexed newToken);

    // =========================================================================
    // ERRORS
    // =========================================================================

    error MarketDeadlineMustBeInFuture();
    error MarketDeadlineTooFar(uint256 deadline, uint256 maxAllowed);
    error MarketDeadlineBeforeRevealPhaseEnd();
    error MarketRequestAlreadyExists(bytes32 reqid);
    error MarketRequestNotFound(bytes32 reqid);
    error MarketBiddingPhaseEnded(uint256 currentTime, uint256 biddingEndTime);
    error MarketBiddingPhaseNotEnded(uint256 currentTime, uint256 biddingEndTime);
    error MarketRevealPhaseEnded(uint256 currentTime, uint256 revealEndTime);
    error MarketRevealPhaseNotEnded(uint256 currentTime, uint256 revealEndTime);
    error MarketBidRevealMismatch(bytes32 expected, bytes32 actual);
    error MarketFeeExceedsMaximum(uint256 fee, uint256 maxFee);
    error MarketMaxFeeTooLow(uint256 provided, uint256 minimum);
    error MarketMinStakeTooLow(uint256 provided, uint256 minimum);
    error MarketDeadlinePassed(uint256 currentTime, uint256 deadline);
    error MarketNotExpectedProver(address expected, address actual);
    error MarketInvalidRequestStatus(ReqStatus status);
    error MarketBeforeDeadline(uint256 currentTime, uint256 deadline);
    error MarketProverNotEligible(address prover, uint256 requiredStake, uint256 actualStake);
    error MarketZeroAddress();
    error MarketInvalidStakingController();

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
     * @param bidHash Keccak256 hash of (fee, nonce) - keeps bid secret until reveal
     * @dev Can override previous bids during bidding phase
     */
    function bid(bytes32 reqid, bytes32 bidHash) external;

    /**
     * @notice Reveal a previously submitted sealed bid
     * @dev Must be called during reveal phase with matching hash
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
     * @notice Get submitted proof for a fulfilled request
     * @param reqid The request ID to query
     * @return proof The submitted zk proof (returns empty array if not fulfilled)
     */
    function getProof(bytes32 reqid) external view returns (uint256[8] memory proof);

    /**
     * @notice Get sealed bid hash for a specific prover
     * @param reqid The request ID to query
     * @param prover The prover address to query
     * @return bidHash The sealed bid hash (empty if no bid submitted)
     */
    function getBidHash(bytes32 reqid, address prover) external view returns (bytes32 bidHash);
}
