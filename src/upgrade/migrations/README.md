# `src/upgrade/migrations/`

## Responsibility

Version-specific migration helpers or migration notes.

## Expected use

- Initialize newly appended storage fields.
- Backfill derived state when unavoidable.
- Keep migrations narrow, explicit, and test-backed.

## Rule

If a migration cannot be explained in one short paragraph, it is probably too risky and should be redesigned.
