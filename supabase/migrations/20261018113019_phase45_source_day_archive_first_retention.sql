-- Phase 45: archive-FIRST, bounded source-day retention.
-- Preserves the current and previous Hong Kong calendar days.
-- Existing ft-source-next-day-archive-24h cron is NOT modified.
-- This function only retires snapshots after a separately authenticated,
-- SHA256 full-download verified immutable private Storage archive and the
-- Postgres restore dry-run have succeeded for the EXACT source-day record.
create table if not exists private.ft_source_day_retirement_ledger (
  source_key text not null check(source_key in ('FLASHSCORE','FOREBET')),
  source_day date not null,
  record_count integer not null check(record_count between 1 and 5000),
  source_content_md5 text not null check(source_content_md5 ~ '^[a-f0-9]{32}$'),
  storage_bucket text not null default 'fast-tracker-ingest'
    check(storage_bucket='fast-tracker-ingest'),
  storage_path text not null unique,
  archive_sha256 text not null check(archive_sha256 ~ '^[a-f0-9]{64}$'),
  archive_bytes integer not null check(archive_bytes between 100 and 5500000),
  retired_at timestamptz not null default now(),
  primary key(source_key,source_day)
);
revoke all on private.ft_source_day_retirement_ledger from PUBLIC,anon,authenticated;
grant select,insert on private.ft_source_day_retirement_ledger to service_role;
alter table private.ft_source_day_retirement_ledger enable row level security;

create or replace function public.ft_source_day_retention_candidates()
returns jsonb language plpgsql stable security invoker
set search_path to pg_catalog,public,private,pg_temp
as $fn$
declare
 v_today date := (now() at time zone 'Asia/Hong_Kong')::date;
 v_items jsonb;
 v_remaining integer;
 v_older_than_archive_window integer;
begin
 with selected as materialized (
   select s.source_key,s.source_day,s.record_count,s.content_md5
   from private.ft_source_day_snapshot s
   where s.source_day < v_today - 1
     and s.source_day >= v_today - 30
   order by s.source_day,s.source_key
   limit 3
 )
 select coalesce(jsonb_agg(jsonb_build_object(
   'sourceKey',source_key,'sourceDay',source_day,
   'recordCount',record_count,'contentMd5',content_md5)
   order by source_day,source_key),'[]'::jsonb)
 into v_items from selected;
 select count(*) into v_remaining from private.ft_source_day_snapshot
 where source_day < v_today - 1 and source_day >= v_today - 30;
 select count(*) into v_older_than_archive_window
 from private.ft_source_day_snapshot where source_day < v_today - 30;
 return jsonb_build_object('hktToday',v_today,'keepDays',2,
   'candidates',v_items,'pendingEligible',v_remaining,
   'blockedOlderThan30Days',v_older_than_archive_window);
end;
$fn$;
revoke all on function public.ft_source_day_retention_candidates()
 from PUBLIC,anon,authenticated;
grant execute on function public.ft_source_day_retention_candidates() to service_role;

create or replace function public.ft_source_day_retire_proven(
  p_source_key text,p_source_day date,p_content_md5 text,p_record_count integer,
  p_archive_path text,p_archive_sha text,p_archive_bytes integer
) returns integer language plpgsql volatile security invoker
set search_path to pg_catalog,public,private,storage,pg_temp
as $fn$
declare
 v_today date := (now() at time zone 'Asia/Hong_Kong')::date;
 v_row record;
 v_deleted integer;
 v_expected_path text;
begin
 if not pg_try_advisory_xact_lock(hashtext('ft_source_day_retention'),20261018)
 then raise exception 'SOURCE_RETIRE_BUSY'; end if;
 if p_source_key not in ('FLASHSCORE','FOREBET')
    or p_source_day is null
    or p_source_day >= v_today - 1
    or p_source_day < v_today - 30
    or p_content_md5 !~ '^[a-f0-9]{32}$'
    or p_archive_sha !~ '^[a-f0-9]{64}$'
    or p_record_count not between 1 and 5000
    or p_archive_bytes not between 100 and 5500000
 then raise exception 'SOURCE_RETIRE_INVALID_OR_RECENT'; end if;
 v_expected_path:='source-day/v1/'||p_source_day::text||'/'||
   p_source_key||'-'||p_archive_sha||'.json.txt';
 if p_archive_path is distinct from v_expected_path
    or not exists (
      select 1 from storage.objects o
      where o.bucket_id='fast-tracker-ingest'
        and o.name=v_expected_path
        and (o.metadata->>'size')::integer=p_archive_bytes
    )
 then raise exception 'SOURCE_RETIRE_ARCHIVE_OBJECT_MISMATCH'; end if;
 select s.source_key,s.source_day,s.record_count,s.content_md5,
   md5(s.source_rows::text) as computed_md5
 into v_row from private.ft_source_day_snapshot s
 where s.source_key=p_source_key and s.source_day=p_source_day
 for update;
 if not found then raise exception 'SOURCE_RETIRE_ROW_NOT_FOUND'; end if;
 if v_row.content_md5 <> p_content_md5
    or v_row.computed_md5 <> p_content_md5
    or v_row.record_count <> p_record_count
 then raise exception 'SOURCE_RETIRE_ROW_CHANGED_AFTER_ARCHIVE'; end if;
 delete from private.ft_source_day_snapshot s
 where s.source_key=p_source_key and s.source_day=p_source_day
    and s.record_count=p_record_count and s.content_md5=p_content_md5
    and md5(s.source_rows::text)=p_content_md5
    and s.source_day < (now() at time zone 'Asia/Hong_Kong')::date - 1;
 get diagnostics v_deleted=row_count;
 if v_deleted<>1 then raise exception 'SOURCE_RETIRE_PARTIAL_ROLLBACK'; end if;
 insert into private.ft_source_day_retirement_ledger (
   source_key,source_day,record_count,source_content_md5,
   storage_path,archive_sha256,archive_bytes
 ) values (
   p_source_key,p_source_day,p_record_count,p_content_md5,
   p_archive_path,p_archive_sha,p_archive_bytes
 );
 return v_deleted;
end;
$fn$;
revoke all on function public.ft_source_day_retire_proven(
 text,date,text,integer,text,text,integer) from PUBLIC,anon,authenticated;
grant execute on function public.ft_source_day_retire_proven(
 text,date,text,integer,text,text,integer) to service_role;
