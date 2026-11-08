-- Only verified final (not half-time/live) Flashscore corner snapshots.
-- FT detail capture must be >=120min after scheduled kickoff; conservative.
ALTER TABLE private.ft_verified_flashscore_results
  ADD COLUMN IF NOT EXISTS home_corners smallint CHECK(home_corners BETWEEN 0 AND 30),
  ADD COLUMN IF NOT EXISTS away_corners smallint CHECK(away_corners BETWEEN 0 AND 30),
  ADD COLUMN IF NOT EXISTS corner_captured_at timestamptz;

CREATE OR REPLACE FUNCTION private.ft_archive_verified_flashscore_corners()
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER
SET search_path TO 'pg_catalog','private','public','pg_temp'
AS $fn$
DECLARE n integer;
BEGIN
 IF NOT pg_try_advisory_xact_lock(hashtext('ft_verified_flashscore_corners_hourly'))
 THEN RETURN jsonb_build_object('status','BUSY'); END IF;
 WITH eligible AS (
   SELECT 'FS:'||s.external_event_id match_id,
      s.league_external_id league_id,
      s.kickoff_utc,s.detail_fetched_at,
      regexp_match(
        split_part(s.detail_raw->>'statistics_raw','¬~SE÷1st Half',1),
        'SG÷Corner kicks¬SH÷([0-9]{1,2})¬SI÷([0-9]{1,2})') corners
   FROM public.phase15_source_shadow_current s
   WHERE s.source_key='FLASHSCORE'
     AND s.raw->>'AB'='3' AND s.raw->>'AC'='3'
     AND s.detail_raw->>'statistics_raw' LIKE 'SE÷Match%'
     AND s.detail_fetched_at>=s.kickoff_utc+interval '120 minutes'
     AND s.detail_fetched_at<=s.kickoff_utc+interval '72 hours'
 ), updated AS (
   UPDATE private.ft_verified_flashscore_results r
     SET home_corners=(e.corners[1])::smallint,
         away_corners=(e.corners[2])::smallint,
         corner_captured_at=e.detail_fetched_at
   FROM eligible e
   WHERE e.corners IS NOT NULL
     AND e.corners[1]~'^[0-9]{1,2}$'
     AND e.corners[2]~'^[0-9]{1,2}$'
     AND (e.corners[1])::int BETWEEN 0 AND 30
     AND (e.corners[2])::int BETWEEN 0 AND 30
     AND r.match_id=e.match_id
     AND r.league_id=e.league_id
     AND abs(extract(epoch FROM (r.kickoff_utc-e.kickoff_utc)))<=60
     AND r.home_corners IS NULL AND r.away_corners IS NULL
   RETURNING 1
 )
 SELECT count(*) INTO n FROM updated;
 RETURN jsonb_build_object('status','CORNERS_ARCHIVED',
   'new_fulltime_corners',n);
END;
$fn$;

DO $job$
DECLARE v_cmd text; v_name text; old_prefix text :=
 'SELECT private.ft_archive_verified_flashscore_results();';
BEGIN
 SELECT jobname,command INTO v_name,v_cmd FROM cron.job WHERE jobid=48;
 IF v_name IS DISTINCT FROM 'ft-prune-public-matches-12h-7d'
   OR v_cmd NOT LIKE old_prefix||'%'
   OR position('ft_archive_verified_flashscore_corners' IN v_cmd)>0
 THEN RAISE EXCEPTION 'FT_CORNERS_JOB48_CONTRACT_CHANGED'; END IF;
 PERFORM cron.alter_job(48,command=>
   replace(v_cmd,old_prefix,
     old_prefix||E'\n'||'SELECT private.ft_archive_verified_flashscore_corners();'));
END $job$;
REVOKE ALL ON FUNCTION private.ft_archive_verified_flashscore_corners()
FROM PUBLIC,anon,authenticated;
SELECT private.ft_archive_verified_flashscore_corners();
