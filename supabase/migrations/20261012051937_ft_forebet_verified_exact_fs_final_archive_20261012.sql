-- Source-verified final score evidence for *already archived* Forebet forecasts.
-- No provider request, no score fabrication, no change to 180-day archive horizon.
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

CREATE OR REPLACE FUNCTION private.ft_preserve_forebet_verified_final(p_event_id text)
RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'pg_catalog','public','private','pg_temp'
AS $f$
DECLARE n integer := 0;
BEGIN
 IF p_event_id !~ '^FS:[A-Za-z0-9]{6,16}$' THEN RETURN 0; END IF;
 UPDATE public.forebet_archive a
   SET raw = a.raw || jsonb_build_object('verified_final_result',
     jsonb_build_object(
       'source','FLASHSCORE','match_id',p_event_id,
       'home_goals',(s.raw->>'AG')::integer,
       'away_goals',(s.raw->>'AH')::integer,
       'source_captured_at',s.fetched_at,
       'kickoff_utc',s.kickoff_utc,
       'identity_gate','EXACT_FS_PROVIDER_ID_AND_KICKOFF'
     ))
 FROM public.matches m
 JOIN public.phase15_source_shadow_current s
   ON s.source_key='FLASHSCORE' AND m.canonical_event_id='FS:'||s.external_event_id
 WHERE m.canonical_event_id=p_event_id
   AND a.match_id=m.canonical_event_id
   AND a.captured_at<=m.kickoff_hkt
   AND s.raw->>'AB'='3' AND s.raw->>'AC'='3'
   AND (s.raw->>'AG')~'^[0-9]{1,2}$'
   AND (s.raw->>'AH')~'^[0-9]{1,2}$'
   AND s.kickoff_utc IS NOT NULL
   AND abs(extract(epoch FROM (s.kickoff_utc-m.kickoff_hkt)))<=1200
   AND s.fetched_at >= s.kickoff_utc
   AND s.fetched_at <= s.kickoff_utc+interval '7 days'
   AND NOT a.raw ? 'verified_final_result';
 GET DIAGNOSTICS n=ROW_COUNT;
 RETURN n;
END
$f$;

CREATE OR REPLACE FUNCTION private.ft_preserve_forebet_final_before_fixture_prune()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'pg_catalog','private','public','pg_temp'
AS $t$
BEGIN
  PERFORM private.ft_preserve_forebet_verified_final(OLD.canonical_event_id);
  RETURN OLD;
END
$t$;

CREATE TRIGGER ft_preserve_forebet_final_before_fixture_prune
BEFORE DELETE ON public.matches
FOR EACH ROW WHEN (OLD.canonical_event_id LIKE 'FS:%')
EXECUTE FUNCTION private.ft_preserve_forebet_final_before_fixture_prune();

-- One-time verified historical backfill for still registered exact FS fixtures.
SELECT private.ft_preserve_forebet_verified_final(a.match_id)
FROM public.forebet_archive a
JOIN public.matches m ON m.canonical_event_id=a.match_id
WHERE a.match_id LIKE 'FS:%' AND m.kickoff_hkt<=now()
GROUP BY a.match_id;

REVOKE ALL ON FUNCTION private.ft_preserve_forebet_verified_final(text)
FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.ft_preserve_forebet_final_before_fixture_prune()
FROM PUBLIC,anon,authenticated;
