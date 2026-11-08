
create or replace view public.phase2_lineup_coverage_current as
with cohort as (
 select hkjc_event_id,home_zh,away_zh,kickoff_hkt from matches
 where selling=true and coalesce(in_play,false)=false and kickoff_hkt>=now() and kickoff_hkt<now()+interval '48 hours'
), a as (
 select c.hkjc_event_id,c.home_zh,c.away_zh,c.kickoff_hkt,
 count(e.id) lineup_rows,
 count(distinct lower(e.player_name)) filter(where e.starter and e.team_side='H') home_starters,
 count(distinct lower(e.player_name)) filter(where e.starter and e.team_side='A') away_starters,
 count(e.id) filter(where e.confirmed) confirmed_rows,
 count(distinct e.source_name) source_count
 from cohort c left join phase2_match_lineup_evidence e using(hkjc_event_id) group by 1,2,3,4
)
select *,case when home_starters=11 and away_starters=11 and confirmed_rows>0 then 'CONFIRMED'
when home_starters=11 and away_starters=11 then 'PREDICTED_FULL'
when home_starters=0 and away_starters=0 then 'MISSING' else 'PARTIAL' end lineup_status,
(select e.source_name from phase2_match_lineup_evidence e where e.hkjc_event_id=a.hkjc_event_id order by e.confirmed desc,e.fetched_at desc nulls last limit 1) canonical_source
from a;
