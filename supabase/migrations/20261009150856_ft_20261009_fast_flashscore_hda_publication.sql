
create or replace function public.ft_publish_flashscore_hda_current(p_rows jsonb,p_health jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public,pg_temp
as $$
declare v_count integer := 0;
begin
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'no_verified_flashscore_bookmaker_rows';
  end if;
  v_count := public.ft_replace_bookmaker_current_generic('FLASHSCORE_BET365', p_rows);
  insert into public.source_health(source,metric,value_text,status,notes,observed_at,raw)
  values (
    'FLASHSCORE_BET365','cloud_ingest',v_count::text,'OK',
    'Verified current Flashscore/Bet365 HDA published; auxiliary discovery and movements are independent.',
    now(),coalesce(p_health,'{}'::jsonb) || jsonb_build_object('published_bookmaker_rows',v_count,'auxiliary_status','DEFERRED')
  )
  on conflict(source,metric) do update set
    value_text=excluded.value_text,status=excluded.status,notes=excluded.notes,
    observed_at=excluded.observed_at,raw=excluded.raw;
  return jsonb_build_object('published_bookmaker_rows',v_count,'status','CURRENT_HDA_COMMITTED');
end;
$$;
revoke all on function public.ft_publish_flashscore_hda_current(jsonb,jsonb) from public, anon, authenticated;
grant execute on function public.ft_publish_flashscore_hda_current(jsonb,jsonb) to service_role;
