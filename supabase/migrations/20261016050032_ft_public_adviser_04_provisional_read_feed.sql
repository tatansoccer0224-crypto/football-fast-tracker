
CREATE OR REPLACE FUNCTION public.ft_public_adviser_provisional_candidates()
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path TO pg_catalog,public,private
AS $body$
  WITH qualified AS (
    SELECT
      c.provider,c.canonical_event_id,c.source_event_id,c.source_revision,
      c.source_home,c.source_away,c.canonical_home,c.canonical_away,
      c.canonical_competition,c.source_url,c.source_kickoff,c.source_captured_at,
      c.last_checked_at,c.home_similarity,c.away_similarity,c.league_evidence,
      o.observation,
      count(*) OVER (PARTITION BY c.provider,c.canonical_event_id) AS competing_provisional
    FROM private.ft_adviser_provisional_05 c
    JOIN public.adviser_source_observations o
      ON o.provider=c.provider AND o.source_event_id=c.source_event_id
     AND o.revision=c.source_revision AND o.identity_status='UNMATCHED'
     AND o.source_url=c.source_url AND o.source_kickoff=c.source_kickoff
    JOIN public.flashscore_primary_fixture_current f
      ON f.match_id=c.canonical_event_id
      AND f.status='SCHEDULED'
      AND f.identity_authority='FLASHSCORE'
      AND f.provider_identity_status='VERIFIED_IDENTITY'
      AND f.fetched_at>=now()-interval '36 hours'
      AND f.kickoff_hkt>now()
      AND abs(extract(epoch FROM f.kickoff_hkt-c.source_kickoff))<=60
    WHERE c.state='PROVISIONAL'
      AND c.provider IN ('BETCLAN','SPORTYTRADER')
      AND c.canonical_event_id~'^FS:[A-Za-z0-9_-]{5,32}$'
      AND c.source_kickoff>now()
      AND c.source_kickoff<now()+interval '48 hours'
      AND c.last_checked_at>=now()-interval '36 hours'
      AND c.last_checked_at<=now()+interval '1 minute'
      AND c.source_captured_at>=now()-interval '48 hours'
      AND c.source_captured_at<=now()
      AND c.home_similarity>=0.4
      AND c.away_similarity>=0.4
      AND c.home_similarity<=1
      AND c.away_similarity<=1
      AND (
        (c.provider='BETCLAN'
          AND c.source_url ~ '^https://www[.]betclan[.]com/predictionsdetails/football/[0-9]+/[^?#]+/$')
        OR (c.provider='SPORTYTRADER'
          AND c.source_url ~ '^https://www[.]sportytrader[.]com/en/betting-tips/[^/?#]+-[0-9]+/$')
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.adviser_source_observations v
        WHERE v.provider=c.provider AND v.canonical_event_id=c.canonical_event_id
          AND v.identity_status='VERIFIED'
      )
  ), safe AS (
    SELECT * FROM qualified
    WHERE competing_provisional=1
    ORDER BY source_kickoff,provider,canonical_event_id
    LIMIT 180
  ), rows AS (
    SELECT jsonb_build_object(
      'id',canonical_event_id,
      'provider',provider,
      'status','PROVISIONAL_NOT_VERIFIED',
      'sourceHome',source_home,'sourceAway',source_away,
      'canonicalHome',canonical_home,'canonicalAway',canonical_away,
      'league',canonical_competition,
      'kickoff',source_kickoff,
      'sourceUrl',source_url,
      'sourceCapturedAt',source_captured_at,
      'lastChecked',last_checked_at,
      'homeSimilarity',home_similarity,
      'awaySimilarity',away_similarity,
      'leagueEvidence',league_evidence,
      'hda',CASE
        WHEN jsonb_typeof(observation->'hda')='object'
         AND (observation#>>'{hda,home}') ~ '^(0([.][0-9]+)?|1([.]0+)?)$'
         AND (observation#>>'{hda,draw}') ~ '^(0([.][0-9]+)?|1([.]0+)?)$'
         AND (observation#>>'{hda,away}') ~ '^(0([.][0-9]+)?|1([.]0+)?)$'
         AND abs(((observation#>>'{hda,home}')::numeric+
                  (observation#>>'{hda,draw}')::numeric+
                  (observation#>>'{hda,away}')::numeric)-1)<0.02
        THEN observation->'hda' ELSE NULL END,
      'predictedScore',CASE WHEN observation->>'predicted_score' ~ '^[0-9]{1,2}-[0-9]{1,2}$'
        THEN observation->>'predicted_score' ELSE NULL END,
      'over25',CASE WHEN jsonb_typeof(observation->'over25')='number'
        AND (observation->>'over25')::numeric BETWEEN 0 AND 1
        THEN observation->'over25' ELSE NULL END,
      'bttsYes',CASE WHEN jsonb_typeof(observation->'btts_yes')='number'
        AND (observation->>'btts_yes')::numeric BETWEEN 0 AND 1
        THEN observation->'btts_yes' ELSE NULL END,
      'tip',CASE WHEN length(observation->>'tip')<=100
        THEN observation->>'tip' ELSE NULL END
    ) AS value
    FROM safe
  )
  SELECT jsonb_build_object(
    'source','ADVISER_PROVISIONAL_FLASHscore_0_4',
    'quality','PROVISIONAL_NOT_VERIFIED',
    'generatedAt',now(),
    'rows',coalesce(jsonb_agg(value),'[]'::jsonb)
  ) FROM rows;
$body$;

REVOKE ALL ON FUNCTION public.ft_public_adviser_provisional_candidates()
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ft_public_adviser_provisional_candidates()
  TO service_role;
COMMENT ON FUNCTION public.ft_public_adviser_provisional_candidates()
  IS 'Bounded sanitized read-only 0.4 adviser candidates for Edge; only service_role may execute; never promotes identities.';
