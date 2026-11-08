create or replace view phase2_lineup_coverage_current as
with cohort as (
 select hkjc_event_id,home_zh,away_zh,kickoff_hkt from matches
 where selling=true and coalesce(in_play,false)=false and kickoff_hkt>=now() and kickoff_hkt<now()+interval '48 hours'
), canon as (
 select r.* from phase2_canonical_lineup_rows_current r join cohort c using(hkjc_event_id)
), a as (
 select c.hkjc_event_id,c.home_zh,c.away_zh,c.kickoff_hkt,
 count(x.id) lineup_rows,
 count(*) filter(where x.starter and x.team_side='H') home_starters,
 count(*) filter(where x.starter and x.team_side='A') away_starters,
 count(*) filter(where x.confirmed) confirmed_rows,
 count(distinct x.source_name) source_count,
 max(x.source_name) canonical_source
 from cohort c left join canon x using(hkjc_event_id) group by 1,2,3,4
)
select hkjc_event_id,home_zh,away_zh,kickoff_hkt,lineup_rows,home_starters,away_starters,confirmed_rows,source_count,
case when home_starters=11 and away_starters=11 and confirmed_rows>=22 then 'CONFIRMED'
when home_starters=11 and away_starters=11 then 'PREDICTED_FULL'
when home_starters=0 and away_starters=0 then 'MISSING' else 'PARTIAL' end lineup_status,
canonical_source from a;
