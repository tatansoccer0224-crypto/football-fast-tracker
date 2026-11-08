-- Stable job-name lookup: do not assume pg_cron numeric IDs match across environments.
-- Free football-data.co.uk CSVs allow at most two light automated sessions weekly.
DO $$
DECLARE v_jobid bigint;
BEGIN
  SELECT jobid INTO STRICT v_jobid
  FROM cron.job
  WHERE jobname='ft-football-data-csv-daily';
  PERFORM cron.alter_job(job_id:=v_jobid,schedule:='15 2 * * 2,5');
END;
$$;
