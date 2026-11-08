-- Phase 14: existing SportyTrader tips ALREADY have date+wall time. This
-- derives a source-page offset ONLY from multiple independently proved
-- linked SportyTrader events in a >=2-date cohort. These matches stay review-only.
-- No new source requests, no cron, no synthetic bookmaker/model probabilities.
BEGIN;
-- Calibrated wall times are NOT independently source-verified kickoff.
-- One-to-one review candidates only, never used for model/backtest accuracy.
CREATE TABLE IF NOT EXISTS private.ft_sportytrader_calibrated_05 (
  provider text NOT NULL DEFAULT 'SPORTYTRADER' CHECK(provider='SPORTYTRADER'),
  source_event_id text NOT NULL,
  source_revision text NOT NULL,
  source_url text NOT NULL,
  canonical_event_id text NOT NULL CHECK(canonical_event_id ~ '^FS:[A-Za-z0-9_-]{5,32}$'),
  source_home text NOT NULL,
  source_away text NOT NULL,
  source_competition text NOT NULL,
  canonical_home text NOT NULL,
  canonical_away text NOT NULL,
  canonical_competition text NOT NULL,
  predicted_kickoff timestamptz NOT NULL,
  home_similarity numeric NOT NULL CHECK(home_similarity BETWEEN 0.25 AND 1),
  away_similarity numeric NOT NULL CHECK(away_similarity BETWEEN 0.25 AND 1),
  league_similarity numeric NOT NULL CHECK(league_similarity BETWEEN 0.5 AND 1),
  clock_offset_minutes integer NOT NULL CHECK(clock_offset_minutes BETWEEN -720 AND 720),
  calibration_samples integer NOT NULL CHECK(calibration_samples>=4),
  calibration_agreement numeric NOT NULL CHECK(calibration_agreement BETWEEN 0.9 AND 1),
  source_captured_at timestamptz NOT NULL,
  last_checked_at timestamptz NOT NULL DEFAULT now(),
  state text NOT NULL DEFAULT 'PROVISIONAL' CHECK(state IN('PROVISIONAL','EXPIRED','DISCONNECTED')),
  PRIMARY KEY(provider,source_event_id)
);
CREATE INDEX IF NOT EXISTS ft_sporty_calibrated_fixture_idx ON private.ft_sportytrader_calibrated_05(canonical_event_id) WHERE state='PROVISIONAL';
ALTER TABLE private.ft_sportytrader_calibrated_05 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.ft_sportytrader_calibrated_05 FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION private.ft_recheck_sportytrader_calibrated_05()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'pg_catalog','private','public','extensions'
AS $function$
DECLARE count_new integer:=0; count_closed integer:=0;
BEGIN
  PERFORM pg_advisory_xact_lock(20261018,505);
  UPDATE private.ft_sportytrader_calibrated_05
    SET state=CASE WHEN predicted_kickoff<=now() THEN 'EXPIRED' ELSE 'DISCONNECTED' END,
        last_checked_at=now()
  WHERE state='PROVISIONAL';
  GET DIAGNOSTICS count_closed=ROW_COUNT;
  WITH seeds AS (
    SELECT DISTINCT ON(s.source_event_id)
      s.source_event_id,
      (s.observation->>'source_date')::date AS source_day,
      round(extract(epoch from (
         (((s.observation->>'source_date')::date+
            (s.observation->>'source_wall_time')::time) AT TIME ZONE 'UTC')
         - s.source_kickoff))/60)::integer AS offset_min
    FROM public.adviser_source_observations s
    WHERE s.provider='SPORTYTRADER'
      AND s.source_kickoff IS NOT NULL
      AND s.observation->>'kickoff_timezone_verified'='true'
      AND s.observation->>'source_date' ~ '^20[0-9]{2}-[01][0-9]-[0-3][0-9]$'
      AND s.observation->>'source_wall_time' ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
      AND s.captured_at>=now()-interval '7 days'
    ORDER BY s.source_event_id,s.last_seen_at DESC
  ), cohort AS (
    SELECT offset_min,count(*)::integer n,count(distinct source_day)::integer days
    FROM seeds WHERE offset_min between -720 and 720
    GROUP BY offset_min
  ), calibration AS (
    SELECT offset_min,n,n::numeric/nullif((SELECT sum(n) FROM cohort),0) agreement
    FROM cohort WHERE n>=4 AND days>=2
      AND n::numeric/nullif((SELECT sum(n) FROM cohort),0)>=0.9
    ORDER BY n DESC LIMIT 1
  ), source_latest AS (
    SELECT DISTINCT ON(s.source_event_id)
      s.source_event_id,s.revision,s.source_url,s.source_home,s.source_away,
      s.source_competition,s.captured_at,s.observation
    FROM public.adviser_source_observations s
    WHERE s.provider='SPORTYTRADER' AND s.identity_status='UNMATCHED'
      AND s.source_kickoff IS NULL AND s.captured_at>=now()-interval '36 hours'
      AND s.source_competition IS NOT NULL
      AND s.observation->>'source_date' ~ '^20[0-9]{2}-[01][0-9]-[0-3][0-9]$'
      AND s.observation->>'source_wall_time' ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
      AND s.source_url ~ '^https://www[.]sportytrader[.]com/en/betting-tips/[^/?#]+-[0-9]+/$'
    ORDER BY s.source_event_id,s.last_seen_at DESC,s.captured_at DESC
  ), source_clock AS (
    SELECT s.*,cal.offset_min,cal.n calibration_samples,cal.agreement,
      (((s.observation->>'source_date')::date+
         (s.observation->>'source_wall_time')::time) AT TIME ZONE 'UTC')
         - cal.offset_min * interval '1 minute' AS calibrated_kickoff
    FROM source_latest s CROSS JOIN calibration cal
  ), paired AS (
    SELECT s.*,f.match_id,f.home_en canonical_home,f.away_en canonical_away,
      f.league canonical_competition,
      extensions.similarity(extensions.unaccent(lower(s.source_home)),
                            extensions.unaccent(lower(f.home_en)))::numeric hs,
      extensions.similarity(extensions.unaccent(lower(s.source_away)),
                            extensions.unaccent(lower(f.away_en)))::numeric aw,
      extensions.similarity(extensions.unaccent(lower(s.source_competition)),
                            extensions.unaccent(lower(f.league)))::numeric ls
    FROM source_clock s
    JOIN public.flashscore_primary_fixture_current f
      ON abs(extract(epoch from f.kickoff_hkt-s.calibrated_kickoff))<=60
      AND f.kickoff_hkt>now() AND f.kickoff_hkt<=now()+interval '48 hours'
      AND f.status='SCHEDULED'
      AND f.identity_authority='FLASHSCORE'
      AND f.provider_identity_status='VERIFIED_IDENTITY'
      AND f.fetched_at>=now()-interval '36 hours'
    WHERE NOT EXISTS(
      SELECT 1 FROM private.ft_adviser_pair_rejections rejected
      WHERE rejected.provider='SPORTYTRADER' AND rejected.source_url=s.source_url
        AND rejected.canonical_event_id=f.match_id)
      AND NOT EXISTS(
      SELECT 1 FROM public.adviser_source_observations verified
      WHERE verified.provider='SPORTYTRADER' AND verified.canonical_event_id=f.match_id
        AND verified.identity_status='VERIFIED')
      AND NOT EXISTS(
      SELECT 1 FROM private.ft_adviser_provisional_05 old
      WHERE old.provider='SPORTYTRADER' AND old.state='PROVISIONAL'
        AND (old.canonical_event_id=f.match_id OR old.source_event_id=s.source_event_id))
  ), qualified AS (
    SELECT *,count(*) OVER(PARTITION BY source_event_id) source_matches,
      count(*) OVER(PARTITION BY match_id) target_sources
    FROM paired WHERE hs>=0.25 AND aw>=0.25 AND ls>=0.5
  ), unique_pairs AS (
    SELECT * FROM qualified WHERE source_matches=1 AND target_sources=1
    ORDER BY calibrated_kickoff,source_event_id LIMIT 120
  )
  INSERT INTO private.ft_sportytrader_calibrated_05 (
    provider,source_event_id,source_revision,source_url,canonical_event_id,
    source_home,source_away,source_competition,canonical_home,canonical_away,
    canonical_competition,predicted_kickoff,home_similarity,away_similarity,
    league_similarity,clock_offset_minutes,calibration_samples,
    calibration_agreement,source_captured_at,last_checked_at,state)
  SELECT 'SPORTYTRADER',source_event_id,revision,source_url,match_id,
    source_home,source_away,source_competition,canonical_home,canonical_away,
    canonical_competition,calibrated_kickoff,hs,aw,ls,offset_min,
    calibration_samples,agreement,captured_at,now(),'PROVISIONAL'
  FROM unique_pairs
  ON CONFLICT(provider,source_event_id) DO UPDATE SET
    source_revision=EXCLUDED.source_revision,
    source_home=EXCLUDED.source_home,source_away=EXCLUDED.source_away,
    source_competition=EXCLUDED.source_competition,
    canonical_home=EXCLUDED.canonical_home,canonical_away=EXCLUDED.canonical_away,
    canonical_competition=EXCLUDED.canonical_competition,
    predicted_kickoff=EXCLUDED.predicted_kickoff,
    home_similarity=EXCLUDED.home_similarity,away_similarity=EXCLUDED.away_similarity,
    league_similarity=EXCLUDED.league_similarity,
    clock_offset_minutes=EXCLUDED.clock_offset_minutes,
    calibration_samples=EXCLUDED.calibration_samples,
    calibration_agreement=EXCLUDED.calibration_agreement,
    source_captured_at=EXCLUDED.source_captured_at,
    last_checked_at=now(),state='PROVISIONAL'
  WHERE private.ft_sportytrader_calibrated_05.canonical_event_id=EXCLUDED.canonical_event_id
    AND private.ft_sportytrader_calibrated_05.source_url=EXCLUDED.source_url
    AND EXCLUDED.source_captured_at>=private.ft_sportytrader_calibrated_05.source_captured_at;
  GET DIAGNOSTICS count_new=ROW_COUNT;
  RETURN jsonb_build_object(
    'status','CALIBRATED_PROVISIONAL_NOT_VERIFIED',
    'threshold',0.25,'matched',count_new,'retired',count_closed,
    'active',(SELECT count(*) FROM private.ft_sportytrader_calibrated_05 WHERE state='PROVISIONAL'));
