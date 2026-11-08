
create or replace function public.ft_refresh_cloud_odds_movement()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','pg_temp'
as $function$
declare
  v_rows integer := 0;
begin
  delete from public.odds_movement_current;

  insert into public.odds_movement_current (
    hkjc_event_id,captured_at,kickoff_hkt,home,away,
    movement_side,now_odds,
    odds_24h,move_24h_pp,
    odds_2h,move_2h_pp,
    odds_1h,move_1h_pp,
    vol_24h_pp,signal,
    model_side,model_prob,model_alignment,
    match_confidence,alert_score,raw,updated_at
  )
  with ids as (
    select distinct s.hkjc_event_id
    from public.odds_snapshots s
    join public.bet365_current b
      on b.hkjc_event_id=s.hkjc_event_id
     and b.source='FLASHSCORE_BET365'
    where s.source='FLASHSCORE_BET365'
      and s.market='ML'
      and s.hkjc_event_id is not null
  ),
  base as (
    select
      i.hkjc_event_id,
      m.kickoff_hkt,
      m.home_en home,
      m.away_en away,
      b.match_quality,
      c.captured_at,
      c.home_price ch,c.draw_price cd,c.away_price ca,
      o.home_price oh,o.draw_price od,o.away_price oa,
      h1.home_price h1h,h1.draw_price h1d,h1.away_price h1a,
      h2.home_price h2h,h2.draw_price h2d,h2.away_price h2a,
      h24.home_price h24h,h24.draw_price h24d,h24.away_price h24a
    from ids i
    join public.matches m using(hkjc_event_id)
    join public.bet365_current b
      on b.hkjc_event_id=i.hkjc_event_id
     and b.source='FLASHSCORE_BET365'
    cross join lateral (
      select s.*
      from public.odds_snapshots s
      where s.hkjc_event_id=i.hkjc_event_id
        and s.source='FLASHSCORE_BET365'
        and s.market='ML'
      order by s.captured_at desc
      limit 1
    ) c
    cross join lateral (
      select s.*
      from public.odds_snapshots s
      where s.hkjc_event_id=i.hkjc_event_id
        and s.source='FLASHSCORE_BET365'
        and s.market='ML'
      order by s.captured_at
      limit 1
    ) o
    left join lateral (
      select s.*
      from public.odds_snapshots s
      where s.hkjc_event_id=i.hkjc_event_id
        and s.source='FLASHSCORE_BET365'
        and s.market='ML'
        and s.captured_at <= c.captured_at-interval '1 hour'
      order by s.captured_at desc
      limit 1
    ) h1 on true
    left join lateral (
      select s.*
      from public.odds_snapshots s
      where s.hkjc_event_id=i.hkjc_event_id
        and s.source='FLASHSCORE_BET365'
        and s.market='ML'
        and s.captured_at <= c.captured_at-interval '2 hours'
      order by s.captured_at desc
      limit 1
    ) h2 on true
    left join lateral (
      select s.*
      from public.odds_snapshots s
      where s.hkjc_event_id=i.hkjc_event_id
        and s.source='FLASHSCORE_BET365'
        and s.market='ML'
        and s.captured_at <= c.captured_at-interval '24 hours'
      order by s.captured_at desc
      limit 1
    ) h24 on true
  ),
  probs as (
    select b.*,
      case when ch>1 and cd>1 and ca>1 then (1/ch)/(1/ch+1/cd+1/ca) end cph,
      case when ch>1 and cd>1 and ca>1 then (1/cd)/(1/ch+1/cd+1/ca) end cpd,
      case when ch>1 and cd>1 and ca>1 then (1/ca)/(1/ch+1/cd+1/ca) end cpa,
      case when h1h>1 and h1d>1 and h1a>1 then (1/h1h)/(1/h1h+1/h1d+1/h1a) end p1h,
      case when h1h>1 and h1d>1 and h1a>1 then (1/h1d)/(1/h1h+1/h1d+1/h1a) end p1d,
      case when h1h>1 and h1d>1 and h1a>1 then (1/h1a)/(1/h1h+1/h1d+1/h1a) end p1a,
      case when h2h>1 and h2d>1 and h2a>1 then (1/h2h)/(1/h2h+1/h2d+1/h2a) end p2h,
      case when h2h>1 and h2d>1 and h2a>1 then (1/h2d)/(1/h2h+1/h2d+1/h2a) end p2d,
      case when h2h>1 and h2d>1 and h2a>1 then (1/h2a)/(1/h2h+1/h2d+1/h2a) end p2a,
      case when h24h>1 and h24d>1 and h24a>1 then (1/h24h)/(1/h24h+1/h24d+1/h24a) end p24h,
      case when h24h>1 and h24d>1 and h24a>1 then (1/h24d)/(1/h24h+1/h24d+1/h24a) end p24d,
      case when h24h>1 and h24d>1 and h24a>1 then (1/h24a)/(1/h24h+1/h24d+1/h24a) end p24a,
      case when oh>1 and od>1 and oa>1 then (1/oh)/(1/oh+1/od+1/oa) end oph,
      case when oh>1 and od>1 and oa>1 then (1/od)/(1/oh+1/od+1/oa) end opd,
      case when oh>1 and od>1 and oa>1 then (1/oa)/(1/oh+1/od+1/oa) end opa
    from base b
  ),
  chosen as (
    select p.*,
      case
        when abs(cph-coalesce(p24h,p2h,p1h,oph)) >= greatest(
             abs(cpd-coalesce(p24d,p2d,p1d,opd)),
             abs(cpa-coalesce(p24a,p2a,p1a,opa))) then 'H'
        when abs(cpd-coalesce(p24d,p2d,p1d,opd)) >=
             abs(cpa-coalesce(p24a,p2a,p1a,opa)) then 'D'
        else 'A'
      end side
    from probs p
    where cph is not null and cpd is not null and cpa is not null
  )
  select
    x.hkjc_event_id,x.captured_at,x.kickoff_hkt,x.home,x.away,
    x.side,
    case x.side when 'H' then x.ch when 'D' then x.cd else x.ca end now_odds,
    case x.side when 'H' then x.h24h when 'D' then x.h24d else x.h24a end odds_24h,
    case x.side when 'H' then round((x.cph-x.p24h)*100,2)
                when 'D' then round((x.cpd-x.p24d)*100,2)
                else round((x.cpa-x.p24a)*100,2) end move_24h_pp,
    case x.side when 'H' then x.h2h when 'D' then x.h2d else x.h2a end odds_2h,
    case x.side when 'H' then round((x.cph-x.p2h)*100,2)
                when 'D' then round((x.cpd-x.p2d)*100,2)
                else round((x.cpa-x.p2a)*100,2) end move_2h_pp,
    case x.side when 'H' then x.h1h when 'D' then x.h1d else x.h1a end odds_1h,
    case x.side when 'H' then round((x.cph-x.p1h)*100,2)
                when 'D' then round((x.cpd-x.p1d)*100,2)
                else round((x.cpa-x.p1a)*100,2) end move_1h_pp,
    (
      select round((max(z.p)-min(z.p))*100,2)
      from (
        select case x.side
          when 'H' then (1/s.home_price)/(1/s.home_price+1/s.draw_price+1/s.away_price)
          when 'D' then (1/s.draw_price)/(1/s.home_price+1/s.draw_price+1/s.away_price)
          else (1/s.away_price)/(1/s.home_price+1/s.draw_price+1/s.away_price)
        end p
        from public.odds_snapshots s
        where s.hkjc_event_id=x.hkjc_event_id
          and s.source='FLASHSCORE_BET365'
          and s.market='ML'
          and s.captured_at >= x.captured_at-interval '24 hours'
          and s.home_price>1 and s.draw_price>1 and s.away_price>1
      ) z
    ) vol_24h_pp,
    case
      when coalesce(
        abs(case x.side when 'H' then (x.cph-x.p24h)*100 when 'D' then (x.cpd-x.p24d)*100 else (x.cpa-x.p24a)*100 end),
        abs(case x.side when 'H' then (x.cph-x.p2h)*100 when 'D' then (x.cpd-x.p2d)*100 else (x.cpa-x.p2a)*100 end),
        abs(case x.side when 'H' then (x.cph-x.p1h)*100 when 'D' then (x.cpd-x.p1d)*100 else (x.cpa-x.p1a)*100 end)
      ) is null then 'COLLECTING'
      when greatest(
        coalesce(abs(case x.side when 'H' then (x.cph-x.p24h)*100 when 'D' then (x.cpd-x.p24d)*100 else (x.cpa-x.p24a)*100 end),0),
        coalesce(abs(case x.side when 'H' then (x.cph-x.p2h)*100 when 'D' then (x.cpd-x.p2d)*100 else (x.cpa-x.p2a)*100 end),0),
        coalesce(abs(case x.side when 'H' then (x.cph-x.p1h)*100 when 'D' then (x.cpd-x.p1d)*100 else (x.cpa-x.p1a)*100 end),0)
      ) >= 2 then 'MOVE'
      else 'STABLE'
    end signal,
    null::text model_side,
    null::numeric model_prob,
    'NO_MODEL'::text model_alignment,
    coalesce(x.match_quality,1)::numeric match_confidence,
    greatest(
      coalesce(abs(case x.side when 'H' then (x.cph-x.p24h)*100 when 'D' then (x.cpd-x.p24d)*100 else (x.cpa-x.p24a)*100 end),0),
      coalesce(abs(case x.side when 'H' then (x.cph-x.p2h)*100 when 'D' then (x.cpd-x.p2d)*100 else (x.cpa-x.p2a)*100 end),0),
      coalesce(abs(case x.side when 'H' then (x.cph-x.p1h)*100 when 'D' then (x.cpd-x.p1d)*100 else (x.cpa-x.p1a)*100 end),0)
    )::numeric alert_score,
    jsonb_build_object(
      'source','FLASHSCORE_BET365',
      'method','NO_VIG_PROBABILITY_MOVEMENT',
      'baseline_priority',jsonb_build_array('24h','2h','1h','opening'),
      'opening_odds',jsonb_build_object('home',x.oh,'draw',x.od,'away',x.oa),
      'current_odds',jsonb_build_object('home',x.ch,'draw',x.cd,'away',x.ca)
    ),
    now()
  from chosen x;

  get diagnostics v_rows = row_count;

  insert into public.source_health(source,metric,value_text,status,notes,observed_at,raw)
  values(
    'FLASHSCORE_BET365','odds_movement',
    v_rows::text,
    case when v_rows>0 then 'OK' else 'ATTENTION' end,
    'Current odds movement cache rebuilt only from verified cloud Bet365 ML snapshots.',
    now(),
    jsonb_build_object('rows',v_rows,'source','FLASHSCORE_BET365','windows',jsonb_build_array('1h','2h','24h'))
  )
  on conflict(source,metric) do update set
    value_text=excluded.value_text,status=excluded.status,notes=excluded.notes,
    observed_at=excluded.observed_at,raw=excluded.raw;

  return jsonb_build_object('rows',v_rows,'source','FLASHSCORE_BET365');
end
$function$;
