
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA extensions;

CREATE TABLE IF NOT EXISTS private.ft_adviser_provisional_05 (
  provider text NOT NULL CHECK (provider IN ('BETCLAN','SPORTYTRADER')),
  source_event_id text NOT NULL,
  source_revision text NOT NULL,
  canonical_event_id text NOT NULL CHECK (canonical_event_id LIKE 'FS:%'),
  source_url text NOT NULL,
  source_home text NOT NULL,
  source_away text NOT NULL,
  source_competition text NOT NULL,
  canonical_home text NOT NULL,
  canonical_away text NOT NULL,
  canonical_competition text NOT NULL,
  source_kickoff timestamptz NOT NULL,
  home_similarity numeric(6,4) NOT NULL CHECK (home_similarity >= 0.5 AND home_similarity <= 1),
  away_similarity numeric(6,4) NOT NULL CHECK (away_similarity >= 0.5 AND away_similarity <= 1),
  league_evidence text NOT NULL CHECK (league_evidence IN ('CORROBORATED','NEEDS_REVIEW')),
  state text NOT NULL CHECK (state IN ('PROVISIONAL','DISCONNECTED','EXPIRED','SUPERSEDED_BY_VERIFIED')),
  reason text NOT NULL,
  source_captured_at timestamptz NOT NULL,
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  last_checked_at timestamptz NOT NULL DEFAULT now(),
  disconnected_at timestamptz,
  PRIMARY KEY (provider,source_event_id)
);
COMMENT ON TABLE private.ft_adviser_provisional_05 IS
'Unpublished, reversible team-name >=0.5 adviser/Flashscore candidate evidence. Never treated as VERIFIED, and never included in betting forecasts unless independently verified.';
CREATE INDEX IF NOT EXISTS ft_adviser_provisional_05_state_idx
 ON private.ft_adviser_provisional_05 (state, source_kickoff);
