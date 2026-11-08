
create table if not exists public.team_alias_hourly_metrics (
  bucket timestamptz primary key,
  total_aliases integer not null,
  verified_master integer not null,
  candidate_master integer not null,
  ambiguous_master integer not null,
  unresolved_current integer not null,
  flashscore_aliases integer not null,
  fotmob_aliases integer not null,
  evidence_rows integer not null,
  sources integer not null,
  created_at timestamptz not null default now()
);

alter table public.team_alias_hourly_metrics enable row level security;
revoke all on table public.team_alias_hourly_metrics from anon,authenticated;

create or replace function public.ft_ingest_shadow_alias_evidence_v2()
returns jsonb
language plpgsql
security invoker
set search_path=public
as $$
declare
  v_evidence integer:=0;
  v_direct_promoted integer:=0;
begin
  with canon as (
    select
      s.source_key as source,
      s.external_event_id,
      s.matched_hkjc_event_id,
      s.match_confidence,
      s.identity_status,
      s.home_name,
      s.away_name,
      s.fetched_at,
      coalesce(u.tournament,m.tournament) tournament,
      coalesce(u.kickoff_hkt,m.kickoff_hkt,s.kickoff_utc) kickoff_hkt,
      coalesce(u.home_en,m.home_en) home_en,
      coalesce(u.away_en,m.away_en) away_en
    from public.phase15_source_shadow_current s
    left join public.hkjc_upcoming_current u on u.hkjc_event_id=s.matched_hkjc_event_id
    left join public.matches m on m.hkjc_event_id=s.matched_hkjc_event_id
    where s.source_key in ('FLASHSCORE','FOTMOB')
      and s.matched_hkjc_event_id is not null
      and coalesce(s.match_confidence,0)>=0.94
      and s.fetched_at>=now()-interval '7 days'
      and coalesce(u.kickoff_hkt,m.kickoff_hkt,s.kickoff_utc)>=now()-interval '3 days'
      and coalesce(u.kickoff_hkt,m.kickoff_hkt,s.kickoff_utc)<now()+interval '48 hours'
  ),
  pairs as (
    select source,external_event_id,matched_hkjc_event_id,'H'::text team_side,
           home_name alias,home_en hkjc_en,tournament,kickoff_hkt,
           match_confidence,identity_status,fetched_at
    from canon
    where nullif(trim(home_name),'') is not null and nullif(trim(home_en),'') is not null
    union all
    select source,external_event_id,matched_hkjc_event_id,'A',
           away_name,away_en,tournament,kickoff_hkt,
           match_confidence,identity_status,fetched_at
    from canon
    where nullif(trim(away_name),'') is not null and nullif(trim(away_en),'') is not null
  ),
  ins as (
    insert into public.team_alias_evidence_v2(
      source,alias,alias_key,team_key,hkjc_event_id,team_side,tournament,kickoff_hkt,
      evidence_type,confidence,observed_at,raw
    )
    select
      p.source,
      trim(p.alias),
      public.ft_team_name_key(p.alias),
      'HKJC:'||public.ft_team_name_key(p.hkjc_en),
      p.matched_hkjc_event_id,
      p.team_side,
      p.tournament,
      p.kickoff_hkt,
      'PHASE1_SHADOW_MATCH',
      p.match_confidence,
      coalesce(p.fetched_at,now()),
      jsonb_build_object(
        'hkjc_name_en',p.hkjc_en,
        'external_event_id',p.external_event_id,
        'identity_status',p.identity_status,
        'match_confidence',p.match_confidence
      )
    from pairs p
    join public.team_entities_v2 te
      on te.team_key='HKJC:'||public.ft_team_name_key(p.hkjc_en)
    where public.ft_team_name_key(p.alias) is not null
    on conflict do nothing
    returning 1
  )
  select count(*) into v_evidence from ins;

  with canon as (
    select
      s.source_key as source,
      s.matched_hkjc_event_id,
      s.match_confidence,
      s.identity_status,
      s.home_name,
      s.away_name,
      coalesce(u.home_en,m.home_en) home_en,
      coalesce(u.away_en,m.away_en) away_en,
      s.fetched_at
    from public.phase15_source_shadow_current s
    left join public.hkjc_upcoming_current u on u.hkjc_event_id=s.matched_hkjc_event_id
    left join public.matches m on m.hkjc_event_id=s.matched_hkjc_event_id
    where s.source_key in ('FLASHSCORE','FOTMOB')
      and s.matched_hkjc_event_id is not null
      and coalesce(s.match_confidence,0)>=0.98
      and s.identity_status in ('EXACT_PAIR','VERIFIED_ALIAS','SHARED_ALIAS')
      and s.fetched_at>=now()-interval '7 days'
  ),
  pairs as (
    select source,home_name alias,home_en canonical,match_confidence,fetched_at from canon
    union all
    select source,away_name,away_en,match_confidence,fetched_at from canon
  ),
  up as (
    insert into public.team_aliases(
      source,alias,canonical_hkjc_name,confidence,
      first_seen_hkt,last_seen_hkt,match_count,status,alias_source,updated_at
    )
    select
      source,trim(alias),trim(canonical),match_confidence,
      coalesce(fetched_at,now()),coalesce(fetched_at,now()),1,
      'ACTIVE','PHASE1_SHADOW_HIGH_CONF',now()
    from pairs
    where nullif(trim(alias),'') is not null
      and nullif(trim(canonical),'') is not null
    on conflict(source,alias) do update set
      canonical_hkjc_name=case
        when excluded.confidence>=public.team_aliases.confidence then excluded.canonical_hkjc_name
        else public.team_aliases.canonical_hkjc_name end,
      confidence=greatest(public.team_aliases.confidence,excluded.confidence),
      last_seen_hkt=greatest(public.team_aliases.last_seen_hkt,excluded.last_seen_hkt),
      match_count=public.team_aliases.match_count+1,
      status='ACTIVE',
      alias_source=case
        when excluded.confidence>=public.team_aliases.confidence then excluded.alias_source
        else public.team_aliases.alias_source end,
      updated_at=now()
    returning 1
  )
  select count(*) into v_direct_promoted from up;

  return jsonb_build_object(
    'shadow_evidence_inserted',v_evidence,
    'high_conf_aliases_upserted',v_direct_promoted
  );