END;
$function$;


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
       AND NOT EXISTS (SELECT 1 FROM private.ft_adviser_pair_rejections rejected
         WHERE rejected.provider=o.provider AND rejected.source_url=o.source_url
         AND rejected.canonical_event_id=f.match_id)
       AND o.source_url IS NOT NULL AND o.source_competition IS NOT NULL
  ), thresholded AS (
    SELECT * FROM pairs
    WHERE (hs>=0.4 AND aw>=0.4)
       OR (hs>=0.25 AND aw>=0.25 AND league_status='CORROBORATED')
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
     'PROVISIONAL','0.25_BOTH_TEAMS_LEAGUE_KICKOFF_UNIQUE_REVIEW_ONLY',captured_at
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
  WHERE EXCLUDED.source_captured_at>=private.ft_adviser_provisional_05.source_captured_at
    AND EXCLUDED.canonical_event_id=private.ft_adviser_provisional_05.canonical_event_id
    AND EXCLUDED.source_url=private.ft_adviser_provisional_05.source_url
    AND EXCLUDED.source_kickoff=private.ft_adviser_provisional_05.source_kickoff;
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
      EXISTS (SELECT 1 FROM private.ft_adviser_pair_rejections rejected
              WHERE rejected.provider=c.provider AND rejected.source_url=c.source_url
              AND rejected.canonical_event_id=c.canonical_event_id)
      OR c.source_kickoff<=now()
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
           AND (( extensions.similarity(extensions.unaccent(lower(s.source_home)),extensions.unaccent(lower(f.home_en)))>=0.4 AND extensions.similarity(extensions.unaccent(lower(s.source_away)),extensions.unaccent(lower(f.away_en)))>=0.4 )
             OR ( extensions.similarity(extensions.unaccent(lower(s.source_home)),extensions.unaccent(lower(f.home_en)))>=0.25 AND extensions.similarity(extensions.unaccent(lower(s.source_away)),extensions.unaccent(lower(f.away_en)))>=0.25
                 AND (lower(trim(s.source_competition))=lower(trim(f.league))
               OR lower(trim(s.source_competition)) LIKE ('% '||lower(trim(f.league)))
               OR EXISTS (
                 SELECT 1 FROM public.adviser_competition_alias_evidence a
                 WHERE upper(a.provider)=s.provider
                   AND lower(trim(a.source_competition))=lower(trim(s.source_competition))
                   AND lower(trim(a.canonical_competition))=lower(trim(f.league))
               ))))
      )
    );
  GET DIAGNOSTICS n_closed = ROW_COUNT;

  -- Daily cron 51 already runs this function. Reuse that single invocation
  -- for the calibrated SportyTrader lookup; NO additional scheduled job.
  PERFORM private.ft_recheck_sportytrader_calibrated_05();
  RETURN jsonb_build_object('threshold',0.25,'upserted',n_upserted,
    'closed',n_closed,'provisional_remaining',
    (SELECT count(*) FROM private.ft_adviser_provisional_05 WHERE state='PROVISIONAL'),
    'verification','PROVISIONAL_ONLY_NO_PUBLIC_VERIFIED_PROMOTION');
