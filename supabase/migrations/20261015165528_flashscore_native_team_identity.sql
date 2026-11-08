-- Flashscore is the team and fixture identity authority. Legacy rows are
-- privately archived, never translated by replacing an old provider prefix.
set local lock_timeout='5s';
set local statement_timeout='90s';

create table private.ft_identity_retired_rows (
  relation_name text not null,
  row_hash text not null,
  original_row jsonb not null,
  retired_at timestamptz not null default now(),
  primary key(relation_name,row_hash)
);
alter table private.ft_identity_retired_rows enable row level security;
revoke all on private.ft_identity_retired_rows from public,anon,authenticated,service_role;

-- Detach old keys from ancillary evidence in bounded per-table transactions.
-- Facts stay in place; the original link is stored by stable primary key.
create function private.ft_detach_legacy_identity_links(p_relation regclass)
returns jsonb language plpgsql security invoker set search_path=pg_catalog,public,private,pg_temp as $detach_links$
declare r record; trig record; pred text; pk_fields text; payload text; n bigint; total bigint:=0;
begin
 create temporary table if not exists ft_identity_trigger_state on commit drop as
 select tgrelid,tgname,tgenabled from pg_trigger where not tgisinternal;
 if not exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
 where c.oid=p_relation and c.relkind='r' and n.nspname in ('public','private') and c.relname not like '%archive%')
 then raise exception 'UNSUPPORTED_IDENTITY_RELATION'; end if;
 for r in select attname,not attnotnull nullable from pg_attribute
 where attrelid=p_relation and attnum>0 and not attisdropped
 and (attname='team_key' or right(attname,9)='_team_key') and atttypid='text'::regtype loop
  pred:=format('%I is not null and %I !~ %L',r.attname,r.attname,'^FS_TEAM:[A-Za-z0-9]{6,16}$');
  select string_agg(format('%L,t.%I',a.attname,a.attname),',' order by a.attnum) into pk_fields
  from pg_index i join pg_attribute a on a.attrelid=i.indrelid and a.attnum=any(i.indkey)
  where i.indrelid=p_relation and i.indisprimary;
  if pk_fields is null then raise exception 'MISSING_STABLE_ROW_KEY: %',p_relation; end if;
  payload:=format('jsonb_build_object(''detached_column'',%L,''previous_value'',t.%I,''row_identity'',jsonb_build_object(%s))',r.attname,r.attname,pk_fields);
  execute format('insert into private.ft_identity_retired_rows(relation_name,row_hash,original_row) select %L,md5((%s)::text),%s from %s t where %s on conflict do nothing',p_relation::text,payload,payload,p_relation,pred);
  -- ALTER TABLE holds the table lock until all original triggers are restored.
  for trig in select tgname,tgenabled from pg_trigger where tgrelid=p_relation and not tgisinternal and tgenabled<>'D' loop
   execute format('alter table %s disable trigger %I',p_relation,trig.tgname);
   -- Use a local temporary state list rather than changing any trigger policy.
  end loop;
  if r.nullable then execute format('update %s set %I=null where %s',p_relation,r.attname,pred);
  else execute format('delete from %s where %s',p_relation,pred); end if;
  get diagnostics n=row_count; total:=total+n;
  -- Trigger states are captured by the caller from pg_trigger before mutation.
  for trig in select * from ft_identity_trigger_state where tgrelid=p_relation and tgenabled<>'D' loop
   execute format('alter table %s enable %s trigger %I',p_relation,
   case trig.tgenabled when 'A' then 'always' when 'R' then 'replica' else '' end,trig.tgname);
  end loop;
  if not exists(select 1 from pg_constraint where conrelid=p_relation and conname='ft_fs_key_'||r.attname) then
   execute format('alter table %s add constraint %I check (%I is null or %I ~ %L)',p_relation,'ft_fs_key_'||r.attname,r.attname,r.attname,'^FS_TEAM:[A-Za-z0-9]{6,16}$');
  end if;
 end loop;
 return jsonb_build_object('relation',p_relation::text,'detached_links',total);
end $detach_links$;
revoke all on function private.ft_detach_legacy_identity_links(regclass) from public,anon,authenticated,service_role;

