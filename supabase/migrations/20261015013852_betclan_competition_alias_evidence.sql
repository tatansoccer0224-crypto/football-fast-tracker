-- Audited provider-specific competition-name equivalences. Source team names,
-- orientation, kickoff and unique fresh verified Flashscore identity remain
-- mandatory. The proof is retained alongside every mapping.
create table public.adviser_competition_alias_evidence (
  provider text not null check (provider in ('BETCLAN','SPORTYTRADER')),
  source_competition text not null check (length(trim(source_competition)) between 1 and 160),
  canonical_competition text not null check (length(trim(canonical_competition)) between 1 and 160),
  evidence jsonb not null check (jsonb_typeof(evidence)='object'),
  created_at timestamptz not null default now(),
  primary key (provider, source_competition, canonical_competition)
);
alter table public.adviser_competition_alias_evidence enable row level security;
revoke all on public.adviser_competition_alias_evidence from public,anon,authenticated;
grant select on public.adviser_competition_alias_evidence to service_role;

insert into public.adviser_competition_alias_evidence(provider,source_competition,canonical_competition,evidence) values
('BETCLAN','USA Major League Soccer','MLS',jsonb_build_object(
  'capture_run_id','38664994822','captured_at','2026-10-15T01:19:26.496447Z',
  'exact_event_examples',jsonb_build_array(jsonb_build_object('source_event_id','1490539','flashscore_match_id','FS:EeGYoNWg','home','Los Angeles Galaxy','away','Portland Timbers','kickoff_delta_seconds',0,'source_url','https://www.betclan.com/predictionsdetails/football/1490539/los-angeles-galaxy-v-portland-timbers-prediction-h2h-tip-and-match-preview/')))),
('BETCLAN','Republic of Ireland First Division','Division 1',jsonb_build_object(
  'capture_run_id','38664994822','captured_at','2026-10-15T01:19:26.496447Z',
  'exact_event_examples',jsonb_build_array(
    jsonb_build_object('source_event_id','1492996','flashscore_match_id','FS:86k7n8t3','home','Kerry','away','Cork City','kickoff_delta_seconds',0,'source_url','https://www.betclan.com/predictionsdetails/football/1492996/kerry-v-cork-city-prediction-h2h-tip-and-match-preview/'),
    jsonb_build_object('source_event_id','1492998','flashscore_match_id','FS:xnsOrQuS','home','Treaty United','away','Cobh Ramblers','kickoff_delta_seconds',0,'source_url','https://www.betclan.com/predictionsdetails/football/1492998/treaty-united-v-cobh-ramblers-prediction-h2h-tip-and-match-preview/')))),
('BETCLAN','Argentina Liga Profesional Argentina','Liga Profesional - Clausura',jsonb_build_object(
  'capture_run_id','38664994822','captured_at','2026-10-15T01:19:26.496447Z',
  'exact_event_examples',jsonb_build_array(jsonb_build_object('source_event_id','1493190','flashscore_match_id','FS:IwKcV6fm','home','Huracan','away','Gimnasia L.P.','kickoff_delta_seconds',0,'source_url','https://www.betclan.com/predictionsdetails/football/1493190/huracan-v-gimnasia-l.p.-prediction-h2h-tip-and-match-preview/')))),
('BETCLAN','Denmark 1. Division','1st Division',jsonb_build_object(
  'capture_run_id','38664994822','captured_at','2026-10-15T01:19:26.496447Z',
  'exact_event_examples',jsonb_build_array(jsonb_build_object('source_event_id','1551354','flashscore_match_id','FS:MDhApi1T','home','Aarhus Fremad','away','Esbjerg','kickoff_delta_seconds',0,'source_url','https://www.betclan.com/predictionsdetails/football/1551354/aarhus-fremad-v-esbjerg-prediction-h2h-tip-and-match-preview/')))),
('BETCLAN','Hungary NB I','NB I.',jsonb_build_object(
  'capture_run_id','38664994822','captured_at','2026-10-15T01:19:26.496447Z',
  'exact_event_examples',jsonb_build_array(jsonb_build_object('source_event_id','1560257','flashscore_match_id','FS:dWrAonbm','home','MTK Budapest','away','Vasas','kickoff_delta_seconds',0,'source_url','https://www.betclan.com/predictionsdetails/football/1560257/mtk-budapest-v-vasas-prediction-h2h-tip-and-match-preview/')))),
('BETCLAN','Peru Primera División','Liga 1 - Clausura',jsonb_build_object(
  'capture_run_id','38664994822','captured_at','2026-10-15T01:19:26.496447Z',
  'exact_event_examples',jsonb_build_array(jsonb_build_object('source_event_id','1549516','flashscore_match_id','FS:EN504pS8','home','Sport Huancayo','away','Cusco','kickoff_delta_seconds',0,'source_url','https://www.betclan.com/predictionsdetails/football/1549516/sport-huancayo-v-cusco-prediction-h2h-tip-and-match-preview/')))),
