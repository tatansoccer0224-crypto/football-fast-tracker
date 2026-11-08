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
    and ((lower(trim(f.home_en))=lower(trim(p_home)) and lower(trim(f.away_en))=lower(trim(p_away)))
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
$function$
