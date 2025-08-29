# Brevis Prover Network Contracts

Smart contracts for the Brevis Prover Network: decentralized Brevis ZK VM proof generation/verification, powered by a competitive marketplace and staking-based economic incentives.

## Components

### Staking
- **StakingController**: Prover registration, staking operations, and slashing management.
- **VaultFactory**: ERC-4626 compliant vault deployment using CREATE2.
- **ProverVault**: Individual tokenized staking vault per prover.

*See [docs/staking.md](docs/staking.md) for detailed architecture and mechanics.*

### Marketplace
- **BrevisMarket**: Reverse sealed‑bid (commit–reveal) auction assigning a prover for ZK proof generation.
- **Verification**: Proofs validated on‑chain through PicoVerifier (Brevis ZK VM).
- **Staking Integration**: Handles prover eligibility, fee distribution, and slashing on non‑delivery or misconduct.

*See [docs/market.md](docs/market.md) for auction mechanics and settlement process.*

## Structure

```
src/
├── staking/                    # Staking system contracts
│   ├── controller/
│   │   └── StakingController.sol # Core staking logic and prover management
│   ├── vault/
│   │   ├── VaultFactory.sol      # Vault deployment factory
│   │   └── ProverVault.sol       # Individual prover staking vault
│   └── interfaces/               # Staking system interfaces
│
├── market/                     # Marketplace contracts  
│   └── BrevisMarket.sol          # Sealed-bid auction marketplace
│
└── pico/                       # Proof verification integration
    ├── PicoVerifier.sol          # Brevis ZK VM proof verifier
    └── IPicoVerifier.sol         # Verifier interface

lib/
└── security/                   # Shared security control library
    └── src/access/               # AccessControl, Ownable, PauserControl
```