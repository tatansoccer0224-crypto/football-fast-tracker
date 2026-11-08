-- Phase 16: restore daily bounded CSV refresh for existing historical-results pipeline.
-- The official publisher updates files at least twice weekly; daily HEAD/GET
-- + SHA256 comparison is idempotent, with no fixture authority changes.
-- One cron run per day, no additional per-match scraping.
DO $do$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job
                 WHERE jobname='ft-football-data-csv-daily' AND active) THEN
    PERFORM cron.schedule(
      'ft-football-data-csv-daily',
      '15 2 * * *', -- 02:15 UTC / 10:15 Hong Kong
      $job$
      SELECT net.http_get(
        url := 'https://hekqxhgjexzxnecwhyao.supabase.co/functions/v1/football-data-direct',
        headers := jsonb_build_object(
          'x-ft-cron-key',
          (SELECT decrypted_secret FROM vault.decrypted_secrets
           WHERE name='fast_tracker_cron_secret')
        ),
        timeout_milliseconds := 55000
      );
      $job$
    );
  END IF;
END
$do$;
