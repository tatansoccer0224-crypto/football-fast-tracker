
create or replace function public.ft_refresh_cloud_market_current()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','private','pg_temp'
as $function$
declare
  v_rows integer := 0;
begin
  delete from private.market_current
  where source_key in ('HKJC','FLASHSCORE_BET365');

  insert into private.market_current
    (hkjc_event_id,source_key,market_key,selection_key,line_text,odds,captured_at,raw,updated_at)
  select
    b.hkjc_event_id,
    'FLASHSCORE_BET365',
    '1X2',
    x.selection_key,
    '',
    x.odds,
    b.fetched_at,
    jsonb_build_object(
      'source',b.source,
      'fixture_id',b.bet365_fixture_id,
      'match_quality',b.match_quality,
      'raw',b.raw
    ),
    now()
  from public.bet365_current b
  cross join lateral (values
    ('HOME',b.bet365_home),
    ('DRAW',b.bet365_draw),
    ('AWAY',b.bet365_away)
  ) x(selection_key,odds)
  where b.source='FLASHSCORE_BET365'
    and x.odds is not null
    and x.odds>1
  on conflict (hkjc_event_id,source_key,market_key,selection_key,line_text)
  do update set
    odds=excluded.odds,
    captured_at=excluded.captured_at,
    raw=excluded.raw,
    updated_at=now();

  get diagnostics v_rows = row_count;

  insert into public.source_health(source,metric,value_text,status,notes,observed_at,raw)
  values(
    'FLASHSCORE_BET365','private_market_current',
    v_rows::text,
    case when v_rows>0 then 'OK' else 'ATTENTION' end,
    'Private current market cache contains verified cloud Bet365 1X2 only; retired HKJC market rows are removed.',
    now(),
    jsonb_build_object('rows',v_rows,'market','1X2','source','FLASHSCORE_BET365')
  )
  on conflict(source,metric) do update set
    value_text=excluded.value_text,status=excluded.status,notes=excluded.notes,
    observed_at=excluded.observed_at,raw=excluded.raw;

  return jsonb_build_object('rows',v_rows,'source','FLASHSCORE_BET365');
end
$function$;

create or replace function private.ft_safe_refresh_phase1_core()
returns void
language plpgsql
set search_path to 'pg_catalog','public','private','api','pg_temp'
as $function$
begin
  begin
    perform public.ft_internal_refresh_phase1_core();
    perform public.ft_refresh_cloud_market_current();
    perform public.ft_refresh_cloud_odds_movement();

    insert into public.source_health(source,metric,value_text,status,notes,observed_at,raw)
    values(
      'PHASE1_CORE_REFRESH','decoupled','OK','OK',
      'Phase 1 core refresh completed with cloud Bet365 market authority and independent prediction evidence.',
      now(),
      jsonb_build_object('mode','CLOUD_MARKET_AUTHORITY','market_source','FLASHSCORE_BET365')
    )
    on conflict(source,metric) do update set
      value_text=excluded.value_text,
      status=excluded.status,
      notes=excluded.notes,
      observed_at=excluded.observed_at,
      raw=excluded.raw;
  exception when others then
    insert into public.source_health(source,metric,value_text,status,notes,observed_at,raw)
    values(
      'PHASE1_CORE_REFRESH','decoupled',sqlerrm,'WARN',
      'Phase 1 core refresh failed; cloud bookmaker staging/current data is preserved independently.',
      now(),
      jsonb_build_object('mode','CLOUD_MARKET_AUTHORITY','sqlstate',sqlstate,'error',sqlerrm)
    )
    on conflict(source,metric) do update set
      value_text=excluded.value_text,
      status=excluded.status,
      notes=excluded.notes,
      observed_at=excluded.observed_at,
      raw=excluded.raw;
  end;
end
$function$;
