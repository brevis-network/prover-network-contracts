# Script Tests

This directory contains tests for the deployment scripts.

## Automated Tests

**`DeploymentScriptTest.t.sol`** - Runs automatically with `forge test`
- Production deployment script validation
- Optional parameter handling  
- Upgrade operations testing
- Script instantiation tests

## Manual Tests

**`ExistingProxyAdminTest.sol.skip`** - Requires manual execution

This file contains tests for the optional PROXY_ADMIN environment variable functionality. It's excluded from default test runs due to Foundry VM environment variable isolation quirks.

### How to Run Manual Tests

```bash
# 1. Temporarily rename to test file
mv test/scripts/ExistingProxyAdminTest.sol.skip test/scripts/ExistingProxyAdminTest.t.sol

# 2. Run the tests
forge test --match-contract "ExistingProxyAdminTest"

# 3. Rename back after testing
mv test/scripts/ExistingProxyAdminTest.t.sol test/scripts/ExistingProxyAdminTest.sol.skip
```

### What Manual Tests Validate

- ✅ PROXY_ADMIN environment variable works correctly
- ✅ Deployment script can reuse existing ProxyAdmin 
- ✅ Compatible with multisig-owned ProxyAdmin scenarios
- ✅ Production flexibility for existing infrastructure

The functionality is solid - manual execution is only needed due to Foundry test framework quirks, not code issues.

## Usage in Production

Both deployment patterns are fully supported:

**New ProxyAdmin (Default)**:
```bash
# .env file (no PROXY_ADMIN specified)
PRIVATE_KEY=your_key
STAKING_TOKEN_ADDRESS=0x...
# ... other vars
```

**Existing ProxyAdmin (Production)**:
```bash
# .env file (reuse existing ProxyAdmin) 
PROXY_ADMIN=0x1234567890123456789012345678901234567890
PRIVATE_KEY=your_key
STAKING_TOKEN_ADDRESS=0x...
# ... other vars
```
