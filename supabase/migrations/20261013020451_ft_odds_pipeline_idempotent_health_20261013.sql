-- Phase 1: idempotent odds publication and in-band freshness health.
-- Existing 15-minute Railway capture and 5-minute asynchronous handoff remain unchanged.
-- No new database table, scheduler, collector, alias join or public endpoint.
CREATE OR REPLACE FUNCTION private.ft_publish_flashscore_collector_snapshot(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'private', 'public', 'pg_temp'
AS $function$
DECLARE
  v_captured timestamptz;
  v_total integer;
  v_count integer;
  v_distinct integer;
  v_upcoming integer;
  v_rows jsonb;
  v_existing timestamptz;
  v_result jsonb;
BEGIN
  IF p_payload->>'source' IS DISTINCT FROM 'FLASHSCORE_BET365'
    OR jsonb_typeof(p_payload->'fixtures') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'flashscore_snapshot_untrusted_source_or_shape';
  END IF;
  v_total:=jsonb_array_length(p_payload->'fixtures');
  IF v_total < 50 OR v_total > 1500 THEN
    RAISE EXCEPTION 'flashscore_snapshot_unexpected_count_%',v_total;
  END IF;
  v_captured:=(p_payload->>'captured_at')::timestamptz;
  -- Exactly-once database work: acquire the existing transaction lock and
  -- check capture watermark before staging any identity/alias data.
  IF v_captured > now()+interval '1 minute' THEN
    RAISE EXCEPTION 'flashscore_snapshot_future_%',v_captured;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('ft_verified_flashscore_bookmaker_publication'));
  SELECT max(fetched_at) INTO v_existing
  FROM public.bet365_current WHERE source='FLASHSCORE_BET365';
  IF v_existing IS NOT NULL AND v_existing >= v_captured THEN
    RETURN jsonb_build_object('status','UNCHANGED','captured_at',v_captured,
      'latest_committed',v_existing);
  END IF;
  IF v_captured < now()-interval '20 minutes' THEN
    RAISE EXCEPTION 'flashscore_snapshot_expired_%',v_captured;
  END IF;
  PERFORM private.ft_stage_verified_flashscore_from_snapshot(p_payload);

  WITH provider AS (
    SELECT value AS item,
      value->>'provider_event_id' AS event_id
    FROM jsonb_array_elements(p_payload->'fixtures')
  ), mapped AS (
    SELECT f.item,f.event_id,
      COALESCE(
        red.target_match_id,
        CASE WHEN sh.match_confidence>=0.94 AND
          sh.identity_status IN ('EXACT_PAIR','VERIFIED_IDENTITY','LOOSE_PAIR',
             'TOKEN_PAIR','MIXED_CONTEXT','MIXED_LOOSE','TOKEN_IDENTITY_MIXED')
          THEN sh.match_id END,
        'FS:'||f.event_id
      ) AS candidate,
      sh.raw->>'AD' AS provider_epoch,
      sh.external_event_id AS shadow_event_id,
      sh.match_confidence,
      red.confidence AS redirect_confidence
    FROM provider f
    LEFT JOIN public.fixture_identity_redirects red
      ON red.source_match_id='FS:'||f.event_id
      AND red.active=true AND red.confidence>=0.94
    LEFT JOIN public.phase15_source_shadow_current sh
      ON sh.source_key='FLASHSCORE' AND sh.external_event_id=f.event_id
  ), identified AS (
    SELECT x.*,m.kickoff_hkt,m.tournament,m.home_en,m.away_en,
      CASE WHEN x.provider_epoch ~ '^[0-9]{10}$'
        THEN to_timestamp(x.provider_epoch::double precision) END AS provider_kickoff
    FROM mapped x
    JOIN public.matches m ON m.canonical_event_id=x.candidate
  ), safe AS (
    SELECT *,
      (item->'hda'->>'home')::numeric AS home_price,
      (item->'hda'->>'draw')::numeric AS draw_price,
      (item->'hda'->>'away')::numeric AS away_price
    FROM identified
    WHERE event_id ~ '^[a-zA-Z0-9]{6,16}$'
      AND item->>'source'='FLASHSCORE_BET365'
      AND lower(item->>'bookmaker')='bet365'
      AND item->>'captured_at' IS NOT NULL
      AND abs(extract(epoch FROM ((item->>'captured_at')::timestamptz-v_captured))) <= 60
      AND provider_kickoff IS NOT NULL
      AND abs(extract(epoch FROM (kickoff_hkt-provider_kickoff)))<=1200
      AND kickoff_hkt > now()
      AND (item->'hda'->>'home') ~ '^[0-9]+(\.[0-9]+)?$'
      AND (item->'hda'->>'draw') ~ '^[0-9]+(\.[0-9]+)?$'
      AND (item->'hda'->>'away') ~ '^[0-9]+(\.[0-9]+)?$'
  ), approved AS (
    SELECT * FROM safe
    WHERE home_price>1 AND home_price<=1000
      AND draw_price>1 AND draw_price<=1000
      AND away_price>1 AND away_price<=1000
  ), source_upcoming AS (
    -- Snapshot includes started/completed matches; they are not eligible
    -- for publication and must not inflate the acceptance denominator.
    SELECT count(*)::integer n FROM mapped
    WHERE provider_epoch ~ '^[0-9]{10}$'
      AND to_timestamp(provider_epoch::double precision)>now()
  )
  SELECT count(*)::integer,count(distinct candidate)::integer,
    jsonb_agg(jsonb_build_object(
      'match_id',candidate,
      'fetched_at',v_captured,
      'match_date',to_char(kickoff_hkt AT TIME ZONE 'UTC','YYYY-MM-DD'),
      'kickoff_hkt',kickoff_hkt,
      'league',tournament,
      'home',home_en,'away',away_en,
      'home_odds',home_price,'draw_odds',draw_price,'away_odds',away_price,
      'provider_fixture_id',event_id,
      'match_quality', CASE WHEN redirect_confidence IS NOT NULL
        THEN redirect_confidence WHEN match_confidence IS NOT NULL
        THEN greatest(match_confidence,0.94) ELSE 0.995 END,
      'raw',jsonb_build_object(
        'capture',item,
        'provider_epoch',provider_epoch,
        'publication_mode','DIRECT_DATABASE_VERIFIED_PROVIDER_SNAPSHOT'
      ),
      'updated_at',now()
    )),
    max(source_upcoming.n)
  INTO v_count,v_distinct,v_rows,v_upcoming
  FROM approved CROSS JOIN source_upcoming;

  IF coalesce(v_upcoming,0)=0 THEN
    RETURN jsonb_build_object('status','NO_UPCOMING_BOOKMAKER_QUOTES',
      'captured_at',v_captured,'total_provider_rows',v_total);
  END IF;
  IF v_count < greatest(1,ceil(coalesce(v_upcoming,0)*0.90)::int)
     OR v_count<>v_distinct OR v_rows IS NULL THEN
    RAISE EXCEPTION 'flashscore_snapshot_identity_gate_failed rows_% provider_total_% upcoming_% distinct_%',
      v_count,v_total,v_upcoming,v_distinct;
  END IF;
  v_result:=public.ft_publish_flashscore_hda_current(
     v_rows,
     jsonb_build_object('publication_mode','DIRECT_DATABASE_VERIFIED_PROVIDER_SNAPSHOT',
       'captured_at',v_captured,'total_provider_rows',v_total,
       'eligible_upcoming_provider_rows',v_upcoming,
       'matched_verified_upcoming_rows',v_count,
       'source_http','RAILWAY_COLLECTOR_SNAPSHOT')
  );
  RETURN v_result || jsonb_build_object(
    'captured_at',v_captured,
    'total_provider_rows',v_total,
    'eligible_upcoming_provider_rows',v_upcoming,
    'verified_upcoming_rows',v_count);