-- Privately archive the old registry graph, then rebuild the same interfaces.
create index if not exists ft_team_alias_reference_key_lookup on private.team_alias_reference(canonical_team_key);
select private.ft_detach_legacy_identity_links('private.team_alias_reference'::regclass);
do $detach$
declare r record; qualified text;
begin
 for r in select n.nspname,c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
 where n.nspname='public' and c.relkind='r' and c.relname in (
 'team_alias_evidence_v2','team_alias_registry_v2','team_alias_gap_queue_v2',
 'team_name_master','team_name_context_master','team_name_event_context_master',
 'team_name_event_context_quarantine','football_alias_offline_pair_evidence',
 'football_alias_supertable') loop
  qualified:=format('%I.%I',r.nspname,r.relname);
  execute format('insert into private.ft_identity_retired_rows(relation_name,row_hash,original_row) select %L,md5(to_jsonb(t)::text),to_jsonb(t) from %s t on conflict do nothing',qualified,qualified);
  execute format('delete from %s',qualified);
 end loop;
 insert into private.ft_identity_retired_rows(relation_name,row_hash,original_row)
 select 'public.team_entities_v2',md5(to_jsonb(t)::text),to_jsonb(t) from public.team_entities_v2 t on conflict do nothing;
 delete from public.team_entities_v2;
end $detach$;

-- Different Flashscore IDs can legitimately have the same display name.
alter table public.team_entities_v2 drop constraint team_entities_v2_name_key_key;
create index team_entities_v2_name_lookup on public.team_entities_v2(name_key);

-- A legacy key cannot silently return through another writer or old queue.
do $guard$
declare r record;
begin
 for r in select n.nspname,c.relname,a.attname
 from pg_attribute a join pg_class c on c.oid=a.attrelid join pg_namespace n on n.oid=c.relnamespace
 where n.nspname in ('public','private') and c.relkind='r'
 and a.attnum>0 and not a.attisdropped and format_type(a.atttypid,a.atttypmod)='text'
 and (a.attname='team_key' or right(a.attname,9)='_team_key')
 and c.relname in ('team_entities_v2','team_alias_evidence_v2','team_alias_registry_v2',
 'team_alias_gap_queue_v2','team_name_master','team_name_context_master','team_name_event_context_master',
 'team_name_event_context_quarantine','football_alias_offline_pair_evidence','football_alias_supertable') loop
  execute format('alter table %I.%I add constraint %I check (%I is null or %I ~ %L)',r.nspname,r.relname,
   'ft_fs_key_'||r.attname,r.attname,r.attname,'^FS_TEAM:[A-Za-z0-9]{6,16}$');
 end loop;
end $guard$;

-- Native source IDs, source epoch and home/away orientation are independent
-- of any pre-existing team-name registry or old canonical key.
create view private.ft_native_flashscore_events with (security_invoker=true) as
select external_event_id,home_external_id,away_external_id,league_external_id,
 home_name,away_name,league_name,kickoff_utc,fetched_at
from public.phase15_source_shadow_current
where source_key='FLASHSCORE'
 and external_event_id~'^[A-Za-z0-9]{6,16}$'
 and home_external_id~'^[A-Za-z0-9]{6,16}$'
 and away_external_id~'^[A-Za-z0-9]{6,16}$'
 and league_external_id~'^[A-Za-z0-9]{6,16}$'
 and home_external_id<>away_external_id
 and nullif(trim(home_name),'') is not null and nullif(trim(away_name),'') is not null
 and raw->>'AA'=external_event_id and raw->>'PX'=home_external_id and raw->>'PY'=away_external_id
 and case when raw->>'AD'~'^[0-9]{10}$' then
   abs(extract(epoch from kickoff_utc)-((raw->>'AD')::numeric))<=60 else false end
 and fetched_at<=now()+interval '1 minute';
revoke all on private.ft_native_flashscore_events from public,anon,authenticated;
grant select on private.ft_native_flashscore_events to service_role;

