
create or replace function private.ft_phase15_learn_exact_shadow()
returns integer
language plpgsql
security definer
set search_path = 'public','private'
as $$
declare
  v_before bigint;
  v_after bigint;
begin
  select count(*) into v_before
  from public.team_alias_evidence_v2 e
  where exists (
    select 1 from public.phase15_source_registry r
    where r.source_key=e.source and r.discovery_enabled=true and r.active=true
  );

  insert into public.team_alias_evidence_v2
    (source, alias, alias_key, team_key, hkjc_event_id, team_side, tournament,
     kickoff_hkt, evidence_type, confidence, observed_at, raw)
  select
    s.source_key,
    x.alias,
    public.ft_team_name_key(x.alias),
    x.team_key,
    s.matched_hkjc_event_id,
    x.side,
    u.tournament,
    u.kickoff_hkt,
    'PHASE15_EXACT_PAIR',
    0.99,
    s.fetched_at,
    jsonb_build_object('source_event_id',s.external_event_id,'identity_status',s.identity_status)
  from public.phase15_source_shadow_current s
  join public.phase15_source_registry r
    on r.source_key=s.source_key
   and r.discovery_enabled=true
   and r.active=true
  join public.hkjc_upcoming_current u
    on u.hkjc_event_id=s.matched_hkjc_event_id
  cross join lateral (
    select s.home_name alias, 'H'::text side, mh.team_key
    from public.team_name_master mh
    where mh.source='HKJC_EN'
      and mh.status='VERIFIED'
      and mh.source_key=public.ft_team_name_key(u.home_en)
    union all
    select s.away_name alias, 'A'::text side, ma.team_key
    from public.team_name_master ma
    where ma.source='HKJC_EN'
      and ma.status='VERIFIED'
      and ma.source_key=public.ft_team_name_key(u.away_en)
  ) x
  where s.identity_status='EXACT_PAIR'
    and s.match_confidence >= 0.99
    and public.ft_team_name_key(s.home_name)=public.ft_team_name_key(u.home_en)
    and public.ft_team_name_key(s.away_name)=public.ft_team_name_key(u.away_en)
  on conflict do nothing;

  select count(*) into v_after
  from public.team_alias_evidence_v2 e
  where exists (
    select 1 from public.phase15_source_registry r
    where r.source_key=e.source and r.discovery_enabled=true and r.active=true
  );

  return (v_after-v_before)::integer;
end
$$;

create or replace function private.ft_phase15_discovery_cycle()
returns jsonb
language plpgsql
security definer
set search_path='public','private'
as $$
declare
  v_base jsonb;
  v_cross_resolved integer := 0;
  v_deferred integer := 0;
  v_pruned integer := 0;
begin
  v_base := private.ft_phase15_discovery_maintenance();

  update public.phase15_data_opportunity_queue q
  set status='RESOLVED',
      resolved_at=coalesce(q.resolved_at,now()),
      updated_at=now(),
      last_result='Resolved by an autonomous shadow source'
  where q.status in ('OPEN','RETRY')
    and q.gap_type='INDEPENDENT_EVIDENCE_MISSING'
    and exists (
      select 1
      from public.phase15_source_shadow_current s
      join public.phase15_source_registry r
        on r.source_key=s.source_key
       and r.active=true
       and r.discovery_enabled=true
      where s.matched_hkjc_event_id=q.hkjc_event_id
        and s.match_confidence >= 0.94
    );
  get diagnostics v_cross_resolved = row_count;

  update public.phase15_data_opportunity_queue q
  set status='DEFERRED',
      updated_at=now(),
      last_result='Outside current HKJC discovery horizon'
  where q.status in ('OPEN','RETRY')
    and not exists (
      select 1 from public.hkjc_upcoming_current u
      where u.hkjc_event_id=q.hkjc_event_id
        and u.kickoff_hkt between now()-interval '3 hours' and now()+interval '48 hours'
    );
  get diagnostics v_deferred = row_count;

  delete from public.phase15_source_shadow_current s
  where (s.kickoff_utc is not null and s.kickoff_utc < now()-interval '72 hours')
     or (s.kickoff_utc is not null and s.kickoff_utc > now()+interval '8 days');
  get diagnostics v_pruned = row_count;

  return v_base || jsonb_build_object(
    'cross_source_resolved',v_cross_resolved,
    'stale_deferred',v_deferred,
    'shadow_rows_pruned',v_pruned
  );
end
$$;

revoke all on function private.ft_phase15_learn_exact_shadow() from public;
revoke all on function private.ft_phase15_discovery_cycle() from public;
grant execute on function private.ft_phase15_learn_exact_shadow() to postgres, service_role;
grant execute on function private.ft_phase15_discovery_cycle() to postgres, service_role;

select cron.schedule(
  'phase15-flashscore-scout-6h',
  '17 */6 * * *',
  $$select net.http_get(
      url := 'https://hekqxhgjexzxnecwhyao.supabase.co/functions/v1/phase15-flashscore-scout',
      timeout_milliseconds := 60000
    );$$
);

select cron.alter_job(
  job_id := (select jobid from cron.job where jobname='phase15-discovery-maintenance-6h'),
  command := 'select private.ft_phase15_discovery_cycle();',
  active := true
);
