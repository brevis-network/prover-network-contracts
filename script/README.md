# Prover Network Deployment Scripts

This directory contains deployment scripts for the Brevis Prover Network contracts including both the staking system and market contracts.

## Scripts Overview

### 1. `DeployProverNetwork.s.sol` ✨ 
**Recommended**: Comprehensive deployment script that deploys the entire Brevis Prover Network in the correct order.

**Deploys:**
- **Staking System**: VaultFactory (upgradeable with transparent proxy), StakingController (upgradeable with transparent proxy)
- **Market System**: BrevisMarket (upgradeable with transparent proxy) 
- **Connects all components**: Links StakingController to VaultFactory and grants BrevisMarket the slasher role using AccessControl
- **Storage gaps included**: All contracts have proper storage gaps for safe future upgrades

### 2. `StakingController.s.sol`
Deploys only the StakingController as an upgradeable contract using transparent proxy pattern.

### 3. `VaultFactory.s.sol`
Deploys only the VaultFactory as an upgradeable contract using transparent proxy pattern.

### 4. `BrevisMarket.s.sol`  
Deploys only the BrevisMarket as an upgradeable contract using transparent proxy pattern.

**Note:** Individual ProverVaults are automatically deployed via CREATE2 through the VaultFactory when provers are registered by the backend.

## Setup

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
   MAX_SLASH_FACTOR=5000                # 50% max slashing
   
   # Market System  
   PICO_VERIFIER_ADDRESS=0x...          # PicoVerifier contract
   BIDDING_PHASE_DURATION=300           # 5 minutes
   REVEAL_PHASE_DURATION=600            # 10 minutes
   MIN_MAX_FEE=1000000000000000         # 0.001 ETH spam protection
   ```

**Note:** The deployer becomes the initial owner of all contracts. For production, transfer ownership to a multisig after deployment (see "Ownership Transfer" section below).

## Deployment Commands

### Deploy Complete Prover Network (Recommended)

```bash
# Deploy to local testnet
forge script script/DeployProverNetwork.s.sol --rpc-url http://localhost:8545 --broadcast

# Deploy to testnet (e.g., Sepolia)
forge script script/DeployProverNetwork.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify

# Deploy to mainnet
forge script script/DeployProverNetwork.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify
```

### Deploy Individual Components

```bash
# Deploy VaultFactory only
forge script script/VaultFactory.s.sol --rpc-url $RPC_URL --broadcast

# Deploy StakingController only
forge script script/StakingController.s.sol --rpc-url $RPC_URL --broadcast

# Deploy BrevisMarket only
forge script script/BrevisMarket.s.sol --rpc-url $RPC_URL --broadcast
```

## Configuration Parameters

### Core Parameters
- **STAKING_TOKEN_ADDRESS**: ERC20 token used for staking (e.g., WETH, USDC)
- **PICO_VERIFIER_ADDRESS**: PicoVerifier contract for proof verification
- **UNSTAKE_DELAY**: Time delay for unstaking in seconds (e.g., 604800 = 7 days)
## Post-Deployment Steps

After successful deployment, the complete Brevis Prover Network is ready for operation. The deployment script handles all system integrations automatically.

## Verification

After deployment, you can verify contracts are properly connected:

```bash
# Get deployed addresses from deployment logs
STAKING_CONTROLLER_PROXY=0x...  # From deployment output
VAULT_FACTORY_PROXY=0x...       # From deployment output  
BREVIS_MARKET_PROXY=0x...       # From deployment output

# Verify system integration
cast call $VAULT_FACTORY_PROXY "stakingController()" --rpc-url $RPC_URL
cast call $STAKING_CONTROLLER_PROXY "vaultFactory()" --rpc-url $RPC_URL

# Verify configuration
cast call $STAKING_CONTROLLER_PROXY "stakingToken()" --rpc-url $RPC_URL
cast call $STAKING_CONTROLLER_PROXY "minSelfStake()" --rpc-url $RPC_URL
cast call $STAKING_CONTROLLER_PROXY "unstakeDelay()" --rpc-url $RPC_URL

# Verify BrevisMarket setup
cast call $BREVIS_MARKET_PROXY "picoVerifier()" --rpc-url $RPC_URL
cast call $BREVIS_MARKET_PROXY "stakingController()" --rpc-url $RPC_URL
cast call $BREVIS_MARKET_PROXY "biddingPhaseDuration()" --rpc-url $RPC_URL

# Verify slasher role granted
cast call $STAKING_CONTROLLER_PROXY "hasRole(bytes32,address)" \
  $(cast keccak "SLASHER_ROLE") $BREVIS_MARKET_PROXY --rpc-url $RPC_URL
```

## Upgrade Management

### Who Can Upgrade?

The `OWNER_ADDRESS` specified in `.env` controls all proxy upgrades:

```bash
# Get ProxyAdmin addresses (from deployment logs)
PROXY_ADMIN=0x...  # Controls all three proxies

# Check current ProxyAdmin owner
cast call $PROXY_ADMIN "owner()" --rpc-url $RPC_URL

# Transfer to multisig for production security
cast send $PROXY_ADMIN "transferOwnership(address)" $MULTISIG_ADDRESS \
  --private-key $OWNER_PRIVATE_KEY --rpc-url $RPC_URL
```

### Example Upgrade Process

```bash
# 1. Deploy new implementation
NEW_IMPL=$(forge create src/staking/controller/StakingController.sol:StakingController \
  --constructor-args 0 0 0 0 0 \
  --private-key $DEPLOYER_KEY --rpc-url $RPC_URL --json | jq -r '.deployedTo')

# 2. Upgrade proxy (requires owner/multisig)
cast send $PROXY_ADMIN "upgrade(address,address)" \
  $STAKING_CONTROLLER_PROXY $NEW_IMPL \
  --private-key $OWNER_PRIVATE_KEY --rpc-url $RPC_URL

# 3. Verify upgrade
cast call $STAKING_CONTROLLER_PROXY "implementation()" --rpc-url $RPC_URL
```

## Security Considerations

- **Private Key Management**: Never commit private keys to version control
- **Owner Address**: Use a multisig wallet for mainnet deployments (recommended: 3/5 or 4/7 threshold)
- **Upgrade Authority**: The owner controls proxy upgrades for all three core contracts
- **Storage Safety**: All contracts include storage gaps for safe future upgrades
- **Role Management**: Only grant SLASHER_ROLE to trusted entities
- **Parameter Validation**: Carefully review all configuration parameters before mainnet deployment

## Example Deployment Flow

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
