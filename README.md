# EARN Smart Contracts

Upgradeable Solidity contracts for the PAiT EARN yield product.

The protocol accepts USDC-style deposits, mints non-transferable share tokens, tracks linear yield through an APR index, gates user actions through an on-chain subscription system, and exposes separated roles for treasury, compliance, pausing, parameter management, reporting, and upgrades.

Repository: <https://github.com/PA-Network-iT/Earn-contract.git>

## Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Contract Surface](#contract-surface)
- [Repository Layout](#repository-layout)
- [Requirements](#requirements)
- [Setup](#setup)
- [Build And Test](#build-and-test)
- [Deployment Flow](#deployment-flow)
- [Configuration](#configuration)
- [Security Notes](#security-notes)
- [License](#license)

## Overview

EARN is implemented as a Foundry-based smart contract system targeting Solidity `0.8.30`.

The core product stores deposit positions as lots. Each lot has principal, share amount, entry index, timestamps, and lifecycle flags. Users receive ERC-20 share tokens that are intentionally non-transferable. Withdrawals follow a two-step request and execution process: shares are locked at request time, the asset amount is snapshotted, and execution becomes available after a 24-hour lock period.

The subscription suite gates the core product through `SubscriptionManager.hasActiveSubscription(address)`. Subscriptions and package passes are represented by soulbound ERC-721 tokens. Package pass seats can be consumed by new subscribers as sponsor inventory.

## Architecture

| Layer | Contracts | Responsibility |
| --- | --- | --- |
| Core product | `EarnCore`, `EarnStorage`, `EarnTypes` | Deposits, lots, withdrawal lifecycle, APR index checkpoints, treasury liquidity, compliance controls, KYC threshold, subscription gate, UUPS upgrades. |
| Share accounting | `EarnShareToken` | Non-transferable ERC-20 shares controlled by `EarnCore`; locked balances are used during pending withdrawals. |
| Math and authorization libraries | `IndexLib`, `WithdrawalLib`, `KycAuthorization` | Linear APR materialization, share/asset conversion, withdrawal lock timing, pro-rata splits, EIP-712 KYC payload handling. |
| Subscription system | `SubscriptionManager`, `SubscriptionManagerStorage` | Paid subscriptions, package pass purchases, sponsor seat resolution, KYC-gated pass purchases, revenue sweep, admin bootstrap flows. |
| Soulbound NFTs | `SubscriptionNFT`, `PackagePassNFT` | Non-transferable ERC-721 markers for subscriptions and package passes, minted and updated only by the manager. |

## Contract Surface

### EarnCore

- Accepts USDC-style deposits and creates lot records.
- Mints shares through `EarnShareToken`.
- Tracks yield with scheduled APR checkpoints.
- Supports partial and full-lot withdrawal requests.
- Locks shares during pending withdrawals and burns locked shares on settlement.
- Applies optional early withdrawal fees for young lots.
- Supports blacklist, rehabilitation, and compliance force-withdraw flows.
- Maintains treasury reporting and buffer replenishment operations.
- Uses UUPS upgrade authorization through `UPGRADER_ROLE`.

### SubscriptionManager

- Tracks active subscriptions and package passes.
- Supports first-time subscription purchase, renewal, package pass purchase, and package pass upgrade.
- Resolves sponsors through package pass seat inventory.
- Keeps null-fallback subscription revenue on the manager until swept.
- Supports treasury sweep for payment token revenue and accidental ERC-20 recovery.
- Uses a separate EIP-712 domain for package-pass KYC authorizations.

### Tokens

- `EarnShareToken` is a 6-decimal, non-transferable ERC-20 controlled by `EarnCore`.
- `SubscriptionNFT` is a soulbound ERC-721 for subscription status.
- `PackagePassNFT` is a soulbound ERC-721 for package pass tier and remaining seat state.

## Repository Layout

```text
src/
  EarnCore.sol
  EarnShareToken.sol
  EarnRoles.sol
  lib/
  storage/
  subscription/
  types/
  upgrade/
script/
  DeployEarn.s.sol
  DeployEarnShareToken.s.sol
  DeploySubscriptionSuite.s.sol
  BindShareToken.s.sol
  ConfigureRoles.s.sol
  WireSubscriptionManager.s.sol
test/
  integration/
  invariant/
  shared/
  unit/
```

Additional documentation:

- [`SECURITY_REVIEW_FUNCTIONAL_OVERVIEW.html`](./SECURITY_REVIEW_FUNCTIONAL_OVERVIEW.html) - functional security review notes for auditors and security reviewers.
- [`script/README.md`](./script/README.md) - deployment script usage and environment variable details.
- [`src/upgrade/migrations/README.md`](./src/upgrade/migrations/README.md) - migration notes.

## Requirements

- [Foundry](https://book.getfoundry.sh/) with `forge` available in PATH.
- Solidity compiler version `0.8.30`.
- Git submodules or vendored dependencies under `lib/`:
  - `forge-std`
  - `openzeppelin-contracts`
  - `openzeppelin-contracts-upgradeable`

The project is configured with optimizer enabled, `via_ir = true`, deterministic bytecode metadata settings, and read-only Foundry filesystem permissions for tests.

## Setup

Clone the repository:

```bash
git clone https://github.com/PA-Network-iT/Earn-contract.git
cd Earn-contract
```

Install or update dependencies if they are not already present:

```bash
forge install
```

Create a local environment file:

```bash
cp .env.example .env
```

Fill the required values in `.env` for the target network and deployment flow.

## Build And Test

Format contracts:

```bash
forge fmt
```

Build contracts:

```bash
forge build
```

Run the full test suite:

```bash
forge test
```

Run tests with gas reporting:

```bash
forge test --gas-report
```

Run a specific test file:

```bash
forge test --match-path test/unit/withdrawal/WithdrawalFlow.t.sol -vvv
```

## Deployment Flow

The deployment scripts are intentionally thin and deterministic. Review `.env.example` and `script/README.md` before broadcasting any transaction.

Typical sequence:

1. Deploy or configure the payment asset.
2. Deploy `EarnCore` implementation and proxy.
3. Deploy `EarnShareToken` implementation and proxy.
4. Bind the share token to `EarnCore` with `setShareToken(address)`.
5. Deploy `SubscriptionNFT`, `PackagePassNFT`, and `SubscriptionManager`.
6. Set each NFT manager to the `SubscriptionManager` proxy.
7. Wire `SubscriptionManager` into `EarnCore` with `setSubscriptionManager(address)`.
8. Configure operational roles for production wallets or multisigs.

Example dry run:

```bash
forge script script/DeployEarn.s.sol:DeployEarnScript --rpc-url $RPC_URL -vvvv
```

Example broadcast:

```bash
forge script script/DeployEarn.s.sol:DeployEarnScript \
  --rpc-url $RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  -vvvv
```

## Configuration

Important environment variables are defined in `.env.example`.

| Variable | Purpose |
| --- | --- |
| `RPC_URL` | Target network RPC endpoint. |
| `DEPLOYER_PRIVATE_KEY` | Private key used by deployment scripts. |
| `EARN_ADMIN` | Initial admin for `EarnCore`. |
| `EARN_ASSET` | Deposit and payment token address, typically a USDC-style token. |
| `EARN_PROXY` | Deployed `EarnCore` proxy address. |
| `EARN_SHARE_TOKEN` | Deployed `EarnShareToken` proxy address. |
| `SUBSCRIPTION_ADMIN` | Initial admin for subscription contracts. |
| `SUBSCRIPTION_PRICE` | Initial subscription price in payment-token decimals. |
| `ROLE_*` | Optional separated operational role addresses. |

If an admin is a multisig or timelock, submit admin calls through that admin rather than using an EOA deployment key.

## Security Notes

This repository contains upgradeable contracts and role-gated operational flows. Production deployment should include an independent security review of:

- UUPS upgrade authorization and storage layout compatibility.
- Role assignment, multisig ownership, and key management.
- Subscription gate bootstrap timing while `EarnCore.subscriptionManager()` is unset.
- KYC signer custody, rotation, TTL policy, and EIP-712 domain separation.
- Treasury ratio, reported treasury assets, and buffer replenishment operations.
- Withdrawal snapshot accounting, early withdrawal fee handling, and liquidity availability.
- Blacklist, rehabilitation, and compliance force-withdraw behavior.
- Sponsor seat resolution, null-fallback revenue, and `SubscriptionManager.sweep`.

See [`SECURITY_REVIEW_FUNCTIONAL_OVERVIEW.html`](./SECURITY_REVIEW_FUNCTIONAL_OVERVIEW.html) for a structured functional review document.

## License

Contracts use the `MIT` SPDX identifier unless otherwise noted in imported dependencies.