end;
$$;

create or replace function public.ft_snapshot_alias_hourly_metrics()
returns jsonb
language plpgsql
security invoker
set search_path=public
as $$
declare
  v_total integer:=0;
  v_verified integer:=0;
  v_candidate integer:=0;
  v_ambiguous integer:=0;
  v_unresolved integer:=0;
  v_flash integer:=0;
  v_fotmob integer:=0;
  v_evidence integer:=0;
  v_sources integer:=0;
begin
  select count(*)::int,count(distinct source)::int
  into v_total,v_sources from public.team_aliases;

  select
    count(*) filter(where status='VERIFIED')::int,
    count(*) filter(where status='CANDIDATE')::int,
    count(*) filter(where status='AMBIGUOUS')::int
  into v_verified,v_candidate,v_ambiguous
  from public.team_name_master;

  select count(*)::int into v_flash from public.team_aliases where source='FLASHSCORE';
  select count(*)::int into v_fotmob from public.team_aliases where source='FOTMOB';
  select count(*)::int into v_evidence from public.team_alias_evidence_v2;

  select coalesce((raw->>'unresolved_pairs')::int,0)
  into v_unresolved
  from public.source_health
  where source='TEAM_ALIAS_ONE_FOR_ALL' and metric='phase1';

  insert into public.team_alias_hourly_metrics(
    bucket,total_aliases,verified_master,candidate_master,ambiguous_master,
    unresolved_current,flashscore_aliases,fotmob_aliases,evidence_rows,sources
  )
  values(
    date_trunc('hour',now()),v_total,v_verified,v_candidate,v_ambiguous,
    coalesce(v_unresolved,0),v_flash,v_fotmob,v_evidence,v_sources
  )
  on conflict(bucket) do update set
    total_aliases=excluded.total_aliases,
    verified_master=excluded.verified_master,
    candidate_master=excluded.candidate_master,
    ambiguous_master=excluded.ambiguous_master,
    unresolved_current=excluded.unresolved_current,
    flashscore_aliases=excluded.flashscore_aliases,
    fotmob_aliases=excluded.fotmob_aliases,
    evidence_rows=excluded.evidence_rows,
    sources=excluded.sources,
    created_at=now();

  return jsonb_build_object(
    'total_aliases',v_total,'verified_master',v_verified,'candidate_master',v_candidate,
    'ambiguous_master',v_ambiguous,'unresolved_current',coalesce(v_unresolved,0),
    'flashscore_aliases',v_flash,'fotmob_aliases',v_fotmob,
    'evidence_rows',v_evidence,'sources',v_sources
  );
