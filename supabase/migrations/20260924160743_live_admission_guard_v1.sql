create or replace view public.live_admission_guard_v as
select m.hkjc_event_id,m.kickoff_hkt,m.status,m.tournament,m.home_en,m.away_en,m.home_zh,m.away_zh,m.in_play,m.selling,m.fetched_at as match_fetched_at,
 l.fetched_at as live_fetched_at,l.status as live_status,l.pool_status,l.odds_updated_at,
 case when l.hkjc_event_id is not null and l.fetched_at >= now()-interval '5 minutes' then 'LIVE_ODDS'
      when m.in_play then 'WAITING_LIVE_ODDS' else 'NOT_LIVE' end as live_market_state,
 case when m.in_play and l.hkjc_event_id is null then true else false end as in_play_missing_live_market
from public.matches m left join public.hkjc_live_odds_current l using(hkjc_event_id)
where m.in_play = true;

create or replace view public.live_duplicate_guard_v as
select hkjc_event_id,count(*) as canonical_rows
from public.matches where in_play=true group by hkjc_event_id;
