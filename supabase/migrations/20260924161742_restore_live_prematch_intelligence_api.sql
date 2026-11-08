create or replace view public.dashboard_live_intelligence_v with (security_invoker=true) as
with snap as (
  select distinct on (hkjc_event_id, source_key, market_key)
    hkjc_event_id, source_key, market_key, prob_home, prob_draw, prob_away,
    prob_over, prob_under, xg_home, xg_away,
    market_odds_home, market_odds_draw, market_odds_away, captured_at
  from private.prematch_prediction_snapshot
  order by hkjc_event_id, source_key, market_key, captured_at desc
), p as (
  select hkjc_event_id,
    max(prob_home) filter (where source_key='MULTISOURCE' and market_key='1X2') as pre_prob_home,
    max(prob_draw) filter (where source_key='MULTISOURCE' and market_key='1X2') as pre_prob_draw,
    max(prob_away) filter (where source_key='MULTISOURCE' and market_key='1X2') as pre_prob_away,
    max(prob_over) filter (where source_key='MULTISOURCE' and market_key='OU25') as pre_prob_over25,
    max(prob_under) filter (where source_key='MULTISOURCE' and market_key='OU25') as pre_prob_under25,
    max(prob_home) filter (where source_key='FORM' and market_key='1X2') as form_prob_home_snap,
    max(prob_draw) filter (where source_key='FORM' and market_key='1X2') as form_prob_draw_snap,
    max(prob_away) filter (where source_key='FORM' and market_key='1X2') as form_prob_away_snap,
    max(xg_home) filter (where source_key='FORM' and market_key='1X2') as form_xg_home_snap,
    max(xg_away) filter (where source_key='FORM' and market_key='1X2') as form_xg_away_snap,
    max(captured_at) as prematch_captured_at
  from snap group by hkjc_event_id
)
select f.*,
  p.pre_prob_home, p.pre_prob_draw, p.pre_prob_away, p.pre_prob_over25, p.pre_prob_under25,
  coalesce(f.form_prob_home,p.form_prob_home_snap) as display_form_prob_home,
  coalesce(f.form_prob_draw,p.form_prob_draw_snap) as display_form_prob_draw,
  coalesce(f.form_prob_away,p.form_prob_away_snap) as display_form_prob_away,
  coalesce(f.form_xg_home,p.form_xg_home_snap) as display_form_xg_home,
  coalesce(f.form_xg_away,p.form_xg_away_snap) as display_form_xg_away,
  p.prematch_captured_at,
  case when f.best_bet is not null then f.best_bet
       when p.pre_prob_home is null then null
       when p.pre_prob_home >= greatest(p.pre_prob_draw,p.pre_prob_away) then 'H'
       when p.pre_prob_draw >= greatest(p.pre_prob_home,p.pre_prob_away) then 'D'
       else 'A' end as display_prematch_pick,
  case when f.live_score is not null or f.match_minute is not null then 'LIVE_ENRICHED'
       when f.in_play then 'PREMATCH_BASELINE'
       else 'PREMATCH' end as advice_mode
from public.fast_tracker_live_v2 f
left join p using (hkjc_event_id);
