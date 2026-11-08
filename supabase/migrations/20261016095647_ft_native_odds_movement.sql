-- Reconnect source-backed odds movement to the native Flashscore fixture IDs.
-- No new web collector. Reuse the verified, 5-minute bookmaker_odds_current feed.
-- History is checkpointed hourly if unchanged and immediately if changed; source
-- timestamps are never overwritten or manufactured.
CREATE OR REPLACE FUNCTION private.ft_refresh_native_odds_movement()
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'private', 'public', 'pg_temp'
AS $ft$
DECLARE
  v_history integer := 0;
  v_rows integer := 0;
BEGIN
  WITH eligible AS (
    SELECT b.match_id,b.fetched_at,b.bet365_home,b.bet365_draw,b.bet365_away,
           b.match_quality,f.kickoff_hkt
    FROM public.bookmaker_odds_current b
    JOIN public.canonical_fixture_current f ON f.match_id=b.match_id
    WHERE b.source='FLASHSCORE_BET365'
      AND b.match_id LIKE 'FS:%'
      AND b.fetched_at BETWEEN now()-interval '25 minutes' AND now()+interval '2 minutes'
      AND f.kickoff_hkt BETWEEN now()-interval '2 hours' AND now()+interval '7 days'
      AND b.bet365_home>1 AND b.bet365_draw>1 AND b.bet365_away>1
      AND coalesce(b.match_quality,0)>=0.90
  ), candidates AS (
    SELECT e.*,last.captured_at AS previous_capture,
           last.home_price AS previous_home,last.draw_price AS previous_draw,
           last.away_price AS previous_away
    FROM eligible e
    LEFT JOIN LATERAL (
      SELECT s.captured_at,s.home_price,s.draw_price,s.away_price
      FROM public.odds_snapshots s
      WHERE s.match_id=e.match_id
        AND s.source='FLASHSCORE_BET365' AND s.market='ML'
      ORDER BY s.captured_at DESC LIMIT 1
    ) last ON true
  )
  INSERT INTO public.odds_snapshots
    (match_id,captured_at,source,market,line,home_price,draw_price,away_price,raw)
  SELECT c.match_id,c.fetched_at,'FLASHSCORE_BET365','ML','',
         c.bet365_home,c.bet365_draw,c.bet365_away,
         jsonb_build_object('source','FLASHSCORE_BET365',
                            'fixture_authority','FLASHSCORE',
                            'capture_type','ACTUAL_OBSERVED_1X2',
                            'match_quality',c.match_quality)
  FROM candidates c
  WHERE c.previous_capture IS NULL
     OR c.previous_home IS DISTINCT FROM c.bet365_home
     OR c.previous_draw IS DISTINCT FROM c.bet365_draw
     OR c.previous_away IS DISTINCT FROM c.bet365_away
     OR c.previous_capture <= c.fetched_at-interval '60 minutes'
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_history = ROW_COUNT;

  -- Do not call the legacy public.ft_refresh_cloud_odds_movement() here:
  -- that routine joins retired FB keys to public.bet365_current.
  DELETE FROM public.odds_movement_current WHERE match_id LIKE 'FS:%';

  INSERT INTO public.odds_movement_current
    (match_id,captured_at,kickoff_hkt,home,away,movement_side,now_odds,
     odds_24h,move_24h_pp,odds_2h,move_2h_pp,odds_1h,move_1h_pp,
     vol_24h_pp,signal,model_side,model_prob,model_alignment,
     match_confidence,alert_score,raw,updated_at)
  WITH fresh AS (
    SELECT b.match_id,b.fetched_at,b.bet365_home ch,b.bet365_draw cd,
           b.bet365_away ca,b.match_quality,f.kickoff_hkt,f.home_en,f.away_en
    FROM public.bookmaker_odds_current b
    JOIN public.canonical_fixture_current f ON f.match_id=b.match_id
    WHERE b.source='FLASHSCORE_BET365' AND b.match_id LIKE 'FS:%'
      AND b.fetched_at BETWEEN now()-interval '25 minutes' AND now()+interval '2 minutes'
      AND f.kickoff_hkt BETWEEN now()-interval '2 hours' AND now()+interval '7 days'
      AND b.bet365_home>1 AND b.bet365_draw>1 AND b.bet365_away>1
      AND coalesce(b.match_quality,0)>=0.90
  ), past AS (
    SELECT f.*,
           h1.home_price h1h,h1.draw_price h1d,h1.away_price h1a,
           h2.home_price h2h,h2.draw_price h2d,h2.away_price h2a,
           h24.home_price h24h,h24.draw_price h24d,h24.away_price h24a,
           h1.captured_at as captured_1h,h2.captured_at as captured_2h,
           h24.captured_at as captured_24h
    FROM fresh f
    LEFT JOIN LATERAL (
      SELECT s.* FROM public.odds_snapshots s
      WHERE s.match_id=f.match_id AND s.source='FLASHSCORE_BET365' AND s.market='ML'
        AND s.captured_at BETWEEN f.fetched_at-interval '2 hours'
                              AND f.fetched_at-interval '1 hour'
      ORDER BY s.captured_at DESC LIMIT 1
    ) h1 ON true
    LEFT JOIN LATERAL (
      SELECT s.* FROM public.odds_snapshots s
      WHERE s.match_id=f.match_id AND s.source='FLASHSCORE_BET365' AND s.market='ML'
        AND s.captured_at BETWEEN f.fetched_at-interval '4 hours'
                              AND f.fetched_at-interval '2 hours'
      ORDER BY s.captured_at DESC LIMIT 1
    ) h2 ON true
    LEFT JOIN LATERAL (
      SELECT s.* FROM public.odds_snapshots s
      WHERE s.match_id=f.match_id AND s.source='FLASHSCORE_BET365' AND s.market='ML'
        AND s.captured_at BETWEEN f.fetched_at-interval '30 hours'
                              AND f.fetched_at-interval '24 hours'
      ORDER BY s.captured_at DESC LIMIT 1
    ) h24 ON true
  ), denominators AS (
    SELECT p.*,
      (1/ch + 1/cd + 1/ca) AS dc,
      CASE WHEN h1h>1 AND h1d>1 AND h1a>1 THEN (1/h1h + 1/h1d + 1/h1a) END d1,
      CASE WHEN h2h>1 AND h2d>1 AND h2a>1 THEN (1/h2h + 1/h2d + 1/h2a) END d2,
      CASE WHEN h24h>1 AND h24d>1 AND h24a>1 THEN (1/h24h + 1/h24d + 1/h24a) END d24
    FROM past p
  ), per_side AS (
    SELECT d.*,t.side,t.current_odds,t.old_1h,t.old_2h,t.old_24h,
           t.p_now,t.p_1h,t.p_2h,t.p_24h,
           greatest(coalesce(abs(t.p_now-t.p_1h),0),
                    coalesce(abs(t.p_now-t.p_2h),0),
                    coalesce(abs(t.p_now-t.p_24h),0)) AS magnitude
    FROM denominators d
    CROSS JOIN LATERAL unnest(
      ARRAY['H','D','A']::text[],
      ARRAY[ch,cd,ca]::numeric[],
      ARRAY[h1h,h1d,h1a]::numeric[],
      ARRAY[h2h,h2d,h2a]::numeric[],
      ARRAY[h24h,h24d,h24a]::numeric[],
      ARRAY[(1/ch)/dc,(1/cd)/dc,(1/ca)/dc]::numeric[],
      ARRAY[(1/h1h)/d1,(1/h1d)/d1,(1/h1a)/d1]::numeric[],
      ARRAY[(1/h2h)/d2,(1/h2d)/d2,(1/h2a)/d2]::numeric[],
      ARRAY[(1/h24h)/d24,(1/h24d)/d24,(1/h24a)/d24]::numeric[]
    ) AS t(side,current_odds,old_1h,old_2h,old_24h,p_now,p_1h,p_2h,p_24h)
  ), chosen AS (
    SELECT DISTINCT ON (match_id) *
    FROM per_side
    ORDER BY match_id,magnitude DESC,side
  )
  SELECT
    x.match_id,x.fetched_at,x.kickoff_hkt,x.home_en,x.away_en,
    x.side,x.current_odds,
    x.old_24h,round(100*(x.p_now-x.p_24h),2),
    x.old_2h,round(100*(x.p_now-x.p_2h),2),
    x.old_1h,round(100*(x.p_now-x.p_1h),2),
    NULL::numeric,
    CASE WHEN x.p_1h IS NULL AND x.p_2h IS NULL AND x.p_24h IS NULL THEN 'COLLECTING'
         WHEN x.magnitude >= 0.02 THEN 'MOVE' ELSE 'STABLE' END,
    NULL::text,NULL::numeric,'NO_VERIFIED_MODEL',x.match_quality,
    CASE WHEN x.p_1h IS NULL AND x.p_2h IS NULL AND x.p_24h IS NULL
         THEN NULL::numeric ELSE round(100*x.magnitude,2) END,
    jsonb_build_object('source','FLASHSCORE_BET365',
      'fixture_authority','FLASHSCORE','method','NO_VIG_OBSERVED_ONLY',
      'captured_1h',x.captured_1h,'captured_2h',x.captured_2h,
      'captured_24h',x.captured_24h,'verified_model',false,
      'current_odds',jsonb_build_object('home',x.ch,'draw',x.cd,'away',x.ca)),
    now()
  FROM chosen x;
  GET DIAGNOSTICS v_rows = ROW_COUNT;

  INSERT INTO public.source_health(source,metric,value_text,status,notes,observed_at,raw)
  VALUES ('FLASHSCORE_BET365','odds_movement',v_rows::text,
      CASE WHEN v_rows>0 THEN 'OK' ELSE 'ATTENTION' END,
      'Native FS odds history is captured from real source timestamps; missing baselines stay COLLECTING.',
      now(),jsonb_build_object('native_fs_rows',v_rows,'history_appended',v_history,
             'method','SOURCE_BACKED_NO_VIG','model_used',false))
  ON CONFLICT(source,metric) DO UPDATE SET
    value_text=excluded.value_text,status=excluded.status,notes=excluded.notes,
    observed_at=excluded.observed_at,raw=excluded.raw;

  RETURN jsonb_build_object('rows',v_rows,'new_history',v_history,'source','FLASHSCORE_BET365');
END
$ft$;
REVOKE ALL ON FUNCTION private.ft_refresh_native_odds_movement() FROM PUBLIC,anon,authenticated;
-- Existing publication job remains unchanged. A cheap, post-publication SQL-only
-- job samples the already ingested bookmaker data; no extra scraping/network calls.
SELECT cron.schedule('ft-native-odds-movement-15m','3,18,33,48 * * * *',
  'SELECT private.ft_refresh_native_odds_movement();');
