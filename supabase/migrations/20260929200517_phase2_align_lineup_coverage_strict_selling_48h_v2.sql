
create or replace view public.phase2_lineup_coverage_current as
with cohort as (
 select m.hkjc_event_id,m.home_zh,m.away_zh,m.kickoff_hkt from public.matches m
 where m.selling=true and coalesce(m.in_play,false)=false and m.kickoff_hkt>=now() and m.kickoff_hkt<now()+interval '48 hours'
), agg as (
 select c.hkjc_event_id,c.home_zh,c.away_zh,c.kickoff_hkt,
 count(e.id) lineup_rows,
 count(e.id) filter(where e.starter=true and e.team_side='HOME') home_starters,
 count(e.id) filter(where e.starter=true and e.team_side='AWAY') away_starters,
 count(e.id) filter(where e.confirmed=true) confirmed_rows,
 count(distinct e.source_name) source_count
 from cohort c left join public.phase2_canonical_lineup_rows_current e using(hkjc_event_id)
 group by 1,2,3,4
)
select *,case when home_starters=11 and away_starters=11 and confirmed_rows>0 then 'CONFIRMED'
when home_starters=11 and away_starters=11 then 'PREDICTED_FULL'
when home_starters=0 and away_starters=0 then 'MISSING' else 'PARTIAL' end lineup_status,
(select x.source_name from public.phase2_canonical_lineup_rows_current x where x.hkjc_event_id=agg.hkjc_event_id order by x.confirmed desc,x.fetched_at desc nulls last limit 1) canonical_source
from agg;
