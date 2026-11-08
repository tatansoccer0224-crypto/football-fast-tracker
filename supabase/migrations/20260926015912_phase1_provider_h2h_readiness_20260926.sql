
create or replace view public.phase1_provider_h2h_readiness as
with providers(source) as (
  values ('SOFASCORE'::text),('FOTMOB'::text),('FLASHSCORE'::text),('FOOTBALL_DATA'::text)
),
master as (
  select upper(source) source, count(*) filter (where upper(coalesce(status,''))='VERIFIED')::bigint verified_aliases
  from public.team_name_master group by 1
),
event_map as (
  select upper(provider) source, count(*)::bigint event_mappings,
         count(*) filter (where upper(coalesce(mapping_status,''))='VERIFIED')::bigint verified_event_mappings
  from public.phase1_h2h_provider_event_map group by 1
),
meetings as (
  select upper(provider) source, count(*)::bigint meeting_rows,
         count(*) filter (where upper(coalesce(quality,'')) in ('VERIFIED','H2H_OK','OK'))::bigint quality_meeting_rows
  from public.phase1_h2h_provider_meetings group by 1
)
select p.source, coalesce(m.verified_aliases,0) verified_aliases,
       coalesce(e.event_mappings,0) event_mappings,
       coalesce(e.verified_event_mappings,0) verified_event_mappings,
       coalesce(h.meeting_rows,0) meeting_rows,
       coalesce(h.quality_meeting_rows,0) quality_meeting_rows
from providers p
left join master m using(source)
left join event_map e using(source)
left join meetings h using(source);
