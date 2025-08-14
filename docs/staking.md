# ProverStaking Contract Design (Core O(1) Staking / Rewards / Slashing)

## Overview

The `ProverStaking` contract implements a delegation-based staking system with O(1) complexity for all high‑frequency operations via a raw share abstraction and global accumulators:

1. **O(1) Stake / Unstake** – Share mint/burn proportional math without looping over stakers
2. **O(1) Proof Reward Distribution** – Single accumulator update amortizes distribution
3. **O(1) Slashing** – Multiplicative scale adjustment affects all stakes implicitly
4. **O(1) Streaming Rewards** – Global time accumulator weighted by total effective stake


## Table of Contents

- [Core Data Structures](#core-data-structures)
- [Key Constants](#key-constants)
- [Key Algorithms](#key-algorithms)
    - [Raw Shares System](#1-raw-shares-system)
    - [Staking & Unstaking](#2-staking--unstaking)
    - [Proof Reward Distribution](#3-proof-reward-distribution)
    - [Streaming Rewards System](#4-streaming-rewards-system)
    - [Slashing](#5-slashing)
- [Key Invariants](#key-invariants)
- [Edge Cases (Core Mechanics)](#edge-cases-core-mechanics)

---

## Core Data Structures


```solidity
enum ProverState { Null, Active, Retired, Deactivated }

struct ProverInfo {
    // === BASIC METADATA ===
    ProverState state;                // Prover status: Null, Active, Retired, or Deactivated
    uint64 commissionRate;            // Commission in basis points (0-10000)
    uint256 minSelfStake;             // Individual minimum self-stake (≥ globalMinSelfStake)
    
    // === SHARE TRACKING ===
    uint256 totalRawShares;           // Total raw shares (pre-slashing)
    uint256 scale;                    // Global scale factor (1e18 = no slashing)
    
    // === REWARD DISTRIBUTION ===
    uint256 accRewardPerRawShare;     // Accumulated proof rewards per raw share
    uint256 pendingCommission;        // Unclaimed prover commission (aggregated)
    
    // === STREAMING REWARDS ===
    uint256 rewardDebtEff;            // Streaming reward debt (based on effective stake)
    
    // === MIN SELF STAKE UPDATE ===
    PendingMinSelfStakeUpdate pendingMinSelfStakeUpdate; // Pending minSelfStake decrease
    
    // === STAKER DATA ===
    mapping(address => StakeInfo) stakes;       // Individual stake info
    EnumerableSet.AddressSet stakers;           // Staker enumeration
}

struct StakeInfo {
    // === ACTIVE STAKE ===
    uint256 rawShares;                    // Raw shares owned (pre-slashing)
    uint256 rewardDebt;                   // Prevents double-claiming rewards
    uint256 pendingRewards;               // Accumulated unclaimed rewards
    
    // === UNSTAKING QUEUE ===
    PendingUnstake[] pendingUnstakes;     // Array of pending unstake requests
}

struct PendingUnstake {
    uint256 rawShares;        // Raw shares in this unstake request
    uint256 unstakeTime;      // Timestamp when this unstake was initiated
}

struct PendingMinSelfStakeUpdate {
    uint256 newMinSelfStake;  // The new minSelfStake value being requested
    uint256 requestedTime;    // Timestamp when the update was requested
}
```

---

## Key Constants (Core Parameters)

| Constant | Purpose |
|----------|---------|
| `SCALE_FACTOR = 1e18` | Fixed point precision for share & accumulator math |
| `SLASH_FACTOR_DENOMINATOR = 1_000_000` | PPM denominator for slashing percentages (higher precision, fewer rounding losses) |
| `MAX_SLASH_PERCENTAGE = 500_000` | Max single slash = 50% (safety against catastrophic single events) |
| `COMMISSION_RATE_DENOMINATOR = 10_000` | Basis points (1e4) for commission rate inputs |
| `MAX_PENDING_UNSTAKES = 10` | Bounded per‑staker queue (gas bound for completion) |

Only these constants are required to reason about the O(1) core algorithms.

## Key Algorithms

### 1. Raw Shares System

#### Core Concept
The contract uses a **dual-share system**:
- **Raw Shares**: Constant until stake changes, used for proportional calculations
- **Effective Amount**: `rawShares * scale / SCALE_FACTOR`, changes with slashing

#### Mathematical Model

```
rawShares = constant until stake/unstake
effectiveAmount = (rawShares * scale) / SCALE_FACTOR
scale = SCALE_FACTOR initially, decreases with slashing
```

#### Implementation

```solidity
function _effectiveAmount(address _prover, uint256 _rawShares) internal view returns (uint256) {
    ProverInfo storage prover = provers[_prover];
    return (_rawShares * prover.scale) / SCALE_FACTOR;
}

function _rawSharesFromAmount(address _prover, uint256 _amount) internal view returns (uint256) {
    ProverInfo storage prover = provers[_prover];
    return (_amount * SCALE_FACTOR) / prover.scale;
}
```

#### Conversion Formulas

```
rawShares ↔ effectiveAmount conversion:
effectiveAmount = (rawShares × scale) ÷ SCALE_FACTOR
rawShares = (effectiveAmount × SCALE_FACTOR) ÷ scale

Where:
- effectiveAmount: ERC20 token amount (1 token = 1e18 units)
- SCALE_FACTOR: 1e18 (provides 18 decimal precision)
- scale: prover-specific scale factor (starts at 1e18, decreases with slashing)
```

### 2. Staking & Unstaking

**Staking Process:**
```solidity
function stake(address _prover, uint256 _amount) internal {
    // 1. Calculate raw shares: newRawShares = (amount * SCALE_FACTOR) / scale
    // 2. Update reward accounting before share changes
    // 3. Mint shares: rawShares += newRawShares, totalRawShares += newRawShares
    // 4. Track new stakers: prover.stakers.add(_staker) if first stake
    // Note: ERC20 tokens are transferred via safeTransferFrom()
}
```

**Unstaking Process (Two-Phase):**
```solidity
// Phase 1: Request (immediate) - Multiple requests allowed
function requestUnstake(address _prover, uint256 _amount) external {
    // 1. Validate request limit (MAX_PENDING_UNSTAKES = 10)
    // 2. Convert amount to raw shares
    // 3. Move shares: rawShares → pendingUnstakes array
    // 4. Start delay timer for this specific request
    // 5. Remove from stakers set if stake becomes zero
}

// Phase 2: Complete (after delay) - Auto-completes all eligible requests
function completeUnstake(address _prover) external {
    // 1. Iterate through pending requests chronologically
    // 2. Process all requests that meet delay requirement
    // 3. Early break when hitting first non-ready request
    // 4. Calculate total effective amount (subject to slashing during delay)
    // 5. Remove completed requests and transfer ERC20 tokens back to staker
}
```

**Key Features:**
- Stakes remain slashable during unstaking delay
- EnumerableSet automatically tracks active stakers
- All operations maintain proportional relationships
- Multiple unstake requests supported (up to 10 per staker per prover)
- Automatic completion of all eligible requests for better UX
- Unstaking affects staker tracking: removed from stakers set when stake becomes zero

### 3. Proof Reward Distribution

Instead of updating individual staker balances, the system maintains a global accumulator (`accRewardPerRawShare`) that tracks proof rewards earned per raw share. Rewards are calculated on-demand.

```solidity
function addRewards(address _prover, uint256 _amount) external {
    ProverInfo storage prover = provers[_prover];

    uint256 commission = (_amount * prover.commissionRate) / COMMISSION_RATE_DENOMINATOR;
    uint256 stakersReward = _amount - commission;

    // Always credit commission to prover
    prover.pendingCommission += commission;

    if (prover.totalRawShares == 0) {
        // No stakers exist, prover gets all remaining rewards as commission
        prover.pendingCommission += stakersReward;
    } else {
    // O(1) operation: update accumulator for stakers with bounded dust
        uint256 deltaAcc = (stakersReward * SCALE_FACTOR) / prover.totalRawShares;
        uint256 distributed = (deltaAcc * prover.totalRawShares) / SCALE_FACTOR;
    uint256 dust = stakersReward - distributed; // token units lost to truncation ( < totalRawShares )
        
        prover.accRewardPerRawShare += deltaAcc;
    // Dust routed to treasuryPool in implementation (prevents accumulation in limbo)
    }
}

// Proof rewards calculated on-demand when needed
pendingRewards = (rawShares * accRewardPerRawShare / SCALE_FACTOR) - rewardDebt
```

#### Proof Reward Distribution Formulas

```
Commission = totalRewards × commissionRate ÷ COMMISSION_RATE_DENOMINATOR
StakersReward = totalRewards - Commission

If totalRawShares > 0:
    accRewardPerRawShare += (StakersReward × SCALE_FACTOR) ÷ totalRawShares
    pendingCommission += Commission
Else:
    // No stakers exist, prover gets all rewards as commission
    pendingCommission += totalRewards

Pending Rewards (for stakers):
AccruedRewards = (rawShares × accRewardPerRawShare) ÷ SCALE_FACTOR
PendingRewards = previousPendingRewards + (AccruedRewards - rewardDebt)

Where:
- totalRewards: ERC20 token amount
- COMMISSION_RATE_DENOMINATOR: 10000 (for basis points calculation)
- commissionRate: 0-10000 (0% to 100%)
```

### 4. Streaming Rewards System

The streaming rewards system provides continuous time-based reward distribution to all active provers. Unlike proof rewards which are tied to specific work completion, streaming rewards are distributed proportionally based on effective stakes over time.

#### Key Components

1. **Global Accumulator**: `globalAccPerEff` tracks streaming rewards earned per unit of effective stake
2. **Time-Based Distribution**: `globalRatePerSec` defines tokens distributed per second across all active provers
3. **Effective Stake Weighting**: Uses total effective stake amounts for proportional distribution
4. **Separate Accounting**: Streaming rewards use dedicated debt tracking (`rewardDebtEff`) independent of proof rewards
5. **Public Budget Addition**: Anyone can add funds to the streaming budget via `addStreamingBudget`

#### Streaming Reward Algorithm

```solidity
function _updateGlobalStreaming() internal {
    if (totalEffectiveActive == 0) return; // No active provers
    
    uint256 timeElapsed = block.timestamp - lastGlobalTime;
    uint256 totalRewards = globalRatePerSec * timeElapsed;
    
    // Cap by available budget
    if (totalRewards > globalEmissionBudget) {
        totalRewards = globalEmissionBudget;
    }
    
    if (totalRewards > 0) {
        globalAccPerEff += (totalRewards * SCALE_FACTOR) / totalEffectiveActive;
        globalEmissionBudget -= totalRewards;
    }
    
    lastGlobalTime = block.timestamp;
}

// Streaming rewards calculated for active provers only
streamingRewards = (effectiveStake * globalAccPerEff / SCALE_FACTOR) - rewardDebtEff
```

#### State Consideration
Only actively participating provers earn streaming rewards; inactive states simply freeze accrual until reactivation. Settlement is performed before state changes to ensure interval completeness.

#### Streaming Reward Formulas

```
Time Elapsed = block.timestamp - lastGlobalTime
Total Rewards = min(timeElapsed × globalRatePerSec, globalEmissionBudget)

If totalEffectiveActive > 0 AND Total Rewards > 0:
    globalAccPerEff += (Total Rewards × SCALE_FACTOR) ÷ totalEffectiveActive
    globalEmissionBudget -= Total Rewards
    lastGlobalTime = block.timestamp

Streaming Rewards (for active prover only):
AccruedStreamingRewards = (effectiveStake × globalAccPerEff) ÷ SCALE_FACTOR
PendingStreamingRewards = AccruedStreamingRewards - rewardDebtEff

Commission Distribution:
StreamingCommission = PendingStreamingRewards × commissionRate ÷ COMMISSION_RATE_DENOMINATOR
StakersStreamingReward = PendingStreamingRewards - StreamingCommission

Where:
- globalRatePerSec: ERC20 tokens per second distributed globally
- effectiveStake: total effective stake for the prover (post-slashing)
- totalEffectiveActive: sum of effective stakes for all active provers only
```

#### Mathematical Properties

1. **Conservation**: Total streaming rewards distributed ≤ `globalRatePerSec × timeElapsed`, capped by budget
2. **Proportionality**: Each active prover receives `(effectiveStake / totalEffectiveActive) × totalStreamingRewards`
3. **State Isolation**: Inactive periods do not accrue rewards, ensuring proper isolation
4. **Precision**: Uses `SCALE_FACTOR` (1e18) to maintain precision in division operations
5. **Dust Handling**: Corrected dust calculations in token units rather than scaled units


### 5. Slashing

Slashing applies a proportional penalty to *all* stake associated with a prover by scaling down a single variable `scale` (O(1)). No per‑staker writes are required; effective balances update implicitly when read.

Core update:
```
remaining = SLASH_FACTOR_DENOMINATOR - slashPPM;
newScale = oldScale * remaining / SLASH_FACTOR_DENOMINATOR;
```

Implications:
```
effectiveBefore_i = raw_i * oldScale / SCALE_FACTOR
effectiveAfter_i  = raw_i * newScale / SCALE_FACTOR = effectiveBefore_i * remaining / SLASH_FACTOR_DENOMINATOR
SlashedFraction   = slashPPM / SLASH_FACTOR_DENOMINATOR
```

Code-enforced parameters:
```
newScale > MIN_SCALE_FLOOR (revert if violated)
auto-deactivate when newScale <= DEACTIVATION_SCALE (Active -> Deactivated)
```

Treasury accounting (aggregate): totalSlashed = totalEffectiveBefore - totalEffectiveAfter is credited to `treasuryPool` once per slash (O(1)).

### Key Invariants

| Invariant | Description |
|-----------|-------------|
| Accumulators Monotonic | `accRewardPerRawShare` & `globalAccPerEff` never decrease |
| Share Conservation | Sum of individual `rawShares` equals `totalRawShares` for a prover |
| Effective Definition | `effective = rawShares * scale / SCALE_FACTOR` (sole source of slashing impact) |
| Linear Slash | Every slash scales all effective balances by the same multiplicative factor |
| Streaming Neutrality | Partitioning time into more updates does not change totals (ignoring truncation dust) |

### Edge Cases (Core Mechanics)

- Pending unstakes are slashable; withdrawal uses the *current* scale.
- Very small rewards: per‑raw-share delta may truncate to zero; undistributed dust is negligible and bounded by `totalRawShares` precision.
- Commission applies only to rewards accrued after a rate change; previously accrued pending rewards unaffected.
- If total raw shares is zero when a reward arrives, all is credited as commission (no distribution iteration required).
- Streaming distribution short-circuits when `totalEffectiveActive == 0` (no division by zero, no accumulator drift).

