-- Restore bounded FotMob identity + lineup freshness without adding a cron job.
-- Job #32 already owns source/lineup refresh. Keep Flashscore cadence unchanged:
-- 12 = full FS scan; 22/32/42/52 = score scan.
-- FotMob identity list refreshes only every 6h at :12; lineup enrichment only hourly at :22.
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';

DO $job$
DECLARE v_name text;v_schedule text;v_command text;
BEGIN
 SELECT jobname,schedule,command INTO v_name,v_schedule,v_command
 FROM cron.job WHERE jobid=32;
 IF v_name IS DISTINCT FROM 'phase2-lineup-source-refresh'
    OR v_schedule IS DISTINCT FROM '12,22,32,42,52 * * * *'
    OR v_command NOT LIKE '%phase15-flashscore-scout%'
    OR position('phase15-source-scout' IN v_command)>0
    OR position('phase2-fotmob-lineups' IN v_command)>0
 THEN RAISE EXCEPTION 'FT_FOTMOB_REFRESH_JOB32_CONTRACT_DRIFT'; END IF;

 PERFORM cron.alter_job(32,command=>$cmd$
select net.http_get(
  url := case
    when extract(minute from (now() at time zone 'UTC'))=12
      then 'https://hekqxhgjexzxnecwhyao.supabase.co/functions/v1/phase15-flashscore-scout?force=1'
    else 'https://hekqxhgjexzxnecwhyao.supabase.co/functions/v1/phase15-flashscore-scout?mode=score'
  end,
  timeout_milliseconds := 60000
);
select net.http_get(
  url := 'https://hekqxhgjexzxnecwhyao.supabase.co/functions/v1/phase15-source-scout?mode=identity&force=1',
  timeout_milliseconds := 60000
)
where extract(minute from (now() at time zone 'UTC'))=12
  and mod(extract(hour from (now() at time zone 'UTC'))::integer,6)=0;
select net.http_get(
  url := 'https://hekqxhgjexzxnecwhyao.supabase.co/functions/v1/phase2-fotmob-lineups',
  timeout_milliseconds := 60000
)
where extract(minute from (now() at time zone 'UTC'))=22;
$cmd$);
END
$job$;

-- No cron.schedule call: active job count remains unchanged.
