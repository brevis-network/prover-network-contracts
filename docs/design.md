# Prover Network Staking System Design

## Overview

The Prover Network implements a delegation-based staking system with **O(1) complexity** for all high-frequency operations using a dual-contract architecture for security isolation:

- **ProverStaking**: Manages stake/unstake/slash operations with raw share abstraction
- **ProverRewards**: Manages reward distribution with commission handling

Key algorithmic features:
- **O(1) Stake/Unstake**: Share mint/burn with proportional math, no staker iteration
- **O(1) Reward Distribution**: Single accumulator update amortizes distribution to all stakers  
- **O(1) Slashing**: Multiplicative scale adjustment affects all stakes implicitly
- **Security Isolation**: Separate token pools and focused contract responsibilities

## Architecture

### ProverStaking Contract
**Purpose**: Core staking mechanics and security
- **Responsibilities**:
  - Stake/unstake operations with two-phase unstaking
  - Slashing functionality with O(1) scale adjustments
  - Prover lifecycle management (Active → Retired → Deactivated)
  - Raw share accounting with scale factors
- **Token Holdings**: Staking tokens only
- **Security Focus**: Core staking logic isolation

### ProverRewards Contract  
**Purpose**: Reward distribution and commission management
- **Responsibilities**:
  - Reward distribution with configurable commission rates
  - Reward withdrawal and debt tracking
  - Commission rate management
  - Dust accumulation handling
- **Token Holdings**: Reward tokens only
- **Security Focus**: Reward logic isolation

### Integration Architecture
The contracts communicate through well-defined interfaces:
- ProverStaking → ProverRewards: Prover initialization, reward settlement
- ProverRewards → ProverStaking: Prover validation, share data queries

## Core Data Structures

### ProverStaking Data Model

```solidity
enum ProverState { Null, Active, Retired, Deactivated }

struct ProverInfo {
    // === BASIC METADATA ===
    ProverState state;                // Current prover status
    uint256 minSelfStake;            // Individual minimum self-stake requirement
    
    // === SHARE TRACKING ===  
    uint256 totalRawShares;          // Total raw shares (pre-slashing)
    uint256 scale;                   // Global scale factor (1e18 = no slashing)
    
    // === MIN SELF STAKE UPDATES ===
    PendingMinSelfStakeUpdate pendingMinSelfStakeUpdate; // Delayed decreases
    
    // === STAKER DATA ===
    mapping(address => StakeInfo) stakes;       // Individual stake info
    EnumerableSet.AddressSet stakers;          // Active staker enumeration
}

struct StakeInfo {
    // === ACTIVE STAKE ===
    uint256 rawShares;                    // Raw shares owned (constant until stake changes)
    
    // === UNSTAKING QUEUE ===
    PendingUnstake[] pendingUnstakes;     // Queue of unstake requests (max 10)
}

struct PendingUnstake {
    uint256 rawShares;        // Raw shares being unstaked
    uint256 unstakeTime;      // Timestamp when unstaking was requested
}
```

### ProverRewards Data Model

```solidity
struct ProverRewardInfo {
    uint64 commissionRate;            // Commission in basis points (0-10000)  
    uint256 accRewardPerRawShare;     // Accumulated rewards per raw share
    uint256 pendingCommission;        // Unclaimed prover commission
}

struct StakerRewardInfo {
    uint256 rewardDebt;               // Prevents double-claiming rewards
    uint256 pendingRewards;           // Accumulated unclaimed rewards
}
```

## Key Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `SCALE_FACTOR` | `1e18` | Fixed point precision for share & accumulator math |
| `SLASH_FACTOR_DENOMINATOR` | `1_000_000` | PPM denominator for slashing percentages |
| `MAX_SLASH_PERCENTAGE` | `500_000` | Maximum single slash = 50% |
| `COMMISSION_RATE_DENOMINATOR` | `10_000` | Basis points for commission rates |
| `MAX_PENDING_UNSTAKES` | `10` | Maximum unstake requests per staker per prover |
| `MIN_SCALE_FLOOR` | `2e17` | Minimum scale (20%) before auto-deactivation |

## Core Algorithms

### 1. Raw Shares System

The system uses a **dual-share abstraction** to achieve O(1) slashing:

```
Raw Shares: Constant until stake/unstake operations
Effective Amount: rawShares × scale ÷ SCALE_FACTOR
Scale Factor: Starts at 1e18, decreases with slashing
```

#### Conversion Formulas
```solidity
// Amount to raw shares (when staking)
rawShares = (amount × SCALE_FACTOR) ÷ scale

// Raw shares to effective amount (current value after slashing)  
effectiveAmount = (rawShares × scale) ÷ SCALE_FACTOR
```

#### Mathematical Properties
- Raw shares remain constant until explicit stake/unstake
- Scale factor provides implicit slashing across all stakes
- Effective amounts change automatically with scale adjustments
- Proportional relationships preserved under all operations

### 2. Staking & Unstaking Operations

