
CREATE TABLE IF NOT EXISTS private.ft_extra_adviser_name_alias (
 provider text NOT NULL CHECK(provider IN ('PRIMATIPS','STATAREA')),
 source_key text NOT NULL CHECK(source_key ~ '^[a-z0-9]+$'),
 canonical_key text NOT NULL CHECK(canonical_key ~ '^[a-z0-9]+$'),
 evidence text NOT NULL,
 active boolean NOT NULL DEFAULT true,
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(provider,source_key)
);
ALTER TABLE private.ft_extra_adviser_name_alias ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.ft_extra_adviser_name_alias FROM PUBLIC,anon,authenticated;
INSERT INTO private.ft_extra_adviser_name_alias (provider,source_key,canonical_key,evidence) VALUES
('PRIMATIPS','parissg','psg','NAME_ALIAS_PROVISIONAL_REVIEW_20261019'),
('STATAREA','parissaintgermain','psg','NAME_ALIAS_PROVISIONAL_REVIEW_20261019'),
('PRIMATIPS','psveindhoven','psv','NAME_ALIAS_PROVISIONAL_REVIEW_20261019'),
('PRIMATIPS','porto','fcporto','NAME_ALIAS_PROVISIONAL_REVIEW_20261019'),
('STATAREA','roma','asroma','NAME_ALIAS_PROVISIONAL_REVIEW_20261019'),
('PRIMATIPS','wiganathletic','wigan','NAME_ALIAS_PROVISIONAL_REVIEW_20261019'),
('PRIMATIPS','crewealexandra','crewe','NAME_ALIAS_PROVISIONAL_REVIEW_20261019'),
('PRIMATIPS','oldhamathletic','oldham','NAME_ALIAS_PROVISIONAL_REVIEW_20261019'),
('STATAREA','miltonkeynesdons','mkdons','NAME_ALIAS_PROVISIONAL_REVIEW_20261019')
ON CONFLICT (provider,source_key) DO NOTHING;

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
  SELECT s.provider,source_event_id,source_date,source_wall_time,source_url,
   COALESCE(ha.canonical_key,regexp_replace(lower(extensions.unaccent(s.source_home)),'[^a-z0-9]+','','g')) AS home_key,
   COALESCE(aa.canonical_key,regexp_replace(lower(extensions.unaccent(s.source_away)),'[^a-z0-9]+','','g')) AS away_key,
   regexp_replace(lower(extensions.unaccent(source_competition)),'[^a-z0-9]+','','g') AS league_key,
   (source_date+source_wall_time::time) AT TIME ZONE 'UTC' AS source_wall_utc
  FROM private.ft_extra_adviser_source_observations s
  LEFT JOIN private.ft_extra_adviser_name_alias ha
    ON ha.provider=s.provider AND ha.active
   AND ha.source_key=regexp_replace(lower(extensions.unaccent(s.source_home)),'[^a-z0-9]+','','g')
  LEFT JOIN private.ft_extra_adviser_name_alias aa
    ON aa.provider=s.provider AND aa.active
   AND aa.source_key=regexp_replace(lower(extensions.unaccent(s.source_away)),'[^a-z0-9]+','','g')
  WHERE s.captured_at>=now()-interval '36 hours'
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
    AND NOT EXISTS (SELECT 1 FROM private.ft_adviser_pair_rejections rejected
                    WHERE rejected.provider=s.provider AND rejected.source_url=s.source_url
                    AND rejected.canonical_event_id=f.match_id)
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
END $function$

