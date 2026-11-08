create or replace view public.phase1_core_identity_h2h_metrics as
select 'H2H_H2H_OK'::text metric, count(*)::bigint value from public.match_h2h_current where quality='H2H_OK'
union all select 'H2H_NO_HISTORY', count(*) from public.match_h2h_current where quality='NO_PREVIOUS_H2H_IN_AVAILABLE_HISTORY'
union all select 'H2H_HISTORY_PARTIAL', count(*) from public.match_h2h_current where quality='HISTORY_PARTIAL'
union all select 'H2H_TRUE_FAIL', count(*) from public.match_h2h_current where quality not in ('H2H_OK','NO_PREVIOUS_H2H_IN_AVAILABLE_HISTORY','HISTORY_PARTIAL')
union all select 'TEAM_MASTER_FLASHSCORE', count(*) from public.team_name_master where source='FLASHSCORE' and status='VERIFIED'
union all select 'TEAM_MASTER_FOOTBALL_DATA', count(*) from public.team_name_master where source='FOOTBALL_DATA' and status='VERIFIED'
union all select 'TEAM_MASTER_FOTMOB', count(*) from public.team_name_master where source='FOTMOB' and status='VERIFIED'
union all select 'TEAM_MASTER_SOFASCORE', count(*) from public.team_name_master where source='SOFASCORE' and status='VERIFIED';
