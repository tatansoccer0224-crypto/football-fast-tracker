
ALTER TABLE private.ft_adviser_provisional_05
 DROP CONSTRAINT ft_adviser_provisional_05_home_similarity_check,
 DROP CONSTRAINT ft_adviser_provisional_05_away_similarity_check;
ALTER TABLE private.ft_adviser_provisional_05
 ADD CONSTRAINT ft_adviser_provisional_05_home_similarity_check
  CHECK(home_similarity>=0.4 and home_similarity<=1),
 ADD CONSTRAINT ft_adviser_provisional_05_away_similarity_check
  CHECK(away_similarity>=0.4 and away_similarity<=1);
COMMENT ON TABLE private.ft_adviser_provisional_05 IS
'Historical table name _05; current team match threshold is 0.4 in both directions. Only provisional, reversible, no verified or public forecast promotion.';
CREATE OR REPLACE FUNCTION private.ft_recheck_adviser_provisional_05()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public', 'private', 'extensions'
AS $function$
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
    SELECT * FROM pairs WHERE hs>=0.4 AND aw>=0.4
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
     'PROVISIONAL','0.4_NAME_BOTH_SIDES_EXACT_TIME_UNIQUE_UNVERIFIED',captured_at
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
                                     extensions.unaccent(lower(f.home_en)))>=0.4
           AND extensions.similarity(extensions.unaccent(lower(s.source_away)),
                                     extensions.unaccent(lower(f.away_en)))>=0.4
      )
    );
  GET DIAGNOSTICS n_closed = ROW_COUNT;

  RETURN jsonb_build_object('threshold',0.4,'upserted',n_upserted,
    'closed',n_closed,'provisional_remaining',
    (SELECT count(*) FROM private.ft_adviser_provisional_05 WHERE state='PROVISIONAL'),
    'verification','PROVISIONAL_ONLY_NO_PUBLIC_VERIFIED_PROMOTION');
END;
$function$
;
