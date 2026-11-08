
CREATE OR REPLACE FUNCTION private.ft_refresh_forebet_supplemental_markets()
RETURNS TABLE (market_key text, changed_rows bigint)
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $function$
  WITH latest_archive AS (
    SELECT DISTINCT ON (a.match_id) a.*
    FROM public.forebet_archive AS a
    WHERE a.captured_at >= NOW() - INTERVAL '36 hours'
      AND a.match_id LIKE 'FS:%'
    ORDER BY a.match_id, a.captured_at DESC
  ),
  verified_pair AS (
    SELECT a.*, p.confidence AS linked_confidence
    FROM latest_archive AS a
    JOIN private.prediction_evidence_current AS p
      ON p.canonical_event_id = a.match_id
     AND p.source_key = 'FOREBET'
     AND p.market_key = '1X2'
     AND p.status = 'CURRENT'
    JOIN public.flashscore_primary_fixture_current AS f
      ON f.match_id = a.match_id
     AND f.kickoff_hkt >= NOW()
    WHERE p.source_updated_at >= NOW() - INTERVAL '36 hours'
      AND ABS(a.prob_home / 100.0 - p.prob_home) <= 0.011
      AND ABS(a.prob_draw / 100.0 - p.prob_draw) <= 0.011
      AND ABS(a.prob_away / 100.0 - p.prob_away) <= 0.011
      AND ABS(EXTRACT(EPOCH FROM (a.captured_at - p.source_updated_at))) <= 300
  ),
  markets AS (
    SELECT
      a.match_id AS canonical_event_id,
      v.market_key,
      a.captured_at AS source_updated_at,
      v.pick,
      v.predicted_score,
      v.prob_over / 100.0 AS prob_over,
      v.prob_under / 100.0 AS prob_under,
      v.avg_goals,
      v.avg_corners,
      a.linked_confidence AS confidence,
      JSONB_BUILD_OBJECT(
        'source','FOREBET',
        'capture_at',a.captured_at,
        'market_line',CASE WHEN v.market_key='OU25' THEN 2.5 ELSE 9.5 END,
        'provenance','forebet_archive_verified_1x2'
      ) AS raw
    FROM verified_pair AS a
    CROSS JOIN LATERAL (
      VALUES
        ('OU25'::text, a.prediction_ou25, a.ou_predicted_score,
          a.prob_over25, a.prob_under25, a.avg_goals, NULL::numeric),
        ('CORNERS95'::text, a.corner_prediction, a.corner_predicted_score,
          a.corner_prob_over95, a.corner_prob_under95, NULL::numeric, a.avg_corners)
    ) AS v(market_key, pick, predicted_score, prob_over, prob_under, avg_goals, avg_corners)
    WHERE v.prob_over BETWEEN 0 AND 100
      AND v.prob_under BETWEEN 0 AND 100
      AND (v.prob_over + v.prob_under) BETWEEN 98 AND 102
  ),
  upserted AS (
    INSERT INTO private.prediction_evidence_current AS old
      (canonical_event_id,source_key,market_key,source_updated_at,
       status,pick,predicted_score,prob_over,prob_under,avg_goals,
       avg_corners,source_count,source_members,confidence,raw,updated_at)
    SELECT
      m.canonical_event_id, 'FOREBET', m.market_key, m.source_updated_at,
      'CURRENT', m.pick, m.predicted_score, m.prob_over, m.prob_under,
      m.avg_goals, m.avg_corners, 1, ARRAY['FOREBET']::text[],
      m.confidence,m.raw,NOW()
    FROM markets AS m
    ON CONFLICT (canonical_event_id,source_key,market_key)
    DO UPDATE SET
      source_updated_at=EXCLUDED.source_updated_at,
      status=EXCLUDED.status,
      pick=EXCLUDED.pick,
      predicted_score=EXCLUDED.predicted_score,
      prob_over=EXCLUDED.prob_over,
      prob_under=EXCLUDED.prob_under,
      avg_goals=EXCLUDED.avg_goals,
      avg_corners=EXCLUDED.avg_corners,
      source_count=EXCLUDED.source_count,
      source_members=EXCLUDED.source_members,
      confidence=EXCLUDED.confidence,
      raw=EXCLUDED.raw,
      updated_at=NOW()
    WHERE EXCLUDED.source_updated_at >= old.source_updated_at
      AND (EXCLUDED.source_updated_at > old.source_updated_at
           OR old.status IS DISTINCT FROM 'CURRENT')
    RETURNING market_key
  )
  SELECT u.market_key, COUNT(*)::bigint
  FROM upserted AS u
  GROUP BY u.market_key;
$function$;
REVOKE ALL ON FUNCTION private.ft_refresh_forebet_supplemental_markets() FROM PUBLIC, anon, authenticated;
