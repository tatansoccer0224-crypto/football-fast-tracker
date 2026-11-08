# Archived historical SQL that was never a recorded production migration

The files below were found in `supabase/migrations` on 2026-11-08 but **do not exist as exact version/name entries** in the connected production `supabase_migrations.schema_migrations` history.

They have been moved verbatim here rather than removed. **Do not apply these files automatically**. Some define earlier versions of existing functions that have already been superseded by production migrations.

- `20261009_ft016_forebet_canonical_publisher.sql` — an 8-digit timestamp used as a migration version; production instead records `20261009110949_ft016_forebet_canonical_publisher`.
- `20261010093000_ft_forebet_avg_goals_contract.sql` — legacy Forebet publisher definition, not a production migration version.
- `20261016055300_ft_retired_storage_lossless_v2.sql` — archived older storage contracts; production has its own recorded migration history and newer deployed definitions.

This archive is read-only provenance, **not** a replay instruction. New migration files must correspond exactly to the real production history; never run `migration repair` to hide a mismatch. The move itself changed only GitHub paths, **not** database functions or stored football data.