#### Staking Process
```solidity
function stake(address _prover, uint256 _amount) {
    // 1. Convert amount to raw shares using current scale
    uint256 newRawShares = (_amount * SCALE_FACTOR) / prover.scale;
    
    // 2. Settle any pending rewards before changing shares
    proverRewards.settleStakerRewards(_prover, msg.sender, currentRawShares);
    
    // 3. Update share accounting
    stakes[msg.sender].rawShares += newRawShares;
    prover.totalRawShares += newRawShares;
    
    // 4. Track staker in enumerable set
    prover.stakers.add(msg.sender);
    
    // 5. Update reward debt for new shares
    proverRewards.updateStakerRewardDebt(_prover, msg.sender, newTotalRawShares);
}
```

#### Two-Phase Unstaking
```solidity
// Phase 1: Request unstaking (immediate)
function requestUnstake(address _prover, uint256 _amount) {
    // 1. Convert amount to raw shares
    uint256 rawSharesToUnstake = (_amount * SCALE_FACTOR) / prover.scale;
    
    // 2. Move shares to pending queue
    stakes[msg.sender].pendingUnstakes.push(PendingUnstake({
        rawShares: rawSharesToUnstake,
        unstakeTime: block.timestamp
    }));
    
    // 3. Reduce active shares
    stakes[msg.sender].rawShares -= rawSharesToUnstake;
    
    // 4. Remove from stakers set if no active stake remains
    if (stakes[msg.sender].rawShares == 0) {
        prover.stakers.remove(msg.sender);
    }
}

// Phase 2: Complete unstaking (after delay)
function completeUnstake(address _prover) {
    // Process all eligible unstake requests
    // Calculate effective amounts using current scale (includes slashing impact)
    // Transfer tokens back to staker
}
```

### 3. O(1) Reward Distribution

Instead of updating individual staker balances, the system uses a **global accumulator** pattern:

```solidity
function addRewards(address _prover, uint256 _totalRewards) {
    // 1. Calculate commission
    uint256 commission = (_totalRewards * commissionRate) / COMMISSION_RATE_DENOMINATOR;
    uint256 stakersReward = _totalRewards - commission;
    
    // 2. Credit commission directly to prover
    proverRewards[_prover].pendingCommission += commission;
    
    // 3. Update global accumulator for stakers (O(1))
    if (totalRawShares > 0) {
        uint256 deltaAcc = (stakersReward * SCALE_FACTOR) / totalRawShares;
        proverRewards[_prover].accRewardPerRawShare += deltaAcc;
        
        // Handle dust from integer division
        uint256 distributed = (deltaAcc * totalRawShares) / SCALE_FACTOR;
        uint256 dust = stakersReward - distributed;
        treasuryPool += dust; // Bounded dust accumulation
    } else {
        // No stakers exist - all rewards go to prover as commission
        proverRewards[_prover].pendingCommission += stakersReward;
    }
}
```

#### Reward Calculation (On-Demand)
```solidity
// Calculate pending rewards when needed
function calculatePendingRewards(address _prover, address _staker) view returns (uint256) {
    uint256 rawShares = proverStaking.getStakerRawShares(_prover, _staker);
    uint256 accRewards = (rawShares * accRewardPerRawShare) / SCALE_FACTOR;
    
    return stakerRewards[_prover][_staker].pendingRewards + (accRewards - rewardDebt);
}
```

### 4. O(1) Slashing Algorithm

Slashing applies a proportional penalty to **all stakes** by adjusting a single scale factor:

```solidity
function slash(address _prover, uint256 slashPPM) {
    // 1. Calculate new scale factor
    uint256 remaining = SLASH_FACTOR_DENOMINATOR - slashPPM;
    uint256 newScale = (prover.scale * remaining) / SLASH_FACTOR_DENOMINATOR;
    
    // 2. Enforce minimum scale
    require(newScale >= MIN_SCALE_FLOOR, "Scale too low");
    
    // 3. Auto-deactivate if below threshold
    if (newScale <= DEACTIVATION_SCALE && prover.state == ProverState.Active) {
        prover.state = ProverState.Deactivated;
    }
    
    // 4. Update scale (affects all stakes implicitly)
    prover.scale = newScale;
    
    // 5. Credit slashed amount to treasury pool
    uint256 totalBefore = _getTotalEffectiveStake(_prover, oldScale);
    uint256 totalAfter = _getTotalEffectiveStake(_prover, newScale);
    treasuryPool += (totalBefore - totalAfter);
}
```

#### Slashing Impact
All effective amounts automatically reflect slashing:
```
Before: effectiveAmount_i = rawShares_i × oldScale ÷ SCALE_FACTOR  
After:  effectiveAmount_i = rawShares_i × newScale ÷ SCALE_FACTOR
Result: effectiveAmount_i reduces by slashPPM percentage
```

## Integration Points

### ProverStaking → ProverRewards
```solidity
// Initialize reward tracking for new provers
proverRewards.initProverRewards(prover, commissionRate);

// Settle rewards before share changes
proverRewards.settleStakerRewards(prover, staker, rawShares);

// Update reward debt after share changes  
proverRewards.updateStakerRewardDebt(prover, staker, newRawShares);
```

