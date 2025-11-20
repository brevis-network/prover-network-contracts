# Vault-Based Staking System

A staking system with isolated per-prover vaults, time-delayed unstaking, proportional slashing, and reward distribution.

## Table of Contents

- [1. System Overview](#1-system-overview)
- [2. Prover Lifecycle](#2-prover-lifecycle)
- [3. Staking & Unstaking](#3-staking--unstaking)
- [4. Rewards & Commission](#4-rewards--commission)
- [5. Slashing Model](#5-slashing-model)
- [6. Parameters & Admin Controls](#6-parameters--admin-controls)
- [7. Security Considerations](#7-security-considerations)
- [Appendix A. API Reference](#appendix-a-api-reference)
- [Appendix B. Core Data Structures](#appendix-b-core-data-structures)

---

## 1. System Overview

The staking system consists of three main components:

### **StakingController** (Central Orchestrator)
- Manages prover lifecycle: delegation, rewards, slashing, and state transitions
- Holds pending unstakes and slashed funds in treasury
- Provides O(1) share accounting and enforces minimum self-stake

### **ProverVault** (Per-Prover Isolation)
- Per-prover ERC4626 vault; only controller can deposit/withdraw underlying
- Shares are transferable ERC20 (minimum self-stake portion non‑transferable)
- Rewards are added without minting shares, increasing share value for all holders

### **VaultFactory** (Deterministic Deployment)
- Creates predictable vault addresses using CREATE2 (supports pre-registration & off-chain discovery)

---

## 2. Prover Lifecycle

### **States & Transitions**

**States:**
- **Null:** Not initialized
- **Active:** Accepting delegations, participating in consensus, slashable
- **Deactivated:** Not accepting new delegations, can still complete unstakes
- **Jailed:** Admin penalty state, cannot self-reactivate

**State Transitions:**
- Initialize prover -> `Active` (requires minimum self-stake)
- Self exit or slashing below minimum -> `Deactivated` (automatic)
- Admin actions -> `Deactivated`/`Jailed`/`Active`
- Retire prover -> `Null` (no stakers, no pending unstakes/commission, dust auto-swept to treasury, retirement permanent)

### **Self-Stake Policy**

- **Minimum Enforcement:** Provers must maintain `MinSelfStake` in active vault shares
- **Exit Policy:** No partial exit below `MinSelfStake`; only full exit is allowed (triggers deactivation)
- **Pending Exclusion:** Only vault shares count, assets in pending unstakes do not
- **Dynamic Enforcement:** Changes to `MinSelfStake` don't force immediate deactivation

---

## 3. Staking & Unstaking

### **Staking Flow**
1. **Validation:** Prover exists and (if delegator) state is Active; minimal amount per stake is 1 full token (1e18 wei).
2. **Deposit:** Controller pulls user tokens and deposits into the prover's vault, receiving shares
3. **Accounting:** Share balances updated via hooks; emit `Staked` (prover, staker, assets, shares)

### **Two-Phase Unstaking**

**Phase 1: Request (`requestUnstake`)**
- Shares are immediately burned and stop accruing rewards; an `UnstakeRequest`is recorded
- Enforces minimum self-stake requirements; maximum 10 pending requests per (prover, staker) pair
- Partial exits enforce the same 1-token minimum on both the withdrawn assets and the remaning assets.

**Phase 2: Completion (`completeUnstake`)**  
- Must wait at least `unstakeDelay` seconds
- Effective amount computed via current slashing scale; transfers assets to user
- Ready requests remain slashable until completion; no "freezing" of value at maturity

---

## 4. Rewards & Commission

### **Reward Distribution**
- Caller invokes `addRewards(prover, totalAmount)` (`msg.sender` = reward source)
- Lookup rate: `rate = getCommissionRate(prover, msg.sender)` (basis points)
- Split: `commission = totalAmount * rate / 10000`; `remainder = totalAmount - commission`
- Accrue & Donate: add `commission` to `pendingCommission`; send `remainder` to the vault
- Effect: increases vault share price for all holders; reverts if vault has no shares (windfall guard)

### **Commission Rate**
- **Resolution:** `rate = commissionRates[msg.sender] if set else commissionRates[address(0)]` (basis points)
- **Rationale:** Allows flexible commission rates per reward source (e.g., high-cost proofs vs baseline sources)

---

## 5. Slashing Model

### **Slashing Functions**
The system provides two slashing interfaces that both use the same dual-target mechanism:

**Percentage-Based Slashing:**
- Function: `slash(prover, bps)` (percentage in basis points 0-10000) - primary slash function
- Uses the provided percentage to slash both targets proportionally

**Amount-Based Slashing:**
- Function: `slashByAmount(prover, amount)` - convenience variant that internally converts absolute asset amount to bps
- Derivation: `bps = amount * 10000 / (vaultAssets + pendingUnstaking)` (rounded down, capped by `maxSlashBps`)
- Result: may slash less than requested due to cap or rounding

### **Dual-Target Mechanism**
Both slashing methods apply the percentage to two targets, transferring the slashed assets to the controller treasury.
- **Vault Assets:** Proportional removal via `vault.controllerSlash()`
- **Pending Unstakes:** Apply percentage to slashingScale, reduce totalUnstaking

### **Slashing Scale & Application**
- Scale starts at 100%; each slash reduces it proportionally, with a 20% floor to prevent complete value loss
- Provers are automatically deactivated if scale falls below 40% or self-stake drops below minimum
- New unstake requests snapshot the current scale; existing requests adjust proportionally until completion

---

## 6. Parameters & Admin Controls

### **Economic Parameters**
| Parameter | Units / Format | Description |
|-----------|----------------|-------------|
| `minSelfStake` | tokens | Minimum self-stake a prover must maintain to stay Active |
| `maxSlashBps` | bps (0–10000) | Max fraction removable in a single slashing event |
| `unstakeDelay` | seconds | Minimum wait between request and completion of unstake |
| `requireAuthorization` | bool | If true, `initializeProver` requires `AUTHORIZED_PROVER_ROLE` |

### **Authorization**
- **Toggle:** When `requireAuthorization = true`, `initializeProver` requires `AUTHORIZED_PROVER_ROLE`
- **Role Lifecycle:** Admin grants/revokes `AUTHORIZED_PROVER_ROLE` independently of the toggle

### **Admin Capabilities**
- **Parameter Updates:** All economic parameters adjustable by owner
- **Treasury Management:** Withdraw accumulated slashed funds
- **Emergency Powers:** Pause the protocol and recover stuck tokens (only while paused)
- **Role Management:** Grant/revoke slasher and authorized prover roles
- **Prover Control:** Force deactivation, jailing, and retirement

### **Trust Model**
- **Owner Privileges:** Owner has significant economic control; no on-chain timelock is built in
- **Assumptions:** Governance/multisig provides off-chain assurances
- **Emergency Recovery:** Requires paused state, used for stuck tokens

---

## 7. Security Considerations

### **Built-In Protections**

**Smart Contract Safety:** Reentrancy Protection | State Consistency | Access Controls | Input Validation

**Economic Safeguards (summarized):** Core protections are specified in earlier functional sections (slashing floor, windfall guard, request limit, self‑stake minimum, two‑phase unstake with continued slashability) and not repeated here to avoid redundancy; see Sections 3–5.

### **Operational & Governance Risks**

**Admin Powers**
- Owner can change economic parameters without timelock
- Emergency token recovery (when paused) is powerful; scope carefully
- Role mismanagement (slasher / authorized prover) can enable unintended actions

**Parameter Abuse**
- Adverse adjustments to `MinSelfStake`, `MaxSlashBps`, or `UnstakeDelay` can shift economics suddenly
- Governance process (off‑chain) needed for parameter change review

**Commission Front‑Running**
- Provers may raise per‑source commission just before large reward distributions

**Implementation Drift**
- Future vault/controller code changes could desynchronize accounting assumptions
- Maintain invariant tests around share/asset accounting and slashing math

---

## Appendix A. API Reference

**Complete function documentation:** [`IStakingController.sol`](../src/staking/interfaces/IStakingController.sol)

The interface is organized into logical sections:
- **Prover Management** - Initialization, state changes, retirement
- **Staking Operations** - Stake, unstake, complete withdrawal
- **Reward & Commission** - Reward distribution and commission claims
- **Slashing** - Penalty mechanisms
- **View Functions** - Query prover info, staking data, and unstaking status
- **Vault Integration** - Vault interaction controls
- **Admin Functions** - Parameter management and emergency controls

---

## Appendix B. Core Data Structures

### **ProverInfo**
```solidity
struct ProverInfo {
    ProverState state;                               // Null | Active | Deactivated | Jailed
    address vault;                                   // Dedicated ERC4626 vault address
    mapping(address => uint256) shares;              // Fast O(1) share lookups
    EnumerableSet.AddressSet stakers;                // Efficient staker enumeration
    uint256 pendingCommission;                       // Unclaimed commission accumulated
    EnumerableMap.AddressToUintMap commissionRates;  // Source-specific commission rates in basis points (0-10000)
                                                     // address(0) = default rate for unknown sources
    uint64 joinedAt;                                 // Timestamp when the prover joined (initialized)
    string name;                                     // <= 128 bytes
    string iconUrl;                                  // <= 512 bytes
}
```

### **ProverPendingUnstakes**
```solidity
struct ProverPendingUnstakes {
    uint256 totalUnstaking;                         // Current effective total (post-slashing)
    uint256 slashingScale;                          // Cumulative scale remaining (basis points, starts at 10000)
    mapping(address => UnstakeRequest[]) requests;  // Per-staker request arrays
    EnumerableSet.AddressSet stakers;               // Stakers with pending requests
}
```

### **UnstakeRequest**
```solidity
struct UnstakeRequest {
    uint256 amount;         // Original amount when requested
    uint256 requestTime;    // Timestamp of unstake request
    uint256 scaleSnapshot;  // Slashing scale when request was made
}
```

---

**See [`IStakingController.sol`](../src/staking/interfaces/IStakingController.sol) for complete function signatures and parameter documentation.**
