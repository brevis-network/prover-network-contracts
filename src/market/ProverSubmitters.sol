// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./IBrevisMarket.sol";

/**
 * @title ProverSubmitters
 * @notice Abstract contract providing submitter management functionality for ZK proof marketplace provers
 * @dev Allows provers to register submitter addresses that can act on their behalf for bidding and proof submission.
 *      This enables provers managed by multisig wallets or HD wallets to use dedicated "hot" keys for operations
 *      while keeping their main prover keys secure.
 *
 * How to operate:
 * 1. Submitter grants consent: Call `setSubmitterConsent(proverAddress)` from submitter address
 * 2. Prover registers submitter: Call `registerSubmitter(submitterAddress)` from prover address
 * 3. Submitter can now bid/reveal/submit proofs on behalf of the prover
 * 4. To revoke: Prover calls `unregisterSubmitter(submitterAddress)` or submitter calls `setSubmitterConsent(address(0))`
 *
 * Security features:
 * - Two-step registration process prevents front-running attacks
 * - Existing provers cannot be registered as submitters to prevent hijacking
 * - Only registered provers in the staking system can register submitters
 */
abstract contract ProverSubmitters is IBrevisMarket {
    using EnumerableSet for EnumerableSet.AddressSet;

    IStakingController public stakingController; // StakingController staking integration

    // Prover submitter management: dual mapping for O(1) operations in both directions
    mapping(address submitter => address prover) public submitterToProver;
    mapping(address => EnumerableSet.AddressSet) private proverSubmitters; // prover -> submitters

    // Consent mechanism to prevent front-running address registration
    mapping(address submitter => address prover) public submitterConsent;

    /**
     * @notice Set consent to be registered as a submitter by a specific prover
     * @dev Use address(0) to revoke consent. Part of two-step registration process to prevent front-running
     * @param prover The prover address to grant consent to, or address(0) to revoke consent
     */
    function setSubmitterConsent(address prover) external {
        address submitter = msg.sender;
        if (prover != address(0) && prover == submitter) revert MarketCannotRegisterSelf();

        address oldProver = submitterConsent[submitter];
        submitterConsent[submitter] = prover;

        emit SubmitterConsentUpdated(submitter, oldProver, prover);
    }

    /**
     * @notice Register a submitter address that can submit proofs on behalf of the prover
     * @dev Only the prover can register submitters for themselves, requires prior consent from submitter
     * @param submitter The address to register as a submitter
     */
    function registerSubmitter(address submitter) external {
        address prover = msg.sender;
        if (submitter == address(0)) revert MarketZeroAddress();
        if (submitter == prover) revert MarketCannotRegisterSelf();

        // Check if the caller is a registered prover (allow any state except Null)
        IStakingController.ProverState state = stakingController.getProverState(prover);
        if (state == IStakingController.ProverState.Null) {
            revert MarketProverNotRegistered();
        }

        // Check if submitter is already registered to another prover
        address currentProver = submitterToProver[submitter];
        if (currentProver != address(0) && currentProver != prover) {
            revert MarketSubmitterAlreadyRegistered(submitter, currentProver);
        }

        // Prevent registering existing provers as submitters (security protection)
        IStakingController.ProverState submitterState = stakingController.getProverState(submitter);
        if (submitterState != IStakingController.ProverState.Null) {
            revert MarketCannotRegisterProverAsSubmitter(submitter);
        }

        // Require consent from submitter to prevent front-running (UX protection)
        if (submitterConsent[submitter] != prover) {
            revert MarketSubmitterConsentRequired(submitter);
        }

        // Register the submitter in both data structures
        submitterToProver[submitter] = prover;
        proverSubmitters[prover].add(submitter);
        emit SubmitterRegistered(prover, submitter);
    }

    /**
     * @notice Unregister a submitter address
     * @dev Only the prover can unregister their own submitters
     * @param submitter The address to unregister
     */
    function unregisterSubmitter(address submitter) external {
        address prover = submitterToProver[submitter];
        if (prover == address(0)) revert MarketSubmitterNotRegistered(submitter);
        if (prover != msg.sender) revert MarketNotAuthorized();

        // Remove from both data structures
        submitterToProver[submitter] = address(0);
        proverSubmitters[prover].remove(submitter);
        emit SubmitterUnregistered(prover, submitter);
    }

    /**
     * @notice Get all registered submitters for a prover
     * @param prover The prover address
     * @return submitters Array of submitter addresses
     */
    function getSubmittersForProver(address prover) external view returns (address[] memory submitters) {
        return proverSubmitters[prover].values();
    }

    /**
     * @notice Internal utility to get the effective prover for a caller
     * @dev Returns the prover address that the caller is acting on behalf of
     * @param caller Address of the caller (msg.sender)
     * @return prover The prover address (caller if they are a prover, or the prover they're registered to submit for)
     */
    function _getEffectiveProver(address caller) internal view returns (address prover) {
        // First check if caller is a registered submitter
        address registeredProver = submitterToProver[caller];
        if (registeredProver != address(0)) {
            return registeredProver;
        }

        // Otherwise, caller is acting as themselves (direct prover)
        return caller;
    }

    /**
     * @notice Internal utility to check if caller is authorized to act on behalf of a prover
     * @dev Caller can be either the prover themselves or a registered submitter for the prover
     * @param caller Address of the caller (msg.sender)
     * @param prover Address of the prover
     * @return isAuthorized True if caller is authorized to act for the prover
     */
    function _isAuthorizedForProver(address caller, address prover) internal view returns (bool isAuthorized) {
        if (caller == prover) {
            return true;
        }

        // Check if caller is a registered submitter for this prover
        address registeredProver = submitterToProver[caller];
        return (registeredProver == prover);
    }
}
