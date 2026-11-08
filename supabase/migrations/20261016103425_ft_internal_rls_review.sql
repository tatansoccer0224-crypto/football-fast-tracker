-- Internal Fast Tracker tables. No browser / user API access is intended.
-- postgres and service_role (both BYPASSRLS in the verified production instance)
-- retain server-only access; anon and authenticated receive no policies or grants.
-- DO NOT APPLY without owner review of any security-definer/view dependencies.
REVOKE ALL PRIVILEGES ON TABLE
  public.phase1_identity_deferred_queue,
  public.phase1_h2h_provider_event_map,
  public.phase1_h2h_provider_meetings,
  private.ft_flashscore_direct_request_state
FROM anon, authenticated;
ALTER TABLE public.phase1_identity_deferred_queue ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.phase1_h2h_provider_event_map ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.phase1_h2h_provider_meetings ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.ft_flashscore_direct_request_state ENABLE ROW LEVEL SECURITY;
