-- Publish already-stored Football-Data last-five context for one exact Flashscore fixture.
-- Private service-to-service use only. Never use fuzzy team matching or the retired providers.
CREATE OR REPLACE FUNCTION public.ft_detail_historical_form_by_id(p_match_id text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  WITH fixture AS MATERIALIZED (
    SELECT f.match_id, f.kickoff_hkt, f.league, f.home_en, f.away_en
    FROM public.flashscore_primary_fixture_current AS f
    WHERE f.match_id=p_match_id
      AND p_match_id ~ '^FS:[A-Za-z0-9_-]{5,32}$'
      AND f.identity_authority='FLASHSCORE'
      AND f.provider_identity_status='VERIFIED_IDENTITY'
      AND f.kickoff_hkt BETWEEN now()-interval '3 hours' AND now()+interval '48 hours'
      AND (
        f.league <> 'Premier League'
        OR EXISTS (
          SELECT 1
          FROM public.phase15_source_shadow_current AS shadow
          WHERE shadow.source_key='FLASHSCORE'
            AND shadow.match_id=f.match_id
            AND shadow.league_external_id='SY30SsKF'
            AND shadow.league_name='Premier League'
            AND shadow.identity_status='VERIFIED_IDENTITY'
            AND shadow.fetched_at>=now()-interval '7 days'
            AND shadow.kickoff_utc IS NOT NULL
            AND abs(extract(epoch FROM shadow.kickoff_utc-f.kickoff_hkt))<=60
            AND shadow.home_name=f.home_en
            AND shadow.away_name=f.away_en
            AND shadow.raw->>'AB'='1'
        )
      )
    LIMIT 1
  )
  SELECT jsonb_build_object(
    'matchId', f.match_id,
    'home', public.ft_historical_form_by_team(f.home_en,f.league,f.kickoff_hkt),
    'away', public.ft_historical_form_by_team(f.away_en,f.league,f.kickoff_hkt)
  ) FROM fixture AS f;
$$;
REVOKE ALL ON FUNCTION public.ft_detail_historical_form_by_id(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ft_detail_historical_form_by_id(text) TO service_role;
