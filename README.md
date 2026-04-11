# EARN Smart Contracts

EN: Upgradeable Solidity contracts for the EARN yield product. The system accepts USDC-style deposits, mints non-transferable share tokens, tracks linear yield through an index, supports sponsor reward accounting, and exposes controlled treasury, compliance, pause, and upgrade roles.

FA: قراردادهای Solidity قابل ارتقا برای محصول سودده EARN. سیستم سپرده‌های شبیه USDC را دریافت می‌کند، share token غیرقابل‌انتقال mint می‌کند، سود خطی را با index پیگیری می‌کند، حسابداری پاداش sponsor را پشتیبانی می‌کند و نقش‌های کنترل‌شده خزانه، compliance، pause و upgrade دارد.

## Layout / ساختار

- `src/`: EN core contracts, libraries, storage, types, and mocks. / FA قراردادهای اصلی، libraryها، storage، typeها و mockها.
- `script/`: EN Foundry deployment and configuration scripts. / FA اسکریپت‌های Foundry برای deploy و configuration.
- `test/`: EN unit, integration, invariant, shared fixture, mock, and stub tests. / FA تست‌های واحد، یکپارچه، invariant، fixtureهای مشترک، mockها و stubها.

## Verification / اعتبارسنجی

EN: Use Foundry when available:

FA: وقتی Foundry نصب باشد از دستورهای زیر استفاده کنید:

```bash
forge fmt
forge test
```

EN: The contracts target Solidity `0.8.30` with optimizer, `via_ir`, deterministic bytecode metadata, and dependency remappings from `remappings.txt`.

FA: قراردادها Solidity نسخه `0.8.30` را با optimizer، `via_ir`، metadata قطعی و remappingهای موجود در `remappings.txt` هدف می‌گیرند.
