# Prover Network Deployment Scripts

This directory contains deployment scripts for the Brevis Prover Network contracts including both the staking system and market contracts.

## Table of Contents

- [1. Setup](#1-setup)
- [2. Deployment Options](#2-deployment-options)
- [2a. Config JSON](#2a-config-json)
- [3. Verification](#3-verification)
- [4. Upgrade](#4-upgrade)
- [5. Example Flow](#5-example-flow)
- [6. Testing](#6-testing)

## 1. Setup

1. **Copy environment template:**
   ```bash
   cp scripts/.env.example .env
   ```

2. **Fill in your configuration in `.env` (config required):**
   ```bash
  RPC_URL=...
  PRIVATE_KEY=0x...
  ETHERSCAN_API_KEY=...

  # Required: JSON config for parameters/addresses
  DEPLOY_CONFIG=scripts/example_config.json
   ```

**Note:** The deployer becomes the initial owner of all contracts. For production, transfer ownership to a multisig after deployment.

## 2. Deployment Options

> **Deployment Architecture**: Uses **OpenZeppelin v4 upgradeable contracts** to enable **shared administration** across all proxies for simplified multisig operations.

### Deploy Complete Prover Network (Recommended)

**`DeployProverNetwork.s.sol`** ✨ - Comprehensive deployment script that deploys the entire Brevis Prover Network: VaultFactory, StakingController, StakingViewer, BrevisMarket (upgradeable with transparent proxy and **shared ProxyAdmin** for simplified administration), connects all components, and grants proper roles.

```bash
# Deploy to local testnet
forge script scripts/DeployProverNetwork.s.sol --rpc-url http://localhost:8545 --broadcast

# Deploy to testnet (e.g., Sepolia)
forge script scripts/DeployProverNetwork.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify

# Deploy to mainnet
forge script scripts/DeployProverNetwork.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify
```

### Deploy Individual Components

For specialized deployments, you can deploy individual components:

**`StakingController.s.sol`** - Deploys only the StakingController as an upgradeable contract:
```bash
forge script scripts/StakingController.s.sol --rpc-url $RPC_URL --broadcast
```

**`VaultFactory.s.sol`** - Deploys only the VaultFactory as an upgradeable contract:
```bash
forge script scripts/VaultFactory.s.sol --rpc-url $RPC_URL --broadcast
```

**`BrevisMarket.s.sol`** - Deploys only the BrevisMarket as an upgradeable contract:
```bash
forge script scripts/BrevisMarket.s.sol --rpc-url $RPC_URL --broadcast
```

**`StakingViewer.s.sol`** - Deploys only the StakingViewer (read-only contract, no proxy needed):
```bash
forge script scripts/StakingViewer.s.sol --rpc-url $RPC_URL --broadcast
```

**`MockPicoVerifier.s.sol`** - Deploys a mock PicoVerifier for testing:
```bash
forge script scripts/MockPicoVerifier.s.sol --rpc-url $RPC_URL --broadcast
```

> **Note:** Individual ProverVaults are automatically deployed via CREATE2 through the VaultFactory when provers are registered.

**All deployment scripts are config-driven via `DEPLOY_CONFIG`. To reuse an existing ProxyAdmin, set `proxyAdmin.address` in the config JSON.**

## 2a. Config JSON

All deployment scripts require a config JSON file via `DEPLOY_CONFIG`. The JSON is the single source of truth; there are no parameter env fallbacks.

Example at `scripts/example_config.json`:

```json
{
  "proxyAdmin": { "address": "0x..." },
  "staking": {
    "token": "0x...",
    "unstakeDelay": 604800,
    "minSelfStake": 0,
    "maxSlashBps": 1000
  },
  "market": {
    "picoVerifier": "0x...",
    "biddingPhaseDuration": 300,
    "revealPhaseDuration": 600,
    "minMaxFee": 0,
    "slashBps": 0,
    "slashWindow": 0,
    "protocolFeeBps": 0,
    "overcommitBps": 500
  },
  "addresses": {
    "stakingController": "0x...",
    "vaultFactory": "0x..."
  }
}
```

Usage:

```bash
export DEPLOY_CONFIG=scripts/example_config.json
forge script scripts/DeployProverNetwork.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
```

## 3. Verification

After deployment, you can verify contracts are properly connected:

```bash
# Get deployed addresses from deployment logs
STAKING_CONTROLLER_PROXY=0x...  # From deployment output
VAULT_FACTORY_PROXY=0x...       # From deployment output
STAKING_VIEWER=0x...            # From deployment output  
BREVIS_MARKET_PROXY=0x...       # From deployment output

# Verify system integration
cast call $VAULT_FACTORY_PROXY "stakingController()" --rpc-url $RPC_URL
cast call $STAKING_CONTROLLER_PROXY "vaultFactory()" --rpc-url $RPC_URL
cast call $STAKING_VIEWER "stakingController()" --rpc-url $RPC_URL

# Verify configuration
cast call $STAKING_CONTROLLER_PROXY "stakingToken()" --rpc-url $RPC_URL
cast call $STAKING_CONTROLLER_PROXY "minSelfStake()" --rpc-url $RPC_URL
cast call $STAKING_CONTROLLER_PROXY "unstakeDelay()" --rpc-url $RPC_URL

# Verify BrevisMarket setup
cast call $BREVIS_MARKET_PROXY "picoVerifier()" --rpc-url $RPC_URL
cast call $BREVIS_MARKET_PROXY "stakingController()" --rpc-url $RPC_URL
cast call $BREVIS_MARKET_PROXY "biddingPhaseDuration()" --rpc-url $RPC_URL

# Verify optional market parameters (if configured)
cast call $BREVIS_MARKET_PROXY "slashBps()" --rpc-url $RPC_URL
cast call $BREVIS_MARKET_PROXY "slashWindow()" --rpc-url $RPC_URL  
cast call $BREVIS_MARKET_PROXY "protocolFeeBps()" --rpc-url $RPC_URL

# Verify slasher role granted
cast call $STAKING_CONTROLLER_PROXY "hasRole(bytes32,address)" \
  $(cast keccak "SLASHER_ROLE") $BREVIS_MARKET_PROXY --rpc-url $RPC_URL

# Test StakingViewer functionality
cast call $STAKING_VIEWER "getSystemOverview()" --rpc-url $RPC_URL
```

## 4. Upgrade

### Who Can Upgrade?

**Shared Administration Architecture**: All proxy contracts (VaultFactory, StakingController, BrevisMarket) share the same admin for unified upgrade control. The admin can be configured in two ways:

- **Development/Testing**: EOA as direct admin (calls `upgradeTo()` directly on proxy)
- **Production**: ProxyAdmin contract as admin, owned by multisig (calls `upgrade()` on ProxyAdmin)

Our deployment scripts use the **ProxyAdmin contract pattern** for consistency, but technically the admin could be a direct EOA.

```bash
# Get the shared admin address (ProxyAdmin contract in our case)
PROXY_ADMIN=0x...  # Controls ALL proxy contracts

# Check current ProxyAdmin owner  
cast call $PROXY_ADMIN "owner()" --rpc-url $RPC_URL

# Transfer to multisig for production security (recommended)
cast send $PROXY_ADMIN "transferOwnership(address)" $MULTISIG_ADDRESS \
  --private-key $OWNER_PRIVATE_KEY --rpc-url $RPC_URL
```

**Benefits of Shared ProxyAdmin Contract Pattern**:
- ✅ Unified upgrade interface for all proxies
- ✅ Simplified multisig operations and consistent administration
- ✅ Can be owned by EOA (testing) or multisig (production)

### Example Upgrade Process

```bash
# 1. Deploy new implementation
NEW_IMPL=$(forge create src/staking/controller/StakingController.sol:StakingController \
  --constructor-args 0 0 0 0 0 \
  --private-key $DEPLOYER_KEY --rpc-url $RPC_URL --json | jq -r '.deployedTo')

# 2. Upgrade proxy using shared ProxyAdmin contract
# For EOA-owned ProxyAdmin (development/testing):
cast send $PROXY_ADMIN "upgrade(address,address)" \
  $STAKING_CONTROLLER_PROXY $NEW_IMPL \
  --private-key $OWNER_PRIVATE_KEY --rpc-url $RPC_URL

# For multisig-owned ProxyAdmin (production):
# Use your multisig interface (Safe, etc.) to call:
# upgrade($STAKING_CONTROLLER_PROXY, $NEW_IMPL)

# If you need to call an initialization function during upgrade:
# cast send $PROXY_ADMIN "upgradeAndCall(address,address,bytes)" \
#   $STAKING_CONTROLLER_PROXY $NEW_IMPL $INIT_CALLDATA \
#   --private-key $OWNER_PRIVATE_KEY --rpc-url $RPC_URL

# 3. Verify upgrade
cast call $STAKING_CONTROLLER_PROXY "implementation()" --rpc-url $RPC_URL
```

**Note**: StakingViewer is not upgradeable (deployed as a regular contract, not proxy). To upgrade StakingViewer, simply deploy a new instance with the updated StakingController address and update your frontend configuration.

## 5. Example Flow

```bash
# 1. Set up environment
cp scripts/.env.example .env
# Edit .env with your values (use multisig for OWNER_ADDRESS on mainnet)

# 2. Deploy to testnet first
forge script scripts/DeployProverNetwork.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast

# 3. Verify deployment works correctly
# Use the verification commands from section 3 to test the deployed contracts
cast call $STAKING_CONTROLLER_PROXY "stakingToken()" --rpc-url $SEPOLIA_RPC_URL
cast call $BREVIS_MARKET_PROXY "picoVerifier()" --rpc-url $SEPOLIA_RPC_URL

# 4. Deploy to mainnet with verification
forge script scripts/DeployProverNetwork.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify

# 5. Transfer ownership to multisig (recommended for production)
# See "Upgrade Management" section above

# Brevis Prover Network is ready for operation! 🎉
```

### Additional Role Management

If you need to manage roles after deployment:

```bash
# Grant additional slasher role (if needed)
cast send $STAKING_CONTROLLER_PROXY "grantRole(bytes32,address)" \
  $(cast keccak "SLASHER_ROLE") $NEW_SLASHER --rpc-url $RPC_URL

# Revoke slasher role  
cast send $STAKING_CONTROLLER_PROXY "revokeRole(bytes32,address)" \
  $(cast keccak "SLASHER_ROLE") $OLD_SLASHER --rpc-url $RPC_URL

# Check role membership
cast call $STAKING_CONTROLLER_PROXY "hasRole(bytes32,address)" \
  $(cast keccak "SLASHER_ROLE") $ADDRESS --rpc-url $RPC_URL
```

## 6. Testing

The deployment scripts are thoroughly tested to ensure reliability:

```bash
# Run deployment script tests
forge test --match-contract DeployProverNetworkTest

# Run full test suite (includes deployment tests)
forge test
```

**Frontend Integration**: After deployment, use the StakingViewer address in your frontend for optimized read operations. See `docs/frontend_guide.md` for complete integration guidance.