create view private.ft_native_team_alias_evidence with (security_invoker=true) as
with fs as (select * from private.ft_native_flashscore_events),
provider_events as (
 select 'FLASHSCORE'::text as source,external_event_id as source_event_id,
 external_event_id as fs_event_id,home_name as source_home,away_name as source_away,
 home_external_id as provider_home_id,away_external_id as provider_away_id,
 league_name as source_competition,fetched_at as captured_at,
 null::text as source_url,home_external_id,away_external_id,league_external_id
 from fs
 union all
 select case a.provider when 'BETCLAN' then 'BCL' when 'SPORTYTRADER' then 'STA' end,
 a.source_event_id,f.external_event_id,a.source_home,a.source_away,'','',
 a.source_competition,a.captured_at,a.source_url,f.home_external_id,f.away_external_id,f.league_external_id
 from public.adviser_source_observations a join fs f on a.canonical_event_id='FS:'||f.external_event_id
 where a.identity_status='VERIFIED' and a.provider in ('BETCLAN','SPORTYTRADER')
 and abs(extract(epoch from a.source_kickoff-f.kickoff_utc))<=60
 and lower(trim(a.source_home))=lower(trim(f.home_name))
 and lower(trim(a.source_away))=lower(trim(f.away_name))
 and a.captured_at<=f.kickoff_utc and a.captured_at<=now()+interval '1 minute'
 union all
 select s.source_key,s.external_event_id,f.external_event_id,s.home_name,s.away_name,
 coalesce(s.home_external_id,''),coalesce(s.away_external_id,''),s.league_name,s.fetched_at,
 s.raw->>'source_url',f.home_external_id,f.away_external_id,f.league_external_id
 from public.phase15_source_shadow_current s join fs f on s.match_id='FS:'||f.external_event_id
 where s.source_key in ('FOREBET','FOTMOB','SOFASCORE','FOOTBALL_DATA')
 and s.identity_status in ('VERIFIED_IDENTITY','VERIFIED','EXACT_PAIR')
 and abs(extract(epoch from s.kickoff_utc-f.kickoff_utc))<=60
 and lower(trim(s.home_name))=lower(trim(f.home_name))
 and lower(trim(s.away_name))=lower(trim(f.away_name))
 and s.fetched_at<=now()+interval '1 minute'
)
select p.source,p.source_event_id,p.fs_event_id,p.source_competition,p.captured_at,p.source_url,
 x.side,x.source_name,x.provider_team_id,x.flashscore_team_id,p.league_external_id
from provider_events p cross join lateral (values
 ('HOME',p.source_home,p.provider_home_id,p.home_external_id),
 ('AWAY',p.source_away,p.provider_away_id,p.away_external_id)
) x(side,source_name,provider_team_id,flashscore_team_id);
revoke all on private.ft_native_team_alias_evidence from public,anon,authenticated;
grant select on private.ft_native_team_alias_evidence to service_role;

