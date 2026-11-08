-- Fast Tracker operational pg_cron configuration hotfix (no schema migration).
-- Keep source of truth for the bounded change while the pre-existing historical
-- Supabase migration-record/repository mismatch is independently reconciled.
--
-- Sources FOREBET, BETCLAN, SPORTYTRADER and FOOTBALL_DATA have daily captures.
-- Alert at 30 hours (daily run + six-hour grace), not 42 hours. Leave the
-- FLASHSCORE (45m), FOTMOB (7h), and ALIAS_SUPERTABLE (4h) limits unchanged.
-- Preserve the existing cron name, job ID, interval and full timestamp-only
-- health logic. Never infer fixture identity or fabricate source kickoff.
--
-- Apply exactly once via Supabase SQL editor / execute_sql as postgres.
-- Idempotent on repeat: the new 30h state verifies and performs no mutation.
DO $ft_source_freshness_guard$
DECLARE
    v_jobid bigint;
    v_command text;
    v_old_occurrences integer;
    v_new_occurrences integer;
BEGIN
    SELECT jobid, command::text
      INTO v_jobid, v_command
      FROM cron.job
     WHERE jobname = 'ft-pipeline-freshness-hourly'
       AND active = true;
    IF v_jobid IS NULL THEN
        RAISE EXCEPTION 'Pipeline freshness monitor missing or disabled';
    END IF;

    v_old_occurrences :=
        (length(v_command) - length(replace(v_command,
            'INTERVAL ''42 hours''', ''))) / length('INTERVAL ''42 hours''');
    v_new_occurrences :=
        (length(v_command) - length(replace(v_command,
            'INTERVAL ''30 hours''', ''))) / length('INTERVAL ''30 hours''');

    IF v_old_occurrences = 0 AND v_new_occurrences = 4 THEN
        RAISE NOTICE 'Pipeline freshness thresholds already set to 30 hours';
        RETURN;
    END IF;
    IF v_old_occurrences <> 4 OR v_new_occurrences <> 0 THEN
        RAISE EXCEPTION 'Unexpected pipeline monitor version: old %, new %',
            v_old_occurrences, v_new_occurrences;
    END IF;

    PERFORM cron.alter_job(
        job_id := v_jobid,
        command := replace(v_command,
            'INTERVAL ''42 hours''', 'INTERVAL ''30 hours'''));
END
$ft_source_freshness_guard$;

-- Postcondition: same active job, same hourly cadence; four daily sources
-- now WARN once their last recorded source data is more than 30 hours old.
SELECT jobid, jobname, schedule, active,
       (length(command::text) -
        length(replace(command::text,'INTERVAL ''30 hours''',''))) /
          length('INTERVAL ''30 hours''') AS daily_source_30h_thresholds
FROM cron.job WHERE jobname='ft-pipeline-freshness-hourly';
