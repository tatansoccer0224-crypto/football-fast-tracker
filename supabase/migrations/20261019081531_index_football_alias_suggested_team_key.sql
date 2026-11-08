CREATE INDEX IF NOT EXISTS ft_super_suggested_team_lookup ON public.football_alias_supertable (suggested_team_key) WHERE suggested_team_key IS NOT NULL;
