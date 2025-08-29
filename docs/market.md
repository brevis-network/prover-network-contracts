# ZK Proof Marketplace

A sealed-bid reverse auction marketplace for zero-knowledge proof generation with staking-based prover eligibility.

## Table of Contents

- [1. System Overview](#1-system-overview)
- [2. API Reference](#2-api-reference)
- [3. Core Data Structures](#3-core-data-structures)
- [4. Reverse Auction Process](#4-reverse-auction-process)
- [5. Integration with Staking](#5-integration-with-staking)
- [6. Configuration & Admin](#6-configuration--admin)

---

## 1. System Overview

**BrevisMarket** orchestrates sealed-bid reverse auctions for ZK proof requests:
- **Sealed-Bid Reverse Auctions:** Provers compete by bidding lower fees to win (procurement style)
- **Reverse Second-Price Mechanism:** Winner (lowest bidder) pays second-lowest bid
- **Staking Integration:** Only eligible staked provers can participate
- **Automatic Rewards:** Winner fees distributed through staking system

### **Request Flow**
```
Request → Bidding Phase → Reveal Phase → Proof Submission → Payment
```

### **Key Properties**
- Reverse auction: Lower fee bids have better chance of winning
- Integrated with StakingController for prover eligibility
- Uses staking token automatically for all fees
- Winner payments become staking rewards via `addRewards()`

---

## 2. API Reference

**Complete documentation:** [`IBrevisMarket.sol`](../src/market/IBrevisMarket.sol)

**Core Functions:**
- `requestProof()` - Submit request with fee escrow
- `bid()` - Submit sealed bid hash (lower fees preferred)
- `reveal()` - Reveal actual bid amount
- `submitProof()` - Submit ZK proof (winner only)
- `refund()` - Refund expired requests

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
    uint256 maxFee;    // Maximum fee willing to pay
    uint256 minStake;  // Required prover minimum stake
    uint64 deadline;   // Proof submission deadline
}
```

---

## 4. Reverse Auction Process

### **Phase 1: Bidding**
- Duration: `biddingPhaseDuration` seconds from request time
- Provers submit `keccak256(fee, nonce)` to hide bids
- **Key:** Lower fee bids are more competitive (reverse auction)
- Eligibility checked: must meet `minStake` requirement
- Can overwrite previous bids

### **Phase 2: Revealing** 
- Duration: `revealPhaseDuration` seconds after bidding ends
- Must provide original `fee` and `nonce` matching hash
- System tracks winner (lowest bidder) and second-place (second-lowest)
- Eligibility re-verified

### **Phase 3: Proof Submission**
- Winner submits ZK proof before request deadline
- Proof verified by PicoVerifier contract
- **Payment:** Winner pays second-lowest bid (reverse second-price auction)
- **Fallback:** If only one bidder, winner pays their own bid
- **Distribution:** Fee → staking rewards, excess → requester

### **Refund Mechanism**
- If deadline passes without fulfillment, anyone can trigger refund
- Full `maxFee` returned to original requester

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
- **Amount:** Second-lowest bid in reverse auction (or winner's bid if only one bidder)
- Subject to prover commission rates in staking system
- Marketplace uses `stakingController.stakingToken()` automatically

---

## 6. Configuration & Admin

### **Parameters**
- `biddingPhaseDuration` - Sealed bid submission window
- `revealPhaseDuration` - Bid reveal window  
- `minMaxFee` - Minimum maxFee for spam protection
- `MAX_DEADLINE_DURATION` - Maximum request lifetime (30 days)

### **Admin Functions**
- Update timing parameters
- Update minMaxFee
- Change PicoVerifier address

### **Constants**
- Fee token automatically synced with staking system
- No pause or emergency recovery mechanisms

---

**For detailed function signatures:** [`IBrevisMarket.sol`](../src/market/IBrevisMarket.sol)**
