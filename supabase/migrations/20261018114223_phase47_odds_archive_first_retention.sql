-- Phase47: bounded odds history archive-first retirement.
-- Recent odds movement remains in PostgreSQL for at least seven full days.
-- No bookmaker fetch, odds source change or current market mutation.
create table if not exists private.ft_odds_retirement_ledger (
  archive_sha256 text primary key check(archive_sha256 ~ '^[a-f0-9]{64}$'),
  storage_path text not null unique,
  archive_bytes integer not null check(archive_bytes between 100 and 4000000),
  oldest_captured_at timestamptz not null,
  newest_captured_at timestamptz not null,
  min_id bigint not null,
  max_id bigint not null,
  retired_rows integer not null check(retired_rows between 1 and 1000),
  retired_at timestamptz not null default now()
);
revoke all on private.ft_odds_retirement_ledger from PUBLIC,anon,authenticated;
grant select,insert on private.ft_odds_retirement_ledger to service_role;
alter table private.ft_odds_retirement_ledger enable row level security;

create or replace function public.ft_odds_retention_candidates()
returns jsonb language sql stable security invoker
set search_path to pg_catalog,public,private,pg_temp
as $fn$
with eligible as materialized (
 select s.id,s.captured_at,to_jsonb(s) full_row,md5(to_jsonb(s)::text) row_md5
 from public.odds_snapshots s
 where s.captured_at < now()-interval '7 days'
   and s.source='FLASHSCORE_BET365' and s.market='ML'
   and not exists (
     select 1 from public.flashscore_primary_fixture_current f
     where f.match_id=s.match_id and f.kickoff_hkt>=now()-interval '48 hours')
 order by s.captured_at,s.id
 limit 1000
)
select jsonb_build_object(
 'minAgeDays',7,'rows',coalesce(jsonb_agg(
   jsonb_build_object('row',full_row,'rowMd5',row_md5)
   order by captured_at,id),'[]'::jsonb))
from eligible;
$fn$;
revoke all on function public.ft_odds_retention_candidates()
 from PUBLIC,anon,authenticated;
grant execute on function public.ft_odds_retention_candidates() to service_role;

create or replace function public.ft_retire_proven_odds_batch(
 p_rows jsonb,p_storage_path text,p_archive_sha text,p_archive_bytes integer
) returns integer language plpgsql volatile security invoker
set search_path to pg_catalog,public,private,storage,pg_temp
as $fn$
declare
 v_count integer;
 v_unique integer;
 v_eligible integer;
 v_deleted integer;
 v_min bigint;
 v_max bigint;
 v_first timestamptz;
 v_last timestamptz;
begin
 if not pg_try_advisory_xact_lock(hashtext('ft_odds_history_retire'),20261018)
 then raise exception 'ODDS_RETIRE_BUSY'; end if;
 if jsonb_typeof(p_rows)<>'array'
    or p_archive_sha !~ '^[a-f0-9]{64}$'
    or p_archive_bytes not between 100 and 4000000
 then raise exception 'ODDS_RETIRE_INVALID_ARCHIVE_ARGS'; end if;
 v_count:=jsonb_array_length(p_rows);
 if v_count not between 1 and 1000 then
   raise exception 'ODDS_RETIRE_BATCH_BOUND'; end if;
 select count(distinct (j->>'id')::bigint), min((j->>'id')::bigint),
   max((j->>'id')::bigint)
 into v_unique,v_min,v_max
 from jsonb_array_elements(p_rows) j
 where j->>'id' ~ '^[0-9]{1,16}$'
   and j->>'rowMd5' ~ '^[a-f0-9]{32}$';
 if v_unique<>v_count then raise exception 'ODDS_RETIRE_DUPLICATE_OR_BAD_IDS'; end if;
 if p_storage_path <> 'odds-history/v1/'||v_min||'-'||v_max||'-'||p_archive_sha||'.jsonl.txt'
    or not exists (
      select 1 from storage.objects o
      where o.bucket_id='fast-tracker-ingest'
        and o.name=p_storage_path
        and (o.metadata->>'size')::integer=p_archive_bytes
    )
 then raise exception 'ODDS_RETIRE_PRIVATE_ARCHIVE_MISSING'; end if;
 with wanted as (
  select (j->>'id')::bigint id,j->>'rowMd5' row_md5
  from jsonb_array_elements(p_rows) j
 )
 select count(*), min(s.captured_at),max(s.captured_at)
 into v_eligible,v_first,v_last
 from wanted w join public.odds_snapshots s on s.id=w.id
 where md5(to_jsonb(s)::text)=w.row_md5
  and s.captured_at<now()-interval '7 days'
  and s.source='FLASHSCORE_BET365' and s.market='ML'
  and not exists(
    select 1 from public.flashscore_primary_fixture_current f
    where f.match_id=s.match_id and f.kickoff_hkt>=now()-interval '48 hours');
 if v_eligible<>v_count then raise exception 'ODDS_RETIRE_SOURCE_CHANGED_OR_ACTIVE'; end if;
 with wanted as (
  select (j->>'id')::bigint id,j->>'rowMd5' row_md5
  from jsonb_array_elements(p_rows) j
 ), gone as (
  delete from public.odds_snapshots s using wanted w
  where s.id=w.id and md5(to_jsonb(s)::text)=w.row_md5
   and s.captured_at<now()-interval '7 days'
   and s.source='FLASHSCORE_BET365' and s.market='ML'
   and not exists(
     select 1 from public.flashscore_primary_fixture_current f
     where f.match_id=s.match_id and f.kickoff_hkt>=now()-interval '48 hours')
  returning s.id
 )
 select count(*) into v_deleted from gone;
 if v_deleted<>v_count then raise exception 'ODDS_RETIRE_PARTIAL_DELETE_ROLLBACK'; end if;
 insert into private.ft_odds_retirement_ledger(
   archive_sha256,storage_path,archive_bytes,oldest_captured_at,
   newest_captured_at,min_id,max_id,retired_rows
 ) values(p_archive_sha,p_storage_path,p_archive_bytes,v_first,v_last,v_min,v_max,v_deleted);
 return v_deleted;
end;
$fn$;
revoke all on function public.ft_retire_proven_odds_batch(jsonb,text,text,integer)
 from PUBLIC,anon,authenticated;
grant execute on function public.ft_retire_proven_odds_batch(jsonb,text,text,integer)
 to service_role;