create function private.ft_refresh_flashscore_native_identity()
returns jsonb language plpgsql security invoker set search_path=pg_catalog,public,private,pg_temp as $refresh$
declare n_entities integer; n_aliases integer;
begin
 if not pg_try_advisory_xact_lock(hashtext('ft_flashscore_native_identity')) then
  return jsonb_build_object('status','BUSY'); end if;
 with legs as (
 select home_external_id id,home_name name,fetched_at,external_event_id from private.ft_native_flashscore_events
 union all select away_external_id,away_name,fetched_at,external_event_id from private.ft_native_flashscore_events
 ), latest as (select distinct on(id) * from legs order by id,fetched_at desc,external_event_id)
 insert into public.team_entities_v2(team_key,name_key,canonical_name_en,status,first_seen_at,last_seen_at,updated_at)
 select 'FS_TEAM:'||id,public.ft_team_name_key(name),name,'ACTIVE',fetched_at,fetched_at,now() from latest
 on conflict(team_key) do update set name_key=excluded.name_key,canonical_name_en=excluded.canonical_name_en,
 last_seen_at=greatest(team_entities_v2.last_seen_at,excluded.last_seen_at),updated_at=now()
 where (team_entities_v2.name_key,team_entities_v2.canonical_name_en,team_entities_v2.last_seen_at)
 is distinct from (excluded.name_key,excluded.canonical_name_en,greatest(team_entities_v2.last_seen_at,excluded.last_seen_at));

 with evidence as (
 select source,public.ft_team_name_key(source_name) alias_key,
 public.ft_team_name_key(coalesce(source_competition,'')) competition_key,
 coalesce(provider_team_id,'') provider_team_id,min(source_name) provider_name,
 coalesce(source_competition,'') source_competition,'FS_TEAM:'||flashscore_team_id team_key,
 count(distinct source_event_id)::integer observations,min(source_event_id) example,
 min(source_url) source_url,max(captured_at) observed_at,
 jsonb_build_object('authority','FLASHSCORE','method','EXACT_EVENT_ORIENTED_TEAM_IDS_AND_KICKOFF',
 'flashscore_team_id',flashscore_team_id,'flashscore_league_id',min(league_external_id),
 'flashscore_event_id',min(fs_event_id)) evidence
 from private.ft_native_team_alias_evidence
 group by source,public.ft_team_name_key(source_name),public.ft_team_name_key(coalesce(source_competition,'')),
 coalesce(provider_team_id,''),coalesce(source_competition,''),flashscore_team_id
 ), safe as (
 select source,alias_key,coalesce(competition_key,'') competition_key,provider_team_id,
 min(provider_name) provider_name,min(source_competition) source_competition,
 case when count(distinct team_key)=1 then min(team_key) end team_key,
 case when count(distinct team_key)=1 then 'VERIFIED' else 'AMBIGUOUS' end status,
 sum(observations)::integer observations,min(example) example,min(source_url) source_url,
 max(observed_at) observed_at,jsonb_build_object('native_evidence',jsonb_agg(evidence)) evidence
 from evidence where alias_key is not null group by source,alias_key,competition_key,provider_team_id
 )
 insert into public.football_alias_supertable(source,alias_key,competition_key,provider_team_id,
 provider_name,source_competition,verified_team_key,resolution_status,confidence,resolution_method,
 observations,source_event_id_example,source_detail_url,last_observed_at,evidence)
 select source,alias_key,competition_key,provider_team_id,provider_name,source_competition,team_key,
 status,case when status='VERIFIED' then 1 else 0 end,'FLASHSCORE_NATIVE_EVENT_EVIDENCE',
 observations,example,source_url,observed_at,evidence from safe
 on conflict(source,alias_key,competition_key,provider_team_id) do update set
 verified_team_key=excluded.verified_team_key,resolution_status=excluded.resolution_status,
 confidence=excluded.confidence,observations=excluded.observations,last_observed_at=excluded.last_observed_at,
 evidence=excluded.evidence,refreshed_at=now()
 where (football_alias_supertable.verified_team_key,football_alias_supertable.resolution_status,
 football_alias_supertable.observations,football_alias_supertable.last_observed_at,football_alias_supertable.evidence)
 is distinct from (excluded.verified_team_key,excluded.resolution_status,
 excluded.observations,excluded.last_observed_at,excluded.evidence);

 insert into public.football_alias_supertable(source,alias_key,provider_team_id,provider_name,
 verified_team_key,resolution_status,confidence,resolution_method,last_observed_at,evidence)
 select 'FLASHSCORE_TEAM_ID',substring(team_key from 9),substring(team_key from 9),canonical_name_en,
 team_key,'VERIFIED',1,'NATIVE_PROVIDER_TEAM_ID',last_seen_at,jsonb_build_object('authority','FLASHSCORE')
 from public.team_entities_v2
 on conflict(source,alias_key,competition_key,provider_team_id) do nothing;

 -- Name-only registries expose ambiguity instead of choosing a same-named ID.
 with names as (
 select source,alias_key,verified_team_key team_key,min(provider_name) name,
 max(last_observed_at) observed_at,max(observations) observations
 from public.football_alias_supertable where resolution_status='VERIFIED'
 group by source,alias_key,verified_team_key
 ), classified as (
 select n.*,count(*) over(partition by source,alias_key) identities from names n
 )
 insert into public.team_alias_registry_v2(source,alias_key,team_key,alias,status,confidence,
 evidence_count,distinct_event_count,verification_method,first_seen_at,last_seen_at,updated_at)
 select source,alias_key,team_key,name,case when identities=1 then 'VERIFIED' else 'AMBIGUOUS' end,
 case when identities=1 then 1 else 0 end,observations,observations,'FLASHSCORE_NATIVE_EVENT_EVIDENCE',
 observed_at,observed_at,now() from classified
 on conflict(source,alias_key,team_key) do update set status=excluded.status,confidence=excluded.confidence,
 evidence_count=excluded.evidence_count,distinct_event_count=excluded.distinct_event_count,
 last_seen_at=excluded.last_seen_at,updated_at=now()
 where (team_alias_registry_v2.status,team_alias_registry_v2.confidence,
 team_alias_registry_v2.evidence_count,team_alias_registry_v2.last_seen_at)
 is distinct from (excluded.status,excluded.confidence,excluded.evidence_count,excluded.last_seen_at);
 update public.team_alias_registry_v2 r set status='AMBIGUOUS',confidence=0,updated_at=now()
 where r.status<>'AMBIGUOUS' and exists(select 1 from public.football_alias_supertable s
 where s.source=r.source and s.alias_key=r.alias_key and s.resolution_status='AMBIGUOUS');
 perform public.ft_refresh_team_name_master();
 select count(*) into n_entities from public.team_entities_v2;
 select count(*) into n_aliases from public.football_alias_supertable;
 return jsonb_build_object('authority','FLASHSCORE','entities',n_entities,'aliases',n_aliases);
