
alter table public.flashscore_fixture_current
  drop constraint if exists flashscore_fixture_current_identity_status_check;

alter table public.flashscore_fixture_current
  add constraint flashscore_fixture_current_identity_status_check
  check (identity_status in (
    'EXACT_EXISTING','CREATED','DEFERRED_NEARBY','DISCOVERED_ONLY','INVALID_TIME','AMBIGUOUS'
  ));
