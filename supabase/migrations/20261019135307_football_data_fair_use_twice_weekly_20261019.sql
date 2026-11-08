-- Source owner's published limit: personal-use automated CSV downloads at most twice weekly.
-- Keep the existing task, credential, and 22-league scope; prevent daily repeated fetches.
SELECT cron.alter_job(
  job_id := 55,
  schedule := '15 2 * * 2,5'
);
