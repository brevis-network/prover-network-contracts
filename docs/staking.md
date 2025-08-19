# Prover Network Staking System

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
    ProverState state;                // Current prover status
    uint256 totalRawShares;          // Total raw shares (pre-slashing)
    uint256 scale;                   // Global scale factor (1e18 = no slashing)
    mapping(address => StakeInfo) stakes;       // Individual stake info
    EnumerableSet.AddressSet stakers;          // Active staker enumeration
}

struct StakeInfo {
    uint256 rawShares;                    // Raw shares owned (constant until stake changes)
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
| `MAX_SLASH_PERCENTAGE` | `500_000` | Maximum single slash = 50% (default, configurable) |
| `COMMISSION_RATE_DENOMINATOR` | `10_000` | Basis points for commission rates |
| `MAX_PENDING_UNSTAKES` | `10` | Maximum unstake requests per staker per prover |
| `DEACTIVATION_SCALE` | `2e17` | Scale threshold (20%) for auto-deactivation |
| `MIN_SCALE_FLOOR` | `1e17` | Hard minimum scale (10%) to prevent underflow |

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
    // 1. Validation and early transfer
    IERC20(stakingToken).safeTransferFrom(msg.sender, address(this), _amount);
    
    // 2. Convert amount to raw shares using current scale
    uint256 newRawShares = (_amount * SCALE_FACTOR) / prover.scale;
    
    // 3. Settle any pending rewards before changing shares
    if (address(proverRewards) != address(0)) {
        proverRewards.settleStakerRewards(_prover, msg.sender, currentRawShares);
    }
    
    // 4. Update share accounting
    stakeInfo.rawShares += newRawShares;
    prover.totalRawShares += newRawShares;
    
    // 5. Track staker in enumerable set
    if (stakeInfo.rawShares == newRawShares) { // First time staking
        prover.stakers.add(msg.sender);
    }
    
    // 6. Update reward debt for new shares
    if (address(proverRewards) != address(0)) {
        proverRewards.updateStakerRewardDebt(_prover, msg.sender, stakeInfo.rawShares);
    }
}
```

#### Two-Phase Unstaking
```solidity
// Phase 1: Request unstaking (immediate)
function requestUnstake(address _prover, uint256 _amount) {
    // 1. Convert amount to raw shares
    uint256 rawSharesToUnstake = (_amount * SCALE_FACTOR) / prover.scale;
    
    // 2. Settle pending rewards before share changes
    if (address(proverRewards) != address(0)) {
        proverRewards.settleStakerRewards(_prover, msg.sender, stakeInfo.rawShares);
    }
    
    // 3. Reduce active shares first
    stakeInfo.rawShares -= rawSharesToUnstake;
    prover.totalRawShares -= rawSharesToUnstake;
    
    // 4. Add to pending unstake queue
    stakeInfo.pendingUnstakes.push(PendingUnstake({
        rawShares: rawSharesToUnstake,
        unstakeTime: block.timestamp
    }));
    
    // 5. Remove from stakers set if no active stake remains
    if (stakeInfo.rawShares == 0) {
        prover.stakers.remove(msg.sender);
    }
    
    // 6. Update reward debt for reduced shares
    if (address(proverRewards) != address(0)) {
        proverRewards.updateStakerRewardDebt(_prover, msg.sender, stakeInfo.rawShares);
    }
}

