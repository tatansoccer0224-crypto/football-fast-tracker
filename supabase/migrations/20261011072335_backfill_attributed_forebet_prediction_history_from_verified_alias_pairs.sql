
create or replace function private.ft_publish_historical_verified_forebet_pairs()
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_new integer;
begin
with verified as (
select source,alias_key,min(verified_team_key) team_key from public.football_alias_supertable
where resolution_status='VERIFIED' and source='FOREBET'
group by source,alias_key having count(distinct verified_team_key)=1
),
canon as (select name_key,min(team_key) team_key from public.team_entities_v2 group by name_key having count(distinct team_key)=1),
fb as(
select s.external_event_id,s.home_name,s.away_name,s.league_name,s.raw,s.fetched_at,
(s.raw->>'source_fixture_date')::date event_date,
regexp_replace(lower(s.home_name),'[^a-z0-9]','','g') hk,
regexp_replace(lower(s.away_name),'[^a-z0-9]','','g') ak
from public.phase15_source_shadow_current s
where s.source_key='FOREBET' and s.raw->>'source_fixture_date'~'^20[0-9]{2}-[0-9]{2}-[0-9]{2}$'
),
fbresolved as (
select f.*,h.team_key ht,a.team_key at from fb f
join verified h on h.alias_key=f.hk and h.source='FOREBET'
join verified a on a.alias_key=f.ak and a.source='FOREBET'
),
matchresolved as(
select m.hkjc_event_id,m.kickoff_hkt,m.home_en,m.away_en,h.team_key ht,a.team_key at
from public.matches m join canon h on h.name_key=regexp_replace(lower(m.home_en),'[^a-z0-9]','','g')
join canon a on a.name_key=regexp_replace(lower(m.away_en),'[^a-z0-9]','','g')
),
paired as(
select f.*,m.hkjc_event_id,m.kickoff_hkt
from fbresolved f join matchresolved m on f.ht=m.ht and f.at=m.at
and (m.kickoff_hkt at time zone 'Asia/Taipei')::date between f.event_date-1 and f.event_date+1
),
safe as(
select p.* from paired p where
(select count(distinct hkjc_event_id) from paired x where x.external_event_id=p.external_event_id)=1
and (select count(distinct external_event_id) from paired x where x.hkjc_event_id=p.hkjc_event_id)=1
and (p.raw->>'prob_home_pct')~'^[0-9]{1,3}$'
and (p.raw->>'prob_draw_pct')~'^[0-9]{1,3}$'
and (p.raw->>'prob_away_pct')~'^[0-9]{1,3}$'
and ((p.raw->>'prob_home_pct')::int+(p.raw->>'prob_draw_pct')::int+(p.raw->>'prob_away_pct')::int) between 98 and 102
and (p.raw->>'predicted_score')~'^[0-9]{1,2}-[0-9]{1,2}$'
and (p.raw->>'avg_goals')~'^[0-9]+(\.[0-9]+)?$'
and (p.raw->>'avg_goals')::numeric between 0.1 and 12
and p.raw->>'source_url' like 'https://www.forebet.com/en/football/matches/%'
),
saved as (
insert into public.forebet_predictions (
hkjc_event_id,fetched_at,forebet_match_date,forebet_kickoff_text,forebet_league_short,
forebet_home_team,forebet_away_team,prob_home,prob_draw,prob_away,prediction_1x2,
predicted_score,avg_goals,forebet_detail_url,match_score,raw
)
select hkjc_event_id,fetched_at,event_date::text,raw->>'source_display_time',league_name,
home_name,away_name,(raw->>'prob_home_pct')::numeric,(raw->>'prob_draw_pct')::numeric,
(raw->>'prob_away_pct')::numeric,
case when (raw->>'prob_home_pct')::numeric>greatest((raw->>'prob_draw_pct')::numeric,(raw->>'prob_away_pct')::numeric) then '1'
when (raw->>'prob_draw_pct')::numeric>greatest((raw->>'prob_home_pct')::numeric,(raw->>'prob_away_pct')::numeric) then 'X'
when (raw->>'prob_away_pct')::numeric>greatest((raw->>'prob_home_pct')::numeric,(raw->>'prob_draw_pct')::numeric) then '2'
else null end,
raw->>'predicted_score',(raw->>'avg_goals')::numeric,
raw->>'source_url',0.985,
jsonb_build_object('source','FOREBET','provider_event_id',external_event_id,'captured_from','offline_source_shadow_20261011',
'identity_method','two_verified_team_ids+unique_fixture+date','historical_backfill',true,
'kickoff_timezone_known',false,'publication_time',fetched_at,'original_source_evidence',raw)
from safe
on conflict(hkjc_event_id) do nothing
returning hkjc_event_id
)
select count(*) into v_new from saved;
return jsonb_build_object('new_forebet_predictions',v_new,'method','offline_verified_pair_fixture_match','as_of',now());
end $$;
revoke all on function private.ft_publish_historical_verified_forebet_pairs() from public,anon,authenticated;
grant execute on function private.ft_publish_historical_verified_forebet_pairs() to service_role;
