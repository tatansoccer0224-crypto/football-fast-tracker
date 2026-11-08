
create or replace view public.live_shadow_compare_v
with (security_invoker=true)
as
with joined as (
  select
    l.hkjc_event_id,
    l.fetched_at as hkjc_live_at,
    s.updated_at_source as production_score_at,
    sh.captured_at as shadow_at,
    s.source as production_source,
    s.source_match_id as production_source_match_id,
    sh.source as shadow_source,
    sh.source_match_id as shadow_source_match_id,
    s.home_score as production_home_score,
    s.away_score as production_away_score,
    sh.home_score as shadow_home_score,
    sh.away_score as shadow_away_score,
    s.minute as production_minute,
    sh.minute as shadow_minute,
    d.detail_status as shadow_detail_status,
    case
      when upper(coalesce(s.source,''))='FOOTBALL_LIVE_API_SELF_HOSTED' then 'FOTMOB'
      when upper(coalesce(s.source,'')) like 'FOTMOB%' then 'FOTMOB'
      when upper(coalesce(s.source,'')) like 'SOFASCORE%' then 'SOFASCORE'
      when upper(coalesce(s.source,'')) like 'HKJC%' then 'HKJC'
      else null
    end as production_namespace,
    case
      when upper(coalesce(sh.source,'')) like 'FOTMOB%' then 'FOTMOB'
      when upper(coalesce(sh.source,'')) like 'SOFASCORE%' then 'SOFASCORE'
      when upper(coalesce(sh.source,'')) like 'HKJC%' then 'HKJC'
      else null
    end as shadow_namespace,
    sh.hkjc_event_id as shadow_hkjc_event_id
  from public.hkjc_live_odds_current l
  left join public.live_score_current s using(hkjc_event_id)
  left join public.live_source_shadow_current sh using(hkjc_event_id)
  left join public.live_detail_shadow_current d using(hkjc_event_id)
  where l.fetched_at >= now()-interval '3 minutes'
)
select
  hkjc_event_id,hkjc_live_at,production_score_at,shadow_at,
  production_source,production_source_match_id,shadow_source,shadow_source_match_id,
  production_home_score,production_away_score,shadow_home_score,shadow_away_score,
  production_minute,shadow_minute,shadow_detail_status,
  case
    when shadow_hkjc_event_id is null then false
    when coalesce(shadow_source,'')='SOURCE_GAP' then false
    when shadow_source_match_id is null or shadow_source_match_id='' then false
    else true
  end as shadow_present,
  case
    when shadow_hkjc_event_id is null then null::boolean
    when coalesce(shadow_source,'')='SOURCE_GAP' then null::boolean
    when production_source_match_id is null or shadow_source_match_id is null then null::boolean
    when production_namespace is null or shadow_namespace is null then null::boolean
    when production_namespace <> shadow_namespace then null::boolean
    else production_source_match_id = shadow_source_match_id
  end as source_id_match,
  case
    when shadow_hkjc_event_id is null then null::boolean
    when coalesce(shadow_source,'')='SOURCE_GAP' then null::boolean
    when production_home_score is null or production_away_score is null
      or shadow_home_score is null or shadow_away_score is null then null::boolean
    else production_home_score=shadow_home_score and production_away_score=shadow_away_score
  end as score_match,
  case
    when shadow_hkjc_event_id is null then null::integer
    when coalesce(shadow_source,'')='SOURCE_GAP' then null::integer
    when production_minute is null or shadow_minute is null then null::integer
    else abs(production_minute-shadow_minute)
  end as minute_delta
from joined;
