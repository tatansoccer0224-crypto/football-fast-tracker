-- FT 2026-10-12: Preserve source-verified pre-kickoff Forebet predictions
-- independently of the 12-hour matches table TTL. No new scheduled task.
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

-- This legacy archive was itself cascade-deleted along with its fixture.
ALTER TABLE public.forebet_archive
  DROP CONSTRAINT forebet_archive_hkjc_event_id_fkey;

-- RLS is already enabled. Preserve it; do not grant any Data API access.
CREATE OR REPLACE FUNCTION private.ft_archive_verified_forebet_event(p_event_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'pg_catalog','public','private','pg_temp'
AS $f$
BEGIN
  INSERT INTO public.forebet_archive (
    match_id,captured_at,league,home_team,away_team,home_zh,away_zh,
    kickoff_hkt,prob_home,prob_draw,prob_away,prediction_1x2,
    predicted_score,avg_goals,power_home,power_away,power_source,power_updated,
    prediction_ou25,prob_over25,prob_under25,ou_predicted_score,
    corner_prediction,corner_prob_under95,corner_prob_over95,
    corner_predicted_score,avg_corners,forebet_detail_url,raw)
  SELECT
    f.canonical_event_id,f.fetched_at,
    COALESCE(NULLIF(f.forebet_league_short,''),m.tournament),
    COALESCE(NULLIF(f.forebet_home_team,''),m.home_en),
    COALESCE(NULLIF(f.forebet_away_team,''),m.away_en),
    m.home_zh,m.away_zh,m.kickoff_hkt,
    f.prob_home,f.prob_draw,f.prob_away,f.prediction_1x2,
    f.predicted_score,f.avg_goals,f.power_home,f.power_away,
    f.power_source,f.power_updated,
    f.prediction_ou25,f.prob_over25,f.prob_under25,f.ou_predicted_score,
    f.corner_prediction,f.corner_prob_under95,f.corner_prob_over95,
    f.corner_predicted_score,f.avg_corners,f.forebet_detail_url,
    jsonb_build_object('archive_origin','VERIFIED_PREKICKOFF_FOREBET',
      'source_capture_at',f.fetched_at,'source_forebet_url',f.forebet_detail_url,
      'source_metadata',coalesce(f.raw,'{}'::jsonb))
  FROM public.forebet_predictions f
  JOIN public.matches m ON m.canonical_event_id=f.canonical_event_id
  WHERE f.canonical_event_id=p_event_id
    AND m.kickoff_hkt IS NOT NULL
    AND f.fetched_at IS NOT NULL
    AND f.fetched_at <= m.kickoff_hkt
    AND f.fetched_at >= m.kickoff_hkt-interval '30 days'
    AND COALESCE(f.match_score,0)>=0.94
    AND f.prob_home BETWEEN 0 AND 100
    AND f.prob_draw BETWEEN 0 AND 100
    AND f.prob_away BETWEEN 0 AND 100
    AND (f.prob_home+f.prob_draw+f.prob_away) BETWEEN 98 AND 102
  ON CONFLICT(match_id,captured_at) DO UPDATE
    SET prob_over25=COALESCE(public.forebet_archive.prob_over25,excluded.prob_over25),
        prob_under25=COALESCE(public.forebet_archive.prob_under25,excluded.prob_under25),
        prediction_ou25=COALESCE(public.forebet_archive.prediction_ou25,excluded.prediction_ou25),
        ou_predicted_score=COALESCE(public.forebet_archive.ou_predicted_score,excluded.ou_predicted_score),
        corner_prob_under95=COALESCE(public.forebet_archive.corner_prob_under95,excluded.corner_prob_under95),
        corner_prob_over95=COALESCE(public.forebet_archive.corner_prob_over95,excluded.corner_prob_over95),
        corner_prediction=COALESCE(public.forebet_archive.corner_prediction,excluded.corner_prediction),
        corner_predicted_score=COALESCE(public.forebet_archive.corner_predicted_score,excluded.corner_predicted_score),
        avg_corners=COALESCE(public.forebet_archive.avg_corners,excluded.avg_corners),
        forebet_detail_url=COALESCE(public.forebet_archive.forebet_detail_url,excluded.forebet_detail_url)
    WHERE (public.forebet_archive.prob_over25 IS NULL
      AND excluded.prob_over25 IS NOT NULL)
      OR (public.forebet_archive.corner_prob_over95 IS NULL
      AND excluded.corner_prob_over95 IS NOT NULL);
END
$f$;

CREATE OR REPLACE FUNCTION private.ft_archive_forebet_on_source_write()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'pg_catalog','private','public','pg_temp'
AS $t$
BEGIN
  PERFORM private.ft_archive_verified_forebet_event(NEW.canonical_event_id);
  RETURN NEW;
END
$t$;

CREATE TRIGGER ft_archive_forebet_on_source_write
AFTER INSERT OR UPDATE ON public.forebet_predictions
FOR EACH ROW
EXECUTE FUNCTION private.ft_archive_forebet_on_source_write();

-- One-time preservation of all currently verified pre-kickoff source forecasts.
SELECT private.ft_archive_verified_forebet_event(f.canonical_event_id)
FROM public.forebet_predictions f
JOIN public.matches m ON m.canonical_event_id=f.canonical_event_id
WHERE f.fetched_at <= m.kickoff_hkt;

-- Retain forecast-only archive for 180 days, using existing job #48.
DO $job$
DECLARE v_name text; v_old text;
BEGIN
  SELECT jobname,command INTO v_name,v_old FROM cron.job WHERE jobid=48;
  IF v_name IS DISTINCT FROM 'ft-prune-public-matches-12h-7d'
     OR v_old NOT LIKE 'DELETE FROM public.matches m%'
     OR position('forebet_archive' IN v_old)>0 THEN
    RAISE EXCEPTION 'FOREBET_ARCHIVE_RETENTION_JOB_UNEXPECTED';
  END IF;
  PERFORM cron.alter_job(48,
    command => v_old || E'\n' ||
    'DELETE FROM public.forebet_archive WHERE kickoff_hkt < now() - interval ''180 days'';'
  );
END
$job$;

REVOKE ALL ON FUNCTION private.ft_archive_verified_forebet_event(text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.ft_archive_forebet_on_source_write() FROM PUBLIC,anon,authenticated;
