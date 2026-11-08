
SET LOCAL search_path=public,pg_catalog;
DO $$
DECLARE original_sql text;
BEGIN
 original_sql := pg_get_viewdef('public.forebet_identity_candidate_queue_v'::regclass,true);
 IF original_sql IS NULL OR position('forebet_availability' in original_sql)=0
 THEN RAISE EXCEPTION 'Unexpected Forebet queue definition'; END IF;
 original_sql := rtrim(rtrim(original_sql), ';');
 EXECUTE 'CREATE OR REPLACE VIEW public.forebet_identity_candidate_queue_v WITH (security_invoker = true) AS SELECT * FROM ('|| original_sql || ') historical_queue WHERE kickoff_hkt >= now() - interval ''3 hours''';
END
$$;
COMMENT ON VIEW public.forebet_identity_candidate_queue_v IS 'Live identity review (last 3 hours through future); the historical Forebet availability table remains unchanged.';
