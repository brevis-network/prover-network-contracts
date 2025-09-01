# ZK Proof Marketplace

A sealed-bid reverse auction marketplace for zero-knowledge proof generation, with staking governing prover eligibility, fee distribution, and slashing.

## Table of Contents

- [1. System Overview](#1-system-overview)
- [2. API Reference](#2-api-reference)
- [3. Core Data Structures](#3-core-data-structures)
- [4. Reverse Auction Process](#4-reverse-auction-process)
- [5. Integration with Staking](#5-integration-with-staking)
- [6. Prover Submitters](#6-prover-submitters)
- [7. Configuration & Admin](#7-configuration--admin)

---

## 1. System Overview

**BrevisMarket** orchestrates sealed-bid reverse auctions for ZK proof requests:
- **Sealed-Bid Reverse Auctions:** Provers submit hidden bids, competing to offer the lowest fee
- **Reverse Second-Price:** The winner (lowest bidder) is paid the amount of the second-lowest bid
- **Staking Integration:** Prover eligibility, fee distribution as rewards, and slashing enforcement
- **Protocol Fee Cut:** Takes a configurable cut from the final payment to the prover

### **Request Flow**
```
Request → Bidding Phase → Reveal Phase → Proof Submission → Payment
                                       ↘ Refund (if no bid or deadline missed) → Slash (if applicable)
```

---

## 2. API Reference

**Complete documentation:** [`IBrevisMarket.sol`](../src/market/IBrevisMarket.sol)

**Core Functions:**
- `requestProof()` - Submit request with fee escrow
- `bid()` - Submit sealed bid hash (lower fees preferred)
- `reveal()` - Reveal actual bid amount
- `submitProof()` - Submit ZK proof (bid winner only)
- `refund()` - Trigger refund to requester if no valid bid or deadline missed
- `slash()` - Penalize non-performing assigned prover (after refund)

---

## 3. Core Data Structures

### **ProofRequest**
```solidity
struct ProofRequest {
    uint64 nonce;                    // Re-submission identifier
    bytes32 vk;                      // ZK circuit verification key
    bytes32 publicValuesDigest;      // Public input hash
    string imgURL;                   // ELF binary URL (optional)
    bytes[] inputData;               // Input data (alternative to URL)
    string inputURL;                 // Input data URL (alternative to data)
    FeeParams fee;                   // Payment parameters
}
```

### **FeeParams**
```solidity
struct FeeParams {
    uint256 maxFee;    // Maximum fee requester is willing to pay
    uint256 minStake;  // Required prover minimum stake
    uint64 deadline;   // Proof submission deadline
}
```

---

## 4. Reverse Auction Process

### **Phase 1: Bidding**
- Duration: `biddingPhaseDuration` seconds from request time
- Provers submit `keccak256(fee, nonce)` to hide bids
- Eligibility: must be an active prover with at least `minStake` assets

### **Phase 2: Revealing** 
- Duration: `revealPhaseDuration` seconds after bidding ends
- Must provide original `fee` and `nonce` matching hash
- System tracks winner (lowest bidder) and second-place (second-lowest)
- Eligibility re-verified

### **Phase 3: Proof Submission**
- Winner submits ZK proof (verified by PicoVerifier) before request deadline
- Winner gets paid second-lowest bid or their own bid if only one bidder
- Distribution: Fee -> staking rewards after protocol cut, excess -> requester

### **Refund**
- If no bid or deadline missed, anyone can trigger a full refund of `maxFee` to the requester

---

## 5. Integration with Staking

### **Prover Eligibility**
```solidity
stakingController.isProverEligible(prover, minimumStake)
```
- Checked at both bid and reveal phases
- Requires Active prover state with sufficient vault assets

### **Fee Distribution**
- Winner fee automatically sent via `stakingController.addRewards()`
- Amount: Second-lowest bid in reverse auction (or the only bidder's bid), subject to protocol fee cut

### **Slashing**
- Penalizes assigned provers who fail to deliver after winning an auction.
- Prerequisites:
  - Request must be refunded first
  - Must be within slash window after deadline
- Calculation: `slashAmount = (request.minStake × slashBps) / 10000`
  - Uses request's required minStake (not prover's total assets) for and predictable and consistent penalties

---

## 6. Prover Submitters

The marketplace supports **submitter authorization** where provers can register submitter addresses to act on their behalf. This enables provers managed by multisig wallets or HD wallets to use dedicated "hot" keys for bidding and proof submission while keeping their main prover keys secure.

### **Two-Step Registration Process**
```
1. Submitter grants consent: setSubmitterConsent(proverAddress)
2. Prover registers submitter: registerSubmitter(submitterAddress)
```

### **Security Protections**
- **Consent Required:** Prevents front-running by requiring submitter's explicit consent
- **Prover Verification:** Only registered provers in staking system can register submitters
- **Hijacking Prevention:** Existing provers cannot be registered as submitters for other provers

### **Operations**
```solidity
// Grant/revoke consent (submitter calls this)
setSubmitterConsent(proverAddress)  // Grant consent to prover
setSubmitterConsent(address(0))     // Revoke consent

// Register/unregister (prover calls this)
registerSubmitter(submitterAddress)    // Register consenting submitter
unregisterSubmitter(submitterAddress)  // Remove submitter
```

### **Data Access**
- `submitterToProver[submitter]` - Returns the prover a submitter is registered to
- `submitterConsent[submitter]` - Returns the prover a submitter has consented to
- `getSubmittersForProver(prover)` - Returns array of all submitters for a prover

---

## 7. Configuration & Admin

### **Parameters**
- `biddingPhaseDuration` - Sealed bid submission window
- `revealPhaseDuration` - Bid reveal window  
- `minMaxFee` - Minimum allowed maxFee to prevent spam requests
- `slashBps` - Slashing percentage in basis points (0-10000)
- `slashWindow` - Time window for slashing after deadline
- `protocolFeeBps` - Protocol’s cut of prover payment in basis points (0-10000)

### **Admin Functions**
- Update parameters
- Change PicoVerifier address

### **Constants**
- Fee token automatically synced with staking system
- `MAX_DEADLINE_DURATION` - Maximum request lifetime (30 days)

---

**For exact function signatures and interface definitions, see [`IBrevisMarket.sol`](../src/market/IBrevisMarket.sol)**
