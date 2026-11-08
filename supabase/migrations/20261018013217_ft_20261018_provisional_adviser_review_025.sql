-- Phase 12: 25% is a provisional review threshold, NEVER verified.
-- Existing strong >=40% matching remains; 25-40% requires corroborated
-- league + independent kickoff (legacy) or >=90% clock calibration from 10+
-- independent fixtures, >=0.5 league similarity and <=60s delta (extra).
-- Both require one-to-one source-to-Flashscore identity, with expiry and
-- conflicting-evidence disconnection. No scraping or score inference.
BEGIN;
-- Versioned candidate-threshold policy: 30% is PROVISIONAL ONLY.
-- For 30-40% cases require one >=70% side AND independently corroborated
-- competition for BCL/SportyTrader, or >=50% league + <=60s for calibrated
-- PrimaTips/Statarea. Existing >=40% candidates retain previous gates.
ALTER TABLE private.ft_adviser_provisional_05
 DROP CONSTRAINT ft_adviser_provisional_05_home_similarity_check,
 DROP CONSTRAINT ft_adviser_provisional_05_away_similarity_check;
ALTER TABLE private.ft_adviser_provisional_05
 ADD CONSTRAINT ft_adviser_provisional_05_home_similarity_check
   CHECK(home_similarity BETWEEN 0.25 AND 1),
 ADD CONSTRAINT ft_adviser_provisional_05_away_similarity_check
   CHECK(away_similarity BETWEEN 0.25 AND 1);
ALTER TABLE private.ft_extra_adviser_provisional_04
 DROP CONSTRAINT ft_extra_adviser_provisional_04_home_similarity_check,
 DROP CONSTRAINT ft_extra_adviser_provisional_04_away_similarity_check;
ALTER TABLE private.ft_extra_adviser_provisional_04
 ADD CONSTRAINT ft_extra_adviser_provisional_04_home_similarity_check
   CHECK(home_similarity BETWEEN 0.25 AND 1),
 ADD CONSTRAINT ft_extra_adviser_provisional_04_away_similarity_check
   CHECK(away_similarity BETWEEN 0.25 AND 1);
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

  RETURN jsonb_build_object('threshold',0.25,'upserted',n_upserted,
    'closed',n_closed,'provisional_remaining',
    (SELECT count(*) FROM private.ft_adviser_provisional_05 WHERE state='PROVISIONAL'),
    'verification','PROVISIONAL_ONLY_NO_PUBLIC_VERIFIED_PROMOTION');
END;
$function$;


