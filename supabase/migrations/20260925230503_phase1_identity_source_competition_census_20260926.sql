
create or replace view public.phase1_identity_source_competition_census as
select
  q.source,
  coalesce(nullif(trim(q.source_competition), ''), 'UNKNOWN') as source_competition,
  count(*)::bigint as unresolved_names,
  sum(coalesce(q.evidence_count,0))::bigint as evidence_total,
  max(q.evidence_count)::bigint as max_evidence_count,
  min(q.first_seen_at) as first_seen_at,
  max(q.last_seen_at) as last_seen_at,
  count(*) filter (where q.candidate_team_key is not null)::bigint as with_candidate,
  count(*) filter (where q.reason ilike '%collision%')::bigint as collision_count
from public.phase1_identity_deferred_queue q
where q.reactivated_at is null
group by q.source, coalesce(nullif(trim(q.source_competition), ''), 'UNKNOWN');

comment on view public.phase1_identity_source_competition_census is
'Phase 1 static identity backlog census by provider and competition context; unresolved only. Supports safe league/cohort-aware promotion without fuzzy forcing.';
