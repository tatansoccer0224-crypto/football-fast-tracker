-- Create missing canonical fixtures directly from verified Flashscore raw IDs.
-- This removes the need for a bookmaker discovery before a genuine adviser can match.
create or replace function private.ft_stage_adviser_flashscore_fixture(
 p_provider text,p_home text,p_away text,p_competition text,p_kickoff timestamptz)
returns integer language plpgsql security invoker set search_path=public,private,pg_temp as $$
declare ids text[]; n_added integer;
begin
 if p_provider<>'SPORTYTRADER' or p_kickoff is null or p_competition is null then return 0; end if;
 select array_agg(n.external_event_id) into ids
 from private.ft_native_flashscore_events n
 join public.phase15_source_shadow_current s on s.source_key='FLASHSCORE' and s.external_event_id=n.external_event_id
 where public.ft_team_name_key(n.home_name)=public.ft_team_name_key(p_home)
 and public.ft_team_name_key(n.away_name)=public.ft_team_name_key(p_away)
 and abs(extract(epoch from n.kickoff_utc-p_kickoff))<=60
 and n.kickoff_utc>now() and n.kickoff_utc<now()+interval '48 hours'
 and n.fetched_at between now()-interval '45 minutes' and now()+interval '1 minute'
 and s.raw->>'AB'='1' and (s.match_id is null or s.match_id='FS:'||n.external_event_id)
 and (lower(trim(p_competition))=lower(trim(n.league_name))
 or right(lower(trim(p_competition)),length(trim(n.league_name))+1)=' '||lower(trim(n.league_name))
 or exists(select 1 from public.adviser_competition_alias_evidence a where upper(a.provider)=upper(p_provider)
 and lower(trim(a.source_competition))=lower(trim(p_competition)) and lower(trim(a.canonical_competition))=lower(trim(n.league_name))))
 and not exists(select 1 from public.fixture_identity_redirects r where r.source_match_id='FS:'||n.external_event_id and r.active);
 if cardinality(ids) is distinct from 1 then return 0; end if;
 insert into public.matches(canonical_event_id,canonical_match_id,kickoff_hkt,status,tournament,
 home_en,away_en,in_play,selling,fetched_at,source_updated_at,raw,updated_at)
 select 'FS:'||n.external_event_id,n.external_event_id,n.kickoff_utc,'PREEVENT',n.league_name,
 n.home_name,n.away_name,false,false,n.fetched_at,n.fetched_at,
 jsonb_build_object('source','FLASHSCORE','identity_origin','DIRECT_PROVIDER_ID_FROM_EXISTING_SHADOW',
 'provider_event_id',n.external_event_id,'source_fetched_at',n.fetched_at,'trigger','VERIFIED_ADVISER_CANDIDATE'),now()
 from private.ft_native_flashscore_events n where n.external_event_id=ids[1]
 on conflict(canonical_event_id) do nothing;
 get diagnostics n_added=row_count;
 update public.phase15_source_shadow_current s set match_id='FS:'||s.external_event_id,
 identity_status='VERIFIED_IDENTITY',match_confidence=0.995
 where s.source_key='FLASHSCORE' and s.external_event_id=ids[1]
 and (s.match_id is null or s.match_id='FS:'||s.external_event_id)
 and (s.match_id is distinct from 'FS:'||s.external_event_id or s.identity_status is distinct from 'VERIFIED_IDENTITY');
 return n_added;
