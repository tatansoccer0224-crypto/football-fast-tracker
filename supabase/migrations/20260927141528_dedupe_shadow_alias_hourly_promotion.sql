
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
    select source,trim(home_name) alias,trim(home_en) canonical,match_confidence,fetched_at from canon
    where nullif(trim(home_name),'') is not null and nullif(trim(home_en),'') is not null
    union all
    select source,trim(away_name),trim(away_en),match_confidence,fetched_at from canon
    where nullif(trim(away_name),'') is not null and nullif(trim(away_en),'') is not null
  ),
  consensus as (
    select
      source,
      alias,
      count(distinct public.ft_team_name_key(canonical)) target_count,
      (array_agg(canonical order by match_confidence desc,fetched_at desc))[1] canonical,
      max(match_confidence) confidence,
      min(fetched_at) first_seen,
      max(fetched_at) last_seen,
      count(*) evidence_count
    from pairs
    group by source,alias
  ),
  up as (
    insert into public.team_aliases(
      source,alias,canonical_hkjc_name,confidence,
      first_seen_hkt,last_seen_hkt,match_count,status,alias_source,updated_at
    )
    select
      source,alias,canonical,confidence,
      coalesce(first_seen,now()),coalesce(last_seen,now()),greatest(1,evidence_count),
      'ACTIVE','PHASE1_SHADOW_HIGH_CONF',now()
    from consensus
    where target_count=1
    on conflict(source,alias) do update set
      canonical_hkjc_name=case
        when excluded.confidence>=public.team_aliases.confidence then excluded.canonical_hkjc_name
        else public.team_aliases.canonical_hkjc_name end,
      confidence=greatest(public.team_aliases.confidence,excluded.confidence),
      first_seen_hkt=least(public.team_aliases.first_seen_hkt,excluded.first_seen_hkt),
      last_seen_hkt=greatest(public.team_aliases.last_seen_hkt,excluded.last_seen_hkt),
      match_count=greatest(public.team_aliases.match_count,excluded.match_count),
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

revoke all on function public.ft_ingest_shadow_alias_evidence_v2() from public,anon,authenticated;
grant execute on function public.ft_ingest_shadow_alias_evidence_v2() to postgres,service_role;
