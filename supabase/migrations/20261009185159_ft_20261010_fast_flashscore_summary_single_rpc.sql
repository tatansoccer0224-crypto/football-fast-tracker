create or replace function public.ft_fast_flashscore_summary(p_window_hours integer default 24)
returns jsonb language sql stable security invoker
set search_path = public,pg_temp
as $$
 select coalesce(jsonb_agg(
  jsonb_build_object(
   'match_id',f.match_id,'kickoff_hkt',f.kickoff_hkt,'status',f.status,
   'tournament',f.league,'home_en',f.home_en,'away_en',f.away_en,
   'fetched_at',b.fetched_at,'updated_at',coalesce(b.updated_at,f.updated_at),
   'had_home',b.bet365_home,'had_draw',b.bet365_draw,'had_away',b.bet365_away,
   'odds_updated_at',b.fetched_at,'detail_raw',d.detail_raw,
   'detail_fetched_at',d.detail_fetched_at
  ) order by f.kickoff_hkt,f.match_id
 ),'[]'::jsonb)
 from public.active_canonical_fixture_current f
 left join public.bookmaker_odds_current b on b.match_id=f.match_id
 left join lateral (
   select s.detail_raw,s.detail_fetched_at
   from public.phase15_source_shadow_current s
   where s.match_id=f.match_id and s.source_key='FLASHSCORE'
     and s.detail_fetched_at>now()-interval '24 hours'
   order by s.detail_fetched_at desc nulls last limit 1
 ) d on true
 where f.kickoff_hkt >= now()-interval '6 hours'
   and f.kickoff_hkt < now() + make_interval(hours => greatest(1,least(48,p_window_hours)));
$$;
revoke all on function public.ft_fast_flashscore_summary(integer) from public,anon,authenticated;
grant execute on function public.ft_fast_flashscore_summary(integer) to service_role;
