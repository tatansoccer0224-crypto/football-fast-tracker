
update public.phase15_source_registry
set discovery_enabled=false,
    trust_status='QUARANTINED',
    notes='Direct SofaScore edge probe returned HTTP 403 on 2026-09-24; retained for future self-hosted/client-impersonation experiments.',
    updated_at=now()
where source_key='SOFASCORE';

insert into public.phase15_source_registry
  (source_key,source_kind,source_url,trust_status,active,discovery_enabled,trust_score,notes)
values
  ('FLASHSCORE','EXPERIMENTAL','https://global.flashscore.ninja/2/x/feed/','EXPERIMENTAL',true,true,0.20,
   'Phase 1.5 lightweight Flashscore feed scout based on open-source protocol reverse-engineering; shadow-only until trust promotion.')
on conflict (source_key) do update
set source_url=excluded.source_url,
    trust_status='EXPERIMENTAL',
    active=true,
    discovery_enabled=true,
    notes=excluded.notes,
    updated_at=now();
