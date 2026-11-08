-- Version and structurally validate the Phase 4 HDA probability/value contract.
--
-- Goals:
-- 1. Treat only complete non-negative H/D/A triplets as usable model-family evidence.
-- 2. Normalize every accepted family to a proper H/D/A distribution before consensus.
-- 3. Preserve the existing independence rule: Dixon-Coles + Pi are one internal family.
-- 4. Publish explicit calculation/version metadata with fair prices and edge.
-- 5. Do not claim predictive calibration: structural probability validation is distinct
--    from out-of-sample model validation.
--
-- Recovery:
-- - Restore phase4.refresh_model_consensus() from
--   20261007011800_phase4_collapse_correlated_model_methods.sql.
-- - Restore phase4.refresh_value_opportunities() from the preceding production
--   definition recorded in repository/production checkpoint.
-- - Run select phase4.refresh_core().
-- No provider quote, fixture, prediction or historical evidence rows are modified.

create or replace function phase4.refresh_model_consensus()
returns integer
language plpgsql
set search_path to 'phase4', 'public', 'pg_temp'
as $function$
declare n integer;
begin
  delete from phase4.model_consensus_current;

  insert into phase4.model_consensus_current(
    match_id,market_key,selection_key,model_prob,source_count,source_probs,calculated_at
  )
  with b as (
    select
      m.match_id,
      p.model_source,
      p.dc_prob_home,p.dc_prob_draw,p.dc_prob_away,
      p.pi_prob_home,p.pi_prob_draw,p.pi_prob_away,
      f.prob_home,f.prob_draw,f.prob_away,
      case
        when p.dc_prob_home is not null and p.dc_prob_draw is not null and p.dc_prob_away is not null
         and p.dc_prob_home>=0 and p.dc_prob_draw>=0 and p.dc_prob_away>=0
         and (p.dc_prob_home+p.dc_prob_draw+p.dc_prob_away)>0
        then p.dc_prob_home+p.dc_prob_draw+p.dc_prob_away
      end as dc_sum,
      case
        when p.pi_prob_home is not null and p.pi_prob_draw is not null and p.pi_prob_away is not null
         and p.pi_prob_home>=0 and p.pi_prob_draw>=0 and p.pi_prob_away>=0
         and (p.pi_prob_home+p.pi_prob_draw+p.pi_prob_away)>0
        then p.pi_prob_home+p.pi_prob_draw+p.pi_prob_away
      end as pi_sum,
      case
        when f.prob_home is not null and f.prob_draw is not null and f.prob_away is not null
         and f.prob_home>=0 and f.prob_draw>=0 and f.prob_away>=0
         and (f.prob_home+f.prob_draw+f.prob_away)>0
        then f.prob_home+f.prob_draw+f.prob_away
      end as fb_sum
    from public.canonical_fixture_current m
    left join public.model_prediction_current p using(match_id)
    left join public.forebet_prediction_current f using(match_id)
    where m.kickoff_hkt>=now()-interval '6 hours'
      and m.kickoff_hkt<now()+interval '72 hours'
  ),
  methods as (
    select match_id,model_source,'HOME'::text selection_key,
      case when dc_sum is not null then dc_prob_home/dc_sum end dc_p,
      case when pi_sum is not null then pi_prob_home/pi_sum end pi_p,
      case when fb_sum is not null then prob_home/fb_sum end fb_p
    from b
    union all
    select match_id,model_source,'DRAW',
      case when dc_sum is not null then dc_prob_draw/dc_sum end,
      case when pi_sum is not null then pi_prob_draw/pi_sum end,
      case when fb_sum is not null then prob_draw/fb_sum end
    from b
    union all
    select match_id,model_source,'AWAY',
      case when dc_sum is not null then dc_prob_away/dc_sum end,
      case when pi_sum is not null then pi_prob_away/pi_sum end,
      case when fb_sum is not null then prob_away/fb_sum end
    from b
  ),
  families as (
    select *,
      case
        when dc_p is not null and pi_p is not null then (dc_p+pi_p)/2.0
        else coalesce(dc_p,pi_p)
      end as internal_p
    from methods
  ),
  counted as (
    select *,
      ((internal_p is not null)::int + (fb_p is not null)::int) as nsrc
    from families
  )
  select
    match_id,'HAD_1X2',selection_key,
    (coalesce(internal_p,0)+coalesce(fb_p,0))/nsrc,
    nsrc,
    jsonb_strip_nulls(jsonb_build_object(
      'internal',internal_p,
      'forebet',fb_p,
      'lineage',jsonb_strip_nulls(jsonb_build_object(
        'consensus_version','PHASE4_HDA_CONSENSUS_V2',
        'probability_contract','COMPLETE_NONNEGATIVE_HDA_NORMALIZED',
        'predictive_calibration_status','NOT_ESTABLISHED',
        'internal_model_source',model_source,
        'internal_methods',case
          when dc_p is not null and pi_p is not null then jsonb_build_array('dixon_coles','pi')
          when dc_p is not null then jsonb_build_array('dixon_coles')
          when pi_p is not null then jsonb_build_array('pi')
          else null
        end,
        'independent_families',nsrc
      ))
    )),
    now()
  from counted
  where nsrc>0;

  get diagnostics n=row_count;
  return n;