end $refresh$;
revoke all on function private.ft_refresh_flashscore_native_identity() from public,anon,authenticated;
grant execute on function private.ft_refresh_flashscore_native_identity() to service_role;

-- Source-backed collision evidence must be able to quarantine a prior alias.
create or replace function public.ft_preserve_verified_alias_v2() returns trigger
language plpgsql security invoker set search_path=pg_catalog as $$
begin
 if (new.source,new.alias_key,new.team_key) is distinct from (old.source,old.alias_key,old.team_key)
 then raise exception 'IMMUTABLE_ALIAS_IDENTITY'; end if;
 if new.verification_method='FLASHSCORE_NATIVE_EVENT_EVIDENCE' then return new; end if;
 if old.status='VERIFIED' and new.status<>'VERIFIED' then return old; end if;
 return new;
end $$;

-- Refresh only changed observations; do not truncate the identity read path.
create or replace function public.ft_refresh_team_name_master() returns jsonb
language plpgsql security invoker set search_path=pg_catalog,public,pg_temp as $$
begin
 with names as (
 select 'CANONICAL_EN'::text source,canonical_name_en source_name,name_key source_key,
 team_key,canonical_name_en,canonical_name_zh,'VERIFIED'::text status,1::numeric confidence,
 0::integer event_count,first_seen_at,last_seen_at,'["FLASHSCORE_NATIVE_ENTITY"]'::jsonb evidence_sources
 from public.team_entities_v2
 union all
 select r.source,r.alias,r.alias_key,r.team_key,t.canonical_name_en,t.canonical_name_zh,
 r.status,r.confidence,r.distinct_event_count,r.first_seen_at,r.last_seen_at,
 jsonb_build_array(r.verification_method)
 from public.team_alias_registry_v2 r join public.team_entities_v2 t using(team_key)
 ), classified as (
 select n.*,count(*) over(partition by source,source_key) identities from names n
 )
 insert into public.team_name_master(source,source_name,source_key,team_key,canonical_name_en,
 canonical_name_zh,status,confidence,event_count,first_seen_at,last_seen_at,evidence_sources,updated_at)
 select source,source_name,source_key,team_key,canonical_name_en,canonical_name_zh,
 case when identities=1 then status else 'AMBIGUOUS' end,
 case when identities=1 then confidence else 0 end,event_count,first_seen_at,last_seen_at,evidence_sources,now()
 from classified
 on conflict(source,source_key,team_key) do update set source_name=excluded.source_name,
 canonical_name_en=excluded.canonical_name_en,canonical_name_zh=excluded.canonical_name_zh,
 status=excluded.status,confidence=excluded.confidence,event_count=excluded.event_count,
 last_seen_at=excluded.last_seen_at,evidence_sources=excluded.evidence_sources,updated_at=now()
 where (team_name_master.source_name,team_name_master.canonical_name_en,team_name_master.canonical_name_zh,
 team_name_master.status,team_name_master.confidence,team_name_master.event_count,
 team_name_master.last_seen_at,team_name_master.evidence_sources)
 is distinct from (excluded.source_name,excluded.canonical_name_en,excluded.canonical_name_zh,
 excluded.status,excluded.confidence,excluded.event_count,excluded.last_seen_at,excluded.evidence_sources);
 return (select jsonb_build_object('total_rows',count(*),'verified_rows',count(*) filter(where status='VERIFIED'),
 'ambiguous_rows',count(*) filter(where status='AMBIGUOUS'),'authority','FLASHSCORE') from public.team_name_master);
end $$;
revoke all on function public.ft_refresh_team_name_master() from public,anon,authenticated;
grant execute on function public.ft_refresh_team_name_master() to service_role;

