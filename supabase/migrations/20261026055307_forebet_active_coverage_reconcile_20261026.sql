
CREATE OR REPLACE FUNCTION private.ft_refresh_forebet_active_coverage()
RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public, private
AS $fn$
DECLARE
  new_gaps integer := 0;
  total_fixtures integer := 0;
  verified_models integer := 0;
  past_unresolved integer := 0;
  result jsonb;
BEGIN
  -- Only fresh Flashscore source-ID fixtures, no fuzzy identity or scraping.
  WITH active AS (
    SELECT m.canonical_event_id, m.kickoff_hkt, m.tournament,m.home_en,m.away_en
    FROM public.matches m
    WHERE m.raw->>'source'='FLASHSCORE'
      AND m.raw->>'identity_origin'='DIRECT_PROVIDER_ID_FROM_EXISTING_SHADOW'
      AND m.canonical_event_id='FS:' || m.canonical_match_id
      AND m.fetched_at>=now()-interval '2 hours'
      AND m.kickoff_hkt BETWEEN now()-interval '3 hours' AND now()+interval '72 hours'
  )
  INSERT INTO public.forebet_availability
  (match_id,checked_at,match_date,kickoff_hkt,league_zh,home_en,away_en,
   state,reason,raw,updated_at)
  SELECT a.canonical_event_id,NULL,
         (a.kickoff_hkt AT TIME ZONE 'Asia/Hong_Kong')::date::text,
         a.kickoff_hkt,a.tournament,a.home_en,a.away_en,
         'UNRESOLVED','awaiting_first_verified_forebet_capture',
         jsonb_build_object('availability_kind','PENDING_SOURCE_CAPTURE',
                            'fixture_authority','FLASHSCORE','forecast_fabricated',false),
         now()
  FROM active a
  LEFT JOIN public.forebet_predictions f
    ON f.canonical_event_id=a.canonical_event_id
   AND f.fetched_at>=now()-interval '72 hours'
   AND f.predicted_score IS NOT NULL
  LEFT JOIN public.forebet_availability existing ON existing.match_id=a.canonical_event_id
  WHERE f.canonical_event_id IS NULL AND existing.match_id IS NULL
  ON CONFLICT (match_id) DO NOTHING;
  GET DIAGNOSTICS new_gaps=ROW_COUNT;

  SELECT count(*)::int,
         count(*) FILTER(WHERE f.canonical_event_id IS NOT NULL)::int
  INTO total_fixtures, verified_models
  FROM public.matches m
  LEFT JOIN public.forebet_predictions f
    ON f.canonical_event_id=m.canonical_event_id
   AND f.fetched_at>=now()-interval '72 hours'
   AND f.predicted_score IS NOT NULL
  WHERE m.raw->>'source'='FLASHSCORE'
    AND m.raw->>'identity_origin'='DIRECT_PROVIDER_ID_FROM_EXISTING_SHADOW'
    AND m.canonical_event_id='FS:' || m.canonical_match_id
    AND m.fetched_at>=now()-interval '2 hours'
    AND m.kickoff_hkt BETWEEN now()-interval '3 hours' AND now()+interval '72 hours';

  SELECT count(*)::int INTO past_unresolved FROM public.forebet_availability
    WHERE state='UNRESOLVED' AND kickoff_hkt<now()-interval '3 hours';

  result := jsonb_build_object(
    'active_verified_flashscore_fixtures',total_fixtures,
    'fresh_forebet_predictions',verified_models,
    'pending_forebet_predictions',total_fixtures-verified_models,
    'new_pending_rows',new_gaps,
    'historical_expired_unresolved',past_unresolved,
    'window_hours',72,
    'deleted_rows',0);

  INSERT INTO public.source_health
    (source,metric,value_text,status,notes,observed_at,raw)
  VALUES
    ('FOREBET_COVERAGE','verified_upcoming_72h',
     verified_models::text || '/' || total_fixtures::text,
     CASE WHEN total_fixtures=0 THEN 'NO_TARGETS'
          WHEN verified_models<total_fixtures THEN 'WARNING'
          ELSE 'OK' END,
     'Fresh canonical Flashscore fixtures. Missing Forebet forecasts are pending source capture, not invented. Historical gaps excluded.',
     now(),result)
  ON CONFLICT (source,metric) DO UPDATE SET
    value_text=EXCLUDED.value_text,
    status=EXCLUDED.status,
    notes=EXCLUDED.notes,
    observed_at=EXCLUDED.observed_at,
    raw=EXCLUDED.raw;

  RETURN result;
END;
$fn$;
REVOKE ALL ON FUNCTION private.ft_refresh_forebet_active_coverage()
  FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION private.ft_refresh_forebet_active_coverage() IS
  'Reconcile active, genuine Flashscore fixtures with real Forebet predictions. Zero external reads, bounded writes and historical rows retained.';
