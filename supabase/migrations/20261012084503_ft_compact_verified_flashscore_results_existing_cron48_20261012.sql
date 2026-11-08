-- Fast Tracker independent model v0: compact, provider-ID verified observed results.
-- No new crawler, additional cron, bookmaker dependency, or HTML scraping.
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';

CREATE TABLE IF NOT EXISTS private.ft_verified_flashscore_results (
  match_id text PRIMARY KEY CHECK (match_id ~ '^FS:[A-Za-z0-9]{6,16}$'),
  league_id text NOT NULL CHECK (league_id ~ '^[A-Za-z0-9]{6,16}$'),
  home_team_id text NOT NULL CHECK (home_team_id ~ '^[A-Za-z0-9]{6,16}$'),
  away_team_id text NOT NULL CHECK (away_team_id ~ '^[A-Za-z0-9]{6,16}$'),
  league_name text,
  home_name text,
  away_name text,
  kickoff_utc timestamptz NOT NULL,
  source_captured_at timestamptz NOT NULL,
  home_goals smallint NOT NULL CHECK(home_goals BETWEEN 0 AND 20),
  away_goals smallint NOT NULL CHECK(away_goals BETWEEN 0 AND 20),
  identity_evidence text NOT NULL DEFAULT 'FS_ID_TEAM_IDS_LEAGUE_ID_FINISHED_EPOCH',
  archived_at timestamptz NOT NULL DEFAULT now(),
  CHECK(home_team_id<>away_team_id),
  CHECK(source_captured_at>=kickoff_utc AND source_captured_at<=kickoff_utc+interval '72 hours')
);
ALTER TABLE private.ft_verified_flashscore_results ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.ft_verified_flashscore_results FROM PUBLIC,anon,authenticated;
CREATE INDEX IF NOT EXISTS ft_verified_fs_results_league_time
ON private.ft_verified_flashscore_results(league_id,kickoff_utc DESC);
CREATE INDEX IF NOT EXISTS ft_verified_fs_results_home_time
ON private.ft_verified_flashscore_results(home_team_id,kickoff_utc DESC);
CREATE INDEX IF NOT EXISTS ft_verified_fs_results_away_time
ON private.ft_verified_flashscore_results(away_team_id,kickoff_utc DESC);

CREATE OR REPLACE FUNCTION private.ft_archive_verified_flashscore_results()
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER
SET search_path TO 'pg_catalog','private','public','pg_temp'
AS $fn$
DECLARE n integer;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('ft_verified_flashscore_results_once_per_hour'))
  THEN RETURN jsonb_build_object('status','BUSY'); END IF;
  WITH source AS (
    SELECT external_event_id,home_external_id,away_external_id,
      league_external_id,league_name,home_name,away_name,
      kickoff_utc,fetched_at,raw
    FROM public.phase15_source_shadow_current
    WHERE source_key='FLASHSCORE'
      AND raw->>'AB'='3' AND raw->>'AC'='3'
      AND raw->>'AG'~'^[0-9]{1,2}$' AND raw->>'AH'~'^[0-9]{1,2}$'
      AND raw->>'AD'~'^[0-9]{10}$'
      AND external_event_id~'^[A-Za-z0-9]{6,16}$'
      AND home_external_id~'^[A-Za-z0-9]{6,16}$'
      AND away_external_id~'^[A-Za-z0-9]{6,16}$'
      AND league_external_id~'^[A-Za-z0-9]{6,16}$'
      AND home_external_id<>away_external_id
      AND kickoff_utc IS NOT NULL
      AND kickoff_utc<now()
      AND fetched_at>=kickoff_utc AND fetched_at<=kickoff_utc+interval '72 hours'
      AND abs(extract(epoch FROM
        (kickoff_utc-to_timestamp((raw->>'AD')::double precision))))<=60
      AND (raw->>'AG')::integer BETWEEN 0 AND 20
      AND (raw->>'AH')::integer BETWEEN 0 AND 20
  ), inserted AS (
    INSERT INTO private.ft_verified_flashscore_results(
      match_id,league_id,home_team_id,away_team_id,league_name,
      home_name,away_name,kickoff_utc,source_captured_at,home_goals,away_goals)
    SELECT 'FS:'||external_event_id,league_external_id,home_external_id,
      away_external_id,league_name,home_name,away_name,
      kickoff_utc,fetched_at,(raw->>'AG')::smallint,(raw->>'AH')::smallint
    FROM source
    ON CONFLICT(match_id) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO n FROM inserted;
  RETURN jsonb_build_object('status','ARCHIVED','new_verified_results',n);
END;
$fn$;

-- Reuse existing hourly job 48; archive results *before* it deletes active fixtures.
DO $job$
DECLARE old_cmd text; job_title text;
BEGIN
  SELECT jobname,command INTO job_title,old_cmd FROM cron.job WHERE jobid=48;
  IF job_title IS DISTINCT FROM 'ft-prune-public-matches-12h-7d'
     OR old_cmd NOT LIKE 'DELETE FROM public.matches m%'
     OR position('ft_archive_verified_flashscore_results' IN old_cmd)>0
  THEN RAISE EXCEPTION 'FT_RESULT_ARCHIVE_JOB48_CHANGED'; END IF;
  PERFORM cron.alter_job(48,command=>
    'SELECT private.ft_archive_verified_flashscore_results();'||E'\n'||
    old_cmd||E'\n'||
    'DELETE FROM private.ft_verified_flashscore_results WHERE kickoff_utc < now() - interval ''730 days'';');
END $job$;

REVOKE ALL ON FUNCTION private.ft_archive_verified_flashscore_results()
FROM PUBLIC,anon,authenticated;
SELECT private.ft_archive_verified_flashscore_results();
