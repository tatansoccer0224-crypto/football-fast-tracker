-- Independent append-only prospective journal. No fixture FK cascade.
-- Model is experimental; never merged into Forebet/model_predictions or public UI.
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';

CREATE TABLE IF NOT EXISTS private.ft_native_prospective_frozen (
  canonical_event_id text NOT NULL CHECK(canonical_event_id~'^FS:[A-Za-z0-9]{6,16}$'),
  model_version text NOT NULL,
  training_source text NOT NULL CHECK(training_source='FOOTBALL_DATA'),
  fs_league_id text NOT NULL,
  training_league_code text NOT NULL,
  home_team_source text NOT NULL,
  away_team_source text NOT NULL,
  kickoff_utc timestamptz NOT NULL,
  frozen_at timestamptz NOT NULL DEFAULT now(),
  training_count integer NOT NULL CHECK(training_count>=60),
  training_fingerprint text NOT NULL CHECK(length(training_fingerprint)=32),
  score_probability jsonb NOT NULL,
  evidence jsonb NOT NULL,
  PRIMARY KEY(canonical_event_id,model_version),
  CHECK(frozen_at<kickoff_utc-interval '30 minutes'),
  CHECK((score_probability->>'status')='EXPERIMENTAL_UNCALIBRATED'),
  CHECK((score_probability->>'home')::numeric BETWEEN 0 AND 1),
  CHECK((score_probability->>'draw')::numeric BETWEEN 0 AND 1),
  CHECK((score_probability->>'away')::numeric BETWEEN 0 AND 1),
  CHECK(abs((score_probability->>'home')::numeric +
            (score_probability->>'draw')::numeric +
            (score_probability->>'away')::numeric-1)<0.00001)
);
ALTER TABLE private.ft_native_prospective_frozen ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.ft_native_prospective_frozen FROM PUBLIC,anon,authenticated;
CREATE INDEX IF NOT EXISTS ft_native_prospective_kickoff
ON private.ft_native_prospective_frozen(kickoff_utc);

-- Prevent later "corrections" from rewriting the historical prediction.
-- Permit only fixed-horizon retention after 730 days.
CREATE OR REPLACE FUNCTION private.ft_native_frozen_immutable_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER
SET search_path TO 'pg_catalog','private','pg_temp'
AS $guard$
BEGIN
  IF TG_OP='UPDATE' OR OLD.frozen_at>=now()-interval '730 days'
  THEN RAISE EXCEPTION 'NATIVE_FORECAST_IMMUTABLE'; END IF;
  RETURN OLD;
END
$guard$;
CREATE TRIGGER ft_native_frozen_immutable
BEFORE UPDATE OR DELETE ON private.ft_native_prospective_frozen
FOR EACH ROW EXECUTE FUNCTION private.ft_native_frozen_immutable_guard();

CREATE OR REPLACE FUNCTION private.ft_native_freeze_e1_verified()
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER
SET search_path TO 'pg_catalog','private','public','pg_temp'
AS $fn$
DECLARE
 t timestamptz:=clock_timestamp(); rec record;
 home_matches text[];away_matches text[];
 model jsonb; n_added integer:=0;n_candidates integer:=0;
 n_skipped_identity integer:=0;n_skipped_model integer:=0;
