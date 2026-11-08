
do $$
begin
  if exists (select 1 from cron.job where jobid = 4) then
    perform cron.alter_job(4, active := false);
  end if;
  if exists (select 1 from cron.job where jobid = 7) then
    perform cron.alter_job(7, active := false);
  end if;
end $$;
