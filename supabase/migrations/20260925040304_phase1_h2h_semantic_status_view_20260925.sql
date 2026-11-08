create or replace view public.match_h2h_phase1_status as
select
  hkjc_event_id,
  fetched_at,
  kickoff_hkt,
  home_id,
  away_id,
  home,
  away,
  h2h_games,
  home_wins,
  draws,
  away_wins,
  home_goals,
  away_goals,
  avg_total_goals,
  last5,
  meetings,
  source,
  quality,
  case
    when quality = 'H2H_OK' then 'H2H_OK'
    when quality = 'HISTORY_PARTIAL' then 'HISTORY_PARTIAL'
    when quality = 'NO_PREVIOUS_H2H_IN_AVAILABLE_HISTORY' then 'NO_HISTORY'
    else 'TRUE_FAIL'
  end as phase1_status,
  updated_at
from public.match_h2h_current;

comment on view public.match_h2h_phase1_status is
'Phase 1 H2H semantic projection. NO_PREVIOUS_H2H_IN_AVAILABLE_HISTORY maps to NO_HISTORY, HISTORY_PARTIAL remains non-failure, and only unknown/unclassified quality maps to TRUE_FAIL.';