create or replace view public.team_identity_current with (security_invoker=true) as
select m.source,m.source_name,m.source_key,m.team_key,m.canonical_name_en,m.canonical_name_zh,
 m.status,m.confidence,m.event_count,m.first_seen_at,m.last_seen_at,m.evidence_sources,m.updated_at
from public.team_name_master m
where m.team_key~'^FS_TEAM:[A-Za-z0-9]{6,16}$' and m.status='VERIFIED'
 and (select count(distinct x.team_key) from public.team_name_master x
 where x.source=m.source and x.source_key=m.source_key)=1;

-- These spelling/legacy seeders must never promote old registry evidence again.
create or replace function public.ft_seed_verified_legacy_names() returns jsonb
language sql security invoker set search_path=pg_catalog as $$select jsonb_build_object('status','RETIRED','authority','FLASHSCORE')$$;
create or replace function public.ft_refresh_brazilianfootball_team_names() returns jsonb
language sql security invoker set search_path=pg_catalog as $$select jsonb_build_object('status','RETIRED_NAME_ONLY_SEED','authority','FLASHSCORE')$$;
create or replace function private.ft_refresh_football_alias_supertable() returns jsonb
language sql security invoker set search_path=pg_catalog,private as $$select private.ft_refresh_flashscore_native_identity()$$;
-- Preserve Forebet collection/publication; retire only name-only alias learners.
create or replace function public.ft_learn_forebet_availability_identity() returns trigger
language plpgsql security invoker set search_path=pg_catalog as $$begin return new; end$$;
create or replace function public.ft_learn_forebet_availability_context() returns trigger
language plpgsql security invoker set search_path=pg_catalog as $$begin return new; end$$;
create or replace function public.ft_persist_forebet_availability_registry() returns trigger
language plpgsql security invoker set search_path=pg_catalog as $$begin return new; end$$;

select private.ft_refresh_flashscore_native_identity();
-- Reuse one existing scout cadence; no additional job or provider request.
select cron.alter_job(50,command := (select command from cron.job where jobid=50)
 || E'\nselect private.ft_refresh_flashscore_native_identity();');

-- All new/replaced functions keep service-only execution permissions.
revoke all on function public.ft_seed_verified_legacy_names(),public.ft_refresh_brazilianfootball_team_names(),
 private.ft_refresh_football_alias_supertable() from public,anon,authenticated;
grant execute on function public.ft_seed_verified_legacy_names(),public.ft_refresh_brazilianfootball_team_names(),
 private.ft_refresh_football_alias_supertable() to service_role;