ALTER TABLE private.ft_adviser_provisional_05 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.ft_adviser_provisional_05 FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.ft_recheck_adviser_provisional_05()
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER
SET search_path TO pg_catalog,public,private,extensions
AS $body$
DECLARE n_upserted int := 0; n_closed int := 0;
BEGIN
  WITH latest AS (
    SELECT DISTINCT ON (o.provider,o.source_event_id)
       o.provider,o.source_event_id,o.revision,o.source_url,o.source_home,o.source_away,
       o.source_competition,o.source_kickoff,o.captured_at,o.identity_status
    FROM public.adviser_source_observations o
    WHERE o.provider IN ('BETCLAN','SPORTYTRADER')
      AND o.source_kickoff > now()
      AND o.source_kickoff < now()+interval '72 hours'
    ORDER BY o.provider,o.source_event_id,o.last_seen_at DESC,o.captured_at DESC
  ), pairs AS (
    SELECT o.*, f.match_id, f.home_en, f.away_en, f.league,
      extensions.similarity(extensions.unaccent(lower(o.source_home)),
                            extensions.unaccent(lower(f.home_en)))::numeric hs,
      extensions.similarity(extensions.unaccent(lower(o.source_away)),
                            extensions.unaccent(lower(f.away_en)))::numeric aw,
      CASE WHEN lower(trim(o.source_competition))=lower(trim(f.league))
        OR lower(trim(o.source_competition)) LIKE ('% '||lower(trim(f.league)))
        OR EXISTS (
          SELECT 1 FROM public.adviser_competition_alias_evidence a
          WHERE upper(a.provider)=o.provider
            AND lower(trim(a.source_competition))=lower(trim(o.source_competition))
            AND lower(trim(a.canonical_competition))=lower(trim(f.league))
        ) THEN 'CORROBORATED' ELSE 'NEEDS_REVIEW' END league_status
    FROM latest o
    JOIN public.flashscore_primary_fixture_current f
      ON abs(extract(epoch FROM f.kickoff_hkt-o.source_kickoff)) <= 60
      AND f.kickoff_hkt>now()
      AND f.fetched_at>=now()-interval '36 hours'
      AND f.status='SCHEDULED'
      AND f.identity_authority='FLASHSCORE'
      AND f.provider_identity_status='VERIFIED_IDENTITY'
    WHERE o.identity_status='UNMATCHED'
       AND o.source_url IS NOT NULL AND o.source_competition IS NOT NULL
  ), thresholded AS (
    SELECT * FROM pairs WHERE hs>=0.5 AND aw>=0.5
  ), unique_pairs AS (
    SELECT t.*,
      count(*) over(partition by provider,source_event_id) source_n,
      count(*) over(partition by provider,match_id) target_n
    FROM thresholded t
  ), accepted AS (
    SELECT * FROM unique_pairs WHERE source_n=1 AND target_n=1
  )
  INSERT INTO private.ft_adviser_provisional_05
    (provider,source_event_id,source_revision,canonical_event_id,source_url,
     source_home,source_away,source_competition,
     canonical_home,canonical_away,canonical_competition,
     source_kickoff,home_similarity,away_similarity,league_evidence,
     state,reason,source_captured_at)
  SELECT provider,source_event_id,revision,match_id,source_url,
     source_home,source_away,source_competition,home_en,away_en,league,
     source_kickoff,hs,aw,league_status,
     'PROVISIONAL','0.5_NAME_BOTH_SIDES_EXACT_TIME_UNIQUE_UNVERIFIED',captured_at
  FROM accepted
  ON CONFLICT (provider,source_event_id) DO UPDATE SET
    source_revision=EXCLUDED.source_revision,
    canonical_event_id=EXCLUDED.canonical_event_id,
    source_url=EXCLUDED.source_url,
    source_home=EXCLUDED.source_home,
    source_away=EXCLUDED.source_away,
    source_competition=EXCLUDED.source_competition,
    canonical_home=EXCLUDED.canonical_home,
    canonical_away=EXCLUDED.canonical_away,
    canonical_competition=EXCLUDED.canonical_competition,
    source_kickoff=EXCLUDED.source_kickoff,
    home_similarity=EXCLUDED.home_similarity,
    away_similarity=EXCLUDED.away_similarity,
    league_evidence=EXCLUDED.league_evidence,
    state='PROVISIONAL',reason=EXCLUDED.reason,
    source_captured_at=EXCLUDED.source_captured_at,
    last_checked_at=now(),disconnected_at=NULL
  WHERE EXCLUDED.source_captured_at>=private.ft_adviser_provisional_05.source_captured_at;
  GET DIAGNOSTICS n_upserted = ROW_COUNT;

  UPDATE private.ft_adviser_provisional_05 c
    SET state=CASE
          WHEN EXISTS (SELECT 1 FROM public.adviser_source_observations v
                WHERE v.provider=c.provider AND v.source_event_id=c.source_event_id
                  AND v.identity_status='VERIFIED'
                  AND v.canonical_event_id=c.canonical_event_id)
          THEN 'SUPERSEDED_BY_VERIFIED'
          WHEN c.source_kickoff<=now() THEN 'EXPIRED'
          ELSE 'DISCONNECTED' END,
        reason=CASE
          WHEN c.source_kickoff<=now() THEN 'EVENT_STARTED_ARCHIVED_FOR_REVIEW'
          ELSE 'NOT_QUALIFIED_BY_CURRENT_SOURCE_CANONICAL_RECHECK' END,
        disconnected_at=now(),last_checked_at=now()
  WHERE c.state='PROVISIONAL'
    AND (
      c.source_kickoff<=now()
      OR NOT EXISTS (
         SELECT 1 FROM public.adviser_source_observations s
         JOIN public.flashscore_primary_fixture_current f
           ON f.match_id=c.canonical_event_id
          AND f.status='SCHEDULED'
          AND f.kickoff_hkt>now()
          AND f.fetched_at>=now()-interval '36 hours'
          AND f.identity_authority='FLASHSCORE'
          AND f.provider_identity_status='VERIFIED_IDENTITY'
         WHERE s.provider=c.provider AND s.source_event_id=c.source_event_id
           AND s.revision=c.source_revision
           AND s.identity_status='UNMATCHED'
           AND abs(extract(epoch FROM s.source_kickoff-f.kickoff_hkt))<=60
           AND extensions.similarity(extensions.unaccent(lower(s.source_home)),
                                     extensions.unaccent(lower(f.home_en)))>=0.5
           AND extensions.similarity(extensions.unaccent(lower(s.source_away)),
                                     extensions.unaccent(lower(f.away_en)))>=0.5
      )
    );
  GET DIAGNOSTICS n_closed = ROW_COUNT;

  RETURN jsonb_build_object('threshold',0.5,'upserted',n_upserted,
    'closed',n_closed,'provisional_remaining',
    (SELECT count(*) FROM private.ft_adviser_provisional_05 WHERE state='PROVISIONAL'),
    'verification','PROVISIONAL_ONLY_NO_PUBLIC_VERIFIED_PROMOTION');
END;
$body$;
REVOKE ALL ON FUNCTION private.ft_recheck_adviser_provisional_05() FROM PUBLIC, anon, authenticated;

SELECT cron.schedule('ft-adviser-fuzzy-provisional-recheck','40 7 * * *',
  $$SELECT private.ft_recheck_adviser_provisional_05();$$);
