-- Phase 36B: authorized, checksum-backed, small-batch after-use lineup retirement.
-- The Edge worker MUST archive and SHA256-readback the exact input JSONL first.
-- This RPC never accesses the public client; execution only by service_role.
create or replace function public.ft_retire_verified_lineup_batch(
  p_archive_path text,
  p_archive_sha text,
  p_archive_bytes integer,
  p_rows jsonb
) returns integer
language plpgsql
security invoker
set search_path to pg_catalog,public,private,storage,pg_temp
as $function$
declare v_expected integer; v_eligible integer; v_deleted integer; v_distinct integer;
begin
  perform pg_advisory_xact_lock(20261018,36);
  if p_archive_sha !~ '^[a-f0-9]{64}$'
     or p_archive_path !~ '^lineup-cold/v3/[0-9]+-[0-9]+-[a-f0-9]{64}[.]jsonl[.]txt$'
     or right(p_archive_path,length(p_archive_sha||'.jsonl.txt'))<>p_archive_sha||'.jsonl.txt'
  then raise exception 'INVALID_ARCHIVED_LINEUP_SHA_PATH'; end if;
  if p_archive_bytes<100 or p_archive_bytes>3500000
     or not exists(select 1 from storage.objects o
       where o.bucket_id='fast-tracker-ingest'
         and o.name=p_archive_path
         and o.metadata->>'size'=p_archive_bytes::text)
  then raise exception 'ARCHIVED_LINEUP_OBJECT_NOT_PRESENT'; end if;
  if jsonb_typeof(p_rows)<>'array' then
    raise exception 'INVALID_LINEUP_BATCH'; end if;
  v_expected=jsonb_array_length(p_rows);
  if v_expected<1 or v_expected>200 then
    raise exception 'LINEUP_BATCH_BOUND_EXCEEDED'; end if;
  select count(distinct (r->>'id')::bigint) into v_distinct
  from jsonb_array_elements(p_rows) r
  where r->>'id' ~ '^[0-9]{1,16}$';
  if v_distinct<>v_expected then raise exception 'DUPLICATE_OR_INVALID_LINEUP_IDS'; end if;
  with evidence as (
    select x.id,x.match_id,x.source_name,x.player_key,x.fetched_at,x.raw
    from jsonb_to_recordset(p_rows) as x(
      id bigint,match_id text,source_name text,player_key text,fetched_at timestamptz,raw jsonb)
  )
  select count(*) into v_eligible
  from evidence e join public.phase2_match_lineup_evidence l on l.id=e.id
  where l.match_id=e.match_id
    and l.source_name=e.source_name
    and l.player_key is not distinct from e.player_key
    and l.fetched_at=e.fetched_at
    and l.raw is not distinct from e.raw
    and l.fetched_at<now()-interval '14 days'
    and not exists(select 1 from public.flashscore_primary_fixture_current f where f.match_id=l.match_id)
    and not exists(select 1 from public.canonical_fixture_current f
      where f.match_id=l.match_id and f.kickoff_hkt>now()-interval '2 days');
  if v_eligible<>v_expected then
    raise exception 'ARCHIVED_LINEUP_SOURCE_CHANGED_OR_STILL_ACTIVE'; end if;
  with evidence as (
    select x.id,x.match_id,x.source_name,x.player_key,x.fetched_at,x.raw
    from jsonb_to_recordset(p_rows) as x(
      id bigint,match_id text,source_name text,player_key text,fetched_at timestamptz,raw jsonb)
  ), deleted as (
    delete from public.phase2_match_lineup_evidence l using evidence e
    where l.id=e.id and l.match_id=e.match_id and l.source_name=e.source_name
      and l.player_key is not distinct from e.player_key
      and l.fetched_at=e.fetched_at and l.raw is not distinct from e.raw
      and l.fetched_at<now()-interval '14 days'
      and not exists(select 1 from public.flashscore_primary_fixture_current f where f.match_id=l.match_id)
      and not exists(select 1 from public.canonical_fixture_current f
        where f.match_id=l.match_id and f.kickoff_hkt>now()-interval '2 days')
    returning l.id
  )
  select count(*) into v_deleted from deleted;
  if v_deleted<>v_expected then raise exception 'PARTIAL_LINEUP_DELETE_ROLLED_BACK'; end if;
  return v_deleted;
end;
$function$;
revoke all on function public.ft_retire_verified_lineup_batch(text,text,integer,jsonb)
  from PUBLIC,anon,authenticated;
grant execute on function public.ft_retire_verified_lineup_batch(text,text,integer,jsonb)
  to service_role;
