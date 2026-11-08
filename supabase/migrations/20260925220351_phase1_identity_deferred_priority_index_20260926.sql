
create index if not exists phase1_identity_deferred_priority_idx
on public.phase1_identity_deferred_queue (source, evidence_count desc, last_checked_at asc nulls first)
where reactivated_at is null;
