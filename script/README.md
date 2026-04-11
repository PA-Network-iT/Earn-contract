# `script/`

## Responsibility

Operational entrypoints for deployment and upgrade lifecycle.

مسئولیت: entrypointهای عملیاتی برای چرخه deploy و upgrade.

## Current scripts

- `DeployMockUSDC.s.sol`
- `DeployEarn.s.sol`
- `DeployEarnShareToken.s.sol`
- `BindShareToken.s.sol`
- `ConfigureRoles.s.sol`

## Environment variables

Required for deployment:

متغیرهای محیطی مورد نیاز برای deploy:

- `RPC_URL`
- `DEPLOYER_PRIVATE_KEY`
- `EARN_ADMIN`
- `EARN_ASSET`
- `EARN_PROXY` (required after core deploy)
- `EARN_SHARE_TOKEN` (required after share-token deploy)
- `BIND_SHARE_TOKEN_PRIVATE_KEY` (only for direct bind by an EOA admin)
- `CONFIGURE_ROLES_PRIVATE_KEY` (only for direct role grants by an EOA admin)

Optional for mock token deployment:

متغیرهای اختیاری برای deploy توکن mock:

- `RPC_URL`
- `DEPLOYER_PRIVATE_KEY`
- `MOCK_USDC_MINT_TO`
- `MOCK_USDC_MINT_AMOUNT`

Required for role configuration:

متغیرهای مورد نیاز برای تنظیم نقش‌ها:

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

دیپلوی mock USDC با ۶ رقم اعشار:

```bash
forge script script/DeployMockUSDC.s.sol:DeployMockUSDCScript \
  --rpc-url $RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  -vvvv
```

After deploy, set `EARN_ASSET=<mock_usdc_address>` in `.env`.

پس از deploy، مقدار `EARN_ASSET=<mock_usdc_address>` را در `.env` تنظیم کنید.

Dry-run deployment (no broadcast):

اجرای dry-run بدون broadcast:

```bash
forge script script/DeployEarn.s.sol:DeployEarnScript --rpc-url $RPC_URL -vvvv
```

Broadcast deployment:

دیپلوی همراه با broadcast:

```bash
forge script script/DeployEarn.s.sol:DeployEarnScript \
  --rpc-url $RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  -vvvv
```

Deploy share token proxy after core exists:

پس از آماده شدن core، پراکسی share token را deploy کنید:

```bash
forge script script/DeployEarnShareToken.s.sol:DeployEarnShareTokenScript \
  --rpc-url $RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  -vvvv
```

Bind the deployed share token to core:

share token دیپلوی‌شده را به core متصل کنید:

```bash
forge script script/BindShareToken.s.sol:BindShareTokenScript \
  --rpc-url $RPC_URL \
  --private-key $BIND_SHARE_TOKEN_PRIVATE_KEY \
  --broadcast \
  -vvvv
```

If `EARN_ADMIN` is a multisig/timelock, do not run `BindShareToken.s.sol` with the deployer key.
Submit `setShareToken(address)` from the current default admin instead.

اگر `EARN_ADMIN` یک multisig یا timelock است، `BindShareToken.s.sol` را با کلید deployer اجرا نکنید.
در این حالت، `setShareToken(address)` باید از طریق default admin فعلی submit شود.

Configure operational roles:

تنظیم نقش‌های عملیاتی:

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

دامنه مورد انتظار:

- دیپلوی atomic پیاده‌سازی core و proxy؛
- دیپلوی جداگانه پراکسی share token پس از آماده شدن core؛
- اتصال share token از طریق admin فعلی core؛
- اجرای upgradeهای نسخه‌دار؛
- اعمال تنظیمات مخصوص محیط برای local یا staging.

## Rules

- keep scripts thin and deterministic;
- never hide migration logic inside ad hoc script code;
- upgrade scripts must be paired with upgrade tests;
- environment assumptions must be explicit in comments and filenames.

قواعد:

- اسکریپت‌ها باید کوچک و deterministic بمانند؛
- منطق migration نباید داخل کد ad hoc اسکریپت پنهان شود؛
- اسکریپت‌های upgrade باید تست upgrade متناظر داشته باشند؛
- فرض‌های محیطی باید در کامنت‌ها و نام فایل‌ها صریح باشند.