CREATE OR REPLACE FUNCTION private.ft_recheck_extra_adviser_provisional_04()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'private', 'public', 'extensions'
AS $function$
DECLARE matches_count integer; prior_count integer;
BEGIN
 PERFORM pg_advisory_xact_lock(20261016, 404);
 SELECT count(*) INTO prior_count FROM private.ft_extra_adviser_provisional_04;
 DELETE FROM private.ft_extra_adviser_provisional_04;

 WITH s AS (
  SELECT provider,source_event_id,source_date,source_wall_time,
   regexp_replace(lower(extensions.unaccent(source_home)),'[^a-z0-9]+','','g') AS home_key,
   regexp_replace(lower(extensions.unaccent(source_away)),'[^a-z0-9]+','','g') AS away_key,
   regexp_replace(lower(extensions.unaccent(source_competition)),'[^a-z0-9]+','','g') AS league_key,
   (source_date+source_wall_time::time) AT TIME ZONE 'UTC' AS source_wall_utc
  FROM private.ft_extra_adviser_source_observations
  WHERE captured_at>=now()-interval '36 hours'
    AND source_date BETWEEN (now() AT TIME ZONE 'UTC')::date-1
        AND (now() AT TIME ZONE 'UTC')::date+2
 ), f AS (
  SELECT match_id,kickoff_hkt,status,
    regexp_replace(lower(extensions.unaccent(home_en)),'[^a-z0-9]+','','g') AS home_key,
    regexp_replace(lower(extensions.unaccent(away_en)),'[^a-z0-9]+','','g') AS away_key,
    regexp_replace(lower(extensions.unaccent(league)),'[^a-z0-9]+','','g') AS league_key
  FROM public.flashscore_primary_fixture_current
  WHERE identity_authority='FLASHSCORE'
   AND provider_identity_status='VERIFIED_IDENTITY'
   AND fetched_at>=now()-interval '36 hours'
   AND kickoff_hkt>now()-interval '12 hours'
   AND kickoff_hkt<=now()+interval '48 hours'
 ), high_confidence_seeds AS (
  SELECT s.provider,s.source_date,s.source_event_id,f.match_id,
     ((round(extract(epoch FROM (s.source_wall_utc-f.kickoff_hkt))/60)::integer+720+1440*3)%1440)-720 AS offset_min
  FROM s JOIN f ON f.kickoff_hkt::date BETWEEN s.source_date-1 AND s.source_date+1
  WHERE extensions.similarity(s.home_key,f.home_key)>=0.72
    AND extensions.similarity(s.away_key,f.away_key)>=0.72
 ), offset_counts AS (
  SELECT provider,source_date,offset_min,count(DISTINCT source_event_id) AS n
  FROM high_confidence_seeds GROUP BY 1,2,3
 ), offset_rank AS (
  SELECT oc.*,sum(n) OVER(PARTITION BY provider,source_date) AS total,
   row_number() OVER(PARTITION BY provider,source_date ORDER BY n DESC,abs(offset_min),offset_min) AS priority
  FROM offset_counts oc
 ), calibrated AS (
  SELECT provider,source_date,offset_min,n,total
  FROM offset_rank
  WHERE priority=1 AND n>=10 AND total>0 AND n::numeric/total>=0.9
 ), candidates AS (
  SELECT s.provider,s.source_event_id,s.source_date,
    f.match_id AS canonical_event_id,
    extensions.similarity(s.home_key,f.home_key)::numeric AS hs,
    extensions.similarity(s.away_key,f.away_key)::numeric AS aws,
    extensions.similarity(s.league_key,f.league_key)::numeric AS ls,
    o.offset_min,o.n,o.total,
    abs(extract(epoch FROM
      ((s.source_wall_utc - o.offset_min*interval '1 minute') - f.kickoff_hkt)))::numeric AS delta
  FROM s
  JOIN calibrated o ON o.provider=s.provider AND o.source_date=s.source_date
  JOIN f ON f.kickoff_hkt BETWEEN
   s.source_wall_utc-o.offset_min*interval '1 minute'-interval '5 minutes'
   AND s.source_wall_utc-o.offset_min*interval '1 minute'+interval '5 minutes'
  WHERE f.status='SCHEDULED' AND f.kickoff_hkt>now()
    AND ((extensions.similarity(s.home_key,f.home_key)>=0.4
       AND extensions.similarity(s.away_key,f.away_key)>=0.4)
      OR (extensions.similarity(s.home_key,f.home_key)>=0.25
       AND extensions.similarity(s.away_key,f.away_key)>=0.25
       AND extensions.similarity(s.league_key,f.league_key)>=0.5))
 ), unique_candidates AS (
  SELECT c.*,
    count(*) OVER(PARTITION BY provider,source_event_id,source_date) AS matching_targets,
    count(*) OVER(PARTITION BY provider,canonical_event_id) AS matching_sources
  FROM candidates c
 )
 INSERT INTO private.ft_extra_adviser_provisional_04(
  provider,source_event_id,source_date,canonical_event_id,home_similarity,
  away_similarity,league_similarity,league_evidence,source_clock_offset_minutes,
  calibration_samples,calibration_agreement,time_delta_seconds,last_checked_at)
 SELECT provider,source_event_id,source_date,canonical_event_id,hs,aws,ls,
   CASE WHEN ls>=.35 THEN 'NAME_SIMILAR' ELSE 'NEEDS_REVIEW' END,
   offset_min,n,n::numeric/total,delta,now()
 FROM unique_candidates
 WHERE matching_targets=1 AND matching_sources=1
   AND ((hs>=0.4 AND aws>=0.4 AND delta<=300)
     OR (hs>=0.25 AND aws>=0.25 AND ls>=0.5 AND delta<=60));

 GET DIAGNOSTICS matches_count=ROW_COUNT;
 RETURN jsonb_build_object('previous',prior_count,'provisional',matches_count,
   'source','LIVE_FLASHscore_DATE_CALIBRATED_NOT_SOURCE_VERIFIED','threshold',0.25);
END $function$;


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
    'source','ADVISER_PROVISIONAL_FLASHscore_0_25',
    'quality','PROVISIONAL_NOT_VERIFIED',
    'generatedAt',now(),
    'rows',coalesce(jsonb_agg(value),'[]'::jsonb)
  ) FROM rows;
$function$;


