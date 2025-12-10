# Epoch Rewards

Reward ingestion and distribution based on epoch windows, Brevis proofs, and capped per-epoch budgets.

## Table of Contents

- [1. Components & Roles](#1-components--roles)
- [2. Epoch Configuration](#2-epoch-configuration)
- [3. Reward Ingestion Flow](#3-reward-ingestion-flow)
- [4. Distribution Flow](#4-distribution-flow)
- [5. Constraints & Invariants](#5-constraints--invariants)
- [6. Admin & Operations](#6-admin--operations)
- [Appendix A. API Reference](#appendix-a-api-reference)
- [Appendix B. Data Layout](#appendix-b-data-layout)

---

## 1. Components & Roles

### **EpochRewards** (Execution)
- Stores per-epoch, per-prover reward allocations
- Verifies Brevis proofs before accepting new reward data
- Dispatches rewards to `StakingController` via batch `addRewards`

### **EpochManager** (Scheduling)
- Maintains epoch schedule (start, length, max reward) with append-only configs
- Resolves epoch info by timestamp or epoch number

### **Roles**
- **REWARD_UPDATER_ROLE**: Can submit proofs (`setRewards`) and trigger payouts (`distributeRewards`).
- **EPOCH_UPDATER_ROLE**: Can configure epoch schedule (init, append, prune).
- **Owner**: Can withdraw stuck reward tokens and update verification key hash.

---

## 2. Epoch Configuration

- Epochs defined by start timestamp, fixed length, and per-epoch max reward.
- Configurations are append-only and time-ordered; each entry specifies `fromEpoch`, `fromTime`, `epochLength`, `maxEpochReward`.
- Active config is the latest entry whose `fromTime` is <= target time.
- Helpers:
  - `getCurrentEpochInfo()` -> epoch + active config
  - `getEpochInfoByTimestamp(ts)` -> epoch containing `ts`
  - `getEpochInfoByEpochNumber(epoch)` -> start time + config for a specific epoch

---

## 3. Reward Ingestion Flow

1. Off-chain generates Brevis proof output containing:
   - `epoch`, `startTime`, `endTime`
   - Sorted `(prover, amount)` pairs (20-byte address + 16-byte amount)
2. Caller with `REWARD_UPDATER_ROLE` calls `setRewards(proof, circuitOutput)`:
   - Validates epoch monotonicity (`epoch >= lastUpdatedEpoch`, epoch > 0)
   - Checks window match against `getEpochInfoByEpochNumber`
   - Enforces epoch completeness (now >= epoch end)
   - Verifies Brevis proof (`_checkBrevisProof` with `vkHash`)
   - Requires prover addresses strictly increasing
   - Accumulates amounts into `epochProverRewards[epoch][prover]` and `epochTotalRewards[epoch]`
   - Reverts if cumulative rewards exceed `maxEpochReward`
   - Records `epochLastProver[epoch]` and `lastUpdatedEpoch`

---

## 4. Distribution Flow

- Caller with `REWARD_UPDATER_ROLE` invokes `distributeRewards(epoch, provers)`:
  - For each prover, loads stored amount; reverts if zero
  - Zeros stored amount to prevent double-pay
  - Calls `stakingController.addRewards(provers, amounts)` (batch)
- Tokens are pre-approved once in `_init` (`stakingToken` allowance to controller = max).

---

## 5. Constraints & Invariants

- **Max per epoch**: `epochTotalRewards[epoch]` <= `maxEpochReward` from active config.
- **Ordering**: Provers in proof output must be strictly increasing; prevents duplicates.
- **Epoch window**: Proof window must match configured start/end; current time must be past end.
- **Monotonic updates**: `epoch` must be non-zero and `>= lastUpdatedEpoch`.
- **Non-empty payouts**: Distribution reverts if any requested prover has zero stored amount.

---

## 6. Admin & Operations

- **Setup**: `_init` grants roles to reward updater and epoch updater, sets Brevis verifier, pre-approves staking token to controller.
- **VK Updates**: Owner may update `vkHash` used by Brevis verification.
- **Rescue**: Owner may `withdrawRewards(to, amount)` to recover stuck reward tokens.
- **Epoch Schedule Changes**:
  - `initEpoch(startTs, epochLength, maxReward)` seeds schedule (once).
  - `setEpochConfig(fromEpoch, epochLength, maxReward)` appends by epoch.
  - `setEpochConfigByTime(fromTime, epochLength, maxReward)` appends aligned to a timestamp boundary.
  - `popEpochConfig()` removes last config; `popFutureEpochConfigs()` removes configs starting in the future.

---

## Appendix A. API Reference

Key external functions (see `EpochRewards.sol` and `EpochManager.sol` for full signatures):
- `setRewards(bytes proof, bytes circuitOutput)`
- `distributeRewards(uint32 epoch, address[] provers)`
- `setVkHash(bytes32 vkHash)`
- `withdrawRewards(address to, uint256 amount)`
- `getCurrentEpochInfo()` / `getEpochInfoByTimestamp(uint64 ts)` / `getEpochInfoByEpochNumber(uint32 epoch)`
- `getEpochConfigs()` / `getEpochConfigNumber()`
- `initEpoch(...)`, `setEpochConfig(...)`, `setEpochConfigByTime(...)`, `popEpochConfig()`, `popFutureEpochConfigs()`

---

## Appendix B. Data Layout

### **EpochRewards Storage**
- `vkHash` — verification key hash for Brevis proofs
- `epochProverRewards[epoch][prover]` — pending reward amounts
- `epochLastProver[epoch]` — last prover ingested for ordering check
- `epochTotalRewards[epoch]` — cumulative rewards ingested for the epoch
- `lastUpdatedEpoch` — last epoch successfully ingested

### **EpochManager Storage**
- `startTimestamp` — initial epoch reference time
- `epochConfigs[]` — ordered configs: `{fromEpoch, fromTime, epochLength, maxEpochReward}`
