
create or replace view public.phase1_core_identity_h2h_metrics as
select 'H2H_' || phase1_status as metric, count(*)::bigint as value
from public.match_h2h_phase1_status
group by phase1_status
union all
select 'TEAM_MASTER_' || source as metric, count(*)::bigint as value
from public.team_name_master
where status = 'VERIFIED'
  and source in ('SOFASCORE','FLASHSCORE','FOTMOB','FOOTBALL_DATA')
group by source;
comment on view public.phase1_core_identity_h2h_metrics is
'Phase 1 lightweight operational metrics for H2H semantic status and verified static identity coverage; avoids repeated multi-query diagnostics.';