CREATE OR REPLACE FUNCTION public.ft_public_extra_adviser_provisional()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
WITH selected AS (
 SELECT
  p.canonical_event_id AS id,p.provider,p.home_similarity,p.away_similarity,
  p.league_similarity,p.league_evidence,
  p.source_clock_offset_minutes,p.calibration_samples,p.calibration_agreement,
  p.time_delta_seconds,p.last_checked_at,
  s.source_url,s.source_home,s.source_away,s.source_competition,
  s.source_date,s.source_wall_time,s.captured_at,s.hda,s.observation,
  f.kickoff_hkt,f.home_en,f.away_en,f.league
 FROM private.ft_extra_adviser_provisional_04 p
 JOIN private.ft_extra_adviser_source_observations s
  ON p.provider=s.provider AND p.source_event_id=s.source_event_id
  AND p.source_date=s.source_date
 JOIN public.flashscore_primary_fixture_current f
  ON f.match_id=p.canonical_event_id
  AND f.status='SCHEDULED'
  AND f.identity_authority='FLASHSCORE'
  AND f.provider_identity_status='VERIFIED_IDENTITY'
  AND f.fetched_at>=now()-interval '36 hours'
  AND f.kickoff_hkt>now()
  AND f.kickoff_hkt<=now()+interval '48 hours'
 WHERE p.last_checked_at>=now()-interval '36 hours'
  AND s.captured_at>=now()-interval '36 hours'
  AND p.home_similarity>=0.25 AND p.away_similarity>=0.25
  AND ((p.home_similarity>=0.4 AND p.away_similarity>=0.4
        AND p.time_delta_seconds<=300)
    OR (p.league_similarity>=0.5 AND p.time_delta_seconds<=60))
  AND p.calibration_samples>=10 AND p.calibration_agreement>=0.9
  AND abs(extract(epoch FROM
    (((s.source_date+s.source_wall_time::time) AT TIME ZONE 'UTC') -
      p.source_clock_offset_minutes * interval '1 minute')-f.kickoff_hkt))<=300
  AND (
    (p.provider='PRIMATIPS' AND s.source_url ~ '^https://primatips[.]com/tip/')
    OR (p.provider='STATAREA' AND s.source_url ~ '^https://www[.]statarea[.]com/olddevices/prediction/')
  )
 ORDER BY f.kickoff_hkt,p.provider,p.canonical_event_id
 LIMIT 600
)
SELECT jsonb_build_object(
 'source','EXTRA_ADVISER_PROVISIONAL_025',
 'quality','PROVISIONAL_NOT_VERIFIED_CALIBRATED_WALL_TIME',
 'generatedAt',now(),
 'rows',coalesce(jsonb_agg(jsonb_build_object(
  'id',id,'provider',provider,'status','PROVISIONAL_NOT_VERIFIED',
  'kickoff',kickoff_hkt,'sourceDate',source_date,'sourceWallTime',source_wall_time,
  'kickoffTimezoneVerified',false,
  'clockEvidence','CALIBRATED_FROM_DAY_COHORT_NOT_SOURCE_VERIFIED',
  'clockOffsetMinutes',source_clock_offset_minutes,
  'clockCalibrationSamples',calibration_samples,
  'clockCalibrationAgreement',calibration_agreement,
  'timeDeltaSeconds',time_delta_seconds,
  'sourceUrl',source_url,'sourceHome',source_home,'sourceAway',source_away,
  'canonicalHome',home_en,'canonicalAway',away_en,
  'sourceCompetition',source_competition,'canonicalCompetition',league,
  'homeSimilarity',home_similarity,'awaySimilarity',away_similarity,
  'leagueSimilarity',league_similarity,'leagueEvidence',league_evidence,
  'lastChecked',last_checked_at,'sourceCapturedAt',captured_at,
  'hda',hda,
  'over25',CASE WHEN jsonb_typeof(observation->'over25')='number'
        AND (observation->>'over25')::numeric BETWEEN 0 AND 1
      THEN observation->'over25' ELSE NULL END,
  'bttsYes',CASE WHEN jsonb_typeof(observation->'btts_yes')='number'
        AND (observation->>'btts_yes')::numeric BETWEEN 0 AND 1
      THEN observation->'btts_yes' ELSE NULL END,
  'tip',CASE WHEN length(observation->>'tip')<=6 THEN observation->>'tip' ELSE NULL END
 )),'[]'::jsonb)
) FROM selected
$function$;


-- Preserve existing privileges: read-only public RPCs remain service-only,
-- rechecks stay private and scheduled; no anonymous mutation.
REVOKE ALL ON FUNCTION public.ft_public_adviser_provisional_candidates() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ft_public_adviser_provisional_candidates() TO service_role;
REVOKE ALL ON FUNCTION public.ft_public_extra_adviser_provisional() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ft_public_extra_adviser_provisional() TO service_role;
COMMIT;
