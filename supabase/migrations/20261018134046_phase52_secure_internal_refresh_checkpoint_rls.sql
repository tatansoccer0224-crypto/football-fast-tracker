BEGIN;
SET LOCAL lock_timeout = '1500ms';
SET LOCAL statement_timeout = '12000ms';
DO $guard$
BEGIN
 IF (SELECT relrowsecurity FROM pg_class WHERE oid = 'phase4.refresh_cycle_checkpoint'::regclass) THEN
  RAISE EXCEPTION 'RLS_ALREADY_ENABLED_REVIEW_FIRST';
 END IF;
 IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname IN ('anon','authenticated','service_role')
   AND has_table_privilege(oid,'phase4.refresh_cycle_checkpoint','SELECT')) THEN
  RAISE EXCEPTION 'UNEXPECTED_CLIENT_ROLE_TABLE_READ_ACCESS';
 END IF;
 IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname IN ('anon','authenticated','service_role')
   AND has_table_privilege(oid,'phase4.refresh_cycle_checkpoint','UPDATE')) THEN
  RAISE EXCEPTION 'UNEXPECTED_CLIENT_ROLE_TABLE_WRITE_ACCESS';
 END IF;
 IF NOT (SELECT rolbypassrls FROM pg_roles WHERE rolname='postgres') THEN
  RAISE EXCEPTION 'POSTGRES_NOT_RLS_BYPASS_REVIEW';
 END IF;
END $guard$;
ALTER TABLE phase4.refresh_cycle_checkpoint ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE phase4.refresh_cycle_checkpoint IS 'Internal singleton refresh checkpoint. RLS enabled; no client policies. Owned/updated by privileged postgres only. No anon/authenticated/service_role direct table grants.';
COMMIT;
