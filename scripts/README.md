# Prover Network Deployment Scripts

This directory contains deployment scripts for the Brevis Prover Network contracts including both the staking system and market contracts.

## Table of Contents

- [1. Overview](#1-overview)
- [2. Setup](#2-setup)
- [3. Verification](#3-verification)
- [4. Upgrade](#4-upgrade)
- [5. Example Flow](#5-example-flow)
- [6. Testing](#6-testing)

## 1. Overview

> **Deployment Architecture**: Uses **OpenZeppelin v4 upgradeable contracts** to enable **shared administration** across all proxies for simplified multisig operations.

### Deploy Complete Prover Network (Recommended)

**`DeployProverNetwork.s.sol`** ✨ - Comprehensive deployment script that deploys the entire Brevis Prover Network: VaultFactory, StakingController, StakingViewer, BrevisMarket (upgradeable with transparent proxy and **shared ProxyAdmin** for simplified administration), connects all components, and grants proper roles.

```bash
# Deploy to local testnet
forge script script/DeployProverNetwork.s.sol --rpc-url http://localhost:8545 --broadcast

# Deploy to testnet (e.g., Sepolia)
forge script script/DeployProverNetwork.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify

# Deploy to mainnet
forge script script/DeployProverNetwork.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify
```

### Deploy Individual Components

For specialized deployments, you can deploy individual components using manual proxy deployment:

> **Note**: Individual scripts use the same **shared ProxyAdmin approach** as the main deployment script. Each creates its own ProxyAdmin, but for production you should transfer ownership to the same multisig account to maintain unified administration.

**`StakingController.s.sol`** - Deploys only the StakingController as an upgradeable contract:
```bash
forge script script/StakingController.s.sol --rpc-url $RPC_URL --broadcast
```

**`VaultFactory.s.sol`** - Deploys only the VaultFactory as an upgradeable contract:
```bash
forge script script/VaultFactory.s.sol --rpc-url $RPC_URL --broadcast
```

**`BrevisMarket.s.sol`** - Deploys only the BrevisMarket as an upgradeable contract:
```bash
forge script script/BrevisMarket.s.sol --rpc-url $RPC_URL --broadcast
```

**`StakingViewer.s.sol`** - Deploys only the StakingViewer (read-only contract, no proxy needed):
```bash
forge script script/StakingViewer.s.sol --rpc-url $RPC_URL --broadcast
```

**`MockPicoVerifier.s.sol`** - Deploys a mock PicoVerifier for testing:
```bash
forge script script/MockPicoVerifier.s.sol --rpc-url $RPC_URL --broadcast
```

> **Note:** Individual ProverVaults are automatically deployed via CREATE2 through the VaultFactory when provers are registered.

**All deployment scripts use manual proxy deployment with shared ProxyAdmin pattern for simplified administration. After successful deployment, the complete Brevis Prover Network is ready for operation with all system integrations handled automatically.**

## 2. Setup

1. **Copy environment template:**
   ```bash
   cp script/.env.example .env
   ```

2. **Fill in your configuration in `.env`:**
   ```bash
   # Required for all deployments
   PRIVATE_KEY=0x...                    # Deployer private key (becomes initial owner)
   
   # Staking System
   STAKING_TOKEN_ADDRESS=0x...          # ERC20 token for staking
   UNSTAKE_DELAY=604800                 # 7 days in seconds
   MIN_SELF_STAKE=1000000000000000000   # 1 token minimum
   MAX_SLASH_BPS=5000                   # 50% max slashing
   
   # For standalone StakingViewer deployment
   STAKING_CONTROLLER_ADDRESS=0x...     # Deployed StakingController address
   
   # Market System  
   PICO_VERIFIER_ADDRESS=0x...          # PicoVerifier contract
   BIDDING_PHASE_DURATION=300           # 5 minutes
   REVEAL_PHASE_DURATION=600            # 10 minutes
   MIN_MAX_FEE=1000000000000000         # 0.001 ETH spam protection
   
   # Market System - Optional Parameters (set to 0 to skip)
   MARKET_SLASH_BPS=1000                # 10% slashing percentage for penalties (0 to disable)
   MARKET_SLASH_WINDOW=604800           # 7 days slashing window after deadline (0 to disable)
   MARKET_PROTOCOL_FEE_BPS=100          # 1% protocol fee (0-10000, 0 to disable)
   ```

**Note:** The deployer becomes the initial owner of all contracts. For production, transfer ownership to a multisig after deployment.

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

**Shared ProxyAdmin Approach**: All proxy contracts (VaultFactory, StakingController, BrevisMarket) are controlled by a **single shared ProxyAdmin** contract, simplifying administration:

```bash
# Get the shared ProxyAdmin address (from deployment logs)
SHARED_PROXY_ADMIN=0x...  # Controls ALL proxy contracts

# Check current ProxyAdmin owner  
cast call $SHARED_PROXY_ADMIN "owner()" --rpc-url $RPC_URL

# Transfer to multisig for production security (recommended)
cast send $SHARED_PROXY_ADMIN "transferOwnership(address)" $MULTISIG_ADDRESS \
  --private-key $OWNER_PRIVATE_KEY --rpc-url $RPC_URL
```

**Benefits of Shared ProxyAdmin**:
- ✅ Single contract controls all proxy upgrades 
- ✅ Simplified multisig operations
- ✅ Consistent administration across the entire system

### Example Upgrade Process

```bash
# 1. Deploy new implementation
NEW_IMPL=$(forge create src/staking/controller/StakingController.sol:StakingController \
  --constructor-args 0 0 0 0 0 \
  --private-key $DEPLOYER_KEY --rpc-url $RPC_URL --json | jq -r '.deployedTo')

# 2. Upgrade proxy using shared ProxyAdmin (requires owner/multisig)
cast send $SHARED_PROXY_ADMIN "upgradeAndCall(address,address,bytes)" \
  $STAKING_CONTROLLER_PROXY $NEW_IMPL "0x" \
  --private-key $OWNER_PRIVATE_KEY --rpc-url $RPC_URL

# 3. Verify upgrade
cast call $STAKING_CONTROLLER_PROXY "implementation()" --rpc-url $RPC_URL
```

**Note**: StakingViewer is not upgradeable (deployed as a regular contract, not proxy). To upgrade StakingViewer, simply deploy a new instance with the updated StakingController address and update your frontend configuration.

## 5. Example Flow

```bash
# 1. Set up environment
cp script/.env.example .env
# Edit .env with your values (use multisig for OWNER_ADDRESS on mainnet)

# 2. Deploy to testnet first
forge script script/DeployProverNetwork.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast

# 3. Verify deployment and test functionality
forge test  # Run full test suite

# 4. Deploy to mainnet with verification
forge script script/DeployProverNetwork.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify

# 5. Transfer ownership to multisig (recommended for production)
# See "Upgrade Management" section above

# 6. Brevis Prover Network is ready for operation! 🎉
# Backend integration points:
# - Staking: Prover registration, stake management, slashing
# - Market: Proof requests, auction participation, verification
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