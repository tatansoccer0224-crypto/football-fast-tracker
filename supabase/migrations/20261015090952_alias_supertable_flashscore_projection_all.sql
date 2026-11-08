-- Expose a safe, provider-wide Flashscore projection of the legacy alias
-- supertable. This is additive: it does not rekey or mutate existing aliases.
-- Missing, forward-conflicting, and reverse-conflicting identities stay
-- explicitly provisional rather than being inferred from spelling.
create or replace view public.football_alias_supertable_flashscore_projection_all
with (security_invoker = true) as
with fs_links as (
  select verified_team_key as legacy_team_key,
         alias_key as flashscore_team_id
  from public.football_alias_supertable
  where source = 'FLASHSCORE_TEAM_ID'
    and resolution_status = 'VERIFIED'
    and verified_team_key is not null
    and alias_key is not null
), fs_by_legacy as (
  select legacy_team_key,
         count(distinct flashscore_team_id)::integer as flashscore_id_count,
         min(flashscore_team_id) as sole_flashscore_team_id,
         array_agg(distinct flashscore_team_id order by flashscore_team_id)
           as flashscore_team_id_candidates
  from fs_links
  group by legacy_team_key
), fs_by_id as (
  select flashscore_team_id,
         count(distinct legacy_team_key)::integer as legacy_key_count
  from fs_links
  group by flashscore_team_id
)
select
  b.source,
  b.alias_key,
  b.competition_key,
  b.provider_team_id,
  b.provider_name,
  b.source_competition,
  b.canonical_competition,
  b.canonical_name_en,
  b.canonical_name_zh,
  b.verified_team_key as legacy_team_key,
  case when coalesce(f.flashscore_id_count,0) = 1
       then f.sole_flashscore_team_id end as flashscore_team_id,
  case when coalesce(f.flashscore_id_count,0) = 1
       then 'FS_TEAM:' || f.sole_flashscore_team_id end as flashscore_team_key,
  coalesce(f.flashscore_id_count,0) as flashscore_id_count,
  coalesce(r.legacy_key_count,0) as legacy_key_count_for_candidate_id,
  case
    when coalesce(f.flashscore_id_count,0) = 0 then 'NO_FLASHSCORE_ID'
    when f.flashscore_id_count > 1 then 'AMBIGUOUS_FLASHSCORE_ID'
    when coalesce(r.legacy_key_count,0) > 1 then 'AMBIGUOUS_LEGACY_KEY'
    else 'VERIFIED_FLASHSCORE_ID'
  end as flashscore_identity_status,
  coalesce(f.flashscore_team_id_candidates, array[]::text[])
    as flashscore_team_id_candidates,
  b.suggested_team_key as legacy_suggested_team_key,
  b.resolution_status as legacy_resolution_status,
  b.confidence as legacy_confidence,
  b.resolution_method as legacy_resolution_method,
  b.observations,
  b.source_event_id_example,
  b.source_detail_url,
  b.last_observed_at,
  b.evidence as legacy_evidence
from public.football_alias_supertable b
left join fs_by_legacy f on f.legacy_team_key = b.verified_team_key
left join fs_by_id r on r.flashscore_team_id = f.sole_flashscore_team_id
where b.source not in ('CANONICAL_EN','CANONICAL_ZH','FLASHSCORE_TEAM_ID')
  and b.resolution_status = 'VERIFIED'
  and b.verified_team_key is not null;

revoke all on public.football_alias_supertable_flashscore_projection_all
  from public, anon, authenticated;
grant select on public.football_alias_supertable_flashscore_projection_all
  to service_role;
