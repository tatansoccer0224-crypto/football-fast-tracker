CREATE OR REPLACE FUNCTION public.ft_fast_flashscore_fixture_by_id(p_match_id text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_build_object(
    'match_id',m.match_id,
    'kickoff_hkt',m.kickoff_hkt,
    'status',m.status,
    'tournament',m.league,
    'home_en',m.home_en,
    'away_en',m.away_en,
    'home_zh',m.home_zh,
    'away_zh',m.away_zh,
    'updated_at',m.updated_at,
    'fetched_at',q.fetched_at,
    'odds_updated_at',q.fetched_at,
    'had_home',q.bet365_home,
    'had_draw',q.bet365_draw,
    'had_away',q.bet365_away,
    'bookmaker_source',q.source,
    'detail_fetched_at',d.detail_fetched_at,
    'detail_raw',d.detail_raw,
     'fs_home_score',m.provider_home_score,
     'fs_away_score',m.provider_away_score,
     'fs_score_fetched_at',m.provider_score_fetched_at,
     'verified_lineup',public.ft_verified_lineup_fast(m.match_id),
   'verified_managers',public.ft_verified_managers_fast(m.match_id),
    'forebet_prediction',fb.prediction,
    'internal_model',im.model,
    'player_match_stats',fm.stats,
    'player_match_stats_fetched_at',fm.detail_fetched_at
  )
  FROM public.flashscore_primary_fixture_current m
  LEFT JOIN public.bet365_current q
    ON q.match_id=m.match_id AND q.source='FLASHSCORE_BET365'
  LEFT JOIN LATERAL (
    SELECT s.detail_fetched_at,s.detail_raw
    FROM public.phase15_source_shadow_current s
    WHERE s.match_id=m.match_id AND s.source_key='FLASHSCORE'
      AND s.detail_fetched_at IS NOT NULL
    ORDER BY s.detail_fetched_at DESC NULLS LAST
    LIMIT 1
  ) d ON true

  LEFT JOIN LATERAL (
    SELECT jsonb_build_object(
      'match_id',m.match_id,'fetched_at',fp.fetched_at,
      'prob_home',fp.prob_home,'prob_draw',fp.prob_draw,'prob_away',fp.prob_away,
      'prediction_1x2',fp.prediction_1x2,'predicted_score',fp.predicted_score,
      'avg_goals',fp.avg_goals,
      'prob_over25',fp.prob_over25,'prob_under25',fp.prob_under25,
      'corner_prediction',fp.corner_prediction,
      'corner_prob_under95',fp.corner_prob_under95,
      'corner_prob_over95',fp.corner_prob_over95,
      'corner_predicted_score',fp.corner_predicted_score,
      'avg_corners',fp.avg_corners,
      'forebet_detail_url',fp.forebet_detail_url,
      'forebet_league_short',fp.forebet_league_short
    ) AS prediction
    FROM public.forebet_predictions fp
    WHERE fp.hkjc_event_id=m.match_id
    LIMIT 1
  ) fb ON true
  LEFT JOIN LATERAL (
    SELECT jsonb_build_object(
      'match_id',m.match_id,'fetched_at',mp.fetched_at,'quality',mp.quality,
      'model_source',mp.model_source,'training_matches',mp.training_matches,
      'team_match_quality',mp.team_match_quality,
      'dc_prob_home',mp.dc_prob_home,'dc_prob_draw',mp.dc_prob_draw,
      'dc_prob_away',mp.dc_prob_away,
      'dc_xg_home',mp.dc_xg_home,'dc_xg_away',mp.dc_xg_away,
      'dc_prob_over25',mp.dc_prob_over25,
      'pi_prob_home',mp.pi_prob_home,'pi_prob_draw',mp.pi_prob_draw,
      'pi_prob_away',mp.pi_prob_away,
      'pi_home_rating',mp.pi_home_rating,'pi_away_rating',mp.pi_away_rating,
      'pi_diff',mp.pi_diff
    ) AS model
    FROM public.fixture_identity_redirects r
    JOIN public.model_predictions mp ON mp.hkjc_event_id=r.source_match_id
    WHERE r.target_match_id=m.match_id AND r.active
      AND r.confidence >= 0.995 AND r.source_match_id LIKE 'FB%'
      AND mp.quality='MODELED'
      AND mp.dc_prob_home IS NOT NULL AND mp.dc_prob_draw IS NOT NULL
      AND mp.dc_prob_away IS NOT NULL AND mp.fetched_at<=m.kickoff_hkt
    ORDER BY r.confidence DESC,mp.fetched_at DESC
    LIMIT 1
  ) im ON true
  LEFT JOIN LATERAL (
    SELECT s.detail_fetched_at,
      (SELECT COALESCE(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'playerId', COALESCE(kv.value->>'id',kv.key),
        'playerName',kv.value->>'name',
        'teamId',kv.value->>'teamId',
        'teamName',kv.value->>'teamName',
        'optaId',kv.value->>'optaId',
        'shirtNumber',kv.value->>'shirtNumber',
        'positionId',kv.value->>'positionId',
        'isGoalkeeper',coalesce((kv.value->>'isGoalkeeper')::boolean,false),
        'rating',jsonb_path_query_first(kv.value, '$.stats[*].stats.* ? (@.key == "rating_title").stat.value'),
        'minutes',jsonb_path_query_first(kv.value, '$.stats[*].stats.* ? (@.key == "minutes_played").stat.value'),
        'goals',jsonb_path_query_first(kv.value, '$.stats[*].stats.* ? (@.key == "goals").stat.value'),
        'assists',jsonb_path_query_first(kv.value, '$.stats[*].stats.* ? (@.key == "assists").stat.value'),
        'totalShots',jsonb_path_query_first(kv.value, '$.stats[*].stats.* ? (@.key == "total_shots").stat.value'),
        'shotsOnTarget',jsonb_path_query_first(kv.value, '$.stats[*].stats.* ? (@.key == "ShotsOnTarget").stat.value'),
        'chancesCreated',jsonb_path_query_first(kv.value, '$.stats[*].stats.* ? (@.key == "chances_created").stat.value'),
        'accuratePasses',jsonb_path_query_first(kv.value, '$.stats[*].stats.* ? (@.key == "accurate_passes").stat.value'),
        'passAttempts',jsonb_path_query_first(kv.value, '$.stats[*].stats.* ? (@.key == "accurate_passes").stat.total'),
        'tackles',jsonb_path_query_first(kv.value, '$.stats[*].stats.* ? (@.key == "matchstats.headers.tackles").stat.value'),
        'interceptions',jsonb_path_query_first(kv.value, '$.stats[*].stats.* ? (@.key == "interceptions").stat.value'),
        'clearances',jsonb_path_query_first(kv.value, '$.stats[*].stats.* ? (@.key == "clearances").stat.value'),
        'recoveries',jsonb_path_query_first(kv.value, '$.stats[*].stats.* ? (@.key == "recoveries").stat.value'),
        'duelsWon',jsonb_path_query_first(kv.value, '$.stats[*].stats.* ? (@.key == "duel_won").stat.value'),
        'touches',jsonb_path_query_first(kv.value, '$.stats[*].stats.* ? (@.key == "touches").stat.value'),
        'saves',jsonb_path_query_first(kv.value, '$.stats[*].stats.* ? (@.key == "saves").stat.value'),
        'goalsConceded',jsonb_path_query_first(kv.value, '$.stats[*].stats.* ? (@.key == "goals_conceded").stat.value')
      ))),'[]'::jsonb)
       FROM jsonb_each(CASE WHEN jsonb_typeof(s.detail_raw #> '{content,playerStats}')='object'
         THEN s.detail_raw #> '{content,playerStats}' ELSE '{}'::jsonb END) AS kv
       WHERE kv.value->>'name' IS NOT NULL
      ) AS stats
    FROM public.phase15_source_shadow_current s
    WHERE s.match_id=m.match_id AND s.source_key='FOTMOB'
      AND s.identity_status IN ('EXACT_PAIR','VERIFIED_IDENTITY')
      AND s.match_confidence>=0.98
      AND s.detail_fetched_at IS NOT NULL
    ORDER BY s.detail_fetched_at DESC NULLS LAST LIMIT 1
  ) fm ON true
  WHERE m.match_id=p_match_id AND p_match_id LIKE 'FS:%'
  LIMIT 1;
$function$
