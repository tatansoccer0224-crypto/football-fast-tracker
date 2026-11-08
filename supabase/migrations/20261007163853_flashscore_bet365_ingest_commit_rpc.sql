create or replace function public.ft_commit_flashscore_bet365_ingest(
  p_fixture_stage jsonb,
  p_canonical_creates jsonb,
  p_redirects jsonb,
  p_stage jsonb,
  p_bookmaker_rows jsonb,
  p_snapshots jsonb,
  p_health jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  market_refresh jsonb;
  movement_refresh jsonb;
  verified_count integer := coalesce((p_health->>'verified')::integer, 0);
begin
  if jsonb_typeof(p_canonical_creates) = 'array' and jsonb_array_length(p_canonical_creates) > 0 then
    perform public.ft_upsert_canonical_fixtures_generic(p_canonical_creates);
  end if;

  if jsonb_typeof(p_redirects) = 'array' and jsonb_array_length(p_redirects) > 0 then
    insert into public.fixture_identity_redirects(
      source_match_id,target_match_id,source_name,confidence,evidence,active,updated_at
    )
    select source_match_id,target_match_id,source_name,confidence,evidence,active,updated_at
    from jsonb_to_recordset(p_redirects) as x(
      source_match_id text,
      target_match_id text,
      source_name text,
      confidence numeric,
      evidence jsonb,
      active boolean,
      updated_at timestamptz
    )
    on conflict (source_match_id) do update set
      target_match_id=excluded.target_match_id,
      source_name=excluded.source_name,
      confidence=excluded.confidence,
      evidence=excluded.evidence,
      active=excluded.active,
      updated_at=excluded.updated_at;
  end if;

  if jsonb_typeof(p_fixture_stage) = 'array' and jsonb_array_length(p_fixture_stage) > 0 then
    insert into public.flashscore_fixture_current(
      provider_event_id,captured_at,fixture_date,kickoff_utc,league,home,away,
      canonical_match_id,identity_status,raw,updated_at
    )
    select provider_event_id,captured_at,fixture_date,kickoff_utc,league,home,away,
           canonical_match_id,identity_status,raw,updated_at
    from jsonb_to_recordset(p_fixture_stage) as x(
      provider_event_id text,
      captured_at timestamptz,
      fixture_date date,
      kickoff_utc timestamptz,
      league text,
      home text,
      away text,
      canonical_match_id text,
      identity_status text,
      raw jsonb,
      updated_at timestamptz
    )
    on conflict (provider_event_id) do update set
      captured_at=excluded.captured_at,
      fixture_date=excluded.fixture_date,
      kickoff_utc=excluded.kickoff_utc,
      league=excluded.league,
      home=excluded.home,
      away=excluded.away,
      canonical_match_id=excluded.canonical_match_id,
      identity_status=excluded.identity_status,
      raw=excluded.raw,
      updated_at=excluded.updated_at;

    delete from public.flashscore_fixture_current t
    where not exists (
      select 1
      from jsonb_array_elements(p_fixture_stage) e
      where e->>'provider_event_id'=t.provider_event_id
    );
  end if;

  if jsonb_typeof(p_stage) = 'array' and jsonb_array_length(p_stage) > 0 then
    insert into public.flashscore_bet365_current(
      provider_event_id,captured_at,fixture_date,kickoff_utc,league,home,away,
      home_price,draw_price,away_price,opening_home,opening_draw,opening_away,
      canonical_match_id,identity_status,raw,updated_at
    )
    select provider_event_id,captured_at,fixture_date,kickoff_utc,league,home,away,
           home_price,draw_price,away_price,opening_home,opening_draw,opening_away,
           canonical_match_id,identity_status,raw,updated_at
    from jsonb_to_recordset(p_stage) as x(
      provider_event_id text,
      captured_at timestamptz,
      fixture_date date,
      kickoff_utc timestamptz,
      league text,
      home text,
      away text,
      home_price numeric,
      draw_price numeric,
      away_price numeric,
      opening_home numeric,
      opening_draw numeric,
      opening_away numeric,
      canonical_match_id text,
      identity_status text,
      raw jsonb,
      updated_at timestamptz
    )
    on conflict (provider_event_id) do update set
      captured_at=excluded.captured_at,
      fixture_date=excluded.fixture_date,
      kickoff_utc=excluded.kickoff_utc,
      league=excluded.league,
      home=excluded.home,
      away=excluded.away,
      home_price=excluded.home_price,
      draw_price=excluded.draw_price,
      away_price=excluded.away_price,
      opening_home=excluded.opening_home,
      opening_draw=excluded.opening_draw,
      opening_away=excluded.opening_away,
      canonical_match_id=excluded.canonical_match_id,
      identity_status=excluded.identity_status,
      raw=excluded.raw,
      updated_at=excluded.updated_at;

    delete from public.flashscore_bet365_current t
    where not exists (
      select 1
      from jsonb_array_elements(p_stage) e
      where e->>'provider_event_id'=t.provider_event_id
    );
  end if;

  perform public.ft_replace_bookmaker_current_generic(
    'FLASHSCORE_BET365',
    case when jsonb_typeof(p_bookmaker_rows)='array' then p_bookmaker_rows else '[]'::jsonb end
  );

  if jsonb_typeof(p_snapshots) = 'array' and jsonb_array_length(p_snapshots) > 0 then
    perform public.ft_insert_market_snapshots_generic(p_snapshots);
  end if;

  market_refresh := public.ft_refresh_cloud_market_current();
  movement_refresh := public.ft_refresh_cloud_odds_movement();

  p_health := coalesce(p_health,'{}'::jsonb) || jsonb_build_object(
    'market_refresh', market_refresh,
    'movement_refresh', movement_refresh
  );

  insert into public.source_health(source,metric,value_text,status,notes,observed_at,raw)
  values(
    'FLASHSCORE_BET365',
    'cloud_ingest',
    verified_count::text,
    case when verified_count > 0 then 'OK' else 'ATTENTION' end,
    case when verified_count > 0
      then 'Cloud snapshot ingested; only strict unique canonical matches promoted.'
      else 'Cloud snapshot healthy but no strict canonical fixture matches promoted.'
    end,
    now(),
    p_health
  )
  on conflict (source,metric) do update set
    value_text=excluded.value_text,
    status=excluded.status,
    notes=excluded.notes,
    observed_at=excluded.observed_at,
    raw=excluded.raw;

  return jsonb_build_object(
    'verified',verified_count,
    'market_refresh',market_refresh,
    'movement_refresh',movement_refresh
  );
end;
$$;

revoke all on function public.ft_commit_flashscore_bet365_ingest(jsonb,jsonb,jsonb,jsonb,jsonb,jsonb,jsonb) from public;
grant execute on function public.ft_commit_flashscore_bet365_ingest(jsonb,jsonb,jsonb,jsonb,jsonb,jsonb,jsonb) to service_role;
