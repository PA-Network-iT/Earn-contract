# EARN Smart Contracts

Upgradeable Solidity contracts for the EARN yield product. The system accepts USDC-style deposits, mints non-transferable share tokens, tracks linear yield through an index, supports sponsor reward accounting, and exposes controlled treasury, compliance, pause, and upgrade roles.

## Layout

- `src/`: Core contracts, libraries, storage, types, and mocks.
- `script/`: Foundry deployment and configuration scripts.
- `test/`: Unit, integration, invariant, shared fixture, mock, and stub tests.

## Verification

Use Foundry when available:

```bash
forge fmt
forge test
```

The contracts target Solidity `0.8.30` with optimizer, `via_ir`, deterministic bytecode metadata, and dependency remappings from `remappings.txt`.
