-- Build a versioned prospective HDA evaluation from genuinely captured prematch snapshots.
--
-- Evaluation design:
-- - only settled H/D/A outcomes from private.match_results
-- - latest complete HDA snapshot captured at least 30 minutes before kickoff
-- - source_updated_at must be null or no later than kickoff
-- - probabilities are normalized before scoring
-- - DC and PI are also evaluated as the correlated INTERNAL_BLEND used by Phase 4
--
-- This proves only outcome-safe prospective snapshot evaluation. The repository does
-- not contain the external model-training pipeline, so training cutoff remains
-- explicitly unverified and release validation stays fail-closed.
--
-- Recovery:
-- - restore phase4.refresh_model_consensus() from
--   20261007140500_phase4_gate_value_on_model_validation.sql
-- - drop phase4.refresh_model_evaluation() and phase4.model_evaluation_current
--   only if this additive evaluation layer itself must be removed
-- - run select phase4.refresh_core();
-- Raw snapshots/results are not modified.

create table if not exists phase4.model_evaluation_current(
  model_key text primary key,
  evaluation_version text not null,
  evaluation_design text not null,
  capture_cutoff_minutes integer not null,
  settled_matches integer not null,
  first_kickoff timestamptz,
  last_kickoff timestamptz,
  first_capture timestamptz,
  last_capture timestamptz,
  avg_brier numeric,
  avg_rps numeric,
  avg_logloss numeric,
  top_pick_accuracy numeric,
  mean_top_probability numeric,
  top_calibration_gap numeric,
  training_cutoff_verified boolean not null default false,
  training_cutoff_status text not null,
  release_validation_status text not null,
  details jsonb not null default '{}'::jsonb,
  calculated_at timestamptz not null default now()
);

alter table phase4.model_evaluation_current enable row level security;