// Phase 2: Complete unstaking (after delay)
function completeUnstake(address _prover) {
    // 1. Process all eligible unstake requests chronologically
    // 2. Calculate effective amounts using current scale (includes slashing impact)
    // 3. Remove completed requests from queue
    // 4. Transfer total tokens back to staker
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
    
    // 2. Enforce hard minimum scale (prevents catastrophic underflow)
    require(newScale > MIN_SCALE_FLOOR, "ScaleTooLow");
    
    // 3. Apply new scale
    prover.scale = newScale;
    
    // 4. Auto-deactivate if below soft threshold
    if (newScale <= DEACTIVATION_SCALE && prover.state == ProverState.Active) {
        prover.state = ProverState.Deactivated;
        activeProvers.remove(_prover);
    }
    
    // 5. Credit slashed amount to treasury pool
    uint256 totalBefore = _getTotalEffectiveStake(_prover); // Uses old scale
    uint256 totalAfter = _getTotalEffectiveStake(_prover);  // Uses new scale
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

## Prover Lifecycle & States

### Prover States
```solidity
enum ProverState {
    Null,        // Not registered
    Active,      // Accepting new stakes and proofs
    Retired,     // Self-initiated exit, can unretire if conditions met
    Deactivated  // Admin or slashing deactivated, admin can reactivate
}
```

### State Transitions

#### Initialization: Null → Active
- Call `initProver(commissionRate)`
- Automatically stakes global minimum self-stake amount
- Initializes reward tracking if ProverRewards contract is set

#### Retirement: Active → Retired (Self-Initiated)
- Anyone can call `retireProver()` when conditions are met:
  - No active stakes remain (`totalRawShares == 0`)
  - No pending commission rewards
- Prover can `unretireProver()` if:
  - Scale factor > `DEACTIVATION_SCALE` (not severely slashed)
  - Meets global minimum self-stake requirements

#### Deactivation: Active → Deactivated
- **Auto-deactivation**: Scale drops to/below `DEACTIVATION_SCALE` (20%)
- **Admin deactivation**: Owner calls `deactivateProver()`
- **Self-exit**: Prover unstakes all self-stake triggers auto-deactivation

#### Reactivation: Deactivated → Active
- Admin calls `reactivateProver()` if:
  - Scale factor > `DEACTIVATION_SCALE`
  - Meets global minimum self-stake requirements

### Global Minimum Self-Stake Management
- Single global minimum self-stake applies to all provers
- Set during contract initialization via constructor parameter
- Can be updated by owner via `setGlobalParam()`
- All provers must maintain self-stake above global minimum to accept new delegations
- Exception: Can go to zero for complete exit (triggers auto-deactivation)

## Integration Points

### ProverStaking → ProverRewards
```solidity
// Initialize reward tracking for new provers
if (address(proverRewards) != address(0)) {
    proverRewards.initProverRewards(prover, commissionRate);
}

// Settle rewards before share changes
if (address(proverRewards) != address(0)) {
    proverRewards.settleStakerRewards(prover, staker, rawShares);
}

// Update reward debt after share changes  
if (address(proverRewards) != address(0)) {
    proverRewards.updateStakerRewardDebt(prover, staker, newRawShares);
}
```

### ProverRewards → ProverStaking
```solidity
// Validate prover exists and get data
require(proverStaking.isProverRegistered(prover), "Invalid prover");
uint256 totalRawShares = proverStaking.getTotalRawShares(prover);
uint256 stakerShares = proverStaking.getStakerRawShares(prover, staker);
ProverState state = proverStaking.getProverState(prover);
```

### Security Design

### Token Isolation
- **Staking Tokens**: Held exclusively by ProverStaking contract
- **Reward Tokens**: Held exclusively by ProverRewards contract  
- **Zero Cross-Access**: Neither contract can access the other's tokens
- **Complete Separation**: Vulnerabilities in one domain cannot affect the other

### Access Control
- **ProverRewards Integration**: Only ProverStaking can call settlement functions
- **Admin Functions**: Only owner can link contracts and set global parameters
- **Role-Based Permissions**: `SLASHER_ROLE` for slashing operations

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
| **Scale Bounds** | DEACTIVATION_SCALE > MIN_SCALE_FLOOR (20% > 10%) |

## Global Parameters

The system uses a unified parameter management system:

```solidity
enum ParamName {
    UnstakeDelay,        // Time delay for unstaking completion
    MinSelfStake,  // Minimum self-stake required for all provers
    MaxSlashFactor   // Maximum slash factor per operation
}
```

### Default Values
- **UnstakeDelay**: 7 days
- **MinSelfStake**: Set during contract initialization
- **MaxSlashFactor**: 500,000 PPM (50%)

### Parameter Updates
- Only owner can update via `setGlobalParam(ParamName, uint256)`
- Changes take effect immediately
- Events emitted for all parameter changes

## Deployment Guide

### 1. Contract Deployment
```solidity
// Deploy staking token (or use existing)
ERC20 stakingToken = new ERC20("Staking Token", "STAKE");

// Deploy reward token (can be same as staking token)
ERC20 rewardToken = new ERC20("Reward Token", "REWARD");

// Deploy ProverStaking with global minimum self-stake
ProverStaking proverStaking = new ProverStaking(
    address(stakingToken),
    50e18 // Example: 50 tokens minimum self-stake
);

// Deploy ProverRewards
ProverRewards proverRewards = new ProverRewards(
    address(proverStaking),
    address(rewardToken)
);
```

### 2. Contract Configuration
```solidity
// Link ProverRewards to ProverStaking
proverStaking.setProverRewardsContract(address(proverRewards));

// Grant slasher role for slashing operations
proverStaking.grantRole(proverStaking.SLASHER_ROLE(), slasherAddress);

// Optional: Update global parameters
proverStaking.setGlobalParam(ProverStaking.ParamName.UnstakeDelay, 14 days);
proverStaking.setGlobalParam(ProverStaking.ParamName.MaxSlashFactor, 300000); // 30%
```

### 3. Upgradeability Support
For upgradeable deployments, use the no-argument constructor and initialize:
```solidity
// Deploy behind proxy
ProverStaking proverStaking = new ProverStaking();
proverStaking.init(address(stakingToken), minSelfStake);

ProverRewards proverRewards = new ProverRewards();
proverRewards.init(address(proverStaking), address(rewardToken));
```

## API Reference

### ProverStaking Functions

#### Core Operations
- `initProver(uint64 commissionRate)` - Register as prover with global minimum stake
- `stake(address prover, uint256 amount)` - Stake tokens to prover
- `requestUnstake(address prover, uint256 amount)` - Request unstaking
- `requestUnstakeAll(address prover)` - Request unstaking all tokens
- `completeUnstake(address prover)` - Complete unstaking after delay

#### Prover Management
- `retireProver(address prover)` - Retire a prover (anyone can call)
- `unretireProver()` - Unretire self (prover only)

#### Admin Operations
- `slash(address prover, uint256 percentage)` - Slash prover stakes (SLASHER_ROLE)
- `deactivateProver(address prover)` - Deactivate prover (owner)
- `reactivateProver(address prover)` - Reactivate prover (owner)
- `setGlobalParam(ParamName param, uint256 value)` - Set global parameters (owner)
- `setProverRewardsContract(address proverRewards)` - Link rewards contract (owner)
- `withdrawFromTreasuryPool(address to, uint256 amount)` - Withdraw slashed tokens (owner)

#### View Functions
- `getProverInfo(address prover)` - Get comprehensive prover information
- `getStakeInfo(address prover, address staker)` - Get staker's position details
- `isProverEligible(address prover, uint256 minStake)` - Check work eligibility
- `getAllProvers()` - Get all registered provers
- `activeProverList()` - Get currently active provers
- `getProverStakers(address prover)` - Get stakers for a prover

### ProverRewards Functions

#### Core Operations
- `addRewards(address prover, uint256 amount)` - Distribute rewards with commission
- `withdrawRewards(address prover)` - Withdraw accumulated rewards
- `updateCommissionRate(uint64 newRate)` - Update commission rate (prover only)

#### Admin Operations
- `withdrawFromTreasuryPool(address to, uint256 amount)` - Withdraw dust (owner)

#### View Functions
- `getProverRewardInfo(address prover)` - Get commission and accumulator data
- `getStakerRewardInfo(address prover, address staker)` - Get reward details
- `calculateTotalPendingRewards(address prover, address staker)` - Calculate total pending

### Migration from Single Contract
For systems migrating from a monolithic staking contract:

| Old Function | New Location |
|--------------|--------------|
| `addRewards()` | `ProverRewards.addRewards()` |
| `withdrawRewards()` | `ProverRewards.withdrawRewards()` |
| `updateCommissionRate()` | `ProverRewards.updateCommissionRate()` |
| Core staking functions | Remain in `ProverStaking` |

## Edge Cases & Considerations

### Slashing During Unstaking
- Pending unstakes remain subject to slashing during the delay period
- Completion uses current scale factor, reflecting any slashing that occurred
- Stakers bear slashing risk until tokens are fully withdrawn
- No protection against slashing during unstaking period

### Reward Distribution Scenarios
- **Zero Stakers**: All rewards credited as commission to prover
- **Tiny Rewards**: Integer division dust accumulated in treasury pool
- **Commission Changes**: Only affect rewards distributed after the change
- **Prover Self-Rewards**: Prover receives both staking rewards and commission

### Self-Stake Management
- **Below Global Minimum**: Prover cannot accept new delegations (own staking still allowed)
- **Complete Exit**: Unstaking all self-stake triggers auto-deactivation
- **Partial Exit**: Must maintain global minimum or go to zero
- **Reactivation**: Requires meeting global minimum self-stake requirements

### Scale Factor Edge Cases
- **Severe Slashing**: Auto-deactivation when scale ≤ 20% (DEACTIVATION_SCALE)
- **Hard Floor**: Slashing cannot reduce scale below 10% (MIN_SCALE_FLOOR)
- **Mathematical Precision**: Scale uses 18 decimal precision for accuracy
- **Reactivation Blocked**: Cannot reactivate if scale ≤ deactivation threshold

## Treasury Pool Management

Both contracts maintain separate treasury pools for different purposes:

### ProverStaking Treasury Pool
- **Source**: Tokens from slashing operations
- **Purpose**: Captures the difference between pre-slash and post-slash total values
- **Withdrawal**: Owner can withdraw via `withdrawFromTreasuryPool(address to, uint256 amount)`
- **Accounting**: Automatically updated during slash operations

### ProverRewards Treasury Pool  
- **Source**: Dust from integer division in reward distribution
- **Purpose**: Accumulates rounding errors to prevent token loss
- **Withdrawal**: Owner can withdraw via `withdrawFromTreasuryPool(address to, uint256 amount)`
- **Bounded Growth**: Dust per distribution limited by total stakers

### Treasury Pool Calculations
```solidity
// Slashing treasury (ProverStaking)
uint256 totalBefore = (totalRawShares * oldScale) / SCALE_FACTOR;
uint256 totalAfter = (totalRawShares * newScale) / SCALE_FACTOR;
treasuryPool += (totalBefore - totalAfter);

// Reward dust treasury (ProverRewards)
uint256 distributed = (deltaAcc * totalRawShares) / SCALE_FACTOR;
uint256 dust = stakersReward - distributed;
treasuryPool += dust;
```

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

The system includes comprehensive test coverage across all functional areas:

### Unit Tests
- **Individual Functions**: Behavior verification and parameter validation
- **State Transitions**: Prover lifecycle and state management
- **Mathematical Operations**: Share conversions and scale factor calculations
- **Access Control**: Permission checks and role-based restrictions

### Integration Tests  
- **Cross-Contract Communication**: ProverStaking ↔ ProverRewards interaction
- **End-to-End Workflows**: Complete stake → reward → unstake cycles
- **State Synchronization**: Consistent state across both contracts
- **Graceful Degradation**: ProverStaking operation without ProverRewards

### Security Tests
- **Access Control**: Unauthorized access prevention
- **Token Isolation**: Separation of staking and reward token pools
- **Reentrancy Protection**: ReentrancyGuard effectiveness
- **Integer Overflow/Underflow**: SafeMath and bounds checking

### Performance Tests
- **Gas Efficiency**: O(1) operation verification
- **Batch Operations**: Multiple unstake request handling
- **Large Scale**: Behavior with many stakers and provers
- **Edge Conditions**: Maximum values and boundary conditions

### Edge Case Coverage
- **Slashing Scenarios**: Various slash percentages and timing
- **Zero-Value Operations**: Empty stakes, rewards, and withdrawals
- **Extreme Scale Factors**: Near minimum and maximum values
- **Queue Management**: Maximum pending unstake scenarios