-- 2026-11-08 verified source-delivery timing hotfix.
-- Existing BetClan/SportyTrader GitHub daily capture starts at 05:30 HKT,
-- and its last successful run completed ~02:34 UTC in production.
-- The provisional source-to-Flashscore recheck previously only ran 07:40 UTC,
-- leaving a multi-hour lag even after an otherwise successful capture.
--
-- Add 03:40 UTC to the existing 07:40 UTC daily run.
-- Keep the existing function and source-time/league/uniqueness guards;
-- do not change any identity classification or fabricate missing kickoffs.
-- No table migrations or historical-row deletion.
DO $ft_add_early_adviser_recheck$
DECLARE existing_job_id bigint; existing_schedule text; existing_command text;
BEGIN
  SELECT jobid,schedule,command::text INTO existing_job_id,existing_schedule,existing_command
  FROM cron.job
  WHERE jobname='ft-adviser-fuzzy-provisional-recheck' AND active;
  IF existing_job_id IS NULL THEN
    RAISE EXCEPTION 'Adviser provisional recheck cron not active or not present';
  END IF;
  IF trim(existing_command) <> 'SELECT private.ft_recheck_adviser_provisional_05();' THEN
    RAISE EXCEPTION 'Unexpected adviser recheck command; no mutation';
  END IF;
  IF existing_schedule='40 3,7 * * *' THEN
    RAISE NOTICE 'Extra early recheck already active';
    RETURN;
  END IF;
  IF existing_schedule<>'40 7 * * *' THEN
    RAISE EXCEPTION 'Unexpected adviser provisional schedule: %',existing_schedule;
  END IF;
  PERFORM cron.alter_job(job_id:=existing_job_id,schedule:='40 3,7 * * *');
END
$ft_add_early_adviser_recheck$;

SELECT jobid,jobname,schedule,active
FROM cron.job WHERE jobname='ft-adviser-fuzzy-provisional-recheck';
