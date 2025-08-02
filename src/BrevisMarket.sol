// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

// fee/prover related
struct FeeParams {
    uint256 maxFee; // maxFee to pay for the proof
    uint256 minStake; // provers must stake >= this to be eligible for bid
    uint64 deadline; // proof need to be submitted by this time in epoch seconds
}

struct ProofRequest {
    uint64 nonce; // allow re-submit same data
    string imgURL; // ELF binary
    bytes32 vk; // verify key for binary
    // inputData or (inputURL+inputHash)
    bytes inputData;
    string inputURL;
    bytes32 inputHash;
    FeeParams fee;    
}

struct Bidder {
    address prover;
    uint256 fee;
}

enum ReqStatus {
    Pending,
    Fulfilled,
    Refunded
}

// per req saved in state
struct ReqState {
    ReqStatus status;
    uint64 receiveBlock; // req is recorded at this blocknum, needed for bid/reveal phase
    address sender; // msg.sender of requestProof
    FeeParams fee;
    // needed for verify
    bytes32 vk;
    bytes32 inputHash;
    mapping(address => bytes32) bids; // received sealed bids by provers

    Bidder bidder0; // lowest fee bidder
    Bidder bidder1; // 2nd lowest bidder

    uint256[8] proof;
}

contract BrevisMarket {
    uint64 public constant BIDDING_PHASE_BLOCKS = 5;
    uint64 public constant REVEAL_PHASE_BLOCKS = 5;

    mapping(bytes32 => ReqState) requests; // proof req id -> state

    event NewRequest(bytes32 indexed reqid, ProofRequest req);
    event NewBid(bytes32 indexed reqid, address indexed prover, bytes32 bidHash);
    event BidRevealed(bytes32 indexed reqid, address indexed prover, uint256 fee);
    event ProofSubmitted(bytes32 indexed reqid, address indexed prover, uint256[8] proof);
    event Refunded(bytes32 indexed reqid, address indexed requester, uint256 amount);

    // caller must pay gas token equal to req.maxFee
    function requestProof(ProofRequest calldata req) external payable {
        // check req fields are valid eg. dealine, msg.value >= maxprice
        require(msg.value>=req.fee.maxFee, "insufficient fee");
        require(req.fee.deadline > block.timestamp, "deadline must be in future");

        // calc reqid, save to map
        bytes32 inputHash = req.inputHash;
        if (req.inputData.length > 0) {
            inputHash = keccak256(req.inputData);
        }
        bytes32 reqid = keccak256(abi.encodePacked(req.nonce, req.vk, inputHash));

        ReqState storage reqState = requests[reqid];
        require(reqState.receiveBlock == 0, "request already exists");
        reqState.status = ReqStatus.Pending;
        reqState.receiveBlock = uint64(block.number);
        reqState.sender = msg.sender;
        reqState.fee = req.fee;
        reqState.vk = req.vk;
        reqState.inputHash = inputHash;
        // emit event
        emit NewRequest(reqid, req);
    }

    // bidHash is keccak256(fee, randnum). allow override bid
    function bid(bytes32 reqid, bytes32 bidHash) external {
        ReqState storage req = requests[reqid];
        
        // Validate request exists
        require(req.receiveBlock != 0, "request does not exist");
        
        // Check we're still in bidding phase
        require(
            block.number <= req.receiveBlock + BIDDING_PHASE_BLOCKS,
            "bidding phase ended"
        );

        // Store the sealed bid
        req.bids[msg.sender] = bidHash;
        
        emit NewBid(reqid, msg.sender, bidHash);
    }

    function reveal(bytes32 reqid, uint256 fee, uint256 nonce) external {
        ReqState storage req = requests[reqid];
        
        // Validate request exists
        require(req.receiveBlock != 0, "request does not exist");
        // block in reveal phase
        require(
            block.number > req.receiveBlock + BIDDING_PHASE_BLOCKS,
            "bidding phase not ended"
        );
        require(
            block.number <= req.receiveBlock + BIDDING_PHASE_BLOCKS + REVEAL_PHASE_BLOCKS,
            "reveal phase ended"
        );

        bytes32 expectedHash = keccak256(abi.encodePacked(fee, nonce));
        require(req.bids[msg.sender] == expectedHash, "mismatch bid reveal");
        require(fee <= req.fee.maxFee, "fee exceeds maximum");

        // Update lowest and second lowest bidders
        _updateBidders(req, msg.sender, fee);
        
        emit BidRevealed(reqid, msg.sender, fee);
    }

    // verify and save proof, then send fee to prover, remaining to requester
    function submitProof(bytes32 reqid, uint256[8] calldata proof) external {
        ReqState storage req = requests[reqid];
        require(block.timestamp<=req.fee.deadline, "deadline passed");
        require(msg.sender == req.bidder0.prover, "not expected prover"); // is this necessary? anyway fee is paid to saved addr
        require(req.status == ReqStatus.Pending, "invalid req status");
        // TODO: verify proof via PicoVerifier
        req.proof = proof;
        req.status = ReqStatus.Fulfilled;
        // handle fee
        (bool success, ) = req.bidder0.prover.call{value: req.bidder1.fee}("");
        require(success, "send fee to prover failed");
        (success, ) = req.sender.call{value: req.fee.maxFee - req.bidder1.fee}("");
        require(success, "refund fee failed");

        emit ProofSubmitted(reqid, msg.sender, proof);
    }

    // send pending req past deadline maxfee to requester
    function refund(bytes32 reqid) external {
        ReqState storage req = requests[reqid];
        require(block.timestamp>req.fee.deadline, "before deadline");
        require(req.status == ReqStatus.Pending, "invalid req status");
        req.status = ReqStatus.Refunded;
        (bool success, ) = req.sender.call{value: req.fee.maxFee}("");
        require(success, "refund fee failed");

        emit Refunded(reqid, req.sender, req.fee.maxFee);
    }

    function _updateBidders(
        ReqState storage req,
        address prover,
        uint256 fee
    ) internal {
        // If no bidders yet, or this is lower than current lowest
        if (req.bidder0.prover == address(0) || fee < req.bidder0.fee) {
            // Move current lowest to second lowest
            req.bidder1 = req.bidder0;
            // Set new lowest
            req.bidder0 = Bidder({
                prover: prover,
                fee: fee
            });
        }
        // If this is lower than second lowest (but not lowest)
        else if (req.bidder1.prover == address(0) || fee < req.bidder1.fee) {
            req.bidder1 = Bidder({
                prover: prover,
                fee: fee
            });
        }
    }

}