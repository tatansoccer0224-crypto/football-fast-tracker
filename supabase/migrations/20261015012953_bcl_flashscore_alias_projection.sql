-- Build a safe Flashscore-facing projection of the legacy BetClan aliases.
-- The old HKJC-keyed evidence remains untouched; ambiguous and missing
-- Flashscore IDs never become verified aliases in this projection.
create or replace view public.football_alias_supertable_flashscore_projection
with (security_invoker = true) as
with candidates as (
  select
    b.source,b.alias_key,b.competition_key,b.provider_team_id,b.provider_name,
    b.source_competition,b.canonical_competition,b.verified_team_key as legacy_team_key,
    b.canonical_name_en,b.canonical_name_zh,b.resolution_status as legacy_resolution_status,
    b.confidence as legacy_confidence,b.resolution_method as legacy_resolution_method,
    b.observations,b.source_event_id_example,b.source_detail_url,b.last_observed_at,
    b.evidence as legacy_evidence,
    count(distinct f.alias_key)::integer as flashscore_id_count,
    min(f.alias_key) as sole_flashscore_team_id,
    array_agg(distinct f.alias_key) filter (where f.alias_key is not null) as flashscore_team_id_candidates
  from public.football_alias_supertable b
  left join public.football_alias_supertable f
    on f.source = 'FLASHSCORE_TEAM_ID'
   and f.resolution_status = 'VERIFIED'
   and f.verified_team_key = b.verified_team_key
  where b.source = 'BCL'
    and b.resolution_status = 'VERIFIED'
    and b.verified_team_key is not null
  group by b.source,b.alias_key,b.competition_key,b.provider_team_id,b.provider_name,
    b.source_competition,b.canonical_competition,b.verified_team_key,b.canonical_name_en,
    b.canonical_name_zh,b.resolution_status,b.confidence,b.resolution_method,b.observations,
    b.source_event_id_example,b.source_detail_url,b.last_observed_at,b.evidence
)
select source,alias_key,competition_key,provider_team_id,provider_name,source_competition,
  canonical_competition,canonical_name_en,canonical_name_zh,legacy_team_key,
  case when flashscore_id_count = 1 then sole_flashscore_team_id end as flashscore_team_id,
  case when flashscore_id_count = 1 then 'FS_TEAM:' || sole_flashscore_team_id end as flashscore_team_key,
  flashscore_id_count,
  case when flashscore_id_count = 1 then 'VERIFIED_FLASHSCORE_ID'
       when flashscore_id_count > 1 then 'AMBIGUOUS_FLASHSCORE_ID'
       else 'NO_FLASHSCORE_ID' end as flashscore_identity_status,
  flashscore_team_id_candidates,legacy_resolution_status,legacy_confidence,legacy_resolution_method,
  observations,source_event_id_example,source_detail_url,last_observed_at,legacy_evidence
from candidates;
revoke all on public.football_alias_supertable_flashscore_projection from public, anon, authenticated;
grant select on public.football_alias_supertable_flashscore_projection to service_role;