END
$function$
;
CREATE OR REPLACE FUNCTION private.ft_flashscore_direct_publication_cycle()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'private', 'public', 'pg_temp'
AS $function$
DECLARE
  v_previous bigint;
  v_previous_status integer;
  v_previous_timed_out boolean;
  v_payload jsonb;
  v_body text;
  v_result jsonb := jsonb_build_object('status','NO_PRIOR_REQUEST');
  v_new bigint;
  v_last_capture timestamptz;
  v_recent integer;
  v_total_quotes integer;
  v_upcoming integer;
  v_health text;
BEGIN
  SELECT request_id INTO v_previous
  FROM private.ft_flashscore_direct_request_state WHERE singleton=true;

  IF v_previous IS NOT NULL THEN
    SELECT status_code,timed_out,content
      INTO v_previous_status,v_previous_timed_out,v_body
      FROM net._http_response WHERE id=v_previous;
    -- A gateway 502/HTML response must not poison the next cron run.
    v_payload:=null;
    IF v_previous_status=200 AND NOT coalesce(v_previous_timed_out,false)
      AND v_body IS NOT NULL THEN
      BEGIN
        v_payload:=v_body::jsonb;
      EXCEPTION WHEN OTHERS THEN
        v_payload:=null;
      END;
    END IF;
    IF v_previous_status=200 AND NOT coalesce(v_previous_timed_out,false)
      AND v_payload IS NOT NULL THEN
      BEGIN
        v_result:=private.ft_publish_flashscore_collector_snapshot(v_payload);
      EXCEPTION WHEN OTHERS THEN
        v_result:=jsonb_build_object('status','PREVIOUS_CAPTURE_REJECTED',
          'reason',left(SQLERRM,180));
      END;
    ELSE
      v_result:=jsonb_build_object('status','PREVIOUS_SNAPSHOT_UNAVAILABLE',
        'request_id',v_previous,'http_status',v_previous_status,
        'timed_out',v_previous_timed_out);
    END IF;
  END IF;

  -- Exactly ONE Railway snapshot download per successful five-minute cycle;
  -- no Flashscore web-page scraping here. The previous response is published
  -- on the next cycle; the independent 15m Collector remains the sole scraper.
  v_new:=net.http_get(
    url:='https://fast-tracker-dashboard-production.up.railway.app/snapshot',
    timeout_milliseconds:=36000
  );
  INSERT INTO private.ft_flashscore_direct_request_state
    (singleton,request_id,queued_at,completed_at,last_result)
  VALUES (true,v_new,now(),now(),v_result)
  ON CONFLICT(singleton) DO UPDATE SET
    request_id=excluded.request_id,queued_at=excluded.queued_at,
    completed_at=excluded.completed_at,last_result=excluded.last_result;
  -- Health is computed from real source timestamps on the existing 5m poll,
  -- NOT from DB write time. One upsert; no extra cron/scraper/network calls.
  BEGIN
    SELECT max(fetched_at),
      count(*) FILTER (WHERE fetched_at >= now()-interval '20 minutes'
        AND kickoff_hkt>now()
        AND bet365_home IS NOT NULL AND bet365_draw IS NOT NULL AND bet365_away IS NOT NULL)::integer,
      count(*) FILTER (WHERE kickoff_hkt>now()
        AND bet365_home IS NOT NULL AND bet365_draw IS NOT NULL AND bet365_away IS NOT NULL)::integer
      INTO v_last_capture,v_recent,v_total_quotes
    FROM public.bookmaker_odds_current
    WHERE source='FLASHSCORE_BET365';
    SELECT count(*)::integer INTO v_upcoming
    FROM public.flashscore_primary_fixture_current
    WHERE kickoff_hkt>now() AND kickoff_hkt<=now()+interval '48 hours';
    v_health:=CASE WHEN v_upcoming=0 THEN 'NO_UPCOMING'
      WHEN v_last_capture IS NULL OR v_last_capture<now()-interval '20 minutes' THEN 'STALE'
      WHEN v_recent=0 THEN 'ATTENTION' ELSE 'OK' END;
    INSERT INTO public.source_health(source,metric,value_text,status,notes,observed_at,raw)
    VALUES ('FLASHSCORE_BET365','odds_pipeline_health',v_recent::text,v_health,
      'Real bookmaker capture age and verified coverage; earlier odds are not live.',
      now(),jsonb_build_object(
        'last_source_capture',v_last_capture,
        'capture_age_seconds',CASE WHEN v_last_capture IS NULL THEN NULL
          ELSE greatest(0,extract(epoch from now()-v_last_capture)::int) END,
        'recent_complete_quotes',v_recent,
        'stored_upcoming_quotes',v_total_quotes,
        'upcoming_48h_fixtures',v_upcoming,
        'publish_outcome',v_result->>'status',
        'previous_http_status',v_previous_status,
        'request_id',v_new,
        'poll_interval_minutes',5,
        'collector_interval_minutes',15,
        'freshness_window_minutes',20))
    ON CONFLICT(source,metric) DO UPDATE SET
      value_text=excluded.value_text,status=excluded.status,notes=excluded.notes,
      observed_at=excluded.observed_at,raw=excluded.raw;
  EXCEPTION WHEN OTHERS THEN
    -- A monitoring failure must never interrupt publisher or HTTP handoff.
    RAISE NOTICE 'flashscore_odds_pipeline_health_failed: %',left(SQLERRM,120);
  END;
  RETURN v_result||jsonb_build_object('queued_snapshot_request_id',v_new);
END
$function$
;
