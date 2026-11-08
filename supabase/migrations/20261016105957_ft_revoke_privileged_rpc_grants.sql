-- Internal server-side Fast Tracker RPCs. SEC DEFINER callers must never
-- be available to browser anon/authenticated credentials.
-- Verified in production: all four functions are explicitly granted to
-- postgres + service_role and both roles retain EXECUTE after revocation.
-- The bulk resolver invokes ft_resolve_team_name, so restrict both together.
-- Public website reads through authenticated Edge endpoints, not these RPCs.
REVOKE EXECUTE ON FUNCTION public.ft_commit_flashscore_bet365_ingest(jsonb,jsonb,jsonb,jsonb,jsonb,jsonb,jsonb)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.ft_internal_app_match_detail_critical(text)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.ft_resolve_team_name(text,text)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.ft_resolve_team_names_bulk(text,text[])
  FROM PUBLIC, anon, authenticated;
