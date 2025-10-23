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
- For production, transfer ProxyAdmin ownership to a multisig after deployment (via Etherscan UI).

## 2) Deploy (two steps)

1) Deploy a shared ProxyAdmin (one-time per network):
   ```bash
   forge script scripts/DeploySharedProxyAdmin.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
   ```
   Copy the printed address and set it in `config.json` under `proxyAdmin.address`.

2) Deploy the full Prover Network:
   ```bash
   forge script scripts/DeployProverNetwork.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
   ```

Where to find addresses:
- The script prints all addresses at the end.
- They’re also saved to `broadcast/DeployProverNetwork.s.sol/<chainId>/run-latest.json`.

## 3) Deploy individual components (optional)

For advanced or partial rollouts, you can deploy components separately. These commands are compact wrappers around the same contracts used in the full deploy.

- StakingController (upgradeable via Transparent Proxy):
   ```bash
   forge script scripts/StakingController.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
   ```
- VaultFactory (upgradeable via Transparent Proxy):
   ```bash
   forge script scripts/VaultFactory.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
   ```
- BrevisMarket (upgradeable via Transparent Proxy):
   ```bash
   forge script scripts/BrevisMarket.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
   ```
- StakingViewer (read-only, no proxy):
   ```bash
   forge script scripts/StakingViewer.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
   ```
- Mock PicoVerifier (testing only):
   ```bash
   forge script scripts/MockPicoVerifier.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
   ```

Notes:
- `DeployProverNetwork.s.sol` requires `proxyAdmin.address` in `config.json` and never auto-deploys a ProxyAdmin.
- Component-only scripts may deploy a new ProxyAdmin if one is not provided (check each script’s header if needed).

## 4) After deployment (Etherscan + MetaMask)

- **Verification**: Using `--verify` usually verifies all contracts automatically. If anything remains unverified, open the address on the explorer and use “Verify & Publish” in the UI.
- **Proxy ABI**: If the proxy page shows no ABI, verify both the proxy and the implementation. Explorers usually auto-link; otherwise, look for “Is this a proxy?” on the page.
- **Transfer ownership**: Open your ProxyAdmin on the explorer and call `transferOwnership(newOwner)` from the Write tab (connect MetaMask). Recommended to a multisig.
- **Upgrades later**: Use the ProxyAdmin “upgrade” function in the explorer UI to point a proxy to a new implementation.

## 5) Tips

- Use the chain-specific explorer API key to reduce verification hiccups:
  - Ethereum: `ETHERSCAN_API_KEY`
  - Optimism (incl. OP Sepolia): `OPTIMISM_ETHERSCAN_API_KEY`
  - Arbitrum: `ARBISCAN_API_KEY`, Base: `BASESCAN_API_KEY`, Polygon: `POLYGONSCAN_API_KEY`, etc.
- Occasional HTML 403 logs during `--verify` are benign if subsequent submissions succeed. They’re temporary rate-limit responses from the explorer.

## 6) Testing (optional)

Run the deployment script tests locally:
```bash
forge test --match-contract DeploymentScriptTest
```

That’s it—deploy in two steps, then manage everything else comfortably in the explorer UI.