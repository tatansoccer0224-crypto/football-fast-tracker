-- FT: expose fresh Forebet score/average goals/HDA in the existing single
-- canonical summary RPC. No new view/table/crawler or extra PostgREST request.
-- Historical Forebet records stay stored but cannot be promoted as current.
-- 500.com SPF is a separately sourced, limited-age reference, not Bet365 and
-- not a source for automated EV/value decisions.
CREATE OR REPLACE FUNCTION public.ft_fast_flashscore_summary(p_window_hours integer DEFAULT 24)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
 select coalesce(jsonb_agg(
  jsonb_build_object(
   'match_id',f.match_id,'kickoff_hkt',f.kickoff_hkt,'status',f.status,
   'tournament',f.league,'home_en',f.home_en,'away_en',f.away_en,
   'fetched_at',b.fetched_at,'updated_at',coalesce(b.updated_at,f.updated_at),
   'had_home',b.bet365_home,'had_draw',b.bet365_draw,'had_away',b.bet365_away,
   'odds_updated_at',b.fetched_at,'detail_raw',d.detail_raw,
   'detail_fetched_at',d.detail_fetched_at,
   'forebet_captured_at',fb.fetched_at,
   'forebet_home',fb.prob_home / 100.0,
   'forebet_draw',fb.prob_draw / 100.0,
   'forebet_away',fb.prob_away / 100.0,
   'forebet_predicted_score',fb.predicted_score,
   'forebet_avg_goals',fb.avg_goals,
   'china500_home',c.home,'china500_draw',c.draw,'china500_away',c.away,
   'china500_captured_at',c.captured_at,'china500_source_updated_at',c.source_updated_at
  ) order by f.kickoff_hkt,f.match_id
 ),'[]'::jsonb)
 from public.active_canonical_fixture_current f
 left join public.bookmaker_odds_current b on b.match_id=f.match_id
 left join lateral (
   select s.detail_raw,s.detail_fetched_at
   from public.phase15_source_shadow_current s
   where s.match_id=f.match_id and s.source_key='FLASHSCORE'
     and s.detail_fetched_at>now()-interval '24 hours'
   order by s.detail_fetched_at desc nulls last limit 1
 ) d on true
 left join public.forebet_predictions fb
   on fb.hkjc_event_id=f.match_id
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
   and c.league='EPL'
   and c.captured_at >= now()-interval '40 minutes'
   and c.source_updated_at >= now()-interval '2 hours'
   and c.source_updated_at <= now()+interval '5 minutes'
 where f.kickoff_hkt >= now()-interval '6 hours'
   and f.kickoff_hkt < now() + make_interval(hours => greatest(1,least(48,p_window_hours)));
$function$;
