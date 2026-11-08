-- Re-enable source timestamp refresh for already-linked exact Flashscore IDs.
-- All native event, league, raw source, kickoff, and name checks remain in force.
CREATE OR REPLACE FUNCTION private.ft_promote_native_flashscore_major_fixtures()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
DECLARE n integer:=0;
BEGIN
  -- Source-native Flashscore identifiers only; separate league IDs avoid
  -- ambiguous names such as "Premier League" in other countries.
  WITH allowed(league_id,source_name,canonical_league) AS (
    VALUES
     ('SY30SsKF','Premier League','EPL'),
     ('QeI1Oeyi','LaLiga','LaLigaSPAIN: LaLiga'),
     ('KY7LrA6d','Bundesliga','BundesligaGERMANY: Bundesliga'),
     ('WdNk9YwP','Serie A','Serie AITALY: Serie A'),
     ('0Mp0HlJb','Ligue 1','Ligue 1FRANCE: Ligue 1'),
     ('tUfctlzI','MLS','MLS')
  ), source AS (
    SELECT s.*,a.canonical_league
    FROM public.phase15_source_shadow_current s
    JOIN allowed a
      ON a.league_id=s.league_external_id
     AND a.source_name=s.league_name
    WHERE s.source_key='FLASHSCORE'
      AND s.fetched_at>=now()-interval '25 minutes'
      AND s.kickoff_utc>now()
      AND s.kickoff_utc<=now()+interval '72 hours'
      AND s.external_event_id ~ '^[A-Za-z0-9_-]{5,32}$'
      AND s.home_name IS NOT NULL AND length(btrim(s.home_name))>=2
      AND s.away_name IS NOT NULL AND length(btrim(s.away_name))>=2
      AND lower(btrim(s.home_name))<>lower(btrim(s.away_name))
      AND s.raw->>'AA'=s.external_event_id
      AND s.raw->>'AE'=s.home_name
      AND s.raw->>'AF'=s.away_name
      AND s.raw->>'AD' ~ '^[0-9]{10}$'
      AND abs(extract(epoch FROM s.kickoff_utc) - (s.raw->>'AD')::numeric)<=60
      AND s.raw->>'AB'='1'
      AND (s.match_id IS NULL OR s.match_id='FS:'||s.external_event_id)
      AND NOT EXISTS (
        SELECT 1 FROM public.fixture_identity_redirects red
        WHERE red.source_match_id='FS:'||s.external_event_id
          AND red.active=true
      )
      AND NOT EXISTS(
        SELECT 1 FROM public.matches old
        WHERE old.canonical_event_id <> 'FS:'||s.external_event_id
          AND abs(extract(epoch FROM (old.kickoff_hkt-s.kickoff_utc)))<=900
          AND lower(regexp_replace(old.home_en,'[^[:alnum:]]','','g'))
              =lower(regexp_replace(s.home_name,'[^[:alnum:]]','','g'))
          AND lower(regexp_replace(old.away_en,'[^[:alnum:]]','','g'))
              =lower(regexp_replace(s.away_name,'[^[:alnum:]]','','g'))
      )
    ORDER BY s.kickoff_utc,s.external_event_id
    LIMIT 140
  ), written AS (
    INSERT INTO public.matches AS existing
     (canonical_event_id, canonical_match_id, kickoff_hkt, status, tournament,
      home_en, away_en, in_play, selling, fetched_at, source_updated_at,
      raw, updated_at)
    SELECT 'FS:'||s.external_event_id, s.external_event_id,s.kickoff_utc,
      'PREEVENT',s.canonical_league,s.home_name,s.away_name,false,false,
      s.fetched_at,s.fetched_at,
      jsonb_build_object(
        'source','FLASHSCORE',
        'identity_origin','DIRECT_PROVIDER_ID_FROM_EXISTING_SHADOW',
        'provider_event_id',s.external_event_id,
        'provider_epoch',s.raw->>'AD',
        'provider_league_id',s.league_external_id,
        'source_fetched_at',s.fetched_at
      ),now()
    FROM source s
    ON CONFLICT (canonical_event_id)
    DO UPDATE SET
      fetched_at=EXCLUDED.fetched_at,
      source_updated_at=EXCLUDED.source_updated_at,
      status=EXCLUDED.status,
      updated_at=now()
    WHERE existing.raw->>'source'='FLASHSCORE'
      AND existing.raw->>'provider_event_id'=EXCLUDED.canonical_match_id
      AND existing.raw->>'identity_origin'='DIRECT_PROVIDER_ID_FROM_EXISTING_SHADOW'
      AND existing.kickoff_hkt=EXCLUDED.kickoff_hkt
      AND existing.tournament=EXCLUDED.tournament
      AND existing.home_en=EXCLUDED.home_en
      AND existing.away_en=EXCLUDED.away_en
      AND existing.fetched_at < EXCLUDED.fetched_at
    RETURNING 1
  )
  SELECT count(*) INTO n FROM written;
  RETURN jsonb_build_object('status','OK','rows_inserted_or_refreshed',n,
    'sources','FLASHSCORE_NATIVE_6_VERIFIED_COMPETITIONS',
    'bookmaker_quotes_written',0);
END;
$function$
;
REVOKE ALL ON FUNCTION private.ft_promote_native_flashscore_major_fixtures() FROM PUBLIC, anon, authenticated;
