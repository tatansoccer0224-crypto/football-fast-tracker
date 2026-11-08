
create or replace view public.phase2_lineup_coverage_current as
with cohort as (
 select hkjc_event_id,home_zh,away_zh,kickoff_hkt from public.matches
 where selling=true and coalesce(in_play,false)=false and kickoff_hkt>=now() and kickoff_hkt<now()+interval '48 hours'
), ranked as (
 select e.*,row_number() over(partition by e.hkjc_event_id,e.team_side,coalesce(nullif(e.player_key,''),lower(e.player_name))
 order by e.confirmed desc,e.fetched_at desc nulls last,e.created_at desc) rn
 from public.phase2_match_lineup_evidence e join cohort c using(hkjc_event_id)
), agg as (
 select c.hkjc_event_id,c.home_zh,c.away_zh,c.kickoff_hkt,
 count(r.id) filter(where r.rn=1) lineup_rows,
 count(r.id) filter(where r.rn=1 and r.starter and r.team_side='HOME') home_starters,
 count(r.id) filter(where r.rn=1 and r.starter and r.team_side='AWAY') away_starters,
 count(r.id) filter(where r.rn=1 and r.confirmed) confirmed_rows,
 count(distinct r.source_name) filter(where r.rn=1) source_count
 from cohort c left join ranked r using(hkjc_event_id) group by 1,2,3,4
)
select *,case when home_starters=11 and away_starters=11 and confirmed_rows>0 then 'CONFIRMED'
when home_starters=11 and away_starters=11 then 'PREDICTED_FULL'
when home_starters=0 and away_starters=0 then 'MISSING' else 'PARTIAL' end lineup_status,
(select r.source_name from ranked r where r.hkjc_event_id=agg.hkjc_event_id and r.rn=1 order by r.confirmed desc,r.fetched_at desc nulls last limit 1) canonical_source
from agg;
