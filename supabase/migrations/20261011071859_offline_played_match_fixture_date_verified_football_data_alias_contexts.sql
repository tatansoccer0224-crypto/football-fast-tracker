
create or replace function private.ft_verify_historical_football_data_contexts()
returns jsonb language plpgsql security definer set search_path=public,pg_temp
as $$
declare v_events int; v_contexts int;
begin
with paired as (
select f.match_key,f.match_date,f.league_code,f.home_team,f.away_team,
m.hkjc_event_id,m.home_en,m.away_en,m.tournament
from public.football_data_matches f join public.matches m
on f.match_date between (m.kickoff_hkt at time zone 'Europe/London')::date-1 and (m.kickoff_hkt at time zone 'Europe/London')::date+1
and regexp_replace(lower(f.home_team),'[^a-z0-9]','','g')=regexp_replace(lower(m.home_en),'[^a-z0-9]','','g')
and regexp_replace(lower(f.away_team),'[^a-z0-9]','','g')=regexp_replace(lower(m.away_en),'[^a-z0-9]','','g')
),
safe_fixture as (
select x.* from paired x
where (select count(distinct hkjc_event_id) from paired y where y.match_key=x.match_key)=1
and (select count(distinct match_key) from paired y where y.hkjc_event_id=x.hkjc_event_id)=1
),
legs as (
select match_key,league_code,home_team source_name,home_en canonical_name,tournament
from safe_fixture
union all
select match_key,league_code,away_team,away_en,tournament from safe_fixture
),
safe as (
select l.*,e.team_key,e.hkjc_name_en,e.hkjc_name_zh,
regexp_replace(lower(l.source_name),'[^a-z0-9]','','g') alias_key,
regexp_replace(lower(l.league_code),'[^a-z0-9]','','g') competition_key
from legs l join public.team_entities_v2 e
on e.name_key=regexp_replace(lower(l.canonical_name),'[^a-z0-9]','','g')
where (select count(distinct team_key) from public.team_entities_v2 e2 where e2.name_key=e.name_key)=1
),
scoped as (
select distinct on(alias_key,competition_key,tournament,team_key) *
from safe s where not exists (
select 1 from safe t where t.alias_key=s.alias_key and t.competition_key=s.competition_key and t.team_key<>s.team_key)
order by alias_key,competition_key,tournament,team_key,match_key
),
added as (
insert into public.team_name_context_master
(source,source_name,source_key,source_competition,competition_key,canonical_tournament,
team_key,hkjc_name_en,hkjc_name_zh,status,confidence,event_count,
first_seen_at,last_seen_at,evidence_sources,updated_at)
select 'FOOTBALL_DATA',source_name,alias_key,league_code,competition_key,tournament,
team_key,hkjc_name_en,hkjc_name_zh,'VERIFIED',0.985,1,now(),now(),
jsonb_build_array('HISTORICAL_PLAYED_FIXTURE_EXACT_PAIR','UNIQUE_EVENT_DATE','SOURCE_MATCH:'||match_key),now()
from scoped
on conflict(source,source_key,competition_key,canonical_tournament,team_key) do nothing
returning 1
)
select (select count(*) from safe_fixture),(select count(*) from added) into v_events,v_contexts;
return jsonb_build_object('played_fixtures_grounded',v_events,'context_aliases_added',v_contexts,'time',now());
end $$;
revoke all on function private.ft_verify_historical_football_data_contexts() from public,anon,authenticated;
grant execute on function private.ft_verify_historical_football_data_contexts() to service_role;
