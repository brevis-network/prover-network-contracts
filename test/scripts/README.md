# Script Tests

This directory contains tests for the deployment scripts.

## Automated Tests

These run with `forge test`:

- `DeploymentScriptTest.t.sol`
	- Production deployment script validation
	- Optional parameter handling
	- Upgrade operations testing
	- Script instantiation tests

- `ExistingProxyAdminTest.t.sol`
	- Verifies deploying with an existing ProxyAdmin provided via JSON config
	- Validates multisig-owned ProxyAdmin scenarios
	- Confirms proxies are managed by the provided ProxyAdmin

## Configuration Model (JSON-only)

Deployment scripts now use a single JSON config source. Provide either:

- Inline JSON via `DEPLOY_CONFIG_JSON`, or
- A file path via `DEPLOY_CONFIG` (the script will read the file contents).

To reuse an existing ProxyAdmin, include it in the config under `proxyAdmin.address`.

Example JSON:

```json
{
	"proxyAdmin": { "address": "0x1234567890123456789012345678901234567890" },
	"staking": {
		"token": "0x...",
		"unstakeDelay": 604800,
		"minSelfStake": 1000000000000000000000,
		"maxSlashBps": 5000
	},
	"market": {
		"picoVerifier": "0x...",
		"biddingPhaseDuration": 300,
		"revealPhaseDuration": 600,
		"minMaxFee": 1000000000000000,
		"slashBps": 1000,
		"slashWindow": 86400,
		"protocolFeeBps": 100,
		"overcommitBps": 0
	}
}
```

Notes:
- Legacy environment variable fallbacks (like `PROXY_ADMIN`, `STAKING_TOKEN_ADDRESS`, etc.) have been removed.
- Tests assemble `DEPLOY_CONFIG_JSON` at runtime from a readable base file: `test/scripts/test_config.json`.

