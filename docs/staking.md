# ProverStaking Contract Design Document

## Overview

The `ProverStaking` contract implements a delegation-based staking system for prover networks. It enables users to stake ERC20 tokens with provers while maintaining O(1) complexity for critical operations through a dual-share mechanism and global accumulators. It implements four core algorithms:

1. **O(1) Staking/Unstaking**: Raw shares system enables proportional calculations without iteration
2. **O(1) Reward Distribution**: Global accumulator distributes proof rewards to all stakers simultaneously
3. **O(1) Slashing**: Scale factor mechanism slashes all stakes without touching individual balances
4. **O(1) Streaming Rewards**: Global emission system distributes time-based rewards to active provers


## Table of Contents

- [Core Data Structures](#core-data-structures)
- [Key Constants](#key-constants)
- [Key Algorithms](#key-algorithms)
   - [Raw Shares System](#1-raw-shares-system)
   - [Staking & Unstaking](#2-staking--unstaking)
   - [Proof Reward Distribution](#3-proof-reward-distribution)
   - [Slashing](#4-slashing)
   - [Streaming Rewards System](#5-streaming-rewards-system)

---

## Core Data Structures


```solidity
enum ProverState {
    Null,         // Prover not initialized
    Active,       // Prover accepting new stakes
    Retired,      // Prover deactivated, no new stakes (can unretire)
    Deactivated   // Prover force-deactivated by admin (cannot unretire)
}

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
    uint256 pendingCommission;        // Unclaimed commission (proof + streaming)
    
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
        // O(1) operation: update accumulator for stakers
        prover.accRewardPerRawShare += (stakersReward * SCALE_FACTOR) / prover.totalRawShares;
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

### 4. Slashing

Each prover maintains an independent scale factor that affects all stakes proportionally. Slashing updates only this single value, and all effective amounts automatically reflect the slash.

```solidity
function slash(address _prover, uint256 _percentage) external onlyRole(SLASHER_ROLE) {
    require(_percentage < SLASH_FACTOR_DENOMINATOR, "Cannot slash 100%");

    ProverInfo storage prover = provers[_prover];

    // O(1) operation: update single scale factor
    uint256 remainingFactor = SLASH_FACTOR_DENOMINATOR - _percentage;
    prover.scale = (prover.scale * remainingFactor) / SLASH_FACTOR_DENOMINATOR;

    // All stakes automatically reflect new value via _effectiveAmount()
    // This affects both active stakes AND pending unstakes
}
```

#### Slashing Formula

```
newScale = oldScale × (SLASH_FACTOR_DENOMINATOR - slashPercentage) ÷ SLASH_FACTOR_DENOMINATOR

Where:
- SLASH_FACTOR_DENOMINATOR = 1,000,000 (parts per million for higher precision)
- slashPercentage: 0-1,000,000 (0% to 100%)

Example: 30% slash (300,000 ppm)
newScale = oldScale × (1,000,000 - 300,000) ÷ 1,000,000 = oldScale × 0.7
```

**Example**: 30% slash → `rawShares = 1000, scale = 0.7e18, effective = 700 tokens`

### 5. Streaming Rewards System

The streaming rewards system provides continuous time-based reward distribution to all active provers. Unlike proof rewards which are tied to specific work completion, streaming rewards are distributed proportionally based on effective shares over time.

#### Key Components

1. **Global Accumulator**: `accStreamingRewardPerEffectiveShare` tracks streaming rewards earned per effective share
2. **Time-Based Distribution**: `streamingRate` defines tokens distributed per second across all active provers
3. **Effective Share Weighting**: Uses effective shares (raw shares × multiplier) for proportional distribution
4. **Separate Accounting**: Streaming rewards use dedicated debt tracking (`rewardDebtEff`) independent of proof rewards

#### Streaming Reward Algorithm

```solidity
function _updateGlobalAccumulator() internal {
    if (totalEffectiveActive == 0) return; // No active provers
    
    uint256 timeElapsed = block.timestamp - lastStreamingUpdate;
    uint256 newRewards = timeElapsed * streamingRate;
    
    accStreamingRewardPerEffectiveShare += (newRewards * SCALE_FACTOR) / totalEffectiveActive;
    lastStreamingUpdate = block.timestamp;
}

// Streaming rewards calculated on-demand
streamingRewards = (effectiveShares * accStreamingRewardPerEffectiveShare / SCALE_FACTOR) - rewardDebtEff
```

#### State Transition Impact

Streaming rewards are affected by prover state changes:

- **Joining (Inactive → Active)**: Adds effective shares to `totalEffectiveActive`, updates debt to current accumulator
- **Leaving (Active → Deactivated)**: Removes effective shares from `totalEffectiveActive`, settles accrued rewards
- **Reactivation (Deactivated → Active)**: Re-adds effective shares, resets debt to prevent double-claiming

```solidity
function _updateEffectiveActiveShares(address prover, bool isActive) internal {
    ProverInfo storage info = provers[prover];
    
    if (isActive && info.status != ProverStatus.Active) {
        // Prover becoming active
        totalEffectiveActive += info.totalEffectiveShares;
        info.rewardDebtEff = (info.totalEffectiveShares * accStreamingRewardPerEffectiveShare) / SCALE_FACTOR;
    } else if (!isActive && info.status == ProverStatus.Active) {
        // Prover becoming inactive
        _settleStreamingRewards(prover);
        totalEffectiveActive -= info.totalEffectiveShares;
    }
}
```

#### Commission and Streaming Rewards

Streaming rewards respect the same commission structure as proof rewards:
- Commission percentage applied to total streaming rewards earned by prover
- Remaining rewards distributed to stakers based on raw share percentage
- Commission credited to `pendingCommission`, staker rewards to `pendingRewards`

#### Streaming Reward Formulas

```
Time Elapsed = block.timestamp - lastStreamingUpdate
New Rewards = timeElapsed × streamingRate

If totalEffectiveActive > 0:
    accStreamingRewardPerEffectiveShare += (newRewards × SCALE_FACTOR) ÷ totalEffectiveActive
    lastStreamingUpdate = block.timestamp

Streaming Rewards (for prover):
AccruedStreamingRewards = (effectiveShares × accStreamingRewardPerEffectiveShare) ÷ SCALE_FACTOR
PendingStreamingRewards = AccruedStreamingRewards - rewardDebtEff

Commission Distribution:
StreamingCommission = PendingStreamingRewards × commissionRate ÷ COMMISSION_RATE_DENOMINATOR
StakersStreamingReward = PendingStreamingRewards - StreamingCommission

Where:
- streamingRate: ERC20 tokens per second
- effectiveShares: rawShares × effectiveMultiplier
- totalEffectiveActive: sum of effective shares for all active provers
```

#### Mathematical Properties

1. **Conservation**: Total streaming rewards distributed equals `streamingRate × timeElapsed × numActivePeriods`
2. **Proportionality**: Each prover receives `(effectiveShares / totalEffectiveActive) × totalStreamingRewards`
3. **Independence**: Streaming rewards calculations are independent of proof rewards
4. **Precision**: Uses `SCALE_FACTOR` (1e18) to maintain precision in division operations
