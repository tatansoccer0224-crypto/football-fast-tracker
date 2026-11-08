DO $migration$
DECLARE job_row record;
BEGIN
  FOR job_row IN
    SELECT jobid
    FROM cron.job
    WHERE jobname IN (
      'ft-prune-public-matches-12h-7d',
      'ft-prune-private-matches-12h-7d'
    )
  LOOP
    PERFORM cron.unschedule(job_row.jobid);
  END LOOP;

  PERFORM cron.schedule(
    'ft-prune-public-matches-12h-7d',
    '20 * * * *',
    $job$DELETE FROM public.matches m
      WHERE (
          m.kickoff_hkt < now() - interval '12 hours'
          OR (m.kickoff_hkt > now() + interval '7 days' AND NOT coalesce(m.in_play, false))
        )
        AND NOT EXISTS (
          SELECT 1 FROM public.fixture_identity_redirects r
          WHERE r.source_match_id = m.canonical_event_id
             OR r.target_match_id = m.canonical_event_id
        );$job$
  );

  PERFORM cron.schedule(
    'ft-prune-private-matches-12h-7d',
    '30 * * * *',
    $job$DELETE FROM private.matches m
      WHERE m.kickoff_hkt < now() - interval '12 hours'
         OR (m.kickoff_hkt > now() + interval '7 days' AND NOT coalesce(m.in_play, false));$job$
  );
END
$migration$;

DELETE FROM public.matches m
WHERE (
    m.kickoff_hkt < now() - interval '12 hours'
    OR (m.kickoff_hkt > now() + interval '7 days' AND NOT coalesce(m.in_play, false))
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.fixture_identity_redirects r
    WHERE r.source_match_id = m.canonical_event_id
       OR r.target_match_id = m.canonical_event_id
  );

DELETE FROM private.matches m
WHERE m.kickoff_hkt < now() - interval '12 hours'
   OR (m.kickoff_hkt > now() + interval '7 days' AND NOT coalesce(m.in_play, false));
