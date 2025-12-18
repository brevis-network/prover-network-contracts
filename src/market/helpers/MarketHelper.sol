// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IBrevisMarket.sol";
import "../../token/WrappedNativeToken.sol";

/**
 * @title MarketHelper
 * @notice Helper contract for BrevisMarket to handle native token wrapping/unwrapping
 * @dev Works with existing BrevisMarket without requiring any contract modifications
 *      The helper acts as the "sender" for requests and receives refunds on behalf of users
 */
contract MarketHelper {
    IBrevisMarket public immutable market;
    WrappedNativeToken public immutable wrappedToken;

    // Track the original user for each request ID
    mapping(bytes32 => address) public requestOwners;

    event NativeProofRequested(bytes32 indexed reqid, address indexed owner, uint256 maxFee);
    event NativeRefundReceived(bytes32 indexed reqid, address indexed owner, uint256 amount);

    error MarketHelperInsufficientValue();
    error MarketHelperInvalidFeeAmount();
    error MarketHelperTransferFailed();
    error MarketHelperUnauthorized();

    /**
     * @notice Initialize the helper with market and wrapped token addresses
     * @param _market Address of the BrevisMarket contract
     * @param _wrappedToken Address of the WrappedNativeToken contract
     */
    constructor(address _market, address payable _wrappedToken) {
        market = IBrevisMarket(_market);
        wrappedToken = WrappedNativeToken(_wrappedToken);
    }

    /**
     * @notice Request a proof with native tokens
     * @dev Wraps native tokens and submits proof request
     *      The helper becomes the request "sender" and will receive refunds
     * @param req The proof request parameters (maxFee must match msg.value)
     * @return reqid The unique identifier for this request
     */
    function requestProofNative(IBrevisMarket.ProofRequest calldata req) external payable returns (bytes32 reqid) {
        if (msg.value == 0) revert MarketHelperInsufficientValue();
        if (msg.value != uint256(req.fee.maxFee)) {
            revert MarketHelperInvalidFeeAmount();
        }

        // Calculate request ID (same as BrevisMarket does)
        reqid = keccak256(abi.encodePacked(req.nonce, req.vk, req.publicValuesDigest));

        // Store the original owner
        requestOwners[reqid] = msg.sender;

        // Wrap native tokens
        wrappedToken.deposit{value: msg.value}();

        // Approve market to spend wrapped tokens
        wrappedToken.approve(address(market), msg.value);

        // Submit proof request (helper becomes the sender)
        market.requestProof(req);

        emit NativeProofRequested(reqid, msg.sender, msg.value);
        return reqid;
    }

    /**
     * @notice Refund a request and receive native tokens
     * @dev Anyone can trigger refund, but native tokens go to the original owner
     * @param reqid The request ID to refund
     * @return amount The amount of native tokens refunded to the owner
     */
    function refundNative(bytes32 reqid) external returns (uint256 amount) {
        address owner = requestOwners[reqid];
        if (owner == address(0)) revert MarketHelperUnauthorized();

        // Get request info to know the refund amount
        (,, address sender, uint256 maxFee,,,,,) = market.getRequest(reqid);

        // Verify this helper is the sender
        if (sender != address(this)) revert MarketHelperUnauthorized();

        amount = maxFee;

        // Call refund - wrapped tokens will be sent to this helper
        market.refund(reqid);

        // Unwrap to native tokens
        wrappedToken.withdraw(amount);

        // Transfer native tokens to original owner
        (bool success,) = owner.call{value: amount}("");
        if (!success) revert MarketHelperTransferFailed();

        // Clear the mapping
        delete requestOwners[reqid];

        emit NativeRefundReceived(reqid, owner, amount);
        return amount;
    }

    /**
     * @notice Receive function to accept ETH from wrappedToken.withdraw()
     * @dev Required to receive ETH when unwrapping during refundNative
     */
    receive() external payable {
        // Accept ETH from unwrap operation
    }
}