end
$function$;

create or replace function phase4.refresh_value_opportunities()
returns integer
language plpgsql
set search_path to 'phase4', 'public', 'pg_temp'
as $function$
declare
  n integer;
  min_ev numeric:=coalesce((select (config_value#>>'{}')::numeric from phase4.engine_config where config_key='min_value_ev_pct'),2.0);
  min_sources integer:=coalesce((select (config_value#>>'{}')::integer from phase4.engine_config where config_key='min_model_sources_for_value'),2);
  fresh_seconds integer:=coalesce((select (config_value#>>'{}')::integer from phase4.engine_config where config_key='value_quote_freshness_seconds'),1800);
begin
  delete from phase4.value_opportunities_current;

  insert into phase4.value_opportunities_current(
    match_id,market_key,period_key,line_key,selection_key,provider_id,
    odds_decimal,effective_odds_decimal,model_prob,market_prob_raw,market_prob_devig,
    market_overround,probability_edge_pct,expected_roi_pct,model_source_count,
    quote_age_seconds,status,calculated_at,details
  )
  with q as (
    select mq.*,
      sum(1.0/mq.odds_decimal) over(
        partition by mq.provider_id,mq.match_id,mq.market_key,mq.period_key,mq.line_key
      ) as overround,
      sum(case when mq.selection_key='HOME' then 1 else 0 end) over(
        partition by mq.provider_id,mq.match_id,mq.market_key,mq.period_key,mq.line_key
      ) as home_quotes,
      sum(case when mq.selection_key='DRAW' then 1 else 0 end) over(
        partition by mq.provider_id,mq.match_id,mq.market_key,mq.period_key,mq.line_key
      ) as draw_quotes,
      sum(case when mq.selection_key='AWAY' then 1 else 0 end) over(
        partition by mq.provider_id,mq.match_id,mq.market_key,mq.period_key,mq.line_key
      ) as away_quotes,
      count(*) over(
        partition by mq.provider_id,mq.match_id,mq.market_key,mq.period_key,mq.line_key
      ) as quote_count
    from phase4.market_quotes_current mq
    where mq.active=true
      and mq.match_id is not null
      and mq.compatibility_verified=true
  ),
  calc as (
    select q.*,c.model_prob,c.source_count,c.source_probs,
      1.0/q.odds_decimal raw_prob,
      (1.0/q.odds_decimal)/q.overround devig_prob,
      (c.model_prob-((1.0/q.odds_decimal)/q.overround))*100 edge_pct,
      (c.model_prob*q.effective_odds_decimal-1.0)*100 ev_pct,
      extract(epoch from (now()-coalesce(q.source_ts,q.fetched_at))) age_seconds
    from q
    join phase4.model_consensus_current c
      on c.match_id=q.match_id
     and c.market_key=q.market_key
     and c.selection_key=q.selection_key
    where q.overround is not null
      and q.overround>0
      and (
        q.market_key <> 'HAD_1X2'
        or (q.quote_count=3 and q.home_quotes=1 and q.draw_quotes=1 and q.away_quotes=1)
      )
  )
  select
    match_id,market_key,period_key,line_key,selection_key,provider_id,
    odds_decimal,effective_odds_decimal,model_prob,raw_prob,devig_prob,
    overround,edge_pct,ev_pct,source_count,age_seconds,
    case
      when age_seconds>fresh_seconds then 'STALE'
      when source_count<min_sources then 'LOW_COVERAGE'
      when ev_pct>=min_ev then 'VALUE'
      when ev_pct>0 then 'WATCH'
      else 'NO_EDGE'
    end,
    now(),
    jsonb_build_object(
      'calculation_version','PHASE4_HDA_VALUE_V2',
      'source_probs',source_probs,
      'probability_contract',source_probs->'lineage'->>'probability_contract',
      'predictive_calibration_status',coalesce(source_probs->'lineage'->>'predictive_calibration_status','NOT_ESTABLISHED'),
      'market_probability_method','PROPORTIONAL_DEVIG',
      'fair_odds_method','RECIPROCAL_MODEL_PROBABILITY',
      'edge_method','MODEL_PROB_MINUS_DEVIG_MARKET_PROB',
      'expected_roi_method','MODEL_PROB_TIMES_EFFECTIVE_ODDS_MINUS_ONE',
      'market_implied_pct',round((devig_prob*100)::numeric,2),
      'model_pct',round((model_prob*100)::numeric,2),
      'fair_odds_decimal',case when model_prob>0 then round((1.0/model_prob)::numeric,3) else null end,
      'market_quote_count',quote_count,
      'market_complete',case when market_key='HAD_1X2' then (quote_count=3 and home_quotes=1 and draw_quotes=1 and away_quotes=1) else true end,
      'evidence_coverage_status',case when source_count>=min_sources then 'MULTI_FAMILY' else 'LOW_COVERAGE' end,
      'min_model_sources_for_value',min_sources,
      'value_quote_freshness_seconds',fresh_seconds
    )
  from calc;

  get diagnostics n=row_count;
  return n;
end
$function$;

select phase4.refresh_core();
