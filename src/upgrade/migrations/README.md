# `src/upgrade/migrations/`

## Responsibility

Version-specific migration helpers or migration notes.

## Expected Use

- initialize newly appended storage fields;
- backfill derived state when unavoidable;
- keep migrations narrow, explicit, and test-backed.

## Rule

If a migration cannot be explained in one short paragraph, it is probably too risky and should be redesigned.
