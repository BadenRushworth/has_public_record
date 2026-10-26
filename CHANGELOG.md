# Changelog

## 0.1.1

Fixes
- Ids are validated against the alphabet when created; lower-case and bare ids assigned to a record are normalized
  (a custom attribute type also normalizes `where` / `find_by` values). Reading a row returns exactly what is stored.
- `missing_public_id` counts empty strings, like the report does, so backfill and report agree.
- `has_public_record` on an abstract class raises at declaration instead of breaking `resolve` later.
- Learned length can no longer ratchet past `starting length + max_bumps` during an outage.
- `rename_prefix` reports the rows it actually changed.
- Rake helpers no longer define methods on `Object`; `MODEL=` accepts `user`, `users` or `User`.
- Maintenance no longer drops models that share a table name across databases.
- `--concurrently` only asks for a concurrent index on PostgreSQL.
- The gem now ships its LICENSE and declares `concurrent-ruby`.

Added
- `regenerate_public_id!`, `generate_public_ids(count)`, `HasPublicRecord.well_formed?`, `HasPublicRecord.reset_registry!`.
- `with_generated_public_ids` and `backfill_public_ids!` use one existence query per batch instead of one per row.
- The registry resets when Rails reloads code in development.
- Generator specs; README covers every public method.

## 0.1.0

First release.
