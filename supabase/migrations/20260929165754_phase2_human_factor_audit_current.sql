create or replace view public.phase2_human_factor_audit_current as
with cohort as (
  select hkjc_event_id
  from public.matches
  where selling is true
    and coalesce(in_play,false)=false
    and kickoff_hkt >= now()
    and kickoff_hkt < now()+interval '48 hours'
)
select
 (select count(*) from cohort) as upcoming_matches,
 (select count(*) from public.phase2_player_status_authority_current s join cohort c using(hkjc_event_id)) as status_rows,
 (select count(*) from public.phase2_manager_evidence m join cohort c using(hkjc_event_id)) as manager_rows,
 (select count(*) from public.match_commentary_evidence e join cohort c using(hkjc_event_id)) as commentary_rows,
 (select count(*) from public.phase2_manager_evidence m join cohort c using(hkjc_event_id) where m.created_at >= now()-interval '1 hour') as manager_added_1h,
 (select count(*) from public.match_commentary_evidence e join cohort c using(hkjc_event_id) where e.created_at >= now()-interval '1 hour') as commentary_added_1h;
