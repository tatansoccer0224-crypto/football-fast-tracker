
create or replace function private.ft_seed_played_football_data_to_supertable()
returns jsonb language plpgsql security definer set search_path=public,pg_temp
as $$
declare added int; all_count int;
begin
with legs as (
select league_code,home_team name,match_date,match_key from public.football_data_matches
union all
select league_code,away_team name,match_date,match_key from public.football_data_matches
),
names as (
select league_code,name,regexp_replace(lower(league_code),'[^a-z0-9]','','g') league_key,
regexp_replace(lower(name),'[^a-z0-9]','','g') name_key,
count(*) occurrences,min(match_date) first_date,max(match_date) last_date,min(match_key) exemplar
from legs where name is not null and length(name)>1
group by 1,2,3,4
),
verified_global as (
select alias_key,min(team_key) team_key from public.team_alias_registry_v2
where source='FOOTBALL_DATA' and status='VERIFIED'
group by alias_key having count(distinct team_key)=1
),
verified_scoped as (
select source_key name_key,competition_key league_key,min(team_key) team_key
from public.team_name_context_master
where source='FOOTBALL_DATA' and status='VERIFIED'
group by 1,2 having count(distinct team_key)=1
),
exact as (
select name_key, min(team_key) team_key
from public.team_entities_v2
group by name_key having count(distinct team_key)=1
),
categorized as (
select n.*,vg.team_key global_team,vs.team_key scoped_team,x.team_key exact_team,
case when vg.team_key is not null and vs.team_key is not null and vg.team_key<>vs.team_key then 'AMBIGUOUS'
when coalesce(vs.team_key,vg.team_key) is not null then 'VERIFIED'
when x.team_key is not null then 'CANDIDATE'
else 'UNMATCHED' end identity_status
from names n
left join verified_global vg on vg.alias_key=n.name_key
left join verified_scoped vs on vs.name_key=n.name_key and vs.league_key=n.league_key
left join exact x on x.name_key=n.name_key
),
updates as (
insert into public.football_alias_supertable
(source,alias_key,competition_key,provider_team_id,provider_name,source_competition,
verified_team_key,suggested_team_key,resolution_status,confidence,resolution_method,observations,
source_event_id_example,last_observed_at,evidence)
select 'FOOTBALL_DATA',name_key,league_key,'',name,league_code,
case when identity_status='VERIFIED' then coalesce(scoped_team,global_team) end,
case when identity_status='CANDIDATE' then exact_team end,
identity_status,
case when identity_status='VERIFIED' then 0.985::numeric when identity_status='CANDIDATE' then 0.72::numeric else 0::numeric end,
case when identity_status='VERIFIED' then 'historical_played_fixture_verified_identity'
when identity_status='CANDIDATE' then 'historical_unique_name_candidate'
when identity_status='AMBIGUOUS' then 'historical_scope_global_conflict'
else 'historical_source_only' end,
occurrences,exemplar,last_date::timestamptz,
jsonb_build_object('historical_played_results',true,'source_table','football_data_matches','league_code',league_code,
'first_played',first_date,'last_played',last_date,'result_fixture_count',occurrences)
from categorized
on conflict(source,alias_key,competition_key,provider_team_id)
do update set observations=excluded.observations,last_observed_at=excluded.last_observed_at,
evidence=football_alias_supertable.evidence||excluded.evidence,
verified_team_key=case when football_alias_supertable.resolution_status='VERIFIED' then football_alias_supertable.verified_team_key else excluded.verified_team_key end,
suggested_team_key=case when football_alias_supertable.resolution_status='VERIFIED' then null else excluded.suggested_team_key end,
resolution_status=case when football_alias_supertable.resolution_status='VERIFIED' then 'VERIFIED' else excluded.resolution_status end,
resolution_method=case when football_alias_supertable.resolution_status='VERIFIED' then football_alias_supertable.resolution_method else excluded.resolution_method end,
confidence=greatest(football_alias_supertable.confidence,excluded.confidence),
refreshed_at=now()
returning 1
)
select count(*) into added from updates;
select count(*) into all_count from public.football_alias_supertable where source='FOOTBALL_DATA';
return jsonb_build_object('result_rows_upserted',added,'total_historical_team_rows',all_count,'source','FOOTBALL_DATA','time',now());
end $$;
revoke all on function private.ft_seed_played_football_data_to_supertable() from public,anon,authenticated;
grant execute on function private.ft_seed_played_football_data_to_supertable() to service_role;
