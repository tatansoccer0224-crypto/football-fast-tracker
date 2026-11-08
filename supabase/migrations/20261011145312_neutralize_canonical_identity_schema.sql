-- Preserve native Flashscore records and all column/FK identities while removing
-- former-provider names. All changes are transactional; no CASCADE is used.
SET lock_timeout = '5s';
CREATE TEMP TABLE identity_functions_before ON COMMIT DROP AS
SELECT p.oid, n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) signature,
       pg_get_functiondef(p.oid) definition, p.proargnames, p.proacl, p.proowner
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname IN ('public','private','phase4') AND p.prokind='f'
  AND (p.prosrc ILIKE '%hkjc%' OR array_to_string(p.proargnames,',') ILIKE '%hkjc%');

-- Only this trigger implements the removed bookmaker's identity anchor.
-- Native timestamp-regression triggers are retained and rewritten below.
DROP TRIGGER IF EXISTS trg_phase1_verified_event_context_guard ON public.team_name_event_context_master;
DO $retire$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM identity_functions_before WHERE proname IN (
    'ft_internal_app_phase1_feed_generic','ft_internal_capture_prematch','ft_internal_import_prediction_archive',
    'ft_internal_refresh_phase1_decisions','ft_refresh_womens_intl_team_names',
    'ft_internal_team_form_details','ft_internal_ingest_multisource_alias_evidence',
    'ft_internal_upcoming_canonical_gap_count','ft_refresh_static_identity_context',
    'phase1_event_context_anchor_guard','phase1_guard_verified_event_context_write',
    'ft_phase15_learn_exact_shadow','ft_ingest_shadow_alias_evidence_v2'
  ) LOOP
    EXECUTE format('DROP FUNCTION %I.%I(%s)',r.nspname,r.proname,r.signature);
    DELETE FROM identity_functions_before WHERE oid=r.oid;
  END LOOP;
  -- OUT names/input argument names require recreation, not CREATE OR REPLACE.
  FOR r IN SELECT * FROM identity_functions_before
      WHERE array_to_string(proargnames,',') ILIKE '%hkjc%' LOOP
    EXECUTE format('DROP FUNCTION %I.%I(%s)',r.nspname,r.proname,r.signature);
  END LOOP;
END $retire$;

DO $columns$
DECLARE r record; new_name text;
BEGIN
  FOR r IN SELECT n.nspname,c.relname,a.attname
    FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid
    JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname IN ('public','private','phase4') AND c.relkind IN ('r','p','v','m')
      AND a.attnum>0 AND NOT a.attisdropped AND a.attname ILIKE '%hkjc%'
    ORDER BY c.relkind,c.oid,a.attnum LOOP
    new_name := replace(r.attname,'hkjc','canonical');
    EXECUTE format('ALTER TABLE %I.%I RENAME COLUMN %I TO %I',r.nspname,r.relname,r.attname,new_name);
  END LOOP;
END $columns$;

DO $functions$
DECLARE r record; g record; new_signature text; recipient text;
BEGIN
  FOR r IN SELECT * FROM identity_functions_before ORDER BY oid LOOP
    IF r.proname='ft_guard_current_time_regression' THEN CONTINUE; END IF;
    EXECUTE replace(r.definition,'hkjc','canonical');
    new_signature := replace(r.signature,'hkjc','canonical');
    EXECUTE format('ALTER FUNCTION %I.%I(%s) OWNER TO %I',r.nspname,r.proname,new_signature,pg_get_userbyid(r.proowner));
    -- Restore original grants exactly after recreating typed functions.
    IF array_to_string(r.proargnames,',') ILIKE '%hkjc%' THEN
      EXECUTE format('REVOKE ALL ON FUNCTION %I.%I(%s) FROM PUBLIC',r.nspname,r.proname,new_signature);
      FOR g IN SELECT * FROM aclexplode(coalesce(r.proacl,acldefault('f',r.proowner))) LOOP
        recipient := CASE WHEN g.grantee=0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(g.grantee)) END;
        EXECUTE format('GRANT %s ON FUNCTION %I.%I(%s) TO %s%s',g.privilege_type,r.nspname,r.proname,new_signature,recipient,CASE WHEN g.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END);
      END LOOP;
    END IF;
  END LOOP;
END $functions$;

CREATE OR REPLACE FUNCTION public.ft_guard_current_time_regression() RETURNS trigger
LANGUAGE plpgsql SET search_path TO 'pg_catalog','public' AS $guard$
BEGIN
  IF tg_table_name='matches' THEN
    IF old.fetched_at IS NOT NULL AND (new.fetched_at IS NULL OR new.fetched_at<old.fetched_at) THEN RETURN old; END IF;
  ELSIF tg_table_name='live_score_current' THEN
    IF old.updated_at_source IS NOT NULL AND (new.updated_at_source IS NULL OR new.updated_at_source<old.updated_at_source) THEN RETURN old; END IF;
  ELSIF tg_table_name='live_stats_current' THEN
    IF old.captured_at_hkt IS NOT NULL AND (new.captured_at_hkt IS NULL OR new.captured_at_hkt<old.captured_at_hkt) THEN RETURN old; END IF;
  END IF;
  RETURN new;
END $guard$;

DO $verify$
BEGIN
  IF jsonb_typeof(public.ft_fast_flashscore_summary(24)) <> 'array' THEN
    RAISE EXCEPTION 'Native Flashscore summary did not survive identity migration';
  END IF;
END $verify$;
NOTIFY pgrst, 'reload schema';
