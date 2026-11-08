-- Phase 10: two narrow source competition aliases corroborated by nine
-- one-to-one, exact oriented team names + UTC kickoff + independently verified
-- Flashscore identity, all inside the existing service-role-only matcher.
-- These rows DO NOT match fixtures alone, bypass exact identity, or modify
-- source observations. Revalidation is performed via original ingestion RPC.
insert into public.adviser_competition_alias_evidence
 (provider,source_competition,canonical_competition,evidence)
values
 ('BETCLAN','USA USL Championship','USL Championship',
 jsonb_build_object(
   'audit_date','2026-10-17','source_capture_at','2026-10-17T09:36:06.296408Z',
   'proof','EXACT_SOURCE_TEAMS_ORIENTATION_VERIFIED_FLASHSCORE_KICKOFF_UNIQUE',
   'unique_verified_event_count',4,
   'exact_event_examples',jsonb_build_array(
      jsonb_build_object('source_event_id','1493746','flashscore_match_id','FS:dY05m3lS',
         'home','FC Tulsa','away','Oakland Roots','kickoff_utc','2026-10-18T00:00:00Z','kickoff_delta_seconds',0),
      jsonb_build_object('source_event_id','1493751','flashscore_match_id','FS:67CAdtRr',
         'home','Monterey Bay','away','Colorado Springs','kickoff_utc','2026-10-18T02:00:00Z','kickoff_delta_seconds',0)
   ),
   'security','NEVER_VERIFY_FROM_COMPETITION_ALIAS_ALONE'
 )),
 ('BETCLAN','Norway 1. Division','OBOS-ligaen',
 jsonb_build_object(
   'audit_date','2026-10-17','source_capture_at','2026-10-17T09:36:06.296408Z',
   'proof','EXACT_SOURCE_TEAMS_ORIENTATION_VERIFIED_FLASHSCORE_KICKOFF_UNIQUE',
   'unique_verified_event_count',5,
   'exact_event_examples',jsonb_build_array(
     jsonb_build_object('source_event_id','1495984','flashscore_match_id','FS:Cx1Fm77r',
         'home','Egersund','away','Sogndal','kickoff_utc','2026-10-18T12:30:00Z','kickoff_delta_seconds',0),
     jsonb_build_object('source_event_id','1495990','flashscore_match_id','FS:MkT4bOL0',
         'home','Stromsgodset','away','Haugesund','kickoff_utc','2026-10-18T12:30:00Z','kickoff_delta_seconds',0)
   ),
   'security','NEVER_VERIFY_FROM_COMPETITION_ALIAS_ALONE'
 ))
on conflict(provider,source_competition,canonical_competition) do nothing;