('BETCLAN','Spain Segunda División','LaLiga2',jsonb_build_object(
  'capture_run_id','38664994822','captured_at','2026-10-15T01:19:26.496447Z',
  'exact_event_examples',jsonb_build_array(jsonb_build_object('source_event_id','1569978','flashscore_match_id','FS:juLO6Tte','home','Leganes','away','Cordoba','kickoff_delta_seconds',0,'source_url','https://www.betclan.com/predictionsdetails/football/1569978/leganes-v-cordoba-prediction-h2h-tip-and-match-preview/'))))
on conflict (provider,source_competition,canonical_competition) do nothing;

-- Provider-scoped matcher; keep the older four-argument function available for
-- compatibility while the authenticated ingestion and current view use this.
create function public.ft_adviser_exact_candidates(
  p_provider text,p_home text,p_away text,p_competition text,p_kickoff timestamptz
)
returns table(match_id text)
language sql stable security invoker set search_path=public,pg_temp as $$
  select f.match_id
  from public.flashscore_primary_fixture_current f
  where f.identity_authority='FLASHSCORE'
    and f.provider_identity_status='VERIFIED_IDENTITY'
    and f.status='SCHEDULED'
    and f.kickoff_hkt>now()
    and f.fetched_at between now()-interval '36 hours' and now()+interval '1 minute'
    and abs(extract(epoch from f.kickoff_hkt-p_kickoff))<=60
    and lower(trim(f.home_en))=lower(trim(p_home))
    and lower(trim(f.away_en))=lower(trim(p_away))
    and (
      lower(trim(p_competition))=lower(trim(f.league))
      or right(lower(trim(p_competition)),length(trim(f.league))+1)=' '||lower(trim(f.league))
      or exists (
        select 1 from public.adviser_competition_alias_evidence a
        where upper(trim(a.provider))=upper(trim(p_provider))
          and lower(trim(a.source_competition))=lower(trim(p_competition))
          and lower(trim(a.canonical_competition))=lower(trim(f.league))
      )
    )
$$;
revoke all on function public.ft_adviser_exact_candidates(text,text,text,text,timestamptz) from public,anon,authenticated;
grant execute on function public.ft_adviser_exact_candidates(text,text,text,text,timestamptz) to service_role;

