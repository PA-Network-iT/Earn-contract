# `src/upgrade/migrations/`

## Responsibility

Version-specific migration helpers or migration notes.

مسئولیت: helperها یا یادداشت‌های migration برای هر نسخه مشخص.

## Expected Use

- initialize newly appended storage fields;
- backfill derived state when unavoidable;
- keep migrations narrow, explicit, and test-backed.

کاربرد مورد انتظار:

- مقداردهی اولیه فیلدهای storage که به انتهای layout اضافه شده‌اند؛
- backfill کردن state مشتق‌شده فقط وقتی اجتناب‌ناپذیر است؛
- کوچک، صریح و test-backed نگه داشتن migrationها.

## Rule

If a migration cannot be explained in one short paragraph, it is probably too risky and should be redesigned.

قاعده: اگر migration در یک پاراگراف کوتاه قابل توضیح نیست، احتمالا ریسک زیادی دارد و باید دوباره طراحی شود.
