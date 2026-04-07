# `script/`

## Responsibility

Operational entrypoints for deployment and upgrade lifecycle.

## Current scripts

- `DeployMockUSDC.s.sol`
- `DeployEarn.s.sol`
- `DeployEarnShareToken.s.sol`
- `BindShareToken.s.sol`
- `ConfigureRoles.s.sol`

## Environment variables

Required for deployment:

- `RPC_URL`
- `DEPLOYER_PRIVATE_KEY`
- `EARN_ADMIN`
- `EARN_ASSET`
- `EARN_PROXY` (required after core deploy)
- `EARN_SHARE_TOKEN` (required after share-token deploy)
- `BIND_SHARE_TOKEN_PRIVATE_KEY` (only for direct bind by an EOA admin)
- `CONFIGURE_ROLES_PRIVATE_KEY` (only for direct role grants by an EOA admin)

Optional for mock token deployment:

- `RPC_URL`
- `DEPLOYER_PRIVATE_KEY`
- `MOCK_USDC_MINT_TO`
- `MOCK_USDC_MINT_AMOUNT`

Required for role configuration:

- `RPC_URL`
- `DEPLOYER_PRIVATE_KEY`
- `EARN_PROXY`
- `ROLE_PARAMETER_MANAGER`
- `ROLE_TREASURY_MANAGER`
- `ROLE_COMPLIANCE`
- `ROLE_REPORTER`
- `ROLE_PAUSER`
- `ROLE_UPGRADER`

## Usage

Deploy mock USDC (6 decimals):

```bash
forge script script/DeployMockUSDC.s.sol:DeployMockUSDCScript \
  --rpc-url $RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  -vvvv
```

After deploy, set `EARN_ASSET=<mock_usdc_address>` in `.env`.

Dry-run deployment (no broadcast):

```bash
forge script script/DeployEarn.s.sol:DeployEarnScript --rpc-url $RPC_URL -vvvv
```

Broadcast deployment:

```bash
forge script script/DeployEarn.s.sol:DeployEarnScript \
  --rpc-url $RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  -vvvv
```

Deploy share token proxy after core exists:

```bash
forge script script/DeployEarnShareToken.s.sol:DeployEarnShareTokenScript \
  --rpc-url $RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  -vvvv
```

Bind the deployed share token to core:

```bash
forge script script/BindShareToken.s.sol:BindShareTokenScript \
  --rpc-url $RPC_URL \
  --private-key $BIND_SHARE_TOKEN_PRIVATE_KEY \
  --broadcast \
  -vvvv
```

If `EARN_ADMIN` is a multisig/timelock, do not run `BindShareToken.s.sol` with the deployer key.
Submit `setShareToken(address)` from the current default admin instead.

Configure operational roles:

```bash
forge script script/ConfigureRoles.s.sol:ConfigureRolesScript \
  --rpc-url $RPC_URL \
  --private-key $CONFIGURE_ROLES_PRIVATE_KEY \
  --broadcast \
  -vvvv
```

## Expected Scope

- deploy the core implementation and proxy atomically;
- deploy the share token proxy separately after core exists;
- bind the share token through the current core admin;
- execute versioned upgrades;
- apply environment-specific configuration for local or staging flows.

## Rules

- keep scripts thin and deterministic;
- never hide migration logic inside ad hoc script code;
- upgrade scripts must be paired with upgrade tests;
- environment assumptions must be explicit in comments and filenames.
