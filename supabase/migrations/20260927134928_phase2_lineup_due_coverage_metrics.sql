
alter table public.phase2_lineup_hourly_metrics
  add column if not exists due_90m integer,
  add column if not exists due_confirmed integer,
  add column if not exists due_coverage_pct numeric,
  add column if not exists next_6h integer,
  add column if not exists next_6h_full integer;

create or replace function public.snapshot_phase2_lineup_coverage()
returns void
language plpgsql
security invoker
set search_path=public
as $$
declare
  v_total integer;
  v_missing integer;
  v_partial integer;
  v_predicted integer;
  v_confirmed integer;
  v_coverage numeric;
  v_due integer;
  v_due_confirmed integer;
  v_due_pct numeric;
  v_6h integer;
  v_6h_full integer;
begin
  select
    count(*),
    count(*) filter(where lineup_status='MISSING'),
    count(*) filter(where lineup_status='PARTIAL'),
    count(*) filter(where lineup_status='PREDICTED_FULL'),
    count(*) filter(where lineup_status='CONFIRMED'),
    round(100.0*count(*) filter(where lineup_status in ('PREDICTED_FULL','CONFIRMED'))/nullif(count(*),0),1),
    count(*) filter(where kickoff_hkt<=now()+interval '90 minutes'),
    count(*) filter(where kickoff_hkt<=now()+interval '90 minutes' and lineup_status='CONFIRMED'),
    round(100.0*count(*) filter(where kickoff_hkt<=now()+interval '90 minutes' and lineup_status='CONFIRMED')/
      nullif(count(*) filter(where kickoff_hkt<=now()+interval '90 minutes'),0),1),
    count(*) filter(where kickoff_hkt<=now()+interval '6 hours'),
    count(*) filter(where kickoff_hkt<=now()+interval '6 hours' and lineup_status in ('PREDICTED_FULL','CONFIRMED'))
  into v_total,v_missing,v_partial,v_predicted,v_confirmed,v_coverage,v_due,v_due_confirmed,v_due_pct,v_6h,v_6h_full
  from public.phase2_lineup_coverage_current;

  insert into public.phase2_lineup_hourly_metrics(
    bucket,total_matches,missing,partial,predicted_full,confirmed,coverage_pct,
    due_90m,due_confirmed,due_coverage_pct,next_6h,next_6h_full
  ) values (
    date_trunc('hour',now()),v_total,v_missing,v_partial,v_predicted,v_confirmed,coalesce(v_coverage,0),
    v_due,v_due_confirmed,coalesce(v_due_pct,0),v_6h,v_6h_full
  )
  on conflict(bucket) do update set
    total_matches=excluded.total_matches,missing=excluded.missing,partial=excluded.partial,
    predicted_full=excluded.predicted_full,confirmed=excluded.confirmed,coverage_pct=excluded.coverage_pct,
    due_90m=excluded.due_90m,due_confirmed=excluded.due_confirmed,due_coverage_pct=excluded.due_coverage_pct,
    next_6h=excluded.next_6h,next_6h_full=excluded.next_6h_full,created_at=now();

  insert into public.source_health(source,metric,value_text,status,notes,observed_at,raw)
  values(
    'PHASE2_LINEUP_COVERAGE','hourly',
    jsonb_build_object('total48h',v_total,'full48h',v_predicted+v_confirmed,'coveragePct',coalesce(v_coverage,0),
                       'due90m',v_due,'dueConfirmed',v_due_confirmed,'dueCoveragePct',coalesce(v_due_pct,0),
                       'next6h',v_6h,'next6hFull',v_6h_full)::text,
    case when v_due=0 or coalesce(v_due_pct,0)>=50 then 'OK' else 'WARN' end,
    'Phase 1 kickoff-aware lineup coverage. Due metric only counts fixtures within 90 minutes of kickoff.',
    now(),
    jsonb_build_object('total48h',v_total,'missing',v_missing,'partial',v_partial,'predictedFull',v_predicted,'confirmed',v_confirmed,
                       'coveragePct',coalesce(v_coverage,0),'due90m',v_due,'dueConfirmed',v_due_confirmed,
                       'dueCoveragePct',coalesce(v_due_pct,0),'next6h',v_6h,'next6hFull',v_6h_full)
  )
  on conflict(source,metric) do update set
    value_text=excluded.value_text,status=excluded.status,notes=excluded.notes,
    observed_at=excluded.observed_at,raw=excluded.raw;
end;
$$;

revoke all on function public.snapshot_phase2_lineup_coverage() from public,anon,authenticated;
grant execute on function public.snapshot_phase2_lineup_coverage() to postgres,service_role;
