-- Review-only alias additions verified against Flashscore kickoff and both-team evidence on 2026-10-19.
-- Idempotent: never override an existing manual correction; no new scraping or verified identity promotion.
INSERT INTO private.ft_extra_adviser_name_alias
  (provider, source_key, canonical_key, evidence)
VALUES
  ('PRIMATIPS', 'alianzavalledupar', 'alianza', 'SOURCE_FLASHscore_SAME_KICKOFF_OTHER_TEAM_EXACT_20261019_REVIEW_ONLY'),
  ('PRIMATIPS', 'boyacachico', 'chico', 'SOURCE_FLASHscore_SAME_KICKOFF_OTHER_TEAM_MATCH_20261019_REVIEW_ONLY'),
  ('PRIMATIPS', 'spsanjose', 'sportingfc', 'SOURCE_FLASHscore_SAME_KICKOFF_OTHER_TEAM_EXACT_20261019_REVIEW_ONLY'),
  ('STATAREA', 'alqadisiyah', 'alqadsiah', 'SOURCE_FLASHscore_SAME_KICKOFF_OTHER_TEAM_EXACT_20261019_REVIEW_ONLY')
ON CONFLICT (provider, source_key) DO NOTHING;
