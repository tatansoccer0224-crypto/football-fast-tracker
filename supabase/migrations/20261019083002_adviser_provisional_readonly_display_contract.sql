
CREATE OR REPLACE VIEW public.adviser_accepted_display_current
WITH (security_invoker = true)
AS
WITH latest AS (
  SELECT DISTINCT ON (o.provider, o.source_event_id)
    o.provider,
    o.source_event_id,
    o.revision,
    o.source_url,
    o.source_home,
    o.source_away,
    o.source_competition,
    o.source_kickoff,
    o.captured_at,
    o.last_seen_at,
    o.observation,
    o.run_id
  FROM public.adviser_source_observations AS o
  ORDER BY o.provider, o.source_event_id, o.last_seen_at DESC,
           o.captured_at DESC, o.revision DESC
),
candidate AS (
  SELECT
    o.*,
    p.canonical_event_id,
    p.league_evidence,
    p.home_similarity,
    p.away_similarity,
    p.last_checked_at,
    COUNT(*) OVER (PARTITION BY p.provider, p.source_event_id) AS source_candidate_count,
    COUNT(*) OVER (PARTITION BY p.provider, p.canonical_event_id) AS fixture_candidate_count
  FROM private.ft_adviser_provisional_05 AS p
  JOIN latest AS o
    ON o.provider = p.provider
   AND o.source_event_id = p.source_event_id
  JOIN public.flashscore_primary_fixture_current AS f
    ON f.match_id = p.canonical_event_id
  WHERE p.state = 'PROVISIONAL'
    AND p.disconnected_at IS NULL
    AND p.canonical_event_id LIKE 'FS:%'
    AND p.home_similarity >= 0.25
    AND p.away_similarity >= 0.25
    AND p.home_similarity + p.away_similarity >= 1.15
    AND p.league_evidence IN ('CORROBORATED', 'NEEDS_REVIEW')
    AND ABS(EXTRACT(EPOCH FROM (p.source_kickoff - f.kickoff_hkt))) <= 60
    AND ABS(EXTRACT(EPOCH FROM (o.source_kickoff - f.kickoff_hkt))) <= 60
    AND p.source_kickoff > NOW()
    AND p.source_kickoff < NOW() + INTERVAL '48 hours'
    AND p.last_checked_at >= NOW() - INTERVAL '48 hours'
    AND o.last_seen_at >= NOW() - INTERVAL '48 hours'
    AND o.observation->>'source_event_status' IN
        ('https://schema.org/EventScheduled', 'http://schema.org/EventScheduled')
    AND JSONB_TYPEOF(o.observation->'hda') = 'object'
    AND JSONB_TYPEOF(o.observation->'hda'->'home') = 'number'
    AND JSONB_TYPEOF(o.observation->'hda'->'draw') = 'number'
    AND JSONB_TYPEOF(o.observation->'hda'->'away') = 'number'
    AND NOT EXISTS (
      SELECT 1
      FROM private.ft_adviser_pair_rejections AS r
      WHERE r.provider = p.provider
        AND r.canonical_event_id = p.canonical_event_id
        AND r.source_url = p.source_url
    )
)
SELECT
  c.provider,
  c.source_event_id,
  c.revision,
  c.source_url,
  c.source_home,
  c.source_away,
  c.source_competition,
  c.source_kickoff,
  c.captured_at,
  c.last_seen_at,
  c.canonical_event_id,
  'ACCEPTED_PROVISIONAL'::text AS identity_status,
  c.observation,
  c.run_id
FROM candidate AS c
WHERE c.source_candidate_count = 1
  AND c.fixture_candidate_count = 1
  AND (
      (c.observation->'hda'->>'home')::numeric BETWEEN 0 AND 1
      AND (c.observation->'hda'->>'draw')::numeric BETWEEN 0 AND 1
      AND (c.observation->'hda'->>'away')::numeric BETWEEN 0 AND 1
      AND (
        (c.observation->'hda'->>'home')::numeric +
        (c.observation->'hda'->>'draw')::numeric +
        (c.observation->'hda'->>'away')::numeric
      ) BETWEEN 0.98 AND 1.02
  );
REVOKE ALL ON public.adviser_accepted_display_current FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.adviser_accepted_display_current TO service_role;
