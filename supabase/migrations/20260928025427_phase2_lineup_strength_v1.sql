
create or replace view public.phase2_lineup_strength_current as
with sides as (
  select c.hkjc_event_id, c.kickoff_hkt, 'HOME'::text team_side,
         c.home_zh team_name, c.home_starters starters,
         c.confirmed_rows, c.lineup_status, c.canonical_source
  from public.phase2_lineup_coverage_current c
  union all
  select c.hkjc_event_id, c.kickoff_hkt, 'AWAY'::text team_side,
         c.away_zh team_name, c.away_starters starters,
         c.confirmed_rows, c.lineup_status, c.canonical_source
  from public.phase2_lineup_coverage_current c
),
status_counts as (
  select hkjc_event_id, team_side,
         count(*) filter (
           where coalesce(valid_until, now()+interval '1 day') >= now()
             and lower(coalesce(status_type,'') || ' ' || coalesce(status_value,'')) ~
                 '(injur|suspend|unavail|doubt|傷|停賽|缺陣)'
         )::int unavailable_count,
         max(confidence) filter (
           where coalesce(valid_until, now()+interval '1 day') >= now()
         ) status_confidence
  from public.phase2_player_status_evidence
  group by 1,2
)
select
 s.hkjc_event_id,s.kickoff_hkt,s.team_side,s.team_name,
 least(100,greatest(0,
   round(
     (least(coalesce(s.starters,0),11)::numeric / 11.0 * 100)
     - least(coalesce(sc.unavailable_count,0),5) * 4
   )
 ))::int lineup_strength_pct,
 case
   when s.lineup_status='CONFIRMED' then '確認正選'
   when s.lineup_status='PREDICTED_FULL' then '預計完整'
   when s.lineup_status='PARTIAL' then '部分陣容'
   else '資料不足'
 end lineup_strength_label,
 least(100,greatest(0,
   round(
     case
       when s.lineup_status='CONFIRMED' then 95
       when s.lineup_status='PREDICTED_FULL' then 72
       when s.lineup_status='PARTIAL' then 45
       else 20
     end
     + case when coalesce(sc.unavailable_count,0)>0 then 3 else 0 end
   )
 ))::int lineup_confidence_pct,
 coalesce(s.starters,0)::int starters,
 coalesce(sc.unavailable_count,0)::int unavailable_count,
 s.lineup_status,s.canonical_source,
 'V1_COMPLETENESS_INDEX'::text strength_method
from sides s
left join status_counts sc
  on sc.hkjc_event_id=s.hkjc_event_id and sc.team_side=s.team_side;

comment on view public.phase2_lineup_strength_current is
'Phase 2 lineup strength V1. Completeness-based index, not player-quality rating. Strength and evidence confidence are intentionally separate; upgrade to player-importance weighting when reliable player minutes/ratings exist.';
