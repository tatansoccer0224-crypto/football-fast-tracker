
create or replace view public.phase2_lineup_display_current as
select
  l.*,
  case
    when l.confirmed then false
    when l.starter and exists (
      select 1
      from public.phase2_player_status_evidence s
      where s.hkjc_event_id=l.hkjc_event_id
        and s.team_side=l.team_side
        and s.player_key=l.player_key
        and s.confirmed=true
        and coalesce(s.confidence,0) >= 0.8
        and (s.valid_until is null or s.valid_until >= now())
        and (
          upper(coalesce(s.status_type,'')) in ('SUSPENSION','INTERNATIONALDUTY')
          or upper(coalesce(s.status_value,'')) in ('OUT','UNAVAILABLE','SUSPENDED')
        )
    ) then true
    else false
  end as status_conflict,
  case
    when l.confirmed then true
    when l.starter and exists (
      select 1
      from public.phase2_player_status_evidence s
      where s.hkjc_event_id=l.hkjc_event_id
        and s.team_side=l.team_side
        and s.player_key=l.player_key
        and s.confirmed=true
        and coalesce(s.confidence,0) >= 0.8
        and (s.valid_until is null or s.valid_until >= now())
        and (
          upper(coalesce(s.status_type,'')) in ('SUSPENSION','INTERNATIONALDUTY')
          or upper(coalesce(s.status_value,'')) in ('OUT','UNAVAILABLE','SUSPENDED')
        )
    ) then false
    else true
  end as display_eligible
from public.phase2_canonical_lineup_rows_current l;
comment on view public.phase2_lineup_display_current is
'Phase 2 current-lineup display gate. Preserves canonical evidence; confirmed XI always wins. Predicted starters with confirmed high-confidence suspension/international-duty or explicit OUT/UNAVAILABLE/SUSPENDED status are flagged and not display-eligible. Doubtful/no-data are not treated as OUT.';
