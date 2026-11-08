-- Phase 2: preserve exactly 12 Supabase snapshot reads per hour and the
-- existing Railway 15-minute bookmaker capture, while shifting the read phase.
--
-- Observed production collector completes at ~:04/:19/:34/:49 UTC.
-- Original cron job 38 starts at :03/:08/...; pg_net response is published
-- the NEXT 5-minute cycle: e.g. 02:04:20 capture -> 02:13:00 commit (8m40).
-- Phase-aligning to :01/:06/... should produce ~:11 commit (~6m40),
-- without adding any HTTP requests or changing 20-minute source freshness.
--
-- Guard the exact job ID, original schedule and command; this is an in-place
-- update, not an additional cron entry or a second odds collector.
-- If the baseline changes, fail safely instead of overriding another operator.
DO $phase_align_odds$
DECLARE
  job_record cron.job%ROWTYPE;
BEGIN
  SELECT * INTO job_record FROM cron.job WHERE jobid=38;
  IF NOT FOUND
     OR job_record.schedule <> '3,8,13,18,23,28,33,38,43,48,53,58 * * * *'
     OR job_record.command <> 'select private.ft_flashscore_direct_publication_cycle();'
     OR job_record.active IS DISTINCT FROM true
  THEN
    RAISE EXCEPTION 'odds_publish_job_38_schedule_or_command_drift';
  END IF;
  PERFORM cron.alter_job(
    job_id := 38,
    schedule := '1,6,11,16,21,26,31,36,41,46,51,56 * * * *'
  );
END
$phase_align_odds$;
