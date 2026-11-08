
do $$
begin
 if not exists (select 1 from cron.job where jobname='ft-football-alias-super-daily-v1' and active)
 then
  perform cron.schedule('ft-football-alias-super-daily-v1','10 16 * * *','select private.ft_refresh_football_alias_supertable();');
 end if;
end $$;
