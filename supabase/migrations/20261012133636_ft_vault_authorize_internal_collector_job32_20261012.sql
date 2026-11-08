-- Harden existing internally scheduled data collectors, preserving job 32.
-- The established fast_tracker_cron_secret is held in Supabase Vault;
-- The only source-controlled content is a Vault lookup expression, never the token value.
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';

CREATE OR REPLACE FUNCTION public.ft_internal_cron_key_matches(p_key text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog','vault','extensions','pg_temp'
AS $fn$
 SELECT coalesce(length(p_key)>=32,false)
   AND EXISTS (
     SELECT 1 FROM vault.decrypted_secrets s
     WHERE s.name='fast_tracker_cron_secret'
       AND digest(s.decrypted_secret::bytea,'sha256')=digest(p_key::bytea,'sha256')
   );
$fn$;

REVOKE ALL ON FUNCTION public.ft_internal_cron_key_matches(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ft_internal_cron_key_matches(text) TO service_role;

DO $guard$
DECLARE
 old_cmd text;
 v_job_name text;
 cadence text;
 token_present boolean;
 new_cmd text;
 auth_header text;
BEGIN
 SELECT EXISTS(SELECT 1 FROM vault.decrypted_secrets v
  WHERE v.name='fast_tracker_cron_secret' AND length(decrypted_secret)>=32)
 INTO token_present;
 IF NOT token_present THEN
  RAISE EXCEPTION 'FT_CRON_SECRET_MISSING_OR_TOO_SHORT';
 END IF;

 SELECT j.jobname,j.schedule,j.command INTO v_job_name,cadence,old_cmd
 FROM cron.job j WHERE j.jobid=32;
 IF v_job_name IS DISTINCT FROM 'phase2-lineup-source-refresh'
  OR cadence IS DISTINCT FROM '12,22,32,42,52 * * * *'
  OR old_cmd IS NULL
  OR position('phase15-flashscore-scout' IN old_cmd)=0
  OR position('phase15-source-scout?mode=identity&force=1' IN old_cmd)=0
  OR position('phase2-fotmob-lineups' IN old_cmd)=0
  OR position('x-ft-cron-key' IN old_cmd)>0
  OR (length(old_cmd)-length(replace(old_cmd,'timeout_milliseconds := 60000','')))/
     length('timeout_milliseconds := 60000') <> 3
 THEN RAISE EXCEPTION 'FT_JOB32_AUTH_CUTOVER_CONTRACT_DRIFT';
 END IF;
 auth_header := 'headers := jsonb_build_object(''x-ft-cron-key'','
    || '(SELECT decrypted_secret FROM vault.decrypted_secrets'
    || ' WHERE name=''fast_tracker_cron_secret'')),'
    || E'\n  ';
 new_cmd := replace(old_cmd,'timeout_milliseconds := 60000',
     auth_header||'timeout_milliseconds := 60000');
 PERFORM cron.alter_job(32, command=>new_cmd);
END $guard$;

-- Rollback if a legitimate caller is blocked:
-- restore previous #32 command without custom headers, then roll back the three Edge deployments.
-- The verification function may safely remain; no existing ingestion model/table is changed.
