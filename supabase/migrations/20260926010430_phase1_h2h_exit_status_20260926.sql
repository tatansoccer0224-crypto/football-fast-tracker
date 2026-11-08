
create or replace view public.phase1_h2h_exit_status as
select
  count(*) filter (where quality = 'H2H_OK')::bigint as h2h_ok,
  count(*) filter (where quality = 'NO_PREVIOUS_H2H_IN_AVAILABLE_HISTORY')::bigint as no_history,
  count(*) filter (where quality = 'HISTORY_PARTIAL')::bigint as history_partial,
  count(*) filter (where quality not in ('H2H_OK','NO_PREVIOUS_H2H_IN_AVAILABLE_HISTORY','HISTORY_PARTIAL'))::bigint as true_fail,
  count(*)::bigint as total,
  now() as measured_at
from public.match_h2h_current;
comment on view public.phase1_h2h_exit_status is
'Phase 1 H2H exit-contract diagnostic. NO_HISTORY and HISTORY_PARTIAL are explicitly non-fail; true_fail contains only unrecognized/error quality states.';
