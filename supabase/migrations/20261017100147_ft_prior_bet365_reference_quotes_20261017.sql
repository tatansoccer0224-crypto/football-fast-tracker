-- Phase 6: existing bookmaker observation history is display-only.
-- Separate from the <=20-minute CURRENT quote/market/EV authority.
-- Read-only, security-invoker, bounded, indexed-by-event; no new capture,
-- tables, jobs, aliases, retained data or bookmaker requests.
create or replace function public.ft_prior_bet365_reference_quotes(
    p_window_hours integer default 48
)
returns table (
    match_id text,
    captured_at timestamptz,
    home_price numeric,
    draw_price numeric,
    away_price numeric
)
language sql stable
set search_path = public, pg_temp
as $ft_prior_quote$
    select f.match_id, history.captured_at,
           history.home_price, history.draw_price, history.away_price
    from public.flashscore_primary_fixture_current f
    join lateral (
        select o.captured_at,o.home_price,o.draw_price,o.away_price
        from public.odds_snapshots o
        where o.match_id=f.match_id
          and o.source='FLASHSCORE_BET365' and o.market='ML'
          -- Earlier reference, NEVER a current/real-time bookmaker quote.
          and o.captured_at >= now()-interval '24 hours'
          and o.captured_at < now()-interval '20 minutes'
          and o.captured_at < f.kickoff_hkt
          and o.home_price between 1.01 and 100
          and o.draw_price between 1.01 and 100
          and o.away_price between 1.01 and 100
          -- Retained publisher proof ties the source to the exact FS ID.
          and o.raw->>'fixture_authority'='FLASHSCORE'
          and o.raw->>'capture_type'='ACTUAL_OBSERVED_1X2'
        order by o.captured_at desc
        limit 1
    ) history on true
    where f.match_id ~ '^FS:[A-Za-z0-9_-]{5,32}$'
      and f.kickoff_hkt>now()
      and f.kickoff_hkt<now()+make_interval(hours=>greatest(1,least(48,coalesce(p_window_hours,48))))
      and coalesce(f.in_play,false)=false
      -- The current fast summary already returns truly fresh values.
      and not exists (
          select 1 from public.bookmaker_odds_current b
          where b.match_id=f.match_id
            and b.fetched_at>=now()-interval '20 minutes'
            and b.bet365_home between 1.01 and 100
            and b.bet365_draw between 1.01 and 100
            and b.bet365_away between 1.01 and 100
      )
    order by f.kickoff_hkt,f.match_id
    limit 400;
$ft_prior_quote$;

-- The public feed Edge Function invokes this only using its server-side key.
-- The routine is SECURITY INVOKER (default) and is not open to public clients.
revoke all on function public.ft_prior_bet365_reference_quotes(integer) from public;
revoke all on function public.ft_prior_bet365_reference_quotes(integer) from anon;
revoke all on function public.ft_prior_bet365_reference_quotes(integer) from authenticated;
grant execute on function public.ft_prior_bet365_reference_quotes(integer) to service_role;
