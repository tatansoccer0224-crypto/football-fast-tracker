
do $$
declare
  existing_id bigint;
begin
  select jobid into existing_id
  from cron.job
  where jobname = 'flashscore-bet365-cloud-ingest'
  limit 1;

  if existing_id is not null then
    perform cron.unschedule(existing_id);
  end if;

  perform cron.schedule(
    'flashscore-bet365-cloud-ingest',
    '*/15 * * * *',
    $cron$
      select net.http_post(
        url := 'https://hekqxhgjexzxnecwhyao.supabase.co/functions/v1/flashscore-bet365-ingest',
        headers := '{"Content-Type":"application/json"}'::jsonb,
        body := '{}'::jsonb
      );
    $cron$
  );
end $$;
