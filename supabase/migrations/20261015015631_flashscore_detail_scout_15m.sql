-- Refresh detailed Flashscore match evidence every 15 minutes, while keeping
-- score-only refreshes and the existing identity/FotMob calls unchanged.
-- The detail scout already limits each run to its nearest 10 verified events.
--
-- Rollback: unschedule('phase15-flashscore-detail-refresh') and restore the
-- previous CASE expression in phase2-lineup-source-refresh (minute 12 calls
-- force=1; other invocations use mode=score).
do $migration$
declare
  lineup_job_id bigint;
  detail_job_id bigint;
  lineup_command text := $command$
select net.http_get(
  url := 'https://hekqxhgjexzxnecwhyao.supabase.co/functions/v1/phase15-flashscore-scout?mode=score',
  headers := jsonb_build_object('x-ft-cron-key',(SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name='fast_tracker_cron_secret')),
  timeout_milliseconds := 60000
);
select net.http_get(
  url := 'https://hekqxhgjexzxnecwhyao.supabase.co/functions/v1/phase15-source-scout?mode=identity&force=1',
  headers := jsonb_build_object('x-ft-cron-key',(SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name='fast_tracker_cron_secret')),
  timeout_milliseconds := 60000
)
where extract(minute from (now() at time zone 'UTC'))=12
  and mod(extract(hour from (now() at time zone 'UTC'))::integer,6)=0;
select net.http_get(
  url := 'https://hekqxhgjexzxnecwhyao.supabase.co/functions/v1/phase2-fotmob-lineups',
  headers := jsonb_build_object('x-ft-cron-key',(SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name='fast_tracker_cron_secret')),
  timeout_milliseconds := 60000
)
where extract(minute from (now() at time zone 'UTC'))=22;
$command$;
  detail_command text := $command$
select net.http_get(
  url := 'https://hekqxhgjexzxnecwhyao.supabase.co/functions/v1/phase15-flashscore-scout?force=1',
  headers := jsonb_build_object('x-ft-cron-key',(SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name='fast_tracker_cron_secret')),
  timeout_milliseconds := 60000
);
$command$;
begin
  select jobid into lineup_job_id
  from cron.job
  where jobname='phase2-lineup-source-refresh';
  if lineup_job_id is null then
    raise exception 'Required cron job phase2-lineup-source-refresh is missing';
  end if;

  perform cron.alter_job(
    lineup_job_id,
    schedule := '12,22,32,42,52 * * * *',
    command := lineup_command,
    active := true
  );

  select jobid into detail_job_id
  from cron.job
  where jobname='phase15-flashscore-detail-refresh';
  if detail_job_id is null then
    perform cron.schedule(
      'phase15-flashscore-detail-refresh',
      '*/15 * * * *',
      detail_command
    );
  else
    perform cron.alter_job(
      detail_job_id,
      schedule := '*/15 * * * *',
      command := detail_command,
      active := true
    );
  end if;
end
$migration$;
