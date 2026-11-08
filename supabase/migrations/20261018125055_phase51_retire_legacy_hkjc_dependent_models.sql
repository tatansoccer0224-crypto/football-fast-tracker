-- Phase 51: permanently retire the old HKJC-dependent internal modelling path.
-- Owner authorized breaking legacy dependencies on 2026-10-18.
-- Do not touch Forebet, Flashscore, Football-Data, odds or native prospective freezes.
-- Guard prevents accidentally deleting any forecasts published after the retired era.
BEGIN;
SET LOCAL lock_timeout = '1500ms';
SET LOCAL statement_timeout = '12000ms';
DO $guard$
DECLARE
  v_old_dc integer;
  v_old_form integer;
  v_last_model timestamptz;
  v_last_form timestamptz;
BEGIN
 SELECT count(*),max(fetched_at) INTO v_old_dc,v_last_model
 FROM public.model_predictions;
 SELECT count(*),max(fetched_at) INTO v_old_form,v_last_form
 FROM public.form_predictions;
 IF v_old_dc>40 OR v_old_form>40
    OR v_last_model >= timestamptz '2026-10-07 00:00:00+00'
    OR v_last_form >= timestamptz '2026-10-07 00:00:00+00'
 THEN RAISE EXCEPTION 'REFUSE_DELETE_NONLEGACY_MODEL_RECORDS: DC %, form %, last %, %',
    v_old_dc,v_old_form,v_last_model,v_last_form;
 END IF;
END;
$guard$;
-- Destroy all stale output from the retired publisher, regardless of which
-- label each internal prediction used. No retained legacy model artefacts.
TRUNCATE TABLE public.model_predictions,public.form_predictions,
  phase4.model_consensus_current,phase4.model_evaluation_current;
-- Prevent future ingestion of the retired source under any model/source label.
ALTER TABLE public.model_predictions
  ADD CONSTRAINT ft_model_source_never_hkjc
  CHECK (
    coalesce(model_source,'') !~* 'hkjc|jockey[[:space:]_-]*club'
    AND coalesce(raw::text,'') !~* 'hkjc|jockey[[:space:]_-]*club'
  );
ALTER TABLE public.form_predictions
  ADD CONSTRAINT ft_form_source_never_hkjc
  CHECK (
    coalesce(model_source,'') !~* 'hkjc|jockey[[:space:]_-]*club'
    AND coalesce(raw::text,'') !~* 'hkjc|jockey[[:space:]_-]*club'
  );
REVOKE INSERT,UPDATE,DELETE ON public.model_predictions,public.form_predictions
  FROM anon,authenticated;
-- These four obsolete source-health heartbeats were imported in Sep/Oct,
-- not required by any active source collector. Do not remove general health.
DELETE FROM public.source_health
WHERE source ILIKE '%hkjc%' OR metric ILIKE '%hkjc%';
-- An old consensus publisher reads public.model_prediction_current
-- and blends the retired model with an independently sourced Forebet row.
-- It must never recreate the retired blend in the future.
CREATE OR REPLACE FUNCTION phase4.refresh_model_consensus()
RETURNS integer LANGUAGE plpgsql VOLATILE
SET search_path TO pg_catalog,phase4,public,pg_temp
AS $fn$
BEGIN
  RETURN 0;
END;
$fn$;
COMMIT;
