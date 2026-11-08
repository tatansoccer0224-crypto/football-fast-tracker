create or replace function public.ft_internal_app_match_detail_critical(p_match_id text)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
with latest_source as (
  select source_name, max(fetched_at) as fetched_at
  from public.phase2_match_lineup_evidence
  where match_id = p_match_id
  group by source_name
),
latest_lineups as (
  select l.*
  from public.phase2_match_lineup_evidence l
  join latest_source s
    on s.source_name = l.source_name
   and s.fetched_at = l.fetched_at
  where l.match_id = p_match_id
),
lineup_keys as (
  select distinct player_key
  from latest_lineups
  where player_key is not null and player_key <> ''
)
select jsonb_build_object(
  'fixture', (
    select jsonb_build_object(
      'match_id', f.match_id,
      'kickoff_hkt', f.kickoff_hkt,
      'status', f.status,
      'tournament', f.league,
      'home_en', f.home_en,
      'away_en', f.away_en,
      'home_zh', f.home_zh,
      'away_zh', f.away_zh,
      'in_play', f.in_play,
      'selling', f.selling,
      'pool_status', f.pool_status,
      'fetched_at', f.fetched_at,
      'source_updated_at', f.source_updated_at,
      'updated_at', f.updated_at
    )
    from public.canonical_fixture_current f
    where f.match_id = p_match_id
    limit 1
  ),
  'lineups', coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'match_id', l.match_id,
        'team_side', l.team_side,
        'team_key', l.team_key,
        'player_key', l.player_key,
        'player_name', l.player_name,
        'role', l.role,
        'starter', l.starter,
        'formation_slot', l.formation_slot,
        'shirt_number', l.shirt_number,
        'confirmed', l.confirmed,
        'confidence', l.confidence,
        'source_name', l.source_name,
        'source_url', l.source_url,
        'source_updated_at', l.source_updated_at,
        'fetched_at', l.fetched_at
      )
      order by l.source_name, l.team_side, l.starter desc, l.player_name
    )
    from latest_lineups l
  ), '[]'::jsonb),
  'players', coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'player_key', p.player_key,
        'canonical_name', p.canonical_name,
        'team_key', p.team_key,
        'position', p.position,
        'nationality', p.nationality,
        'date_of_birth', p.date_of_birth,
        'profile', p.profile,
        'source_updated_at', p.source_updated_at,
        'source_ids', p.source_ids
      )
      order by p.player_key
    )
    from public.phase2_players p
    where p.player_key in (select player_key from lineup_keys)
       or p.source_ids->>'flashscore' in (select player_key from lineup_keys)
  ), '[]'::jsonb),
  'value', coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'match_id', v.match_id,
        'market_key', v.market_key,
        'period_key', v.period_key,
        'line_key', v.line_key,
        'selection_key', v.selection_key,
        'provider_id', v.provider_id,
        'odds_decimal', v.odds_decimal,
        'effective_odds_decimal', v.effective_odds_decimal,
        'model_prob', v.model_prob,
        'market_prob_raw', v.market_prob_raw,
        'market_prob_devig', v.market_prob_devig,
        'market_overround', v.market_overround,
        'probability_edge_pct', v.probability_edge_pct,
        'expected_roi_pct', v.expected_roi_pct,
        'model_source_count', v.model_source_count,
        'quote_age_seconds', v.quote_age_seconds,
        'status', v.status,
        'calculated_at', v.calculated_at,
        'details', v.details
      )
      order by v.selection_key
    )
    from public.value_market_feed_current v
    where v.match_id = p_match_id
      and v.provider_id in ('BET365','POLYMARKET')
  ), '[]'::jsonb),
  'source_match_detail', (
    select jsonb_build_object(
      'match_id', d.match_id,
      'source_key', d.source_key,
      'external_event_id', d.external_event_id,
      'detail_raw', d.detail_raw,
      'detail_fetched_at', d.detail_fetched_at,
      'updated_at', d.updated_at
    )
    from public.source_match_detail_current d
    where d.match_id = p_match_id
      and d.source_key = 'FOTMOB'
    order by d.detail_fetched_at desc
    limit 1
  )
);
$$;

revoke all on function public.ft_internal_app_match_detail_critical(text) from public;
grant execute on function public.ft_internal_app_match_detail_critical(text) to service_role;