BEGIN
 IF NOT pg_try_advisory_xact_lock(hashtext('ft_native_freeze_exact_verified_e1'))
 THEN RETURN jsonb_build_object('status','BUSY'); END IF;

 -- Fixed competition ID is the provider's *English* Championship,
 -- not the Scottish Championship, despite both being named "Championship".
 FOR rec IN
 SELECT m.canonical_event_id,m.kickoff_hkt,m.home_en,m.away_en,
   s.home_external_id,s.away_external_id,s.league_external_id
 FROM public.matches m
 JOIN public.phase15_source_shadow_current s
   ON s.source_key='FLASHSCORE'
   AND m.canonical_event_id='FS:'||s.external_event_id
 WHERE s.league_external_id='Q74g9dNP'
   AND m.kickoff_hkt>t+interval '1 hour'
   AND m.kickoff_hkt<t+interval '48 hours'
   AND s.raw->>'AB'='1'
   AND s.kickoff_utc IS NOT NULL
   AND abs(extract(epoch FROM(s.kickoff_utc-m.kickoff_hkt)))<=60
   AND s.fetched_at>=t-interval '3 days'
   AND s.home_external_id~'^[A-Za-z0-9]{6,16}$'
   AND s.away_external_id~'^[A-Za-z0-9]{6,16}$'
   AND NOT EXISTS (
     SELECT 1 FROM public.fixture_identity_redirects d
      WHERE d.source_match_id=m.canonical_event_id AND d.active=true)
   AND NOT EXISTS (
     SELECT 1 FROM private.ft_native_prospective_frozen v
      WHERE v.canonical_event_id=m.canonical_event_id
        AND v.model_version='FAST_TRACKER_INDEPENDENT_POISSON_V0_SQL_EXPERIMENTAL')
 ORDER BY m.kickoff_hkt,m.canonical_event_id LIMIT 40
 LOOP
   n_candidates:=n_candidates+1;
   SELECT array_agg(DISTINCT fd.provider_name)
   INTO home_matches FROM public.football_alias_supertable fs
     JOIN public.football_alias_supertable fd
       ON fd.verified_team_key=fs.verified_team_key
   WHERE fs.source='FLASHSCORE'
     AND fs.resolution_status='VERIFIED'
     AND fs.provider_team_id=rec.home_external_id
     AND fs.source_competition='Championship'
     AND fd.source='FOOTBALL_DATA'
     AND fd.resolution_status='VERIFIED'
     AND fd.source_competition='E1'
     AND fd.verified_team_key IS NOT NULL
     AND EXISTS(SELECT 1 FROM public.football_data_matches d
         WHERE d.league_code='E1' AND d.home_team=fd.provider_name);
   SELECT array_agg(DISTINCT fd.provider_name)
   INTO away_matches FROM public.football_alias_supertable fs
     JOIN public.football_alias_supertable fd
       ON fd.verified_team_key=fs.verified_team_key
   WHERE fs.source='FLASHSCORE'
     AND fs.resolution_status='VERIFIED'
     AND fs.provider_team_id=rec.away_external_id
     AND fs.source_competition='Championship'
     AND fd.source='FOOTBALL_DATA'
     AND fd.resolution_status='VERIFIED'
     AND fd.source_competition='E1'
     AND fd.verified_team_key IS NOT NULL
     AND EXISTS(SELECT 1 FROM public.football_data_matches d
         WHERE d.league_code='E1' AND d.away_team=fd.provider_name);
   IF array_length(home_matches,1) IS DISTINCT FROM 1
      OR array_length(away_matches,1) IS DISTINCT FROM 1
      OR home_matches[1]=away_matches[1]
   THEN n_skipped_identity:=n_skipped_identity+1;CONTINUE;END IF;

   model:=private.ft_native_fd_poisson('E1',home_matches[1],away_matches[1],t);
   IF model->>'status'<>'EXPERIMENTAL_UNCALIBRATED'
      OR model->>'trainingCount' IS NULL
      OR model->>'trainingFingerprint' IS NULL
   THEN n_skipped_model:=n_skipped_model+1;CONTINUE; END IF;

   INSERT INTO private.ft_native_prospective_frozen(
     canonical_event_id,model_version,training_source,
     fs_league_id,training_league_code,home_team_source,away_team_source,
     kickoff_utc,frozen_at,training_count,training_fingerprint,
     score_probability,evidence)
   VALUES(rec.canonical_event_id,
     'FAST_TRACKER_INDEPENDENT_POISSON_V0_SQL_EXPERIMENTAL',
     'FOOTBALL_DATA',rec.league_external_id,'E1',
     home_matches[1],away_matches[1],rec.kickoff_hkt,t,
     (model->>'trainingCount')::integer,model->>'trainingFingerprint',model,
     jsonb_build_object('identity','VERIFIED_FS_TEAM_IDS_AND_E1_ALIAS_PAIR',
       'flashscore_home_team_id',rec.home_external_id,
       'flashscore_away_team_id',rec.away_external_id,
       'flashscore_league_id',rec.league_external_id,
       'football_data_league_code','E1',
       'first_eligible_freeze_at',t,
       'source_training_latest_capture',model->>'latestCaptureAt',
       'not_forebet',true,'experimental_not_for_public_ui',true))
   ON CONFLICT(canonical_event_id,model_version) DO NOTHING;
   IF FOUND THEN n_added:=n_added+1;END IF;
 END LOOP;
 RETURN jsonb_build_object('status','COMPLETE','candidate_fixtures',n_candidates,
   'new_frozen',n_added,'skipped_identity',n_skipped_identity,
   'skipped_quality',n_skipped_model,'run_at',t);
END
$fn$;

-- Existing job 48 executes each hour. No new cron or provider requests.
DO $job$
DECLARE prior_cmd text; job_name text;
BEGIN
 SELECT jobname,command INTO job_name,prior_cmd FROM cron.job WHERE jobid=48;
 IF job_name IS DISTINCT FROM 'ft-prune-public-matches-12h-7d'
    OR prior_cmd NOT LIKE 'SELECT private.ft_archive_verified_flashscore_results();%'
    OR position('ft_native_freeze_e1_verified' IN prior_cmd)>0
 THEN RAISE EXCEPTION 'FT_NATIVE_EXISTING_JOB_CONTRACT_DRIFT'; END IF;
 PERFORM cron.alter_job(48,command=>
    'SELECT private.ft_native_freeze_e1_verified();'||E'\n'||prior_cmd||E'\n'||
    'DELETE FROM private.ft_native_prospective_frozen WHERE frozen_at < now() - interval ''730 days'';');
END $job$;

REVOKE ALL ON FUNCTION private.ft_native_freeze_e1_verified()
 FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.ft_native_frozen_immutable_guard()
 FROM PUBLIC,anon,authenticated;

-- Initial naturally pre-kickoff run; repeated later only through job 48.
SELECT private.ft_native_freeze_e1_verified();
