# EARN Smart Contracts

Upgradeable Solidity contracts for the EARN yield product. The system accepts USDC-style deposits, mints non-transferable share tokens, tracks linear yield through an index, gates access behind on-chain subscriptions, and exposes controlled treasury, compliance, pause, and upgrade roles.

## Layout

- `src/`: Core contracts, libraries, storage, types, and mocks.
  - `src/upgrade/`: `DelayedUUPSUpgradeable` — timelocked UUPS base shared by every proxy.
  - `src/treasury/`: `TreasuryWalletTimelock` — two-step treasury wallet rotation.
  - `src/subscription/`: SubscriptionManager and the two soulbound NFTs.
- `script/`: Foundry deployment, configuration, upgrade, and treasury-rotation scripts.
- `test/`: Unit, integration, invariant, shared fixture, mock, and stub tests.

## Security timelocks

Two admin actions that previously took effect immediately are now two-step and delayed by 24 hours.

### Upgrades (EarnCore, SubscriptionManager, SubscriptionNFT, PackagePassNFT)

`upgradeToAndCall` only accepts an implementation that was scheduled at least `UPGRADE_DELAY`
(24h) earlier, and the schedule is consumed on execution. A compromised `UPGRADER_ROLE` key
therefore cannot swap logic within a block; the pending change is public on-chain the whole time.

```bash
# 1. deploy the implementation
forge script script/upgrade/DeployImplementations.s.sol --tc DeployEarnCoreImplScript --broadcast

# 2. start the timelock (signer needs UPGRADER_ROLE)
UPGRADE_PROXY=... UPGRADE_IMPLEMENTATION=... \
forge script script/upgrade/ScheduleUpgrade.s.sol --tc ScheduleUpgradeScript --broadcast

# 3. after 24h, execute
forge script script/upgrade/ExecuteUpgrade.s.sol --tc ExecuteUpgradeScript --broadcast
```

`cancelScheduledUpgrade()` drops a pending change. Inspect state any time with `scheduledUpgrade()`.

### Treasury wallet (EarnCore, SubscriptionManager)

The single-step `setTreasuryWallet` is gone — it now always reverts with
`TreasuryWalletChangeIsTwoStep`. Rotation is `proposeTreasuryWallet` → wait
`TREASURY_WALLET_CHANGE_DELAY` (24h) → `acceptTreasuryWallet(expectedWallet)`, all gated by
`DEFAULT_ADMIN_ROLE`, with `cancelTreasuryWalletProposal()` as the escape hatch. `treasuryWallet()`
and `pendingTreasuryWallet()` expose the state.

```bash
TREASURY_TARGET=... EARN_TREASURY_WALLET=... \
forge script script/treasury/RotateTreasuryWallet.s.sol --tc ProposeTreasuryWalletScript --broadcast
# ...24h later...
forge script script/treasury/RotateTreasuryWallet.s.sol --tc AcceptTreasuryWalletScript --broadcast
```

### Admin role handover (residual risk)

OpenZeppelin `AccessControl` has no two-step handover for `DEFAULT_ADMIN_ROLE`, and this rewrite
does not fork it to add one. The two money-critical admin powers are already behind the timelocks
above, so the remaining instant-effect surface is wiring (`setShareToken`, which is one-shot,
`setSubscriptionManager`, `setKycSigner`) plus the role graph itself. `DEFAULT_ADMIN_ROLE` must
therefore be a multisig or governance timelock in production, never a single hot EOA. The same
applies to `UPGRADER_ROLE`: the delay limits the blast radius but does not remove the need for a
multisig.

## Deployment note

The storage layouts in `src/storage/EarnStorage.sol` and
`src/subscription/storage/SubscriptionManagerStorage.sol` are written for **fresh proxies**. The
subscription layout in particular dropped the deprecated referral/bonus placeholder slots, so
upgrading a pre-rewrite proxy onto these implementations would corrupt storage.

## Verification

Use Foundry when available:

```bash
forge fmt
forge test
```

The contracts target Solidity `0.8.30` with optimizer, `via_ir`, deterministic bytecode metadata, and dependency remappings from `remappings.txt`.