notify pgrst,'reload schema';
CREATE OR REPLACE FUNCTION public.ft_alias_super_lookup(p_source text, p_name text, p_competition text DEFAULT NULL::text, p_provider_team_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare normalized text; league_key text; rid text; verified text; suggested text; matches_count int; match_status text;
begin
 if p_source is null or p_name is null or length(trim(p_name))=0
    or length(p_name)>180 or length(p_source)>90
    or coalesce(length(p_competition),0)>150 or coalesce(length(p_provider_team_id),0)>90
 then return jsonb_build_object('status','INVALID_INPUT'); end if;
 p_source:=case upper(trim(p_source)) when 'BETCLAN' then 'BCL' when 'SPORTYTRADER' then 'STA' else upper(trim(p_source)) end;
 normalized:=coalesce(nullif(regexp_replace(lower(p_name),'[^a-z0-9]','','g'),''),'u:'||md5(lower(p_name)));
 league_key:=regexp_replace(lower(coalesce(p_competition,'')),'[^a-z0-9]','','g');
 if p_source='FLASHSCORE_TEAM_ID' then normalized:=trim(p_name); end if;
 rid:=coalesce(nullif(p_provider_team_id,''),case when p_source='FLASHSCORE_TEAM_ID' then normalized else '' end);
 if rid='' and league_key='' and p_source in ('FLASHSCORE','FOTMOB')
 and (select count(distinct provider_team_id) from public.football_alias_supertable
 where source=p_source and alias_key=normalized and provider_team_id<>'')>1
 and (select count(distinct competition_key) from public.football_alias_supertable
 where source=p_source and alias_key=normalized and provider_team_id<>'')>1
 then
 return jsonb_build_object('source',p_source,'source_name',p_name,'status','AMBIGUOUS',
 'verified_team_key',null,'suggested_team_key',null,
 'reason','MULTIPLE_SOURCE_TEAM_IDS_DIFFERENT_LEAGUES');
 end if;
 -- A supplied stable ID is an identity gate, never silently ignored.
 with ranked as (
 select *,
 case when rid<>'' and provider_team_id=rid then 0
      when rid='' and league_key<>'' and competition_key=league_key then 0
      when rid='' and competition_key='' then 1
      else 5 end tier
 from public.football_alias_supertable
 where source=p_source and alias_key=normalized
 and (rid='' and (provider_team_id='' or league_key<>'') or rid<>'' and provider_team_id=rid)
 and (league_key='' or competition_key in ('',league_key))
 ),
 first_tier as (select * from ranked where tier=(select min(tier) from ranked)),
 result as(
 select count(*) n,count(distinct verified_team_key) filter(where resolution_status='VERIFIED') verified_n,
 min(verified_team_key) filter(where resolution_status='VERIFIED') verified_team,
 count(distinct suggested_team_key) filter(where resolution_status='CANDIDATE') candidate_n,
 min(suggested_team_key) filter(where resolution_status='CANDIDATE') candidate_team,
 count(*) filter(where resolution_status='AMBIGUOUS') ambiguous_n
 from first_tier
 )
 select n,case when verified_n=1 and ambiguous_n=0 then verified_team else null end,
 case when verified_n=0 and candidate_n=1 and ambiguous_n=0 then candidate_team else null end,
 case when verified_n>1 or ambiguous_n>0 then 'AMBIGUOUS'
      when verified_n=1 then 'VERIFIED'
      when candidate_n=1 then 'CANDIDATE'
      else 'UNMATCHED' end
 into matches_count,verified,suggested,match_status
 from result;
 return jsonb_build_object('source',p_source,'source_name',p_name,'competition',p_competition,
 'provider_team_id',p_provider_team_id,'status',match_status,'verified_team_key',verified,
 'suggested_team_key',suggested,'matches_examined',coalesce(matches_count,0));
end $function$
;
revoke all on function public.ft_alias_super_lookup(text,text,text,text) from public,anon,authenticated;
grant execute on function public.ft_alias_super_lookup(text,text,text,text) to service_role;
CREATE OR REPLACE FUNCTION public.ft_adviser_exact_candidates(p_provider text, p_home text, p_away text, p_competition text, p_kickoff timestamp with time zone)
 RETURNS TABLE(match_id text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with aliases as materialized (
   select public.ft_alias_super_lookup(case upper(p_provider) when 'BETCLAN' then 'BCL' when 'SPORTYTRADER' then 'STA' else upper(p_provider) end,p_home,p_competition) home_alias,
          public.ft_alias_super_lookup(case upper(p_provider) when 'BETCLAN' then 'BCL' when 'SPORTYTRADER' then 'STA' else upper(p_provider) end,p_away,p_competition) away_alias
  )
  select f.match_id
  from public.flashscore_primary_fixture_current f
  join private.ft_native_flashscore_events n on f.match_id='FS:'||n.external_event_id
  cross join aliases a
  where f.identity_authority='FLASHSCORE'
    and f.provider_identity_status='VERIFIED_IDENTITY'
    and f.status='SCHEDULED'
    and f.kickoff_hkt>now()
    and f.fetched_at between now()-interval '36 hours' and now()+interval '1 minute'
    and abs(extract(epoch from f.kickoff_hkt-p_kickoff))<=60
    and ((lower(trim(f.home_en))=lower(trim(p_home)) and lower(trim(f.away_en))=lower(trim(p_away)))
      or (a.home_alias->>'status'='VERIFIED' and a.away_alias->>'status'='VERIFIED'
      and a.home_alias->>'verified_team_key'='FS_TEAM:'||n.home_external_id
      and a.away_alias->>'verified_team_key'='FS_TEAM:'||n.away_external_id))
    and (
      lower(trim(p_competition))=lower(trim(f.league))
      or right(lower(trim(p_competition)),length(trim(f.league))+1)=' '||lower(trim(f.league))
      or exists (
        select 1 from public.adviser_competition_alias_evidence a
        where upper(trim(a.provider))=upper(trim(p_provider))
          and lower(trim(a.source_competition))=lower(trim(p_competition))
          and lower(trim(a.canonical_competition))=lower(trim(f.league))
      )
    )
$function$
;
