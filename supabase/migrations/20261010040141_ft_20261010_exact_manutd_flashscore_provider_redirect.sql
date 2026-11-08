-- Repair the one exact Flashscore provider duplicate omitted by the
-- Man Utd/Manchester Utd alias. Source timestamp, full opponent and scout
-- identity match must all agree before any mutation.
INSERT INTO public.fixture_identity_redirects
 (source_match_id,target_match_id,source_name,confidence,evidence,active,updated_at)
SELECT
 'FS:'||s.external_event_id,
 s.match_id,
 'FLASHSCORE_BET365',
 0.995,
 jsonb_build_object(
  'provider_event_id',s.external_event_id,
  'provider_home',d.home_en,
  'canonical_home',m.home_en,
  'provider_away',d.away_en,
  'canonical_away',m.away_en,
  'provider_kickoff',to_timestamp((s.raw->>'AD')::numeric),
  'canonical_kickoff',m.kickoff_hkt,
  'identity_evidence',s.identity_status,
  'source_confidence',s.match_confidence,
  'rule','EXACT_PROVIDER_EVENT_AND_TIMESTAMP_SCOUT_MATCH'
 ),
 true,
 now()
FROM public.phase15_source_shadow_current s
JOIN public.matches m ON m.hkjc_event_id=s.match_id
JOIN public.matches d ON d.hkjc_event_id='FS:'||s.external_event_id
WHERE s.source_key='FLASHSCORE'
  AND s.external_event_id='hQ2NzTJb'
  AND s.match_id='FB6344'
  AND s.identity_status='EXACT_PAIR'
  AND s.match_confidence>=0.99
  AND m.home_en='Manchester Utd'
  AND d.home_en='Man Utd'
  AND m.away_en=d.away_en
  AND m.kickoff_hkt=to_timestamp((s.raw->>'AD')::numeric)
  AND d.kickoff_hkt=m.kickoff_hkt+interval '1 day'
ON CONFLICT (source_match_id) DO NOTHING;