create or replace function phase4.refresh_model_evaluation()
returns integer
language plpgsql
set search_path to 'phase4','private','public','pg_temp'
as $function$
declare n integer;
begin
  delete from phase4.model_evaluation_current;

  insert into phase4.model_evaluation_current(
    model_key,evaluation_version,evaluation_design,capture_cutoff_minutes,
    settled_matches,first_kickoff,last_kickoff,first_capture,last_capture,
    avg_brier,avg_rps,avg_logloss,top_pick_accuracy,mean_top_probability,
    top_calibration_gap,training_cutoff_verified,training_cutoff_status,
    release_validation_status,details,calculated_at
  )
  with base as (
    select
      s.source_key,s.hkjc_event_id,s.captured_at,s.source_updated_at,
      s.prob_home::numeric ph,s.prob_draw::numeric pd,s.prob_away::numeric pa,
      r.match_id,r.outcome,r.kickoff_hkt,
      row_number() over (
        partition by s.source_key,s.hkjc_event_id
        order by s.captured_at desc
      ) rn
    from private.prematch_prediction_snapshot s
    join private.match_results r on r.hkjc_event_id=s.hkjc_event_id
    where s.market_key='1X2'
      and s.source_key in ('DC','PI','FOREBET')
      and s.prob_home is not null and s.prob_draw is not null and s.prob_away is not null
      and s.captured_at <= r.kickoff_hkt - interval '30 minutes'
      and (s.source_updated_at is null or s.source_updated_at <= r.kickoff_hkt)
      and r.outcome in ('H','D','A')
  ),
  latest as (
    select * from base where rn=1
  ),
  rows as (
    select source_key,hkjc_event_id,match_id,outcome,kickoff_hkt,captured_at,
           ph/(ph+pd+pa) ph,pd/(ph+pd+pa) pd,pa/(ph+pd+pa) pa
    from latest
    where ph>=0 and pd>=0 and pa>=0 and ph+pd+pa>0
  ),
  expanded as (
    select * from rows
    union all
    select
      'INTERNAL_BLEND',d.hkjc_event_id,d.match_id,d.outcome,d.kickoff_hkt,
      greatest(d.captured_at,p.captured_at),
      (d.ph+p.ph)/2.0,(d.pd+p.pd)/2.0,(d.pa+p.pa)/2.0
    from rows d
    join rows p using(hkjc_event_id,match_id,outcome,kickoff_hkt)
    where d.source_key='DC' and p.source_key='PI'
  ),
  scored as (
    select *,
      case outcome when 'H' then ph when 'D' then pd else pa end actual_prob,
      greatest(ph,pd,pa) top_prob,
      case when ph>=pd and ph>=pa then 'H'
           when pd>=ph and pd>=pa then 'D'
           else 'A' end top_pick,
      (
        power(ph-(outcome='H')::int,2)+
        power(pd-(outcome='D')::int,2)+
        power(pa-(outcome='A')::int,2)
      )/3.0 as brier,
      (
        power(ph-(outcome='H')::int,2)+
        power((ph+pd)-((outcome='H')::int+(outcome='D')::int),2)
      )/2.0 as rps
    from expanded
  ),
  agg as (
    select source_key,
      count(*) settled_matches,
      min(kickoff_hkt) first_kickoff,max(kickoff_hkt) last_kickoff,
      min(captured_at) first_capture,max(captured_at) last_capture,
      avg(brier) avg_brier,avg(rps) avg_rps,
      avg(-ln(greatest(actual_prob,0.000001))) avg_logloss,
      avg((top_pick=outcome)::int) top_pick_accuracy,
      avg(top_prob) mean_top_probability,
      avg(top_prob)-avg((top_pick=outcome)::int) top_calibration_gap
    from scored
    group by source_key
  )
  select
    source_key,
    'PHASE4_HDA_EVAL_V1',
    'PROSPECTIVE_SNAPSHOT_LATEST_AT_LEAST_30M_PREKICKOFF',
    30,
    settled_matches,first_kickoff,last_kickoff,first_capture,last_capture,
    avg_brier,avg_rps,avg_logloss,top_pick_accuracy,mean_top_probability,
    top_calibration_gap,
    false,
    'UNVERIFIED_EXTERNAL_MODEL_BUILD',
    'TRAINING_CUTOFF_UNVERIFIED',
    jsonb_build_object(
      'outcome_source','private.match_results',
      'prediction_source','private.prematch_prediction_snapshot',
      'probability_normalization','TRIPLET_SUM_TO_ONE',
      'outcome_leakage_guard','CAPTURE_AT_LEAST_30M_PREKICKOFF_AND_SOURCE_UPDATED_NO_LATER_THAN_KICKOFF',
      'training_cutoff_note','Model training pipeline/cutoff is not present in this repository, so training-data leakage cannot be independently excluded.',
      'coverage_days',greatest(1,(date(last_kickoff)-date(first_kickoff))+1),
      'release_ready',false
    ),
    now()
  from agg;

  get diagnostics n=row_count;
  return n;
end
$function$;

