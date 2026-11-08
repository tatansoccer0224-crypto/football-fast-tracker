-- Production operational monitor only; no DDL, ingestion or source writes.
-- Correct BetClan/SportyTrader diagnostics that otherwise lag for up to 6h.
-- Preserve job ID/name, command body and provider/source identity safeguards.
-- Repeat-safe and fail-closed if the existing schedule was changed elsewhere.
DO $ft_adviser_quality_hourly$
DECLARE v_jobid bigint; v_schedule text;
BEGIN
  SELECT jobid,schedule INTO v_jobid,v_schedule
  FROM cron.job WHERE jobname='ft-adviser-source-quality-6h' AND active=true;
  IF v_jobid IS NULL THEN
    RAISE EXCEPTION 'Adviser source quality cron missing or inactive';
  END IF;
  IF v_schedule='43 * * * *' THEN
    RAISE NOTICE 'Hourly adviser quality check already active';
    RETURN;
  END IF;
  IF v_schedule<>'43 */6 * * *' THEN
    RAISE EXCEPTION 'Unexpected adviser quality schedule %',v_schedule;
  END IF;
  PERFORM cron.alter_job(job_id:=v_jobid,schedule:='43 * * * *');
END
$ft_adviser_quality_hourly$;

SELECT jobid,jobname,schedule,active
FROM cron.job WHERE jobname='ft-adviser-source-quality-6h';