end $$;
revoke all on function private.ft_stage_adviser_flashscore_fixture(text,text,text,text,timestamptz) from public,anon,authenticated;
grant execute on function private.ft_stage_adviser_flashscore_fixture(text,text,text,text,timestamptz) to service_role;
CREATE OR REPLACE FUNCTION public.ft_adviser_exact_candidates(p_provider text, p_home text, p_away text, p_competition text, p_kickoff timestamp with time zone)
 RETURNS TABLE(match_id text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with aliases as materialized (
   select public.ft_alias_super_lookup(case upper(p_provider) when 'BETCLAN' then 'BCL' when 'SPORTYTRADER' then 'STA' else upper(p_provider) end,p_home,p_competition) home_alias,
          public.ft_alias_super_lookup(case upper(p_provider) when 'BETCLAN' then 'BCL' when 'SPORTYTRADER' then 'STA' else upper(p_provider) end,p_away,p_competition) away_alias
  )
  select f.match_id
  from public.flashscore_primary_fixture_current f
  join private.ft_native_flashscore_events n on n.external_event_id=substring(f.match_id from 4)
  cross join aliases a
  where f.identity_authority='FLASHSCORE'
    and f.provider_identity_status='VERIFIED_IDENTITY'
    and f.status='SCHEDULED'
    and f.kickoff_hkt>now()
    and f.fetched_at between now()-interval '36 hours' and now()+interval '1 minute'
    and abs(extract(epoch from f.kickoff_hkt-p_kickoff))<=60
    and ((public.ft_team_name_key(f.home_en)=public.ft_team_name_key(p_home) and public.ft_team_name_key(f.away_en)=public.ft_team_name_key(p_away))
      or (a.home_alias->>'status'='VERIFIED' and a.away_alias->>'status'='VERIFIED'
      and a.home_alias->>'verified_team_key'='FS_TEAM:'||n.home_external_id
      and a.away_alias->>'verified_team_key'='FS_TEAM:'||n.away_external_id))
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
$function$;
CREATE OR REPLACE FUNCTION public.ft_ingest_adviser_observations(p_rows jsonb, p_run_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
   if r->>'source'='SPORTYTRADER' and kick is not null then
    if not coalesce(r->>'parser_version'='sportytrader-v2-linked-sportsevent'
      and r->>'raw_content_hash' ~ '^[a-f0-9]{64}$' and r->>'related_content_hash' ~ '^[a-f0-9]{64}$'
      and r->>'related_source_url' ~ '^https://www[.]sportytrader[.]com/en/results-live/[^/?#]+-[0-9]+/$'
      and r#>>'{related_event_evidence,url}'=r->>'related_source_url'
      and (r#>>'{related_event_evidence,startDate}')::timestamptz=kick
      and lower(trim(r#>>'{related_event_evidence,homeTeam,name}'))=lower(trim(r->>'home'))
      and lower(trim(r#>>'{related_event_evidence,awayTeam,name}'))=lower(trim(r->>'away'))
      and r#>>'{related_event_evidence,organizer,name}'=r->>'source_competition',false)
    then raise exception 'UNSAFE_SPORTY_EVENT_EVIDENCE'; end if;
    perform private.ft_stage_adviser_flashscore_fixture(r->>'source',r->>'home',r->>'away',r->>'source_competition',kick);
   end if;
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
end $function$;

create or replace view private.ft_native_team_alias_evidence with (security_invoker=true) as
 WITH fs AS (
         SELECT ft_native_flashscore_events.external_event_id,
            ft_native_flashscore_events.home_external_id,
            ft_native_flashscore_events.away_external_id,
            ft_native_flashscore_events.league_external_id,
            ft_native_flashscore_events.home_name,
            ft_native_flashscore_events.away_name,
            ft_native_flashscore_events.league_name,
            ft_native_flashscore_events.kickoff_utc,
            ft_native_flashscore_events.fetched_at
           FROM private.ft_native_flashscore_events
        ), provider_events AS (
         SELECT 'FLASHSCORE'::text AS source,
            fs.external_event_id AS source_event_id,
            fs.external_event_id AS fs_event_id,
            fs.home_name AS source_home,
            fs.away_name AS source_away,
            fs.home_external_id AS provider_home_id,
            fs.away_external_id AS provider_away_id,
            fs.league_name AS source_competition,
            fs.fetched_at AS captured_at,
            NULL::text AS source_url,
            fs.home_external_id,
            fs.away_external_id,
            fs.league_external_id
           FROM fs
        UNION ALL
         SELECT
                CASE a.provider
                    WHEN 'BETCLAN'::text THEN 'BCL'::text
                    WHEN 'SPORTYTRADER'::text THEN 'STA'::text
                    ELSE NULL::text
                END AS "case",
            a.source_event_id,
            f.external_event_id,
            a.source_home,
            a.source_away,
            ''::text,
            ''::text,
            a.source_competition,
            a.captured_at,
            a.source_url,
            f.home_external_id,
            f.away_external_id,
            f.league_external_id
           FROM adviser_source_observations a
             JOIN fs f ON a.canonical_event_id = ('FS:'::text || f.external_event_id)
          WHERE a.identity_status = 'VERIFIED'::text AND (a.provider = ANY (ARRAY['BETCLAN'::text, 'SPORTYTRADER'::text])) AND abs(EXTRACT(epoch FROM a.source_kickoff - f.kickoff_utc)) <= 60::numeric AND public.ft_team_name_key(a.source_home) = public.ft_team_name_key(f.home_name) AND public.ft_team_name_key(a.source_away) = public.ft_team_name_key(f.away_name) AND a.captured_at <= f.kickoff_utc AND a.captured_at <= (now() + '00:01:00'::interval)
        UNION ALL
         SELECT s.source_key,
            s.external_event_id,
            f.external_event_id,
            s.home_name,
            s.away_name,
            COALESCE(s.home_external_id, ''::text) AS "coalesce",
            COALESCE(s.away_external_id, ''::text) AS "coalesce",
            s.league_name,
            s.fetched_at,
            s.raw ->> 'source_url'::text,
            f.home_external_id,
            f.away_external_id,
            f.league_external_id
           FROM phase15_source_shadow_current s
             JOIN fs f ON s.match_id = ('FS:'::text || f.external_event_id)
          WHERE (s.source_key = ANY (ARRAY['FOREBET'::text, 'FOTMOB'::text, 'SOFASCORE'::text, 'FOOTBALL_DATA'::text])) AND (s.identity_status = ANY (ARRAY['VERIFIED_IDENTITY'::text, 'VERIFIED'::text, 'EXACT_PAIR'::text])) AND abs(EXTRACT(epoch FROM s.kickoff_utc - f.kickoff_utc)) <= 60::numeric AND lower(TRIM(BOTH FROM s.home_name)) = lower(TRIM(BOTH FROM f.home_name)) AND lower(TRIM(BOTH FROM s.away_name)) = lower(TRIM(BOTH FROM f.away_name)) AND s.fetched_at <= (now() + '00:01:00'::interval)
        )
 SELECT p.source,
    p.source_event_id,
    p.fs_event_id,
    p.source_competition,
    p.captured_at,
    p.source_url,
    x.side,
    x.source_name,
    x.provider_team_id,
    x.flashscore_team_id,
    p.league_external_id
   FROM provider_events p
     CROSS JOIN LATERAL ( VALUES ('HOME'::text,p.source_home,p.provider_home_id,p.home_external_id), ('AWAY'::text,p.source_away,p.provider_away_id,p.away_external_id)) x(side, source_name, provider_team_id, flashscore_team_id);
create or replace view public.adviser_prediction_current with (security_invoker=true) as
with latest as (
 select distinct on(provider,source_event_id) * from public.adviser_source_observations
 order by provider,source_event_id,last_seen_at desc,captured_at desc,
 (observation->>'parser_version'='sportytrader-v2-linked-sportsevent') desc nulls last,
 (identity_status='VERIFIED') desc,revision
)
select o.* from latest o
where o.identity_status='VERIFIED' and o.last_seen_at>=now()-interval '36 hours'
 and o.source_kickoff>now()
 and (o.observation->>'source_event_status' in ('https://schema.org/EventScheduled','http://schema.org/EventScheduled')
  or (o.provider='SPORTYTRADER' and o.observation->>'parser_version'='sportytrader-v2-linked-sportsevent'
   and o.observation->>'kickoff_timezone_verified'='true' and o.observation->>'source_event_status' is null
   and (nullif(trim(o.observation->>'tip'),'') is not null or jsonb_typeof(o.observation->'hda')='object')))
 and (select array_agg(c.match_id) from public.ft_adviser_exact_candidates(o.provider,o.source_home,o.source_away,o.source_competition,o.source_kickoff) c)=array[o.canonical_event_id];
