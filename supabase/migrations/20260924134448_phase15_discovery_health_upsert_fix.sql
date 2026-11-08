CREATE OR REPLACE FUNCTION private.ft_phase15_discovery_maintenance()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  v_run_id bigint;
  v_learned integer := 0;
  v_opened integer := 0;
  v_resolved integer := 0;
  v_rows integer := 0;
  v_sources integer := 0;
begin
  insert into public.phase15_discovery_runs(runner) values ('PHASE15_DB')
  returning run_id into v_run_id;

  insert into public.phase15_source_registry
    (source_key, source_kind, trust_status, active, discovery_enabled, trust_score,
     first_seen_at, last_seen_at, updated_at, notes)
  select
    m.source,
    'OBSERVED',
    'TRUSTED',
    true,
    false,
    0.80,
    min(m.first_seen_at),
    max(m.last_seen_at),
    now(),
    'Observed by One-for-All team identity master'
  from public.team_name_master m
  where m.source is not null
  group by m.source
  on conflict (source_key) do update
    set last_seen_at=greatest(public.phase15_source_registry.last_seen_at,excluded.last_seen_at),
        updated_at=now();

  select count(*) into v_sources from public.phase15_source_registry where active;

  v_learned := private.ft_phase15_learn_exact_shadow();

  insert into public.phase15_data_opportunity_queue
    (hkjc_event_id,gap_type,target_field,source_hint,priority,status,reason,
     first_seen_at,last_seen_at,next_attempt_at,context,updated_at)
  select
    u.hkjc_event_id,'PREDICTION_MISSING','forebet_prediction','FOREBET',
    case when u.kickoff_hkt <= now()+interval '24 hours' then 85 else 65 end,
    'OPEN','HKJC fixture has no Forebet prediction row',
    now(),now(),now(),
    jsonb_build_object('kickoff_hkt',u.kickoff_hkt,'tournament',u.tournament,'home',u.home_en,'away',u.away_en),
    now()
  from public.hkjc_upcoming_current u
  left join public.forebet_predictions f on f.hkjc_event_id=u.hkjc_event_id
  where u.kickoff_hkt between now()-interval '3 hours' and now()+interval '48 hours'
    and f.hkjc_event_id is null
  on conflict (hkjc_event_id,gap_type,source_hint) do update
    set status='OPEN', last_seen_at=now(), next_attempt_at=least(public.phase15_data_opportunity_queue.next_attempt_at,now()),
        priority=greatest(public.phase15_data_opportunity_queue.priority,excluded.priority),
        context=excluded.context, updated_at=now();
  get diagnostics v_rows = row_count;
  v_opened := v_opened + v_rows;

  insert into public.phase15_data_opportunity_queue
    (hkjc_event_id,gap_type,target_field,source_hint,priority,status,reason,
     first_seen_at,last_seen_at,next_attempt_at,context,updated_at)
  select
    u.hkjc_event_id,'MODEL_MISSING','internal_model','INTERNAL_MODEL',
    case when u.kickoff_hkt <= now()+interval '24 hours' then 75 else 55 end,
    'OPEN','HKJC fixture has no internal model row',
    now(),now(),now(),
    jsonb_build_object('kickoff_hkt',u.kickoff_hkt,'tournament',u.tournament,'home',u.home_en,'away',u.away_en),
    now()
  from public.hkjc_upcoming_current u
  left join public.model_predictions m on m.hkjc_event_id=u.hkjc_event_id
  where u.kickoff_hkt between now()-interval '3 hours' and now()+interval '48 hours'
    and m.hkjc_event_id is null
  on conflict (hkjc_event_id,gap_type,source_hint) do update
    set status='OPEN', last_seen_at=now(), priority=greatest(public.phase15_data_opportunity_queue.priority,excluded.priority),
        context=excluded.context, updated_at=now();
  get diagnostics v_rows = row_count;
  v_opened := v_opened + v_rows;

  insert into public.phase15_data_opportunity_queue
    (hkjc_event_id,gap_type,target_field,source_hint,priority,status,reason,
     first_seen_at,last_seen_at,next_attempt_at,context,updated_at)
  select
    u.hkjc_event_id,'HUMAN_FACTOR_MISSING','lineup_injury_referee','API_FOOTBALL',
    case when u.kickoff_hkt <= now()+interval '12 hours' then 90 else 70 end,
    'OPEN','Lineup/injury/referee enrichment is missing or empty',
    now(),now(),now(),
    jsonb_build_object('kickoff_hkt',u.kickoff_hkt,'tournament',u.tournament,'home',u.home_en,'away',u.away_en),
    now()
  from public.hkjc_upcoming_current u
  left join public.human_factors_current h on h.hkjc_event_id=u.hkjc_event_id
  where u.kickoff_hkt between now()-interval '3 hours' and now()+interval '48 hours'
    and (
      h.hkjc_event_id is null or
      (
        nullif(trim(coalesce(h.home_lineup,'')),'') is null and
        nullif(trim(coalesce(h.away_lineup,'')),'') is null and
        nullif(trim(coalesce(h.home_injuries,'')),'') is null and
        nullif(trim(coalesce(h.away_injuries,'')),'') is null and
        nullif(trim(coalesce(h.referee,'')),'') is null
      )
    )
  on conflict (hkjc_event_id,gap_type,source_hint) do update
    set status='OPEN', last_seen_at=now(), priority=greatest(public.phase15_data_opportunity_queue.priority,excluded.priority),
        context=excluded.context, updated_at=now();
  get diagnostics v_rows = row_count;
  v_opened := v_opened + v_rows;

  insert into public.phase15_data_opportunity_queue
    (hkjc_event_id,gap_type,target_field,source_hint,priority,status,reason,
     first_seen_at,last_seen_at,next_attempt_at,context,updated_at)
  select
    u.hkjc_event_id,'SHADOW_SOURCE_MISSING','fixture_detail','FOTMOB',
    case when u.kickoff_hkt <= now()+interval '24 hours' then 80 else 60 end,
    'OPEN','No matched FotMob shadow fixture captured yet',
    now(),now(),now(),
    jsonb_build_object('kickoff_hkt',u.kickoff_hkt,'tournament',u.tournament,'home',u.home_en,'away',u.away_en),
    now()
  from public.hkjc_upcoming_current u
  where u.kickoff_hkt between now()-interval '3 hours' and now()+interval '48 hours'
    and not exists (
      select 1 from public.phase15_source_shadow_current s
      where s.source_key='FOTMOB' and s.matched_hkjc_event_id=u.hkjc_event_id
    )
  on conflict (hkjc_event_id,gap_type,source_hint) do update
    set status='OPEN', last_seen_at=now(), priority=greatest(public.phase15_data_opportunity_queue.priority,excluded.priority),
        context=excluded.context, updated_at=now();
  get diagnostics v_rows = row_count;
  v_opened := v_opened + v_rows;

  insert into public.phase15_data_opportunity_queue
    (hkjc_event_id,gap_type,target_field,source_hint,priority,status,reason,
     first_seen_at,last_seen_at,next_attempt_at,context,updated_at)
  select
    u.hkjc_event_id,'INDEPENDENT_EVIDENCE_MISSING','external_evidence','AUTO_DISCOVERY',
    case when u.kickoff_hkt <= now()+interval '24 hours' then 95 else 75 end,
    'OPEN','No Forebet, model, or matched experimental shadow evidence',
    now(),now(),now(),
    jsonb_build_object('kickoff_hkt',u.kickoff_hkt,'tournament',u.tournament,'home',u.home_en,'away',u.away_en),
    now()
  from public.hkjc_upcoming_current u
  where u.kickoff_hkt between now()-interval '3 hours' and now()+interval '48 hours'
    and not exists (select 1 from public.forebet_predictions f where f.hkjc_event_id=u.hkjc_event_id)
    and not exists (select 1 from public.model_predictions m where m.hkjc_event_id=u.hkjc_event_id)
    and not exists (
      select 1 from public.phase15_source_shadow_current s
      where s.source_key='FOTMOB' and s.matched_hkjc_event_id=u.hkjc_event_id
    )
  on conflict (hkjc_event_id,gap_type,source_hint) do update
    set status='OPEN', last_seen_at=now(), priority=greatest(public.phase15_data_opportunity_queue.priority,excluded.priority),
        context=excluded.context, updated_at=now();
  get diagnostics v_rows = row_count;
  v_opened := v_opened + v_rows;

  update public.phase15_data_opportunity_queue q
  set status='RESOLVED', resolved_at=now(), updated_at=now(), last_result='Data became available'
  where q.status in ('OPEN','RETRY')
    and (
      (q.gap_type='PREDICTION_MISSING' and exists (select 1 from public.forebet_predictions f where f.hkjc_event_id=q.hkjc_event_id))
      or
      (q.gap_type='MODEL_MISSING' and exists (select 1 from public.model_predictions m where m.hkjc_event_id=q.hkjc_event_id))
      or
      (q.gap_type='HUMAN_FACTOR_MISSING' and exists (
        select 1 from public.human_factors_current h
        where h.hkjc_event_id=q.hkjc_event_id
          and (
            nullif(trim(coalesce(h.home_lineup,'')),'') is not null or
            nullif(trim(coalesce(h.away_lineup,'')),'') is not null or
            nullif(trim(coalesce(h.home_injuries,'')),'') is not null or
            nullif(trim(coalesce(h.away_injuries,'')),'') is not null or
            nullif(trim(coalesce(h.referee,'')),'') is not null
          )
      ))
      or
      (q.gap_type='SHADOW_SOURCE_MISSING' and exists (
        select 1 from public.phase15_source_shadow_current s
        where s.source_key='FOTMOB' and s.matched_hkjc_event_id=q.hkjc_event_id
      ))
      or
      (q.gap_type='INDEPENDENT_EVIDENCE_MISSING' and (
        exists (select 1 from public.forebet_predictions f where f.hkjc_event_id=q.hkjc_event_id)
        or exists (select 1 from public.model_predictions m where m.hkjc_event_id=q.hkjc_event_id)
        or exists (select 1 from public.phase15_source_shadow_current s where s.source_key='FOTMOB' and s.matched_hkjc_event_id=q.hkjc_event_id)
      ))
    );
  get diagnostics v_resolved = row_count;

  update public.phase15_source_registry r
  set last_probe_at=(select max(s.fetched_at) from public.phase15_source_shadow_current s where s.source_key='FOTMOB'),
      last_success_at=(select max(s.fetched_at) from public.phase15_source_shadow_current s where s.source_key='FOTMOB'),
      total_records=(select count(*) from public.phase15_source_shadow_current s where s.source_key='FOTMOB'),
      trust_score=least(0.79, 0.25 +
        least(0.30, (select count(*)::numeric/1000 from public.phase15_source_shadow_current s where s.source_key='FOTMOB')) +
        case when exists (select 1 from public.phase15_source_shadow_current s where s.source_key='FOTMOB' and s.matched_hkjc_event_id is not null) then 0.15 else 0 end
      ),
      updated_at=now()
  where r.source_key='FOTMOB'
    and exists (select 1 from public.phase15_source_shadow_current s where s.source_key='FOTMOB');

  insert into public.source_health(source,metric,value_text,status,notes,observed_at,raw)
  values (
    'PHASE15_SOURCE_DISCOVERY','6h',
    jsonb_build_object(
      'active_sources',v_sources,
      'open_queue',(select count(*) from public.phase15_data_opportunity_queue where status in ('OPEN','RETRY')),
      'fotmob_shadow_rows',(select count(*) from public.phase15_source_shadow_current where source_key='FOTMOB'),
      'fotmob_matched_rows',(select count(*) from public.phase15_source_shadow_current where source_key='FOTMOB' and matched_hkjc_event_id is not null),
      'evidence_learned',v_learned
    )::text,
    case when (select count(*) from public.phase15_data_opportunity_queue where status='OPEN' and priority>=90)>0 then 'WARN' else 'OK' end,
    'Phase 1.5 gap-driven source discovery; experimental sources remain shadow-only until promoted.',
    now(),
    jsonb_build_object('run_id',v_run_id)
  )
  on conflict (source,metric) do update set
    value_text=excluded.value_text,
    status=excluded.status,
    notes=excluded.notes,
    observed_at=excluded.observed_at,
    raw=excluded.raw;

  update public.phase15_discovery_runs
  set finished_at=now(),
      status=case when (select count(*) from public.phase15_data_opportunity_queue where status='OPEN' and priority>=90)>0 then 'WARN' else 'OK' end,
      sources_seen=v_sources,
      opportunities_opened=v_opened,
      opportunities_resolved=v_resolved,
      evidence_learned=v_learned,
      notes='Gap-driven discovery maintenance completed'
  where run_id=v_run_id;

  return jsonb_build_object(
    'run_id',v_run_id,
    'active_sources',v_sources,
    'queue_touches',v_opened,
    'resolved',v_resolved,
    'evidence_learned',v_learned,
    'open_queue',(select count(*) from public.phase15_data_opportunity_queue where status in ('OPEN','RETRY'))
  );
exception when others then
  if v_run_id is not null then
    update public.phase15_discovery_runs
      set finished_at=now(), status='FAILED', notes=sqlerrm
    where run_id=v_run_id;
  end if;
  raise;
end
$function$