### ProverRewards → ProverStaking
```solidity
// Validate prover exists and get data
require(proverStaking.isProverRegistered(prover), "Invalid prover");
uint256 totalRawShares = proverStaking.getTotalRawShares(prover);
uint256 stakerShares = proverStaking.getStakerRawShares(prover, staker);
```

## Security Design

### Token Isolation
- **Staking Tokens**: Held exclusively by ProverStaking contract
- **Reward Tokens**: Held exclusively by ProverRewards contract  
- **Zero Cross-Access**: Neither contract can access the other's tokens
- **Complete Separation**: Vulnerabilities in one domain cannot affect the other

### Access Control
- **ProverRewards Integration**: Only ProverStaking can call settlement functions
- **Admin Functions**: Only owner can link contracts and set parameters
- **Role-Based Permissions**: Separate roles for slashing, admin operations

### Operational Safety
- **Graceful Degradation**: ProverStaking functions without ProverRewards if needed
- **Interface Validation**: All cross-contract calls include proper validation
- **State Consistency**: Integration points ensure synchronized state

## Key Invariants

| Invariant | Description |
|-----------|-------------|
| **Share Conservation** | Sum of individual rawShares equals totalRawShares |
| **Accumulator Monotonicity** | accRewardPerRawShare never decreases |
| **Scale Consistency** | All effective amounts use same scale factor |
| **Proportional Slashing** | All stakes reduced by identical percentage |
| **Token Isolation** | Staking and reward tokens never intermix |

## Deployment Guide

### 1. Contract Deployment
```solidity
// Deploy tokens
ERC20 stakingToken = new ERC20("Staking Token", "STAKE");
ERC20 rewardToken = new ERC20("Reward Token", "REWARD"); // Can be same token

// Deploy ProverStaking
ProverStaking proverStaking = new ProverStaking(
    address(stakingToken),
    globalMinSelfStake // e.g., 50e18
);

// Deploy ProverRewards  
ProverRewards proverRewards = new ProverRewards(
    address(proverStaking),
    address(rewardToken)
);
```

### 2. Contract Linking
```solidity
// Link contracts (admin operation)
proverStaking.setProverRewardsContract(address(proverRewards));

// Grant slasher role
proverStaking.grantRole(proverStaking.SLASHER_ROLE(), slasherAddress);
```

## API Reference

### ProverStaking Functions
- `initProver(uint256 minSelfStake, uint64 commissionRate)` - Register as prover
- `stake(address prover, uint256 amount)` - Stake tokens to prover
- `requestUnstake(address prover, uint256 amount)` - Request unstaking
- `completeUnstake(address prover)` - Complete unstaking after delay
- `slash(address prover, uint256 slashPPM)` - Slash prover stakes
- `getProverInfo(address prover)` - Get prover state and stake data

### ProverRewards Functions
- `addRewards(address prover, uint256 amount)` - Distribute rewards
- `withdrawRewards(address prover)` - Withdraw accumulated rewards  
- `updateCommissionRate(uint64 newRate)` - Update commission rate
- `getProverRewardInfo(address prover)` - Get reward and commission data

### Migration from Single Contract
| Old Function | New Function |
|--------------|--------------|
| `proverStaking.addRewards()` | `proverRewards.addRewards()` |
| `proverStaking.withdrawRewards()` | `proverRewards.withdrawRewards()` |
| `proverStaking.updateCommissionRate()` | `proverRewards.updateCommissionRate()` |

## Edge Cases & Considerations

### Slashing During Unstaking
- Pending unstakes remain slashable during delay period
- Completion uses current scale factor (includes slashing impact)
- Stakers bear slashing risk until tokens are withdrawn

### Reward Distribution Edge Cases  
- **Zero Stakers**: All rewards credited as commission to prover
- **Tiny Rewards**: Dust from integer division accumulated in dust pool
- **Commission Changes**: Only affect rewards distributed after the change

### Scale Factor Limits
- **Minimum Scale**: Auto-deactivation when scale drops below 20%
- **Maximum Slash**: Single slash cannot exceed 50% to prevent griefing
- **Scale Floor**: Prevents mathematical underflow and ensures minimum stake value

## Gas Optimization

### O(1) Operations
- **Staking**: Constant gas regardless of total stakers
- **Reward Distribution**: Single accumulator update for all stakers  
- **Slashing**: Scale factor update affects all stakes implicitly
- **Unstaking**: Queue-based system with bounded completion cost

### Contract Size Benefits
- **Focused Functionality**: Each contract optimized for specific domain
- **Reduced Complexity**: Simpler contracts with fewer edge cases
- **Independent Optimization**: Each contract can be optimized separately

## Testing Coverage

The system includes comprehensive tests across all domains:
- **Unit Tests**: Individual function behavior and edge cases
- **Integration Tests**: Cross-contract communication and state consistency
- **Security Tests**: Access control and token isolation
- **Performance Tests**: Gas efficiency of O(1) operations
- **Edge Case Tests**: Slashing during unstaking, zero staker scenarios, dust accumulation