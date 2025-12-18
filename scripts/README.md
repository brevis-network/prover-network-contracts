# Prover Network Deployment Scripts

This guide keeps deployment simple. It focuses on the core two-step process. After deployment, do follow-ups (verification, ownership transfer, upgrades) in your browser with MetaMask + the block explorer.

## 1) Quick setup

1. Copy templates:
   ```bash
   cp scripts/.env.example .env
   cp scripts/example_config.json config.json
   ```

2. Edit `.env` and `config.json`:
   - `.env` must include your `RPC_URL`, `PRIVATE_KEY`, and `DEPLOY_CONFIG=config.json`.
   - `config.json` is the single source of truth. It must include `proxyAdmin.address`.
   - See `scripts/example_config.json` for the full schema.

Notes:
- The deployer is the initial owner of ProxyAdmin and all deployed contracts.
- For production, transfer ProxyAdmin ownership to a multisig after deployment (via block explorer UI).

## 2) Deploy (baseline flow)

> **📌 BLOCKSCOUT USERS:** For Blockscout-based explorers, append `--verifier blockscout --verifier-url $VERIFIER_URL` to any `--verify` command below. Example:
> `forge script <script> --rpc-url $RPC_URL --broadcast --verify -vv --verifier blockscout --verifier-url $VERIFIER_URL`

1. Deploy a shared ProxyAdmin (one-time per network):
   ```bash
   forge script scripts/DeploySharedProxyAdmin.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
   ```
   Copy the printed address and set it in `config.json` under `proxyAdmin.address`.

2. Deploy the Pico verifier:
   ```bash
   forge script scripts/PicoVerifier.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
   ```
   Copy the printed address and set it in `config.json` under `market.picoVerifier`.

3. Deploy the core Prover Network bundle:
   ```bash
   forge script scripts/DeployProverNetwork.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
   ```

Where to find addresses:
- The script prints all addresses at the end.
- They’re also saved to `broadcast/DeployProverNetwork.s.sol/<chainId>/run-latest.json`.

## 3) Deploy individual components (optional)

For advanced or partial rollouts, you can deploy components separately. These commands are compact wrappers around the same contracts used in the full deploy.

> **📌 BLOCKSCOUT USERS:** Append `--verifier blockscout --verifier-url $VERIFIER_URL` to any `--verify` command.

- WrappedNativeToken:
   ```bash
   forge script scripts/WrappedNativeToken.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
   ```
- StakingController (upgradeable via Transparent Proxy):
   ```bash
   forge script scripts/StakingController.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
   ```
   - To deploy implementation only (for upgrades), add in `config.json`:
     ```json
     { "staking": { "implementationOnly": true } }
     ```
     The script will deploy and print the new implementation address without creating a proxy.
- VaultFactory (upgradeable via Transparent Proxy):
   ```bash
   forge script scripts/VaultFactory.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
   ```
- BrevisMarket (upgradeable via Transparent Proxy):
   ```bash
   forge script scripts/BrevisMarket.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
   ```
   - To deploy implementation only (for upgrades), add in `config.json`:
     ```json
     { "market": { "implementationOnly": true } }
     ```
     The script will deploy and print the new implementation address without creating a proxy.
- StakingViewer (read-only, no proxy):
   ```bash
   forge script scripts/StakingViewer.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
   ```
- MarketViewer (read-only, no proxy):
   ```bash
   forge script scripts/MarketViewer.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
   ```
- PicoVerifier (mainnet/testnet verifier implementation):
   ```bash
   forge script scripts/PicoVerifier.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
   ```
- SimpleBrevisProof:
   ```bash
   forge script scripts/SimpleBrevisProof.s.sol --rpc-url $RPC_URL --broadcast -vv
   ```
- EpochRewards (upgradeable via Transparent Proxy):
   ```bash
   forge script scripts/EpochRewards.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
   ```
   - To deploy implementation only (for upgrades), add in `config.json`:
     ```json
     { "epochRewards": { "implementationOnly": true } }
     ```
     The script will deploy and print the new implementation address without creating a proxy.

Notes:
- `DeployProverNetwork.s.sol` requires `proxyAdmin.address` in `config.json` and never auto-deploys a ProxyAdmin.
- `MarketViewer.s.sol` requires `addresses.brevisMarket` in `config.json` (the BrevisMarket proxy/address to read from).
- Upgradeable component scripts (`VaultFactory.s.sol`, `StakingController.s.sol`, `BrevisMarket.s.sol`, `EpochRewards.s.sol`) auto-deploy a ProxyAdmin if `proxyAdmin.address` is missing; the full-network script always uses an existing one.

## 4) After deployment (Block Explorer + MetaMask)

- **Verification**: Using `--verify` usually verifies all contracts automatically. If anything remains unverified, open the address on the explorer and use “Verify & Publish” in the UI.
- **Proxy ABI**: If the proxy page shows no ABI, verify both the proxy and the implementation. Explorers usually auto-link; otherwise, look for “Is this a proxy?” on the page.
- **Transfer ownership**: Open your ProxyAdmin on the explorer and call `transferOwnership(newOwner)` from the Write tab (connect MetaMask). Recommended to a multisig.
- **Upgrades later**: Use the ProxyAdmin “upgrade” function in the explorer UI to point a proxy to a new implementation.

## 5) Tips

### Etherscan verification
- Use chain-specific explorer API keys to reduce verification hiccups:
  - Ethereum: `ETHERSCAN_API_KEY`
  - Optimism (incl. OP Sepolia): `OPTIMISM_ETHERSCAN_API_KEY`
  - Arbitrum: `ARBISCAN_API_KEY`, Base: `BASESCAN_API_KEY` etc.
- Occasional HTML 403 logs during `--verify` are benign if subsequent submissions succeed. They're temporary rate-limit responses from the explorer.

### Blockscout verification
- Set `VERIFIER_URL` to your Blockscout instance's API endpoint (e.g., `https://explorer.example.com/api`).
- No API key required—just add `--verifier blockscout --verifier-url $VERIFIER_URL` to any command with `--verify`.

## 6) Testing (optional)

Run the deployment script tests locally:
```bash
forge test --match-contract DeploymentScriptTest
```

That’s it—deploy in two steps, then manage everything else comfortably in the explorer UI.