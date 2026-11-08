
create or replace view public.flashscore_primary_fixture_current
with (security_invoker=true)
as
select f.match_id,
       s.kickoff_utc as kickoff_hkt,
       f.status,
       s.league_name as league,
       s.home_name as home_en,
       s.away_name as away_en,
       f.home_zh,f.away_zh,
       f.in_play,
       false::boolean as selling,
       null::text as pool_status,
       s.fetched_at,
       s.fetched_at as source_updated_at,
       greatest(f.updated_at,s.updated_at) as updated_at,
       'FLASHSCORE'::text as identity_authority,
       s.external_event_id as provider_event_id,
       s.identity_status as provider_identity_status
from public.active_canonical_fixture_current f
join public.phase15_source_shadow_current s
  on s.source_key='FLASHSCORE'
 and f.match_id='FS:'||s.external_event_id
where f.match_id like 'FS:%'
  and s.kickoff_utc is not null
  and s.fetched_at >= now()-interval '36 hours'
  and abs(extract(epoch from (s.kickoff_utc-f.kickoff_hkt))) <= 7200
  and s.home_name is not null and s.away_name is not null;
revoke all on public.flashscore_primary_fixture_current from public,anon,authenticated;
grant select on public.flashscore_primary_fixture_current to service_role;
comment on view public.flashscore_primary_fixture_current is
'Flashscore event-ID authoritative fixture read lane, no legacy synthetic IDs, no HKJC pricing/pool control; old fixture fields retained solely for stable FK and nonmarket metadata. Strict unique event and kickoff provenance; filter outdated source.';
do $$
declare old_def text;
begin
select pg_get_functiondef('public.ft_fast_flashscore_summary(integer)'::regprocedure) into old_def;
if old_def is null
or (length(old_def)-length(replace(old_def,'from public.active_canonical_fixture_current f',''))) <> length('from public.active_canonical_fixture_current f')
then raise exception 'FAST_SUMMARY_CONTRACT_CHANGED: refusing to overwrite function';
end if;
execute replace(old_def,'from public.active_canonical_fixture_current f','from public.flashscore_primary_fixture_current f');
end $$;
