
create or replace function phase4.refresh_value_opportunities()
returns integer
language plpgsql
set search_path to 'phase4','public','pg_temp'
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
      'source_probs',source_probs,
      'market_implied_pct',round((devig_prob*100)::numeric,2),
      'model_pct',round((model_prob*100)::numeric,2),
      'fair_odds_decimal',case when model_prob>0 then round((1.0/model_prob)::numeric,3) else null end,
      'market_quote_count',quote_count,
      'market_complete',case when market_key='HAD_1X2' then (quote_count=3 and home_quotes=1 and draw_quotes=1 and away_quotes=1) else true end,
      'min_model_sources_for_value',min_sources,
      'value_quote_freshness_seconds',fresh_seconds
    )
  from calc;

  get diagnostics n=row_count;
  return n;
end
$function$;