create or replace function phase4.refresh_model_consensus()
returns integer
language plpgsql
set search_path to 'phase4', 'public', 'pg_temp'
as $function$
declare n integer;
begin
  perform phase4.refresh_model_evaluation();
  delete from phase4.model_consensus_current;

  insert into phase4.model_consensus_current(
    match_id,market_key,selection_key,model_prob,source_count,source_probs,calculated_at
  )
  with b as (
    select
      m.match_id,p.model_source,p.fetched_at as internal_fetched_at,
      f.fetched_at as forebet_fetched_at,
      p.dc_prob_home,p.dc_prob_draw,p.dc_prob_away,
      p.pi_prob_home,p.pi_prob_draw,p.pi_prob_away,
      f.prob_home,f.prob_draw,f.prob_away,
      case when p.dc_prob_home is not null and p.dc_prob_draw is not null and p.dc_prob_away is not null
         and p.dc_prob_home>=0 and p.dc_prob_draw>=0 and p.dc_prob_away>=0
         and (p.dc_prob_home+p.dc_prob_draw+p.dc_prob_away)>0
        then p.dc_prob_home+p.dc_prob_draw+p.dc_prob_away end dc_sum,
      case when p.pi_prob_home is not null and p.pi_prob_draw is not null and p.pi_prob_away is not null
         and p.pi_prob_home>=0 and p.pi_prob_draw>=0 and p.pi_prob_away>=0
         and (p.pi_prob_home+p.pi_prob_draw+p.pi_prob_away)>0
        then p.pi_prob_home+p.pi_prob_draw+p.pi_prob_away end pi_sum,
      case when f.prob_home is not null and f.prob_draw is not null and f.prob_away is not null
         and f.prob_home>=0 and f.prob_draw>=0 and f.prob_away>=0
         and (f.prob_home+f.prob_draw+f.prob_away)>0
        then f.prob_home+f.prob_draw+f.prob_away end fb_sum
    from public.canonical_fixture_current m
    left join public.model_prediction_current p using(match_id)
    left join public.forebet_prediction_current f using(match_id)
    where m.kickoff_hkt>=now()-interval '6 hours'
      and m.kickoff_hkt<now()+interval '72 hours'
  ),
  methods as (
    select match_id,model_source,internal_fetched_at,forebet_fetched_at,'HOME'::text selection_key,
      case when dc_sum is not null then dc_prob_home/dc_sum end dc_p,
      case when pi_sum is not null then pi_prob_home/pi_sum end pi_p,
      case when fb_sum is not null then prob_home/fb_sum end fb_p from b
    union all
    select match_id,model_source,internal_fetched_at,forebet_fetched_at,'DRAW',
      case when dc_sum is not null then dc_prob_draw/dc_sum end,
      case when pi_sum is not null then pi_prob_draw/pi_sum end,
      case when fb_sum is not null then prob_draw/fb_sum end from b
    union all
    select match_id,model_source,internal_fetched_at,forebet_fetched_at,'AWAY',
      case when dc_sum is not null then dc_prob_away/dc_sum end,
      case when pi_sum is not null then pi_prob_away/pi_sum end,
      case when fb_sum is not null then prob_away/fb_sum end from b
  ),
  families as (
    select *,
      case when dc_p is not null and pi_p is not null then (dc_p+pi_p)/2.0
           else coalesce(dc_p,pi_p) end internal_p
    from methods
  ),
  counted as (
    select *,((internal_p is not null)::int+(fb_p is not null)::int) nsrc
    from families
  )
  select
    match_id,'HAD_1X2',selection_key,
    (coalesce(internal_p,0)+coalesce(fb_p,0))/nsrc,
    nsrc,
    jsonb_strip_nulls(jsonb_build_object(
      'internal',internal_p,'forebet',fb_p,
      'lineage',jsonb_strip_nulls(jsonb_build_object(
        'consensus_version','PHASE4_HDA_CONSENSUS_V4',
        'probability_contract','COMPLETE_NONNEGATIVE_HDA_NORMALIZED',
        'predictive_calibration_status','NOT_ESTABLISHED',
        'release_validation_status',coalesce(
          (select e.release_validation_status from phase4.model_evaluation_current e where e.model_key='INTERNAL_BLEND'),
          'NOT_ESTABLISHED'
        ),
        'internal_model_source',model_source,
        'internal_model_captured_at',internal_fetched_at,
        'forebet_captured_at',forebet_fetched_at,
        'internal_methods',case
          when dc_p is not null and pi_p is not null then jsonb_build_array('dixon_coles','pi')
          when dc_p is not null then jsonb_build_array('dixon_coles')
          when pi_p is not null then jsonb_build_array('pi')
          else null end,
        'independent_families',nsrc,
        'evaluation_version',(select e.evaluation_version from phase4.model_evaluation_current e where e.model_key='INTERNAL_BLEND'),
        'evaluation_evidence',jsonb_build_object(
          'internal_blend',(select to_jsonb(e)-'details' from phase4.model_evaluation_current e where e.model_key='INTERNAL_BLEND'),
          'dixon_coles',(select to_jsonb(e)-'details' from phase4.model_evaluation_current e where e.model_key='DC'),
          'pi',(select to_jsonb(e)-'details' from phase4.model_evaluation_current e where e.model_key='PI'),
          'forebet',(select to_jsonb(e)-'details' from phase4.model_evaluation_current e where e.model_key='FOREBET')
        )
      ))
    )),
    now()
  from counted
  where nsrc>0;

  get diagnostics n=row_count;
  return n;
end
$function$;

select phase4.refresh_core();
