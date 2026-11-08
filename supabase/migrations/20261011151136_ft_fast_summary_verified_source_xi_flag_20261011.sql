CREATE OR REPLACE FUNCTION public.ft_fast_flashscore_summary(p_window_hours integer DEFAULT 24)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
 select coalesce(jsonb_agg(
  jsonb_build_object(
   'match_id',f.match_id,'kickoff_hkt',f.kickoff_hkt,'status',f.status,
   'fs_live_verified',f.in_play,
   'fs_home_score',f.provider_home_score,
   'fs_away_score',f.provider_away_score,
   'fs_score_fetched_at',f.provider_score_fetched_at,
   'tournament',f.league,'home_en',f.home_en,'away_en',f.away_en,
   'fetched_at',b.fetched_at,'updated_at',coalesce(b.updated_at,f.updated_at),
   'had_home',b.bet365_home,'had_draw',b.bet365_draw,'had_away',b.bet365_away,
   'odds_updated_at',b.fetched_at,'detail_raw',d.detail_raw,
   'detail_fetched_at',d.detail_fetched_at,
   'flashscore_verified_source_xi',coalesce(sl.lineup_available AND sl.detail_fetched_at>=now()-interval '72 hours',false),
   'flashscore_xi_observed_at',case when sl.lineup_available AND sl.detail_fetched_at>=now()-interval '72 hours' then sl.detail_fetched_at else null end,
   'forebet_captured_at',fb.fetched_at,
   'forebet_home',fb.prob_home / 100.0,
   'forebet_draw',fb.prob_draw / 100.0,
   'forebet_away',fb.prob_away / 100.0,
   'forebet_predicted_score',fb.predicted_score,
   'forebet_avg_goals',fb.avg_goals,
   'historical_form_home',public.ft_historical_form_by_team(f.home_en,f.league,f.kickoff_hkt),
   'historical_form_away',public.ft_historical_form_by_team(f.away_en,f.league,f.kickoff_hkt),
   'china500_home',c.home,'china500_draw',c.draw,'china500_away',c.away,
   'china500_captured_at',c.captured_at,'china500_source_updated_at',c.source_updated_at
  ) order by f.kickoff_hkt,f.match_id
 ),'[]'::jsonb)
 from public.flashscore_primary_fixture_current f
 left join public.bookmaker_odds_current b on b.match_id=f.match_id
 left join lateral (
   select s.detail_raw,s.detail_fetched_at
   from public.phase15_source_shadow_current s
   where s.match_id=f.match_id and s.source_key='FLASHSCORE'
     and s.detail_fetched_at>now()-interval '24 hours'
   order by s.detail_fetched_at desc nulls last limit 1
 ) d on true
 left join public.phase15_source_shadow_current sl
   on sl.source_key='FLASHSCORE' and sl.match_id=f.match_id
   and sl.external_event_id=substring(f.match_id from 4)
 left join public.forebet_predictions fb
   on fb.canonical_event_id=f.match_id
   and fb.fetched_at >= now()-interval '72 hours'
   and fb.fetched_at <= now()+interval '10 minutes'
   and fb.match_score >= 0.94
   and fb.prob_home between 0 and 100
   and fb.prob_draw between 0 and 100
   and fb.prob_away between 0 and 100
   and fb.prob_home+fb.prob_draw+fb.prob_away between 98 and 102
   and fb.predicted_score ~ '^[0-9]{1,2} *- *[0-9]{1,2}$'
   and fb.avg_goals > 0 and fb.avg_goals <= 12
 left join public.ft_500_spf_current c on c.match_id=f.match_id
   and c.league=f.league
   and c.captured_at >= now()-interval '75 minutes'
   and c.source_updated_at >= now()-interval '24 hours'
   and c.source_updated_at <= now()+interval '5 minutes'
 where f.kickoff_hkt >= now()-interval '6 hours'
   and f.kickoff_hkt < now() + make_interval(hours => greatest(1,least(48,p_window_hours)));
$function$
