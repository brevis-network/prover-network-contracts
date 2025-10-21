# Staking System Frontend Integration Guide

This guide provides frontend developers with the essential information needed to integrate with the Brevis prover network staking system. The system enables users to become provers or stake with existing provers to earn rewards.

## Table of Contents

1. [System Overview](#1-system-overview)
   - 1.1 [Core Contracts](#11-core-contracts)
   - 1.2 [User Roles](#12-user-roles)
   - 1.3 [Token Approval](#13-token-approval)
2. [Core Actions](#2-core-actions)
   - 2.1 [Becoming a Prover](#21-becoming-a-prover)
   - 2.2 [Staking with a Prover](#22-staking-with-a-prover)
   - 2.3 [Two-Phase Unstaking Process](#23-two-phase-unstaking-process)
   - 2.4 [Prover Commission Management](#24-prover-commission-management)
3. [Data & Queries](#3-data--queries)
    - 3.1 [Data Structures](#31-data-structures)
    - 3.2 [Read Functions](#32-read-functions)
    - 3.3 [BrevisMarket Stats](#33-brevismarket-stats)
4. [Action Reference](#4-action-reference)
5. [Integration Patterns](#5-integration-patterns)
6. [Error Handling & Performance](#6-error-handling--performance)

---

## 1. System Overview

### 1.1 Core Contracts

**StakingController**
- Purpose: Main interface for all write operations (staking, unstaking, prover initialization, commission management)
- Frontend interaction: All user transactions go through this contract, token approvals must be made to this contract
- Key features: Handles token transfers, manages prover states, processes rewards and slashing

**ProverVault (ERC4626)**
- Purpose: Individual isolated vaults for each prover storing staked assets
- Frontend interaction: ERC20 approve on the vault share token is required before `requestUnstake`
- Key features: Standard ERC4626 vault interface, issues transferable ERC20 share tokens

**StakingViewer**
- Purpose: Optimized read-only contract providing batch operations and unified data access
- Frontend interaction: Primary contract for all data fetching to minimize RPC calls
- Key features: Batch queries, aggregated views, portfolio summaries, conversion utilities

### 1.2 User Roles

**Provers**
- Must maintain minimum self-stake to stay active
- Earn commission on rewards from their stakers
- Can set custom commission rates per reward source

**Stakers**
- Stake tokens with active provers to earn rewards
- Receive shares representing their proportional stake
- Can unstake with a time delay (two-phase process)

### 1.3 Token Approval

Some operations require ERC20 allowances to the StakingController. The approval process follows the standard pattern:

1. **Check current allowance**: `token.allowance(user, stakingController)`
2. **If insufficient**: Call `token.approve(stakingController, amount)` (*exact amount* for security or *max amount* for convenience)
3. **After approval confirmed**: Call the operation function

**Required Tokens by Operation:**

- **Staking Operations** → Approve **staking tokens**:
  - `initializeProver()`: Requires allowance ≥ `minSelfStake()`
  - `stake()`: Requires allowance ≥ stake amount

- **Unstaking Operations** → Approve **vault share tokens**:
  - `requestUnstake()`: Requires vault share allowance ≥ shares amount
  - Get vault address first: `stakingController.getProverVault(prover)`
  - Then approve: `IERC20(vault).approve(stakingController, shares)`

## 2. Core Actions

### 2.1 Becoming a Prover

**Prerequisites:**
- Have sufficient tokens for minimum self-stake
- Optionally need `AUTHORIZED_PROVER_ROLE` if authorization is required

**Contract Function:**
```solidity
function initializeProver(uint64 defaultCommissionRate) external returns (address vault)
```

**Implementation Steps:**
1. Check `minSelfStake()` requirement and verify user has sufficient tokens
2. Check if `requireAuthorization()` is enabled and user has required role
3. Get user's desired default commission rate (0-10000 basis points)
4. Handle token approval (see [Token Approval](#13-token-approval))
5. Call `initializeProver()` with commission rate
6. Save the returned vault address for reference

**Note:** `initializeProver()` automatically stakes exactly `minSelfStake()` - no separate `stake()` call needed.

### 2.2 Staking with a Prover

**Contract Function:**
```solidity
function stake(address prover, uint256 amount) external returns (uint256 shares)
```

**Implementation Steps:**
1. Verify prover is in `Active` state using `getProverState(prover)`
2. Verify user has sufficient token balance for desired stake amount
3. Handle token approval (see [Token Approval](#13-token-approval))
4. Call `stake()` with prover address and amount
5. Display shares received and updated stake balance to user

**Note**: Shares are fixed once issued; rewards increase the asset-per-share ratio (no new shares minted).

**Optional Enhancements:**
- Show prover information using `getProverInfo(prover)`
- Preview shares with `batchPreviewStake([prover], [amount])`

### 2.3 Two-Phase Unstaking Process

**Phase 1: Request Unstaking**
```solidity
function requestUnstake(address prover, uint256 shares) external returns (uint256 amount)
```

**Steps:**
1. Get user's share balance using `getUserStakeWithProver(user, prover)`
2. Validate user has sufficient shares
3. Get vault address using `getProverVault(prover)`
4. Handle vault share approval: `IERC20(vault).approve(stakingController, shares)`
5. Call `requestUnstake()` with desired share amount
6. Record the request timestamp for UI tracking

**Phase 2: Complete Unstaking** 
```solidity
function completeUnstake(address prover) external returns (uint256 amount)
```

**Steps:**
1. Check ready amount using `getUnstakingInfo(prover, user)`
2. If ready amount > 0, call `completeUnstake()` to withdraw staking tokens
3. Update UI to reflect completed withdrawals

**Key Constraints:**
- **Delay period**: Funds become available after `unstakeDelay()` seconds from request
- **Request limit**: Maximum 10 pending requests per (prover, user) pair
- **Batch completion**: `completeUnstake()` processes all ready requests at once
- **Prover self-stake**: If caller is the prover, partial unstake that would leave remaining assets > 0 but < `minSelfStake()` reverts; full exit (remaining assets == 0) is allowed and auto-deactivates the prover

### 2.4 Prover Commission Management

**Contract Functions:**
```solidity
function setCommissionRate(address source, uint64 newRate) external
function resetCommissionRate(address source) external  
function claimCommission() external returns (uint256 amount)
```

**Implementation:**
1. Get current rates using `getCommissionRates(prover)`
2. Set different rates per reward source using `setCommissionRate(source, rate)` (0-10000 basis points)
3. Use `address(0)` for default rate affecting all unspecified sources
4. Check pending commission using `getProverInfo(prover).pendingCommission`
5. Claim accumulated commission via `claimCommission()`

**Key Concepts:**
- **Default rate**: Set with `source = address(0)`, applies to all sources without specific overrides
- **Per-source overrides**: Set specific rates for known reward source contracts
- **Commission updates**: Only affect future rewards, not already earned amounts

## 3. Data & Queries

**Recommendation**: Use **StakingViewer** for most read operations to minimize RPC calls. Use **StakingController** directly only for specific single-value queries or when StakingViewer doesn't provide the needed function.

### 3.1 Data Structures

Understanding these data structures is essential as they represent the return types for most StakingViewer operations.

#### SystemOverview
```solidity
struct SystemOverview {
    uint256 totalVaultAssets;       // Total assets across all vaults
    uint256 totalActiveVaultAssets; // Assets in active prover vaults only
    uint256 totalProvers;           // Total number of provers
    uint256 activeProvers;          // Number of active provers
    uint256 totalStakers;           // Sum of per-prover staker counts (not deduplicated across provers)
    uint256 minSelfStake;           // Minimum self-stake requirement
    uint256 unstakeDelay;           // Unstaking delay period
    address stakingToken;           // The staking token contract address
}
```

#### ProverDisplayInfo
```solidity
struct ProverDisplayInfo {
    address prover;                           // Prover address
    ProverState state;                        // Current prover state
    address vault;                            // Prover's vault address
    uint256 vaultAssets;                      // Current assets in vault
    uint256 vaultShares;                      // Total shares issued by vault
    uint256 totalAssets;                      // Total prover ecosystem assets
    uint256 totalUnstaking;                   // Amount currently being unstaked
    uint256 numStakers;                       // Number of unique stakers
    uint256 slashingScale;                    // Current slashing scale
    uint256 pendingCommission;                // Commission available to claim
    uint64 defaultCommissionRate;             // Default commission rate (basis points)
    ProverCommissionInfo[] commissionRates;   // Per-source commission rates, includes default at source=address(0)
    // Appended display/profile fields
    uint64 joinedAt;                          // When the prover joined (controller-level join timestamp)
    string name;                              // Prover's display name (<= 128 bytes)
    string iconUrl;                           // Prover's icon URL (<= 512 bytes)
    uint64 profileLastUpdated;                // Last updated timestamp for profile fields
}
```

#### UserStakeInfo
```solidity
struct UserStakeInfo {
    address prover;                     // Prover address
    uint256 shares;                     // User's share balance
    uint256 currentValue;               // Current asset value of shares
    uint256 totalUnstaking;             // Total amount being unstaked
    uint256 readyToWithdraw;            // Amount ready to withdraw now
    UnstakeRequest[] pendingRequests;   // All pending unstake requests
    bool isProver;                      // True if user is the prover
}
```

#### UserPortfolio
```solidity
struct UserPortfolio {
    uint256 totalValue;           // Total value of all stakes
    uint256 totalUnstaking;       // Total amount being unstaked
    uint256 totalReadyToWithdraw; // Total ready to withdraw
    UserStakeInfo[] stakes;       // Individual stake information per prover
}
```

#### ProverCommissionInfo
```solidity
struct ProverCommissionInfo {
    address source;    // Reward source address (address(0) for default)
    uint64 rate;       // Commission rate in basis points
}
```
**Note**: Default commission rate can be identified when `source == address(0)`.

### 3.2 Read Functions

**Recommendation**: Use **StakingViewer** for most read operations to minimize RPC calls. Use **StakingController** directly only for specific single-value queries or when StakingViewer doesn't provide the needed function.

#### StakingViewer - Optimized Read Operations (Recommended)

**System Information**
```solidity
// Get complete system overview (1 RPC call instead of 8+)
function getSystemOverview() external view returns (SystemOverview memory);

// Get top provers with full display info
function getTopProvers(uint256 limit) external view returns (ProverDisplayInfo[] memory);
```

**Individual Prover/User Queries**
```solidity  
// Get single prover information
function getProverInfo(address prover) external view returns (ProverDisplayInfo memory);

// Get user's stake with specific prover
function getUserStakeWithProver(address user, address prover) external view returns (UserStakeInfo memory);

// Convert shares/assets for single prover
function convertSharesToAssets(address prover, uint256 shares) external view returns (uint256 assets);
function convertAssetsToShares(address prover, uint256 assets) external view returns (uint256 shares);
```

**Batch Operations**
```solidity
// Get multiple provers info at once  
function getProversInfo(address[] calldata provers) external view returns (ProverDisplayInfo[] memory);

// Get user portfolio across all provers
function getUserPortfolio(address user) external view returns (UserPortfolio memory);

// Batch conversions and previews
function batchConvertToAssets(address[] calldata provers, uint256[] calldata shares) external view returns (uint256[] memory);
function batchPreviewStake(address[] calldata provers, uint256[] calldata assets) external view returns (uint256[] memory, bool[] memory);
```

#### StakingController - Direct Queries (Use Sparingly)

**Basic System Parameters**
```solidity
// Get system settings
function minSelfStake() external view returns (uint256 amount);
function unstakeDelay() external view returns (uint256 delay);
function stakingToken() external view returns (IERC20 token);

// Get prover lists (consider using StakingViewer alternatives)
function getActiveProvers() external view returns (address[] memory provers);
function getAllProvers() external view returns (address[] memory provers);
```

**Single Value Queries**
```solidity
// When you only need a specific single value
function getProverState(address prover) external view returns (ProverState state);
function getStakeInfo(address prover, address staker) external view returns (uint256 shares);
```

**Note**: Most StakingController read functions are superseded by more efficient StakingViewer alternatives. Use StakingController directly only when you need a specific single value that StakingViewer doesn't provide.

### 3.3 BrevisMarket Stats

BrevisMarket exposes per-prover activity and performance stats tailored for explorer views.

#### Struct
```solidity
struct ProverStats {
    uint64 bids;          // total bids placed
    uint64 reveals;       // total bids revealed
    uint64 wins;          // assignments (times the prover was current winner)
    uint64 submissions;   // successful proof submissions
    uint64 lastActiveAt;  // last activity timestamp (only on the prover's own actions)
}
```

#### APIs
```solidity
// Lifetime totals
function getProverStatsTotal(address prover) external view returns (ProverStats memory);

// Recent stats since last reset (epoch-based, lazy per-prover)
function getProverRecentStats(address prover) external view returns (ProverStats memory);

// Current recent window metadata
function getRecentStatsInfo() external view returns (uint64 startAt, uint64 epochId);

// Admin: reset the recent window (startAt=0 uses current block timestamp)
function resetStats(uint64 newStartAt) external;
```

#### Semantics
- wins: incremented on assignment changes during reveal; reflects how many requests a prover was assigned (won).
- submissions: incremented only on successful proof submission.
- missed (derived): `wins - submissions`.
- lastActiveAt: updated on the prover’s own bid/reveal/submit.

#### Recent vs Totals
- Totals aggregate all-time.
- Recent is a lazily maintained window keyed by an epoch id; `resetStats()` by admin starts a new epoch and clears recent counters per prover upon their next activity.

## 4. Action Reference

Quick reference for frontend developers: what functions are needed for each user action.

**Become Prover**
- Write: `initializeProver(defaultCommissionRate)`
- Required reads: `minSelfStake()`, `requireAuthorization()`, token allowance check
- Optional: none (auto-stakes the minimum required amount)
- Note: Separate `stake()` call is NOT needed for initial minimum self-stake

**Stake with Prover**
- Write: `stake(prover, amount)`  
- Required reads: `getProverState(prover)` (must be Active), token balance/allowance
- Optional: `getProverInfo(prover)` for display, `batchPreviewStake([prover], [amount])` for estimation

**Preview Stake Results**
- Write: none
- Reads: `batchPreviewStake(provers[], amounts[])` or `convertAssetsToShares(prover, amount)`
- Use: Estimate shares before actual staking

**Request Unstake**
- Write: `requestUnstake(prover, shares)`
- Required reads: `getUserStakeWithProver(user, prover)` or `getStakeInfo(prover, user)`, `getProverVault(prover)`
- Required approvals: Vault share tokens to StakingController (`IERC20(vault).approve(stakingController, shares)`)
- Optional: Check pending request count (max 10 per prover)

**Complete Unstake**
- Write: `completeUnstake(prover)`
- Required reads: `getUnstakingInfo(prover, user)` for ready amount
- Optional: `getPendingUnstakes(prover, user)` for request details

**Claim Commission (Prover)**
- Write: `claimCommission()`
- Required reads: `getProverInfo(prover)` for pendingCommission amount
- Optional: `getCommissionRates(prover)` for context

**Set Commission Rate (Prover)**
- Write: `setCommissionRate(source, newRate)`
- Required reads: `getCommissionRates(prover)` to check current rates
- Use: `address(0)` for default rate, specific address for per-source override

**Get User Portfolio**
- Write: none
- Reads: `getUserPortfolio(user)` for complete overview
- Alternative: `getUserStakesWithProvers(user, provers[])` for specific provers

**Get System Overview**
- Write: none  
- Reads: `getSystemOverview()` for complete system statistics
- Use: Dashboard display, system health monitoring

**Find Active Provers**
- Write: none
- Reads: `getAllActiveProversInfo()` or `getTopProvers(limit)`
- Use: Prover selection interfaces, leaderboards

**Check Ready Withdrawals**
- Write: none
- Reads: `getUserReadyWithdrawals(user)`
- Use: "One-click withdraw" features across all provers

## 5. Integration Patterns

#### Prover Detail Page
```typescript
// Single RPC call gets all prover information
const proverInfo = await stakingViewer.getProverInfo(proverAddress);

// Display comprehensive prover data:
// - State, total assets, vault assets/shares
// - Number of stakers, slashing scale
// - Commission rates (default + per-source)
// - Pending commission available to claim

// Local conversion for UI display (no additional RPC)
const sharePrice = proverInfo.vaultShares > 0 
    ? proverInfo.vaultAssets / proverInfo.vaultShares : 1;

// Market stats for this prover (totals + recent)
const total = await brevisMarket.getProverStatsTotal(proverAddress);
const recent = await brevisMarket.getProverRecentStats(proverAddress);
const [recentStartAt, recentEpochId] = await brevisMarket.getRecentStatsInfo();

// UI metrics:
// - Proofs Won (lifetime): total.wins
// - Success Rate (lifetime): total.wins > 0 ? total.submissions / total.wins : 0
// - Missed Deadlines (lifetime): total.wins - total.submissions
// - Recent window equivalents: use `recent` instead of `total`
// - Last active: prefer `recent.lastActiveAt` if > 0 else `total.lastActiveAt`
```

#### User Portfolio Dashboard 
```typescript
// Single RPC call gets complete user portfolio
const portfolio = await stakingViewer.getUserPortfolio(userAddress);

// Display total portfolio value and breakdown:
// - Total staked value across all provers  
// - Total unstaking (with timeline)
// - Ready-to-withdraw amounts
// - Individual stake details per prover

// Each stake includes: shares, current value, unstaking status, pending requests
```

#### Prover Selection Interface
```typescript
// Get top provers with full display info
const topProvers = await stakingViewer.getTopProvers(20);

// Or get all active provers  
const activeProvers = await stakingViewer.getAllActiveProversInfo();

// Display prover cards with:
// - Display name and icon (fallbacks if empty)
// - Joined since (joinedAt)
// - Total assets and number of stakers
// - Commission rates and current state
// - Market stats: proofs won, success rate, last active
// - Share price and vault utilization
// - Enable filtering/sorting on retrieved data

// For stake amount preview (batch operation)
const assets = [amount1, amount2, amount3];
const provers = [prover1, prover2, prover3];
const [shares, eligible] = await stakingViewer.batchPreviewStake(provers, assets);
```

#### User Stake Management Page
```typescript
// Get user's stake with specific prover
const stakeInfo = await stakingViewer.getUserStakeWithProver(userAddress, proverAddress);

// Display current stake:
// - Share balance and current asset value
// - Pending unstake requests with timelines  
// - Ready-to-withdraw amounts
// - Prover relationship (if user is the prover)

// For ready withdrawals across all provers
const [provers, amounts, totalReady] = await stakingViewer.getUserReadyWithdrawals(userAddress);
```

#### System Overview Dashboard  
```typescript
// Single RPC call for complete system stats
const overview = await stakingViewer.getSystemOverview();

// Display system metrics:
// - Total assets staked and active prover assets
// - Number of provers (total and active)
// - Total unique stakers across system
// - System parameters (min stake, unstake delay)
```

## 6. Error Handling & Performance

### Error Handling

Common error conditions and user-friendly solutions:

**Prover Not Active**
- Condition: Trying to stake with inactive prover  
- Solution: Select an active prover or wait for reactivation

**Unstake Not Ready**
- Condition: Attempting to complete unstake before delay period
- Solution: Show remaining time, enable completion when ready

**Too Many Pending Unstakes**
- Condition: More than 10 pending requests per prover
- Solution: Complete existing requests or wait for some to mature

**Insufficient Shares** 
- Condition: Requesting to unstake more shares than owned
- Solution: Show available balance, validate input amounts

### RPC Call Optimization

**Always use StakingViewer when possible** to minimize RPC calls:
- `getUserPortfolio()` replaces 20+ individual calls per user
- `getSystemOverview()` replaces 8+ system parameter calls  
- `getProverInfo()` provides complete prover data in 1 call
- Local conversions using `vaultAssets/vaultShares` ratio avoid RPC calls entirely

### Local Share/Asset Calculations

With `ProverDisplayInfo.vaultAssets` and `ProverDisplayInfo.vaultShares`, you can calculate conversions locally:
```typescript
// Convert shares to assets locally (no RPC needed - approximate)
const assetsFromShares = (shares * proverInfo.vaultAssets) / proverInfo.vaultShares;

// Convert assets to shares locally (approximate)  
const sharesFromAssets = (assets * proverInfo.vaultShares) / proverInfo.vaultAssets;

// Use RPC conversions for exact on-chain precision when needed
const exactAssets = await stakingViewer.convertSharesToAssets(prover, shares);
```