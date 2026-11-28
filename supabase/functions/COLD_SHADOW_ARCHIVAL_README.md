# Production cold-shadow archival functions (source-of-truth recovery)

These two checked-in files are **exact copies of the active production code**
retrieved from Supabase project `hekqxhgjexzxnecwhyao` on 2026-11-28 UTC:

| Edge Function | Deployed version | Bounded batch |
|---|---:|---:|
| `ft-flashscore-cold-shadow-retire` | 1 | 80 rows |
| `ft-fotmob-cold-shadow-retire` | 2 | 40 rows |

**Purpose:** Preserve the original unmatched, expired football-source JSON in
Supabase Storage and only retire the matching database rows after retrieving
the uploaded archive and independently verifying SHA-256 and the storage
manifest. The SQL deletion RPC enforces protected-record guards and exact
batch count. Current cron jobs call each function with a Vault-managed secret
and empty JSON body; the source files contain no literal credentials.

## Safe change policy

1. Do **not** redeploy these functions merely because these source files were
   restored to Git. This commit is version control only; production is
   unchanged.
2. Never bypass `ARCHIVE_CHECKSUM_FAILED`, `ARCHIVE_MANIFEST_MISSING`,
   `ARCHIVE_MANIFEST_MISMATCH`, `EXACT_RETIRE_REJECTED`, authorization,
   or the 7-day fetched/fixture/updated age guards.
3. Never change the unmatched-only selection or SQL delete RPC without a
   read-only impact audit, dry-run candidate count, tested restore of an
   archived object and a formal review.
4. Do not delete historic football fixtures, player profiles, verified
   snapshots, canonical identity mappings or betting-adviser evidence to
   make a capacity graph appear smaller.
5. When modifying one of these functions, compare it to the deployed source,
   run tests on the exact changed function, deploy by an authorized Supabase
   operation and verify the resulting Edge Function version and source-health
   archive checksum/manifest telemetry.

## Capacity context

The production database was approximately 369 MiB on November 28, 2026,
and `source_health/SUPABASE_DATABASE/capacity_500mb` reported 77.3%.
`pg_database_size` excludes WAL; deleting rows may not immediately reclaim
filesystem space. The existing archive jobs already verified ongoing batches.
**No bulk deletion or quota-altering change was made in this Git restoration.**
