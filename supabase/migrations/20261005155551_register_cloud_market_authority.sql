
insert into private.source_registry(
  source_key,display_name,source_group,phase,is_independent,enabled,notes,metadata,created_at,updated_at,decision_enabled
)
values(
  'FLASHSCORE_BET365','Bet365 via Flashscore cloud','market_authority',1,true,true,
  'Active cloud bookmaker authority. Strict canonical fixture identity; HDA only until additional markets are verified.',
  jsonb_build_object(
    'owner','phase0_cloud_cutover',
    'acquisition_mode','railway_headless_flashscore',
    'bookmaker','Bet365',
    'fixture_identity','strict_unique_verified',
    'market_scope',jsonb_build_array('1X2'),
    'live_price_role','reference_only_until_verified_in_play'
  ),
  now(),now(),false
)
on conflict(source_key) do update set
  display_name=excluded.display_name,
  source_group=excluded.source_group,
  phase=excluded.phase,
  is_independent=excluded.is_independent,
  enabled=true,
  notes=excluded.notes,
  metadata=excluded.metadata,
  updated_at=now();

update private.source_registry
set enabled=false,
    notes='Retired as active authority on 2026-10-05; retained only for historical/source-key compatibility.',
    metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('retired_at','2026-10-05','replacement','FLASHSCORE_BET365'),
    updated_at=now()
where source_key='HKJC';

update private.source_registry
set enabled=false,
    notes='Legacy Bet365 static/API bridge retired; cloud Bet365 authority uses FLASHSCORE_BET365.',
    metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('retired_at','2026-10-05','replacement','FLASHSCORE_BET365'),
    updated_at=now()
where source_key='BET365';
