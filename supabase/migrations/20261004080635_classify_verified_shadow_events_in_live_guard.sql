
create or replace function public.ft_refresh_live_layer_guard()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  v_now timestamptz := now();
  v_live_count integer := 0;
  v_score_bad integer := 0;
  v_stats_bad integer := 0;
  v_shadow_bad integer := 0;
  v_score_only integer := 0;
  v_no_metrics integer := 0;
  v_events_only integer := 0;
  v_status text := 'OK';
  v_notes text := '';
  v_raw jsonb;
begin
  with live as (
    select hkjc_event_id,fetched_at
    from public.hkjc_live_odds_current
    where fetched_at >= v_now-interval '3 minutes'
  ),
  audit as (
    select
      l.hkjc_event_id,
      case when s.updated_at_source is null or s.updated_at_source < v_now-interval '3 minutes' then true else false end score_bad,
      case
        when coalesce(d.effective_detail_status,'')='NOT_APPLICABLE' then true
        when d.effective_detail_status is null and s.source='HKJC_RUNNING_RESULT' then true
        else false
      end score_only,
      case
        when coalesce(d.effective_detail_status,'')='CAPTURED_NO_METRICS'
          and not (
            sd.captured_at >= v_now-interval '10 minutes'
            and upper(coalesce(sd.detail_status,''))='CAPTURED'
            and case when jsonb_typeof(sd.events)='array' then jsonb_array_length(sd.events) else 0 end > 0
          )
        then true else false
      end no_metrics,
      case
        when coalesce(d.effective_detail_status,'')='CAPTURED_NO_METRICS'
          and sd.captured_at >= v_now-interval '10 minutes'
          and upper(coalesce(sd.detail_status,''))='CAPTURED'
          and case when jsonb_typeof(sd.events)='array' then jsonb_array_length(sd.events) else 0 end > 0
        then true else false
      end events_only,
      case
        when coalesce(d.effective_detail_status,'') in ('NOT_APPLICABLE','CAPTURED_NO_METRICS') then false
        when d.effective_detail_status is null and s.source='HKJC_RUNNING_RESULT' then false
        when st.captured_at_hkt is null or st.captured_at_hkt < v_now-interval '10 minutes' then true
        else false
      end stats_bad,
      case
        when coalesce(s.minute,0)<10 then false
        when coalesce(d.effective_detail_status,'') in ('NOT_APPLICABLE','CAPTURED_NO_METRICS') then false
        when d.effective_detail_status is null and s.source='HKJC_RUNNING_RESULT' then false
        when sh.captured_at_hkt is null or sh.captured_at_hkt < v_now-interval '10 minutes' then true
        else false
      end shadow_bad,
      s.updated_at_source score_at,
      st.captured_at_hkt stats_at,
      sh.captured_at_hkt shadow_at,
      s.minute,
      s.source score_source,
      d.effective_detail_status,
      d.team_stats_count,
      d.events_count,
      d.momentum_count,
      sd.captured_at as shadow_detail_at,
      sd.detail_status as shadow_detail_status,
      case when jsonb_typeof(sd.events)='array' then jsonb_array_length(sd.events) else 0 end as shadow_events_count
    from live l
    left join public.live_score_current s using(hkjc_event_id)
    left join public.live_stats_current st using(hkjc_event_id)
    left join public.live_expected_actual_current sh using(hkjc_event_id)
    left join public.live_detail_shadow_current sd using(hkjc_event_id)
    left join lateral (
      select
        case when jsonb_typeof(h.team_stats)='array' then jsonb_array_length(h.team_stats) else 0 end as team_stats_count,
        case when jsonb_typeof(h.events)='array' then jsonb_array_length(h.events) else 0 end as events_count,
        case when jsonb_typeof(h.momentum)='array' then jsonb_array_length(h.momentum) else 0 end as momentum_count,
        case
          when h.detail_status='CAPTURED'
           and (case when jsonb_typeof(h.team_stats)='array' then jsonb_array_length(h.team_stats) else 0 end)=0
           and (case when jsonb_typeof(h.events)='array' then jsonb_array_length(h.events) else 0 end)=0
           and (case when jsonb_typeof(h.momentum)='array' then jsonb_array_length(h.momentum) else 0 end)=0
          then 'CAPTURED_NO_METRICS'
          else coalesce(h.detail_status,'UNKNOWN')
        end as effective_detail_status
      from public.live_stats_history h
      where h.hkjc_event_id=l.hkjc_event_id
      order by h.captured_at_hkt desc
      limit 1
    ) d on true
  )
  select
    count(*)::int,
    count(*) filter(where score_bad)::int,
    count(*) filter(where stats_bad)::int,
    count(*) filter(where shadow_bad)::int,
    count(*) filter(where score_only)::int,
    count(*) filter(where no_metrics)::int,
    count(*) filter(where events_only)::int,
    coalesce(jsonb_agg(jsonb_build_object(
      'id',hkjc_event_id,'score_bad',score_bad,'stats_bad',stats_bad,'shadow_bad',shadow_bad,
      'score_only',score_only,'no_metrics',no_metrics,'events_only',events_only,
      'detail_status',effective_detail_status,'score_source',score_source,
      'team_stats_count',team_stats_count,'events_count',events_count,'momentum_count',momentum_count,
      'shadow_detail_at',shadow_detail_at,'shadow_detail_status',shadow_detail_status,
      'shadow_events_count',shadow_events_count,'score_at',score_at,'stats_at',stats_at,
      'shadow_at',shadow_at,'minute',minute
    )),'[]'::jsonb)
  into v_live_count,v_score_bad,v_stats_bad,v_shadow_bad,v_score_only,v_no_metrics,v_events_only,v_raw
  from audit;

  if v_live_count=0 then
    v_status:='OK'; v_notes:='No fresh HKJC live matches; guard idle.';
  elsif v_score_bad>0 then
    v_status:='FAIL'; v_notes:=format('Core live delay: %s/%s score rows stale or missing.',v_score_bad,v_live_count);
  elsif v_stats_bad>0 or v_shadow_bad>0 then
    v_status:='WARN'; v_notes:=format('Core live fresh; actual detail lag stats=%s shadow=%s across %s live matches.',v_stats_bad,v_shadow_bad,v_live_count);
  elsif v_score_only>0 or v_no_metrics>0 or v_events_only>0 then
    v_status:='WARN'; v_notes:=format('Core live fresh; source limits score_only=%s no_metrics=%s events_only=%s across %s live matches.',v_score_only,v_no_metrics,v_events_only,v_live_count);
  else
    v_status:='OK'; v_notes:=format('All %s live matches inside layer freshness gates.',v_live_count);
  end if;

  insert into public.source_health(source,metric,status,value_text,notes,observed_at,raw)
  values(
    'LIVE_LAYER_GUARD','heartbeat',v_status,
    concat('live=',v_live_count,' score_bad=',v_score_bad,' stats_bad=',v_stats_bad,' shadow_bad=',v_shadow_bad,' score_only=',v_score_only,' no_metrics=',v_no_metrics,' events_only=',v_events_only),
    v_notes,v_now,
    jsonb_build_object('live_count',v_live_count,'score_bad',v_score_bad,'stats_bad',v_stats_bad,
      'shadow_bad',v_shadow_bad,'score_only',v_score_only,'no_metrics',v_no_metrics,
      'events_only',v_events_only,'matches',v_raw)
  )
  on conflict(source,metric) do update set
    status=excluded.status,value_text=excluded.value_text,notes=excluded.notes,
    observed_at=excluded.observed_at,raw=excluded.raw;

  return jsonb_build_object('status',v_status,'live_count',v_live_count,'score_bad',v_score_bad,
    'stats_bad',v_stats_bad,'shadow_bad',v_shadow_bad,'score_only',v_score_only,
    'no_metrics',v_no_metrics,'events_only',v_events_only);
end;
$function$;
