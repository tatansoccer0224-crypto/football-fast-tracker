
create or replace view public.phase2_lineup_coverage_current
with (security_invoker=true) as
with upcoming as (
  select hkjc_event_id,home_zh,away_zh,kickoff_hkt
  from public.hkjc_upcoming_current
  where kickoff_hkt>=now()-interval '2 hours'
    and kickoff_hkt<now()+interval '48 hours'
),
source_stats as (
  select l.hkjc_event_id,l.source_name,
         count(*) as lineup_rows,
         count(*) filter(where l.starter=true and l.team_side='H') as home_starters,
         count(*) filter(where l.starter=true and l.team_side='A') as away_starters,
         count(*) filter(where l.confirmed=true) as confirmed_rows,
         max(l.fetched_at) as last_fetch,
         case
           when l.source_name='API_FOOTBALL' then 400
           when l.source_name='FLASHSCORE_OFFICIAL' then 350
           when l.source_name ilike '%PREDICTED%' then 150
           else 200
         end as source_priority
  from public.phase2_match_lineup_evidence l
  join upcoming u on u.hkjc_event_id=l.hkjc_event_id
  group by l.hkjc_event_id,l.source_name
),
ranked as (
  select s.*,
         row_number() over(
           partition by s.hkjc_event_id
           order by
             case when s.home_starters=11 and s.away_starters=11 then 1 else 0 end desc,
             s.confirmed_rows desc,
             s.source_priority desc,
             s.last_fetch desc
         ) as rn
  from source_stats s
),
source_counts as (
  select hkjc_event_id,count(*) as source_count
  from source_stats group by hkjc_event_id
)
select u.hkjc_event_id,u.home_zh,u.away_zh,u.kickoff_hkt,
       coalesce(r.lineup_rows,0)::bigint as lineup_rows,
       coalesce(r.home_starters,0)::bigint as home_starters,
       coalesce(r.away_starters,0)::bigint as away_starters,
       coalesce(r.confirmed_rows,0)::bigint as confirmed_rows,
       coalesce(sc.source_count,0)::bigint as source_count,
       case
         when r.home_starters=11 and r.away_starters=11
           then case when r.confirmed_rows>=22 then 'CONFIRMED' else 'PREDICTED_FULL' end
         when coalesce(r.lineup_rows,0)>0 then 'PARTIAL'
         else 'MISSING'
       end as lineup_status,
       r.source_name as canonical_source
from upcoming u
left join ranked r on r.hkjc_event_id=u.hkjc_event_id and r.rn=1
left join source_counts sc on sc.hkjc_event_id=u.hkjc_event_id;

alter table public.phase2_lineup_hourly_metrics enable row level security;
revoke all on table public.phase2_lineup_hourly_metrics from anon,authenticated;

alter function public.snapshot_phase2_lineup_coverage() security invoker;
revoke all on function public.snapshot_phase2_lineup_coverage() from public,anon,authenticated;
grant execute on function public.snapshot_phase2_lineup_coverage() to postgres,service_role;