END;
$function$;



CREATE OR REPLACE FUNCTION public.ft_public_adviser_provisional_candidates()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
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
      AND NOT EXISTS (SELECT 1 FROM private.ft_adviser_pair_rejections rejected
                      WHERE rejected.provider=c.provider AND rejected.source_url=c.source_url
                      AND rejected.canonical_event_id=c.canonical_event_id)
      AND c.provider IN ('BETCLAN','SPORTYTRADER')
      AND c.canonical_event_id~'^FS:[A-Za-z0-9_-]{5,32}$'
      AND c.source_kickoff>now()
      AND c.source_kickoff<now()+interval '48 hours'
      AND c.last_checked_at>=now()-interval '36 hours'
      AND c.last_checked_at<=now()+interval '1 minute'
      AND c.source_captured_at>=now()-interval '48 hours'
      AND c.source_captured_at<=now()
      AND c.home_similarity>=0.25
      AND c.away_similarity>=0.25
      AND ((c.home_similarity>=0.4 AND c.away_similarity>=0.4)
         OR (c.league_evidence='CORROBORATED'))
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
  ), sporty_calibrated AS (
    SELECT c.*,o.observation,
      count(*) OVER(PARTITION BY c.canonical_event_id) competing
    FROM private.ft_sportytrader_calibrated_05 c
    JOIN public.adviser_source_observations o
      ON o.provider='SPORTYTRADER' AND o.source_event_id=c.source_event_id
     AND o.revision=c.source_revision AND o.source_url=c.source_url
     AND o.identity_status='UNMATCHED' AND o.source_kickoff IS NULL
    JOIN public.flashscore_primary_fixture_current f
      ON f.match_id=c.canonical_event_id
      AND f.identity_authority='FLASHSCORE'
      AND f.provider_identity_status='VERIFIED_IDENTITY'
      AND f.status='SCHEDULED'
      AND f.fetched_at>=now()-interval '36 hours'
      AND abs(extract(epoch from f.kickoff_hkt-c.predicted_kickoff))<=60
      AND f.kickoff_hkt>now() AND f.kickoff_hkt<=now()+interval '48 hours'
    WHERE c.state='PROVISIONAL'
      AND c.source_captured_at>=now()-interval '48 hours'
      AND c.last_checked_at>=now()-interval '36 hours'
      AND c.calibration_samples>=4 AND c.calibration_agreement>=0.9
      AND c.home_similarity>=0.25 AND c.away_similarity>=0.25
      AND c.league_similarity>=0.5
      AND NOT EXISTS(SELECT 1 FROM private.ft_adviser_pair_rejections rejected
         WHERE rejected.provider='SPORTYTRADER'
           AND rejected.source_url=c.source_url
           AND rejected.canonical_event_id=c.canonical_event_id)
      AND NOT EXISTS(SELECT 1 FROM public.adviser_source_observations verified
         WHERE verified.provider='SPORTYTRADER'
           AND verified.canonical_event_id=c.canonical_event_id
           AND verified.identity_status='VERIFIED')
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
    UNION ALL
    SELECT jsonb_build_object(
      'id',c.canonical_event_id,
      'provider','SPORTYTRADER','status','PROVISIONAL_NOT_VERIFIED',
      'sourceHome',c.source_home,'sourceAway',c.source_away,
      'canonicalHome',c.canonical_home,'canonicalAway',c.canonical_away,
      'league',c.canonical_competition,'kickoff',c.predicted_kickoff,
      'sourceUrl',c.source_url,'sourceCapturedAt',c.source_captured_at,
      'lastChecked',c.last_checked_at,
      'homeSimilarity',c.home_similarity,'awaySimilarity',c.away_similarity,
      'leagueSimilarity',c.league_similarity,'leagueEvidence','CORROBORATED',
      'clockEvidence','CALIBRATED_FROM_SPORTYTRADER_LINKED_EVENTS_NOT_SOURCE_VERIFIED',
      'clockOffsetMinutes',c.clock_offset_minutes,
      'clockCalibrationSamples',c.calibration_samples,
      'clockCalibrationAgreement',c.calibration_agreement,
      'kickoffTimezoneVerified',false,
      'timeDeltaSeconds',0,
      'hda',CASE WHEN jsonb_typeof(c.observation->'hda')='object'
        AND jsonb_typeof(c.observation->'hda'->'home')='number'
        AND jsonb_typeof(c.observation->'hda'->'draw')='number'
        AND jsonb_typeof(c.observation->'hda'->'away')='number'
        AND (c.observation#>>'{hda,home}')::numeric BETWEEN 0 AND 1
        AND (c.observation#>>'{hda,draw}')::numeric BETWEEN 0 AND 1
        AND (c.observation#>>'{hda,away}')::numeric BETWEEN 0 AND 1
        AND abs(((c.observation#>>'{hda,home}')::numeric+
          (c.observation#>>'{hda,draw}')::numeric+
          (c.observation#>>'{hda,away}')::numeric)-1)<0.02
        THEN c.observation->'hda' ELSE NULL END,
      'predictedScore',NULL,
      'over25',NULL,'bttsYes',NULL,
      'tip',CASE WHEN length(c.observation->>'tip') BETWEEN 1 AND 100
        THEN c.observation->>'tip' ELSE NULL END
    )
    FROM sporty_calibrated c WHERE c.competing=1
  )
  SELECT jsonb_build_object(
    'source','ADVISER_PROVISIONAL_FLASHscore_0_25',
    'quality','PROVISIONAL_NOT_VERIFIED',
    'generatedAt',now(),
    'rows',coalesce(jsonb_agg(value),'[]'::jsonb)
  ) FROM rows;
$function$;



REVOKE ALL ON FUNCTION public.ft_public_adviser_provisional_candidates() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ft_public_adviser_provisional_candidates() TO service_role;
COMMIT;
