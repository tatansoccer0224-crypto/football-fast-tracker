
revoke all on function public.ft_alias_maintenance_v2() from public,anon,authenticated;
grant execute on function public.ft_alias_maintenance_v2() to postgres,service_role;
