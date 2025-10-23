# Prover Network Deployment Scripts

This directory contains deployment scripts for the Brevis Prover Network contracts including both the staking system and market contracts.

## Table of Contents

- [1. Setup](#1-setup)
- [2. Deployment Options](#2-deployment-options)
- [3. Verification](#3-verification)
- [4. Upgrade](#4-upgrade)
- [5. Example Flow](#5-example-flow)
- [6. Testing](#6-testing)

## 1. Setup

1. **Copy templates:**
   ```bash
   cp scripts/.env.example .env
   cp scripts/example_config.json config.json
   ```

2. **Edit `.env` and `config.json`:**
   - Open `.env` and fill in your values. Make sure `DEPLOY_CONFIG` points to your JSON file.
   - Open `config.json` and set all required parameters (see the example file for the full schema).

   Example `.env`:
   ```bash
   RPC_URL=...
   PRIVATE_KEY=0x...
   ETHERSCAN_API_KEY=...
   DEPLOY_CONFIG=config.json
   ```

   See `scripts/example_config.json` for the complete schema and defaults you can adapt.
   - Config JSON is the single source of truth (no per-parameter env fallbacks).
   - `config.json` must include `proxyAdmin.address` (DeployProverNetwork will not auto-deploy a ProxyAdmin).

**Note:** The deployer becomes the initial owner of all contracts. For production, transfer ownership to a multisig after deployment.

## 2. Deployment Options

> **Deployment Architecture**: Uses **OpenZeppelin v4 upgradeable contracts** to enable **shared administration** across all proxies for simplified multisig operations.

### Deploy Complete Prover Network (Recommended)

Two-step flow using a shared ProxyAdmin (required):

1) Deploy a shared ProxyAdmin once per network using `DeploySharedProxyAdmin.s.sol`.

2) Run `DeployProverNetwork.s.sol` with a config JSON that includes `proxyAdmin.address` pointing to the shared ProxyAdmin.

**`DeploySharedProxyAdmin.s.sol`** - Minimal script that deploys a ProxyAdmin and prints its address/owner.
```bash
forge script scripts/DeploySharedProxyAdmin.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
```

**`DeployProverNetwork.s.sol`** ✨ - Comprehensive deployment script that deploys the entire Brevis Prover Network: VaultFactory, StakingController, StakingViewer, BrevisMarket (upgradeable with transparent proxy and shared ProxyAdmin), connects all components, and grants proper roles.

```bash
forge script scripts/DeployProverNetwork.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
```

### Deploy Individual Components

For specialized deployments, you can deploy individual components:

**`StakingController.s.sol`** - Deploys only the StakingController as an upgradeable contract:
```bash
forge script scripts/StakingController.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
```

**`VaultFactory.s.sol`** - Deploys only the VaultFactory as an upgradeable contract:
```bash
forge script scripts/VaultFactory.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
```

**`BrevisMarket.s.sol`** - Deploys only the BrevisMarket as an upgradeable contract:
```bash
forge script scripts/BrevisMarket.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
```

**`StakingViewer.s.sol`** - Deploys only the StakingViewer (read-only contract, no proxy needed):
```bash
forge script scripts/StakingViewer.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
```

**`MockPicoVerifier.s.sol`** - Deploys a mock PicoVerifier for testing:
```bash
forge script scripts/MockPicoVerifier.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
```

> **Note:** Individual ProverVaults are automatically deployed via CREATE2 through the VaultFactory when provers are registered.

Important: `DeployProverNetwork.s.sol` always requires `proxyAdmin.address` in the config JSON and will not auto-deploy a ProxyAdmin. For component-only scripts (VaultFactory, StakingController, BrevisMarket), `proxyAdmin.address` is optional; if omitted, those scripts will deploy a new ProxyAdmin for that component.

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
cp scripts/.env.example deployments/.env
cp scripts/example_config.json deployments/config.json
# Edit .env and config.json with your values

# 2. Deploy a shared ProxyAdmin and capture its address
forge script scripts/DeploySharedProxyAdmin.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
# Update scripts/example_config.json with the printed ProxyAdmin under proxyAdmin.address

# 3. Deploy the full Prover Network (requires proxyAdmin.address in config)
forge script scripts/DeployProverNetwork.s.sol --rpc-url $RPC_URL --broadcast --verify -vv

# 4. Verify deployment works correctly (see section 3)
cast call $STAKING_CONTROLLER_PROXY "stakingToken()" --rpc-url $RPC_URL
cast call $BREVIS_MARKET_PROXY "picoVerifier()" --rpc-url $RPC_URL

# 5. Transfer ProxyAdmin ownership to multisig (recommended for production)
# See "Upgrade" section above for commands

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
forge test --match-contract DeploymentScriptTest

# Run full test suite (includes deployment tests)
forge test
```

**Frontend Integration**: After deployment, use the StakingViewer address in your frontend for optimized read operations. See `docs/frontend_guide.md` for complete integration guidance.