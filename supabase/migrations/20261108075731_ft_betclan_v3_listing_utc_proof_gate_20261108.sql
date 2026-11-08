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
   if r->>'source'='BETCLAN' then
    if coalesce(r->>'parser_version','') not in ('betclan-v2-structured-event',
       'betclan-v3-listing-utc-crosscheck') then
      raise exception 'UNSAFE_PARSER_VERSION';
    end if;
    if r->>'parser_version'='betclan-v3-listing-utc-crosscheck' then
      if coalesce(r->>'source_clock_basis','') in
         ('LISTING_UTC_CORROBORATED','LISTING_UTC_CONFIRMED_DETAIL_CLOCK_CONFLICT') then
        if not coalesce(
          r->>'source_listing_kickoff' ~ '^20[0-9]{2}-[01][0-9]-[0-3][0-9]T([01][0-9]|2[0-3]):[0-5][0-9]:00Z$'
          and r->>'source_kickoff' ~ '[+]00:00$'
          and r->>'source_timezone'='+00:00'
          and r->>'kickoff_timezone_verified'='true'
          and r->>'raw_content_hash' ~ '^[a-f0-9]{64}$'
          and length(coalesce(r->>'source_competition',''))>0
          and left(r->>'source_listing_kickoff',10)=r->>'source_date'
          and substring(r->>'source_listing_kickoff' from 12 for 5)=r->>'source_wall_time'
        ,false) then raise exception 'BETCLAN_LISTING_EVIDENCE_INVALID'; end if;
        if (r->>'source_listing_kickoff')::timestamptz is distinct from
           (r->>'source_kickoff')::timestamptz then
          raise exception 'BETCLAN_LISTING_UTC_MISMATCH';
        end if;
        if r->>'source_clock_basis'='LISTING_UTC_CONFIRMED_DETAIL_CLOCK_CONFLICT' then
          if not coalesce(
             r->>'source_detail_kickoff' ~ '[+-][0-9]{2}:[0-9]{2}$'
             and r->>'source_clock_disagreement_minutes' in ('60','-60')
             and left(r->>'source_listing_kickoff',16)=left(r->>'source_detail_kickoff',16)
          ,false) then raise exception 'BETCLAN_DETAIL_CONFLICT_EVIDENCE_INVALID'; end if;
          if round(extract(epoch from
            ((r->>'source_listing_kickoff')::timestamptz-
             (r->>'source_detail_kickoff')::timestamptz))/60)::int
               <> (r->>'source_clock_disagreement_minutes')::int then
            raise exception 'BETCLAN_DETAIL_OFFSET_CONFLICT';
          end if;
        elsif r->>'source_detail_kickoff' is not null and
           (r->>'source_detail_kickoff')::timestamptz is distinct from
           (r->>'source_kickoff')::timestamptz then
          raise exception 'BETCLAN_DETAIL_CLOCK_NOT_CORROBORATED';
        end if;
      elsif r->>'source_clock_basis'='DETAIL_STRUCTURED_EVENT' then
        if not coalesce(r->>'source_detail_kickoff'=r->>'source_kickoff'
           and r->>'source_kickoff' ~ '(Z|[+-][0-9]{2}:[0-9]{2})$',false) then
          raise exception 'BETCLAN_DETAIL_CLOCK_EVIDENCE_INVALID';
        end if;
      elsif r->>'source_clock_basis' in
         ('CLOCK_UNVERIFIED','LISTING_DETAIL_CLOCK_CONFLICT_UNRESOLVED') then
        if r->>'source_kickoff' is not null
           or r->>'kickoff_timezone_verified'='true' then
          raise exception 'BETCLAN_UNVERIFIED_CLOCK_LEAK';
        end if;
      else
        raise exception 'BETCLAN_UNKNOWN_CLOCK_BASIS';
      end if;
    end if;
   end if;
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
end $function$
