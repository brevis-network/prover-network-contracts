# ZK Proof Marketplace

A sealed-bid reverse auction marketplace for zero-knowledge proof generation, with staking governing prover eligibility, fee distribution, and slashing.

## Table of Contents

- [1. System Overview](#1-system-overview)
- [2. API Reference](#2-api-reference)
- [3. Core Data Structures](#3-core-data-structures)
- [4. Reverse Auction Process](#4-reverse-auction-process)
- [5. Integration with Staking](#5-integration-with-staking)
- [6. Overcommit Protection](#6-overcommit-protection)
- [7. Prover Submitters](#7-prover-submitters)
- [8. Statistics](#8-statistics)
- [8. Market Viewer](#9-market-viewer)
- [10. Configuration & Admin](#9-configuration--admin)

---

## 1. System Overview
## 2. API Reference

**Complete documentation:** [`IBrevisMarket.sol`](../src/market/interfaces/IBrevisMarket.sol) and [`IMarketViewer.sol`](../src/market/interfaces/IMarketViewer.sol)

**Core Functions:**
- `requestProof()` - Submit request with fee escrow
- `bid()` - Submit sealed bid hash (lower fees preferred)
- `reveal()` - Reveal actual bid amount
- `submitProof()` - Submit ZK proof (bid winner only)
- `refund()` - Trigger refund to requester if no valid bid or deadline missed
- `slash()` - Penalize non-performing assigned prover (after refund)

---

## 3. Core Data Structures

### ProofRequest
```solidity
struct ProofRequest {
    uint64 nonce;                // Re-submission identifier
    bytes32 vk;                  // ZK circuit verification key
    bytes32 publicValuesDigest;  // Public input hash
    string imgURL;               // ELF binary URL (optional)
    bytes inputData;             // Input data (alternative to URL)
    string inputURL;             // Input data URL (alternative to data)
    FeeParams fee;               // Payment parameters
}
```

### FeeParams
```solidity
struct FeeParams {
    uint256 maxFee;    // Maximum fee requester is willing to pay
    uint256 minStake;  // Required prover minimum stake
    uint64 deadline;   // Proof submission deadline
}
```

---

## 4. Reverse Auction Process

### Phase 1: Bidding
- Duration: `biddingPhaseDuration` seconds from request time
- Provers submit sealed bid commitments: `keccak256(abi.encodePacked(reqid, prover, fee, nonce))`
- Eligibility: must be an active prover with sufficient stake, computed as:
  - `required = request.minStake + assignedStake[prover] * overcommitBps / 10000`
  - where `assignedStake` is the sum of `minStake` from requests currently assigned to the prover

### Phase 2: Revealing
- Duration: `revealPhaseDuration` seconds after bidding ends
- Must provide `reqid` and the original `fee` and `nonce`
- System tracks winner (lowest bidder) and second-place (second-lowest)
- Eligibility re-verified with the same formula as bidding

### Phase 3: Proof Submission
- Winner submits ZK proof (verified by PicoVerifier) before request deadline
- Winner gets paid second-lowest bid or their own bid if only one bidder
- Distribution: Fee -> staking rewards after protocol cut, excess -> requester

### Refund
- If no bid or deadline missed, anyone can trigger a full refund of `maxFee` to the requester

---

## 5. Integration with Staking

### Prover Eligibility
```solidity
stakingController.isProverEligible(prover, minimumStake)
```
- Checked at both bid and reveal phases.
- Requires Active prover state with sufficient vault assets for the dynamic requirement:
  - `minimumStake = request.minStake + assignedStake[prover] * overcommitBps / 10000`.
  - `assignedStake[prover]` increases when a prover becomes the current winner on reveal, and decreases when the request is fulfilled or refunded.
  - If the winner changes during reveal (because a lower bid is revealed), the `assignedStake` is moved from the previous winner to the new winner.

### Fee Distribution
- Winner fee automatically sent via `stakingController.addRewards()`
- Amount: Second-lowest bid in reverse auction (or the only bidder's bid), subject to protocol fee cut

### Slashing
- Penalizes assigned provers who fail to deliver after winning an auction.
- Prerequisites:
  - Request must be refunded first
  - Must be within slash window after deadline
- Calculation: `slashAmount = (request.minStake × slashBps) / 10000`
  - Uses request's required minStake (not prover's total assets) for predictable and consistent penalties

---

## 6. Overcommit Protection

To preserve slashing feasibility and avoid overcommitting provers across concurrent assignments, the market enforces an eligibility buffer based on currently assigned work.

#### Key concepts:
- `assignedStake[prover]`: the sum of `minStake` across requests where the prover is currently the winner and the request is not yet fulfilled or slashed.
- `overcommitBps`: owner-configurable basis points applied to `assignedStake` when checking new eligibility.

#### Eligibility rule (applies at both bid and reveal):
- `required = request.minStake + assignedStake[prover] * overcommitBps / 10000`
- The staking controller must report the prover eligible for this `required` amount.

#### Lifecycle of `assignedStake`:
- On reveal, when a prover becomes the current winner, their `assignedStake` increases by the request’s `minStake`. If a later reveal produces a lower bid, the `assignedStake` moves from the previous winner to the new winner.
- On `submitProof` (success) or `slash` (failure after refund), the request’s `minStake` is released from the winning prover’s `assignedStake`.

#### Tuning guidance:
- Set `overcommitBps` to balance throughput vs. safety. For example, `500` (5%) adds a small buffer; `10000` (100%) requires a prover to have enough stake to cover all assigned `minStake` cumulatively before taking new work.
---

## 7. Prover Submitters

The marketplace supports **submitter authorization** where provers can register submitter addresses to act on their behalf. This enables provers managed by multisig wallets or HD wallets to use dedicated "hot" keys for bidding and proof submission while keeping their main prover keys secure.

### Two-Step Registration Process
```
1. Submitter grants consent: setSubmitterConsent(proverAddress)
2. Prover registers submitter: registerSubmitter(submitterAddress) or registerSubmitters(submitterArray)
```

### Security Protections
- **Consent Required:** Prevents front-running by requiring submitter's explicit consent
- **Prover Verification:** Only registered provers in staking system can register submitters
- **Hijacking Prevention:** Existing provers cannot be registered as submitters for other provers

### Operations
```solidity
// Grant/revoke consent (submitter calls this)
setSubmitterConsent(proverAddress)  // Grant consent to prover
setSubmitterConsent(address(0))     // Revoke consent

// Register/unregister (prover calls this)
registerSubmitter(submitterAddress)    // Register consenting submitter
unregisterSubmitter(submitterAddress)  // Remove submitter
registerSubmitters(submitterArray)     // Register multiple consenting submitters
unregisterSubmitters(submitterArray)   // Remove multiple submitters

// Self-unregistration (submitter calls this)
unregisterSubmitter()  // Submitter removes themselves
```

### Data Access
- `submitterToProver[submitter]` - Returns the prover a submitter is registered to
- `submitterConsent[submitter]` - Returns the prover a submitter has consented to
- `getSubmittersForProver(prover)` - Returns array of all submitters for a prover

---

## 8. Statistics

BrevisMarket tracks both per-prover activity and system-wide aggregates via lifetime totals and epoch–based recent windows.

### Data Model

Global (system-wide) stats:
```solidity
struct GlobalStats {
    uint64 totalRequests;   // total proof requests made
    uint64 totalFulfilled;  // total proof requests fulfilled
    uint256 totalFees;      // total requester fees actually paid
}
```

Prover stats
```solidity
struct ProverStats {
    uint64 bids;              // total bids placed
    uint64 reveals;           // total bids revealed
    uint64 requestsFulfilled; // successful request fulfillments (proofs delivered)
    uint64 requestsRefunded;  // assigned requests refunded after deadline (missed by the final winner)
    uint64 lastActiveAt;      // last activity timestamp (only on the prover's own actions)
    uint256 feeReceived;      // total rewards (after protocol fee) sent to the prover
}
```

### APIs
Global stats:
- `getGlobalStatsTotal()` — Lifetime totals (system-wide)
- `getGlobalRecentStats()` — Recent (current epoch) stats + start timestamp
- `getGlobalStatsForStatsEpoch(epochId)` — Stats for a specific epoch + time window

Per-prover stats:
- `getProverStatsTotal(prover)` — Lifetime totals
- `getProverRecentStats(prover)` — Recent (current epoch) stats + start timestamp
- `getProverStatsForStatsEpoch(prover, epochId)` — Stats for a specific epoch + time window

Epoch helpers:
- `statsEpochId()` — Current epoch id
- `statsEpochs(index)` — (startAt, endAt) for an epoch (endAt = 0 marks the tail epoch)
- `statsEpochsLength()` — Number of scheduled epochs
- `getRecentStatsInfo()` — (startAt, epochId) for the current stats window

### Semantics
- Totals: cumulative since genesis; snapshots auto carry-forward across epochs.
- Recent: current epoch values as a diff vs the previous snapshot.
- requestsFulfilled: increments on successful `submitProof()` (before deadline).
- requestsRefunded: counts refunds after deadline when a final winner exists; excludes no-winner refunds.
- lastActiveAt: set on prover actions (bid/reveal/submit); non-zero in Recent only if activity this epoch.
- Totals fallback: if no activity in current epoch, totals getters return the previous snapshot.

Global stats mirror the above:
- totalRequests: increments on `requestProof()`.
- totalFulfilled: increments on `submitProof()`.
- totalFees: adds the actual fee paid on `submitProof()`.
- Epochs are scheduled by admin; rollover to a new epoch is lazy on first activity at/after the start time.

---

## 9. Market Viewer

`MarketViewer.sol` is a standalone, stateless read-only helper for efficient off‑chain queries; it keeps `BrevisMarket` lean, and lets us add new query features by simply deploying a new viewer (no market upgrade). See [`IMarketViewer.sol`](../src/market/interfaces/IMarketViewer.sol) for the interface.

Key endpoints:

- Batch request data: `batchGetRequests`, `batchGetBidders`, `batchGetBidHashes`
- Proof payloads are only emitted via the `ProofSubmitted` event, so indexers should track logs instead of querying storage.
- Pending and overdue:
  - Counts: `getProverPendingCount`, `getSenderPendingCount`, `getProverOverdueCount`, `getSenderOverdueCount`
  - Pending (prover): `getProverPendingRequests(prover)` → `ProverPendingItem[]` (fields: `reqid`, `deadline`)
  - Pending (sender): `getSenderPendingRequests(sender)` → `SenderPendingItem[]` (fields: `reqid`, `deadline`, `winner`)
  - Overdue IDs: `getProverOverdueRequests(prover)`, `getSenderOverdueRequests(sender)`
  - Refundable IDs (sender): `getSenderRefundableRequests(sender)`
- Stats composites:
  - `getProverStatsComposite(prover)` returns `{ total, recent, recentStartAt, successRateBps, fulfilled, refunded, pendingCount, overdueCount }`
    - `successRateBps` = `fulfilled / (fulfilled + refunded + overdueCount)` in basis points (0–10000)
  - `getGlobalStatsComposite()` returns `{ total, recent, recentStartAt }`
- Epoch helpers: `getStatsEpochs()`, `getStatsEpochs(epochIds)`

---

## 10. Configuration & Admin

### Parameters
- `biddingPhaseDuration` - Sealed bid submission window
- `revealPhaseDuration` - Bid reveal window  
- `minMaxFee` - Minimum allowed maxFee to prevent spam requests
- `slashBps` - Slashing percentage in basis points (0-10000)
- `slashWindow` - Time window for slashing after deadline
- `protocolFeeBps` - Protocol’s cut of prover payment in basis points (0-10000)
- `overcommitBps` - Buffer applied to a prover’s currently assigned stake when checking eligibility (0-10000). Higher values more aggressively prevent overcommitment. Default is 500 (5%).

### Admin Functions
- Update parameters
- Change PicoVerifier address

Additional:
- `setOvercommitBps(uint256 newBps)` – Owner-only. Sets the overcommit buffer in basis points and emits `OvercommitBpsUpdated(oldBps, newBps)`. Reverts if `newBps > 10000`.

### Constants
- Fee token automatically synced with staking system
- `MAX_DEADLINE_DURATION` - Maximum request lifetime (30 days)

---

**For exact function signatures and interface definitions, see [`IBrevisMarket.sol`](../src/market/interfaces/IBrevisMarket.sol) and [`IMarketViewer.sol`](../src/market/interfaces/IMarketViewer.sol)**