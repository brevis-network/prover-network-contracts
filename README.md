# Brevis Prover Network Contracts

Smart contracts for the Brevis Prover Network — enabling decentralized ZK proof generation and verification through a competitive marketplace and staking-based incentives.

## Components

### Staking
- **StakingController**: Manages prover lifecycle, staking operations, rewards, and slashing.
- **ProverVault**: Implements isolated ERC-4626 vaults for each prover.
- **VaultFactory**: Deploys vaults deterministically via CREATE2.

*See [docs/staking.md](docs/staking.md) for detailed architecture and mechanics.*

### Marketplace
- **BrevisMarket**: Runs sealed-bid, second-price reverse auctions for ZK proof generation.
  - Integrated with `Staking` for eligibility, rewards, and slashing.
  - On-chain proof validation through `PicoVerifier` (Brevis ZK VM).

*See [docs/market.md](docs/market.md) for auction mechanics and settlement process.*

## Structure

```
src/
├── staking/                    # Staking system contracts
│   ├── controller/
│   │   └── StakingController.sol # Core staking logic and prover management
│   ├── vault/
│   │   ├── ProverVault.sol       # Isolated staking vault per prover
│   │   └── VaultFactory.sol      # Deterministic vault deployment factory
│   ├── viewer/
│   │   └── StakingViewer.sol     # Read-only helper providing unified data access
│   └── interfaces/               # Staking interfaces
│
├── market/                     # Auction marketplace contracts
│   └── BrevisMarket.sol          # Sealed-bid reverse second-price auction
│
└── pico/                       # ZK proof verification
    ├── PicoVerifier.sol          # On-chain Brevis VM verifier
    └── IPicoVerifier.sol         # Verifier interface

lib/
└── security/                   # Shared security utilities
    └── src/access/               # Ownable, AccessControl, PauserControl

scripts/                        # Deployment instructions and scripts
test/                           # Forge test suite
```