create or replace view public.phase2_lineup_coverage_display_current as
select
 u.hkjc_event_id,u.home_zh,u.away_zh,u.kickoff_hkt,
 count(d.id) as lineup_rows,
 count(*) filter (where d.starter and d.team_side='H' and d.display_eligible) as home_starters,
 count(*) filter (where d.starter and d.team_side='A' and d.display_eligible) as away_starters,
 count(*) filter (where d.confirmed and d.starter and d.display_eligible) as confirmed_rows,
 count(distinct d.source_name) filter (where d.display_eligible) as source_count,
 case
  when count(*) filter (where d.confirmed and d.starter and d.display_eligible)=22 then 'CONFIRMED_FULL'
  when count(*) filter (where d.starter and d.display_eligible)=22 then 'PREDICTED_FULL'
  when count(d.id) filter (where d.display_eligible)>0 then 'PARTIAL'
  else 'MISSING'
 end as lineup_status,
 max(d.source_name) filter (where d.display_eligible) as canonical_source,
 count(*) filter (where d.status_conflict) as conflict_rows,
 count(*) filter (where d.status_conflict and d.display_eligible) as conflict_leaks
from public.hkjc_upcoming_current u
left join public.phase2_lineup_display_current d on d.hkjc_event_id=u.hkjc_event_id
group by u.hkjc_event_id,u.home_zh,u.away_zh,u.kickoff_hkt;
