-- Phase35 repairs missing identity fields in the in-query fixture projection.
-- Phase34 is safely rolled back live until this version is applied.
-- Phase 34 migration repair: adds existing calibrated SportyTrader source names.
-- No model writes, alias inserts or newly claimed source-clock verification.
-- Phase 33: read-only, on-demand, HKT-dated alias matrix.
-- Existing Flashscore fixtures remain the sole canonical identity.
-- No new capture, scheduled DB writes, speculative joins or model promotion.
create or replace function public.ft_daily_alias_audit(p_hkt_date date)
returns jsonb
language plpgsql stable security definer
set search_path = pg_catalog, public, private, pg_temp
as $fn$
declare
  v_today date := (now() at time zone 'Asia/Hong_Kong')::date;
  v_result jsonb;
begin
  if p_hkt_date is null or p_hkt_date < v_today-7 or p_hkt_date > v_today+7 then
    raise exception 'HKT_DATE_OUT_OF_BOUNDS' using errcode='22023';
  end if;
  with fixtures as materialized (
    select f.match_id, f.kickoff_hkt, f.league, f.home_en, f.away_en,
      f.identity_authority, f.provider_identity_status
    from public.flashscore_primary_fixture_current f
    where f.kickoff_hkt >= (p_hkt_date::timestamp at time zone 'Asia/Hong_Kong')
      and f.kickoff_hkt < ((p_hkt_date + 1)::timestamp at time zone 'Asia/Hong_Kong')
      and f.match_id ~ '^FS:[A-Za-z0-9_-]{5,32}$'
    order by f.kickoff_hkt,f.match_id limit 800
  ), candidates as (
    select p.canonical_event_id id, 'FOREBET' provider, p.forebet_home_team home,
      p.forebet_away_team away, p.forebet_league_short source_league,
      p.forebet_detail_url url, 'SOURCE_LINKED' link_state,p.fetched_at seen_at
    from public.forebet_prediction_current p
    join fixtures f on f.match_id=p.canonical_event_id
    where p.forebet_home_team is not null and p.forebet_away_team is not null
      and p.forebet_detail_url like 'https://www.forebet.com/en/football/matches/%'
    union all
    select p.canonical_event_id,'FOREBET',p.source_home,p.source_away,
      p.canonical_league,p.source_url,'PROVISIONAL',p.last_seen_at
    from public.forebet_provisional_feed_current p
    join fixtures f on f.match_id=p.canonical_event_id
    where p.advisory_status='PROVISIONAL_ONE_SIDE_NOT_VERIFIED'
      and p.last_seen_at>=now()-interval '3 days'
      and not exists(select 1 from public.forebet_prediction_current x
        where x.canonical_event_id=p.canonical_event_id)
    union all
    select p.canonical_event_id,p.provider,p.source_home,p.source_away,
      p.source_competition,p.source_url,'SOURCE_LINKED',p.captured_at
    from public.adviser_prediction_current p
    join fixtures f on f.match_id=p.canonical_event_id
    where p.provider in ('BETCLAN','SPORTYTRADER')
      and p.identity_status='VERIFIED'
      and p.source_home is not null and p.source_away is not null
    union all
    select p.canonical_event_id,p.provider,p.source_home,p.source_away,
      p.source_competition,p.source_url,'PROVISIONAL',p.source_captured_at
    from private.ft_adviser_provisional_05 p
    join fixtures f on f.match_id=p.canonical_event_id
    where p.provider in ('BETCLAN','SPORTYTRADER')
      and p.state='PROVISIONAL' and p.disconnected_at is null
      and p.last_checked_at >= now()-interval '4 days'
      and not exists(select 1 from public.adviser_prediction_current x
        where x.canonical_event_id=p.canonical_event_id and x.provider=p.provider)

    union all
    -- Unverified provider wall-clock translated from six independent source-clock anchors.
    -- This is a review-only identity link, never a verified kickoff or prediction.
    select p.canonical_event_id,'SPORTYTRADER',p.source_home,p.source_away,
      p.source_competition,p.source_url,'PROVISIONAL',p.source_captured_at
    from private.ft_sportytrader_calibrated_05 p
    join fixtures f on f.match_id=p.canonical_event_id
    where p.state='PROVISIONAL'
      and p.last_checked_at>=now()-interval '4 days'
      and p.source_captured_at<=now()
      and p.predicted_kickoff>now()
      and abs(extract(epoch from (p.predicted_kickoff-f.kickoff_hkt)))<=60
      and p.calibration_samples>=4 and p.calibration_agreement>=0.9
      and p.home_similarity>=0.25 and p.away_similarity>=0.25
      and p.league_similarity>=0.5
      and f.identity_authority='FLASHSCORE'
      and f.provider_identity_status='VERIFIED_IDENTITY'
      and p.source_url ~ '^https://www[.]sportytrader[.]com/en/betting-tips/[^/?#]+-[0-9]+/$'
      and not exists (
        select 1 from private.ft_adviser_pair_rejections rejected
        where rejected.provider='SPORTYTRADER'
          and rejected.canonical_event_id=p.canonical_event_id
          and rejected.source_url=p.source_url)
      and not exists (
        select 1 from public.adviser_prediction_current verified
        where verified.provider='SPORTYTRADER'
          and verified.canonical_event_id=p.canonical_event_id
          and verified.identity_status='VERIFIED')
    union all
    select p.canonical_event_id,p.provider,s.source_home,s.source_away,
      s.source_competition,s.source_url,'PROVISIONAL',s.captured_at
    from private.ft_extra_adviser_provisional_04 p
    join fixtures f on f.match_id=p.canonical_event_id
    join lateral (
      select s.source_home,s.source_away,s.source_competition,s.source_url,s.captured_at
      from private.ft_extra_adviser_source_observations s
      where s.provider=p.provider and s.source_event_id=p.source_event_id
        and s.source_date=p.source_date
      order by s.captured_at desc limit 1
    ) s on true
    where p.provider in ('PRIMATIPS','STATAREA')
      and p.last_checked_at >= now()-interval '4 days'
  ), clean as (
    select id,provider,btrim(home) home,btrim(away) away,source_league,url,
      link_state,seen_at,
      row_number() over(partition by id,provider,url
        order by case when link_state='SOURCE_LINKED' then 0 else 1 end,seen_at desc) duplicate_rank
    from candidates
    where length(btrim(coalesce(home,''))) between 1 and 120
      and length(btrim(coalesce(away,''))) between 1 and 120
      and url ~ '^https://'
  ), limited as (
    select id,provider,home,away,source_league,url,link_state,seen_at,
      row_number() over(partition by id,provider
        order by case when link_state='SOURCE_LINKED' then 0 else 1 end, seen_at desc,url) candidate_rank
    from clean where duplicate_rank=1
  ), grouped as (
    select id,provider,jsonb_agg(jsonb_build_object(
      'home',home,'away',away,'league',source_league,'url',url,
      'state',link_state,'capturedAt',seen_at) order by candidate_rank) candidates
    from limited where candidate_rank<=4
    group by id,provider
  ), by_fixture as (
    select id,jsonb_object_agg(provider,candidates) advisers
    from grouped group by id
  )
  select jsonb_build_object(
    'hktDate', p_hkt_date,
    'generatedAt', now(),
    'timezone', 'Asia/Hong_Kong',
    'providers',jsonb_build_array('FOREBET','PRIMATIPS','STATAREA','BETCLAN','SPORTYTRADER'),
    'rows',coalesce(jsonb_agg(jsonb_build_object(
      'id',f.match_id,'kickoff',f.kickoff_hkt,'league',f.league,
      'home',f.home_en,'away',f.away_en,
      'advisers',coalesce(b.advisers,'{}'::jsonb))
      order by f.kickoff_hkt,f.match_id),'[]'::jsonb)
  )
  into v_result
  from fixtures f left join by_fixture b on b.id=f.match_id;
  return coalesce(v_result,'{}'::jsonb);
end;
$fn$;
-- Only the controlled Edge service uses the RPC. Never grant browser clients SQL execution.
revoke all on function public.ft_daily_alias_audit(date) from PUBLIC,anon,authenticated;
grant execute on function public.ft_daily_alias_audit(date) to service_role;


-- Run a REAL invocation during deployment so unresolved CTE fields roll back
-- the migration rather than breaking the public daily API after CI passes.
DO $phase35_smoke$
DECLARE
  v_result jsonb;
BEGIN
  v_result:=public.ft_daily_alias_audit((now() at time zone 'Asia/Hong_Kong')::date);
  IF v_result IS NULL OR jsonb_typeof(v_result->'rows') <> 'array'
     OR jsonb_typeof(v_result->'providers') <> 'array'
     OR v_result->>'timezone' <> 'Asia/Hong_Kong' THEN
    RAISE EXCEPTION 'PHASE35_DAILY_MATRIX_RUNTIME_SMOKE_FAILED';
  END IF;
END;
$phase35_smoke$;