end;
$$;

revoke all on function public.ft_ingest_shadow_alias_evidence_v2() from public,anon,authenticated;
grant execute on function public.ft_ingest_shadow_alias_evidence_v2() to postgres,service_role;

revoke all on function public.ft_snapshot_alias_hourly_metrics() from public,anon,authenticated;
grant execute on function public.ft_snapshot_alias_hourly_metrics() to postgres,service_role;

create or replace function public.ft_alias_maintenance_v2()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_shadow jsonb;
  v_refresh jsonb;
  v_promote jsonb;
  v_master jsonb;
  v_quarantine jsonb;
  v_registry_harden jsonb;
  v_registry_merge jsonb;
  v_static_consensus jsonb;
  v_reannotate jsonb;
  v_health jsonb;
  v_one_for_all jsonb;
  v_runtime_health jsonb;
  v_women jsonb;
  v_brazil jsonb;
  v_context jsonb;
  v_forebet_queue jsonb;
  v_deferred jsonb;
  v_snapshot jsonb;
begin
  v_deferred := public.ft_refresh_deferred_identity_state();

  -- New: every hour absorb high-confidence Phase 1 identities from live source shadows
  -- into the same one-for-all evidence and promotion path.
  v_shadow := public.ft_ingest_shadow_alias_evidence_v2();

  v_refresh := public.ft_refresh_team_alias_v2();
  v_promote := public.ft_promote_verified_alias_v2();
  v_master := public.ft_refresh_team_name_master();
  v_quarantine := public.ft_apply_team_name_quarantine();
  v_registry_harden := public.ft_promote_registry_from_verified_master();
  v_registry_merge := public.ft_merge_alias_registry_into_team_name_master();
  v_quarantine := v_quarantine || public.ft_apply_team_name_quarantine();
  v_context := public.ft_refresh_static_identity_context();
  v_static_consensus := public.ft_promote_static_master_consensus();
  v_quarantine := v_quarantine || public.ft_apply_team_name_quarantine();

  v_reannotate := private.ft_refresh_multisource_master_annotations();

  v_health := public.ft_record_team_name_master_health();
  v_one_for_all := public.ft_record_one_for_all_alias_health();
  v_women := public.ft_refresh_womens_intl_team_names();
  v_brazil := public.ft_refresh_brazilianfootball_team_names();
  v_forebet_queue := public.ft_record_forebet_identity_queue_health();
  v_runtime_health := private.ft_record_alias_runtime_health();

  -- New: durable hourly trend snapshot after all promotions/health refresh.
  v_snapshot := public.ft_snapshot_alias_hourly_metrics();

  return jsonb_build_object(
    'deferred_identity_state',v_deferred,
    'shadow_alias_learning',v_shadow,
    'alias_v2',v_refresh,
    'promotion',v_promote,
    'team_name_master',v_master,
    'quarantine_enforcement',v_quarantine,
    'registry_hardening',v_registry_harden,
    'registry_merge',v_registry_merge,
    'static_identity_context',v_context,
    'static_consensus',v_static_consensus,
    'multisource_reannotation',v_reannotate,
    'team_name_master_health',v_health,
    'one_for_all_health',v_one_for_all,
    'runtime_alias_health',v_runtime_health,
    'forebet_identity_queue',v_forebet_queue,
    'womens_intl_names',v_women,
    'brazilianfootball_names',v_brazil,
    'hourly_snapshot',v_snapshot
  );
end
$function$;
