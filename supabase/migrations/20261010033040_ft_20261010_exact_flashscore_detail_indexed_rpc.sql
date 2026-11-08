CREATE OR REPLACE FUNCTION public.ft_fast_flashscore_fixture_by_id(p_match_id text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER
SET search_path TO public,pg_temp
AS $$
  SELECT jsonb_build_object(
    'match_id',m.hkjc_event_id,
    'kickoff_hkt',m.kickoff_hkt,
    'status',m.status,
    'tournament',m.tournament,
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
    'detail_raw',d.detail_raw
  )
  FROM public.matches m
  LEFT JOIN public.bet365_current q
    ON q.match_id=m.hkjc_event_id AND q.source='FLASHSCORE_BET365'
  LEFT JOIN LATERAL (
    SELECT s.detail_fetched_at,s.detail_raw
    FROM public.phase15_source_shadow_current s
    WHERE s.match_id=m.hkjc_event_id AND s.source_key='FLASHSCORE'
      AND s.detail_fetched_at IS NOT NULL
    ORDER BY s.detail_fetched_at DESC NULLS LAST
    LIMIT 1
  ) d ON true
  WHERE m.hkjc_event_id=p_match_id AND p_match_id LIKE 'FS:%'
  LIMIT 1;
$$;
REVOKE ALL ON FUNCTION public.ft_fast_flashscore_fixture_by_id(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ft_fast_flashscore_fixture_by_id(text) TO service_role;