-- Preserve the authenticated idempotent upsert and allow a same-artifact replay
-- to update only a changed exact identity verdict.
create or replace function public.ft_ingest_adviser_observations(p_rows jsonb,p_run_id text)
returns jsonb language plpgsql security invoker set search_path=public,pg_temp as $$
declare r jsonb; at timestamptz; kick timestamptz; ids text[]; rev text; inserted integer:=0; rejected integer:=0; matched integer:=0; n integer;
begin
 if p_rows is null or jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows)>240 or coalesce(p_run_id,'') !~ '^[0-9]{6,20}$' then
  raise exception 'INVALID_ENVELOPE';
 end if;
 for r in select value from jsonb_array_elements(p_rows) loop
  begin
   if coalesce(r->>'source','') not in ('BETCLAN','SPORTYTRADER') or coalesce(r->>'source_event_id','') !~ '^[0-9]{1,12}$'
      or coalesce(length(r->>'home'),0) not between 1 and 160 or coalesce(length(r->>'away'),0) not between 1 and 160
      or not coalesce(((r->>'source'='BETCLAN' and r->>'source_url' ~ '^https://www\.betclan\.com/predictionsdetails/football/[0-9]+/[^?#]+/$')
        or (r->>'source'='SPORTYTRADER' and r->>'source_url' ~ '^https://www\.sportytrader\.com/en/betting-tips/[^/?#]+-[0-9]+/$')),false) then raise exception 'INVALID_SOURCE'; end if;
   at:=(r->>'captured_at')::timestamptz;
   if at is null or at<now()-interval '36 hours' or at>now()+interval '1 minute' then raise exception 'INVALID_CAPTURE_TIME'; end if;
   if r->'hda' is not null and r->'hda'<>'null'::jsonb then
    if not coalesce((jsonb_typeof(r#>'{hda,home}')='number' and jsonb_typeof(r#>'{hda,draw}')='number' and jsonb_typeof(r#>'{hda,away}')='number'
       and (r#>>'{hda,home}')::numeric between 0 and 1 and (r#>>'{hda,draw}')::numeric between 0 and 1 and (r#>>'{hda,away}')::numeric between 0 and 1
       and abs((r#>>'{hda,home}')::numeric+(r#>>'{hda,draw}')::numeric+(r#>>'{hda,away}')::numeric-1)<=0.025),false) then raise exception 'INVALID_PROBABILITIES'; end if;
   end if;
   if r->>'source'='BETCLAN' and coalesce(r->>'parser_version','')<>'betclan-v2-structured-event' then raise exception 'UNSAFE_PARSER_VERSION'; end if;
   if (r->>'source'='BETCLAN' and substring(r->>'source_url' from '/football/([0-9]+)/')<>r->>'source_event_id')
    or (r->>'source'='SPORTYTRADER' and substring(r->>'source_url' from '-([0-9]+)/$')<>r->>'source_event_id') then raise exception 'EVENT_URL_MISMATCH'; end if;
   if r->>'predicted_score' is not null and r->>'predicted_score' !~ '^[0-9]{1,2}-[0-9]{1,2}$' then raise exception 'INVALID_SCORE'; end if;
   if r->>'over25' is not null and not coalesce(jsonb_typeof(r->'over25')='number' and (r->>'over25')::numeric between 0 and 1,false) then raise exception 'INVALID_GOALS'; end if;
   if r->>'btts_yes' is not null and not coalesce(jsonb_typeof(r->'btts_yes')='number' and (r->>'btts_yes')::numeric between 0 and 1,false) then raise exception 'INVALID_BTTS'; end if;
   kick:=null;
   if r->>'kickoff_timezone_verified'='true' and r->>'source_kickoff' ~ '(Z|[+-][0-9]{2}:[0-9]{2})$' then kick:=(r->>'source_kickoff')::timestamptz; end if;
   select array_agg(c.match_id) into ids from public.ft_adviser_exact_candidates(r->>'source',r->>'home',r->>'away',r->>'source_competition',kick) c;
   rev:=md5((r-'captured_at'-'raw_content_hash'-'identity'-'canonical_event_id')::text);
   insert into public.adviser_source_observations values(
    r->>'source',r->>'source_event_id',rev,r->>'source_url',r->>'home',r->>'away',r->>'source_competition',kick,at,at,
    case when cardinality(ids)=1 then ids[1] end,case when cardinality(ids)=1 then 'VERIFIED' else 'UNMATCHED' end,r,p_run_id)
   on conflict(provider,source_event_id,revision) do update set
    source_kickoff=excluded.source_kickoff,
    captured_at=case when excluded.captured_at>=adviser_source_observations.captured_at then excluded.captured_at else adviser_source_observations.captured_at end,
    last_seen_at=greatest(adviser_source_observations.last_seen_at,excluded.last_seen_at),
    canonical_event_id=excluded.canonical_event_id,
    identity_status=excluded.identity_status,
    observation=case when excluded.captured_at>=adviser_source_observations.captured_at then excluded.observation else adviser_source_observations.observation end,
    run_id=case when excluded.captured_at>=adviser_source_observations.captured_at then excluded.run_id else adviser_source_observations.run_id end
   where excluded.last_seen_at>adviser_source_observations.last_seen_at
      or (excluded.captured_at>=adviser_source_observations.captured_at
          and (excluded.canonical_event_id is distinct from adviser_source_observations.canonical_event_id
               or excluded.identity_status is distinct from adviser_source_observations.identity_status));
   get diagnostics n=row_count; inserted:=inserted+n;
   if cardinality(ids)=1 then matched:=matched+1; end if;
  exception when others then rejected:=rejected+1;
  end;
 end loop;
 return jsonb_build_object('accepted',jsonb_array_length(p_rows)-rejected,'rejected',rejected,'changed',inserted,'matched',matched);
end $$;
revoke all on function public.ft_ingest_adviser_observations(jsonb,text) from public,anon,authenticated;
grant execute on function public.ft_ingest_adviser_observations(jsonb,text) to service_role;

create or replace view public.adviser_prediction_current with (security_invoker=true) as
with latest as (
 select distinct on(provider,source_event_id) * from public.adviser_source_observations
 order by provider,source_event_id,last_seen_at desc,captured_at desc,revision
)
select o.* from latest o
where o.identity_status='VERIFIED' and o.last_seen_at>=now()-interval '36 hours'
 and o.source_kickoff>now() and o.observation->>'source_event_status' in ('https://schema.org/EventScheduled','http://schema.org/EventScheduled')
 and (select array_agg(c.match_id) from public.ft_adviser_exact_candidates(o.provider,o.source_home,o.source_away,o.source_competition,o.source_kickoff) c)=array[o.canonical_event_id];
revoke all on public.adviser_prediction_current from public,anon,authenticated;
grant select on public.adviser_prediction_current to service_role;
