-- Phase 50: populate the existing all-in-one alias inventory from ALREADY
-- INGESTED Football-Data CSV result rows. NEVER infer identity from club names.
-- Read 22 source league codes; no network calls or cron. Zero new paid spend.
-- Archive/source provenance remains PRIVATE_USE. No public user grants.
create or replace function public.ft_sync_fd_super_alias_inventory()
returns jsonb language plpgsql volatile security invoker
set search_path to pg_catalog,public,pg_temp
as $fn$
declare v_total integer; v_leagues integer; v_collisions integer;
        v_inserted integer; v_available integer;
begin
  if not pg_try_advisory_xact_lock(hashtext('ft_fd_super_roster_import'),20261018)
  then return jsonb_build_object('status','BUSY','inserted',0); end if;

  with clubs as materialized (
    select d.league_code,trim(d.home_team) as team
    from public.football_data_matches d where d.source_kind='RESULTS'
      and d.league_code ~ '^[A-Z0-9]{1,4}$'
      and d.home_team is not null
    union
    select d.league_code,trim(d.away_team)
    from public.football_data_matches d where d.source_kind='RESULTS'
      and d.league_code ~ '^[A-Z0-9]{1,4}$'
      and d.away_team is not null
  ), keyed as (
    select league_code,team,public.ft_team_name_key(team) alias_key
    from clubs where team<>''
  )
  select count(*),count(distinct league_code),
    (select count(*) from
       (select league_code,alias_key from keyed
         group by league_code,alias_key having count(*)>1) duplicates)
  into v_total,v_leagues,v_collisions from keyed
  where nullif(alias_key,'') is not null;
  if v_total<300 or v_total>1200 or v_leagues<20 or v_leagues>30
      or v_collisions<>0
  then raise exception 'FD_SOURCE_ROSTER_INCOMPLETE_OR_AMBIGUOUS entries %, leagues %, collisions %',
     v_total,v_leagues,v_collisions; end if;

  with observed as materialized (
    select d.league_code,trim(d.home_team) team,d.fetched_at
    from public.football_data_matches d
    where d.source_kind='RESULTS' and d.league_code ~ '^[A-Z0-9]{1,4}$'
      and nullif(trim(d.home_team),'') is not null
    union all
    select d.league_code,trim(d.away_team) team,d.fetched_at
    from public.football_data_matches d
    where d.source_kind='RESULTS' and d.league_code ~ '^[A-Z0-9]{1,4}$'
      and nullif(trim(d.away_team),'') is not null
  ), dedup as (
    select league_code,team,public.ft_team_name_key(team) alias_key,
      count(*)::integer observations,max(fetched_at) newest_source
    from observed group by league_code,team
  )
  insert into public.football_alias_supertable(
    source,alias_key,competition_key,provider_team_id,provider_name,
    source_competition,resolution_status,confidence,resolution_method,
    observations,last_observed_at,evidence)
  select 'FOOTBALL_DATA',n.alias_key,lower(n.league_code),'',n.team,
    n.league_code,'UNMATCHED',0,
    'SOURCE_ROSTER_ONLY_NO_CROSS_PROVIDER_IDENTITY_CLAIM',
    n.observations,n.newest_source,
    jsonb_build_object('origin','FOOTBALL_DATA_CSV_STORED_RESULTS',
      'licensing','PRIVATE_USE','identityLinked',false)
  from dedup n where nullif(n.alias_key,'') is not null
  on conflict do nothing;
  get diagnostics v_inserted=row_count;

  select count(*) into v_available
  from public.football_alias_supertable a
  where a.source='FOOTBALL_DATA';
  if v_available<v_total then
    raise exception 'FD_INVENTORY_IMPORT_PARTIAL expected %, found %',
      v_total,v_available;
  end if;
  return jsonb_build_object('status','SOURCE_INVENTORY_IMPORTED_NO_IDENTITY_PROMOTION',
    'source','FOOTBALL_DATA','leagues',v_leagues,'available',v_available,
    'inserted',v_inserted,'sourceRequests',0,'verifiedIdentityLinksAdded',0);
end;
$fn$;
revoke all on function public.ft_sync_fd_super_alias_inventory() from PUBLIC,anon,authenticated;
grant execute on function public.ft_sync_fd_super_alias_inventory() to service_role;
