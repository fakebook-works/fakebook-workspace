-- Give each service its own database login instead of sharing one superuser.
--
-- WHY THIS MATTERS MORE THAN IT LOOKS
--
-- Every service connects with the same account, and a survey of the live database shows
-- that account is a SUPERUSER:
--
--   rolname   rolsuper  rolcreatedb  rolcreaterole  rolcanlogin
--   fakebook  t         t            t              t
--
-- Its password sits in the environment of all eight containers. Anyone who reaches any
-- one of them — reading /proc/self/environ is enough — holds superuser on the database
-- server. That is not merely "can read another service's schema": a PostgreSQL superuser
-- can read and write every database, bypass row-level security, and reach the host
-- through COPY ... FROM PROGRAM. The blast radius of a foothold in, say, the upload
-- service is the entire cluster.
--
-- One thing is already right and needs no change: none of the seven service schemas is
-- granted to PUBLIC (has_schema_privilege('public', ..., 'USAGE') is false for all of
-- them). The exposure comes purely from what the services connect as.
--
-- WHAT THIS SCRIPT DOES
--
-- Creates one login role per service, granted only what that service needs on its own
-- schema, and nothing at all on the others. `fakebook` stays the owner so migrations and
-- schema changes continue to run as before; the services stop using it.
--
-- BEFORE RUNNING
--
-- 1. Replace every CHANGE_ME below with a distinct random secret of at least 32 bytes.
--    Do not commit the filled-in copy.
-- 2. This grants on tables that exist today and sets default privileges for tables created
--    later BY fakebook. If a future migration runs as a different role, re-run the GRANT
--    section afterwards.
-- 3. Applying this alone changes nothing until the services are pointed at the new roles —
--    see the deployment note at the end. Do both in one maintenance window.
--
--   .\scripts\apply-migrations.ps1 -WritersStopped -File .\scripts\sql\2026-07-27-per-service-roles.sql
--
-- Idempotent: re-running rotates the service passwords and reconciles every grant.

BEGIN;

-- PostgreSQL grants EXECUTE on newly-created functions to PUBLIC by default.  Services
-- are isolated primarily by schema USAGE, but revoking this default keeps a future
-- accidental schema grant from turning into cross-service execution rights.
ALTER DEFAULT PRIVILEGES FOR ROLE fakebook REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

DO $$
DECLARE
    service record;
BEGIN
    FOR service IN
        SELECT * FROM (VALUES
            ('fakebook_auth',           'auth',           'CHANGE_ME_auth'),
            ('fakebook_social_graph',   'social_graph',   'CHANGE_ME_social_graph'),
            ('fakebook_recommendation', 'recommendation', 'CHANGE_ME_recommendation'),
            ('fakebook_search',         'search',         'CHANGE_ME_search'),
            ('fakebook_notification',   'notification',   'CHANGE_ME_notification'),
            ('fakebook_messenger',      'messenger',      'CHANGE_ME_messenger'),
            ('fakebook_payment',        'payment',        'CHANGE_ME_payment')
        ) AS t(role_name, schema_name, role_password)
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = service.role_name) THEN
            EXECUTE format(
                'CREATE ROLE %I LOGIN NOINHERIT PASSWORD %L',
                service.role_name, service.role_password);
        ELSE
            -- A rerun is also the supported password-rotation path.
            EXECUTE format(
                'ALTER ROLE %I PASSWORD %L',
                service.role_name, service.role_password);
        END IF;

        -- Never inherited, never able to create more roles or databases.
        EXECUTE format(
            'ALTER ROLE %I LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS',
            service.role_name);
    END LOOP;
END
$$;

-- Reconcile, rather than merely add, privileges. This closes stale grants left by an
-- earlier manual setup and makes the verifier meaningful.
DO $$
DECLARE
    service_role text;
    managed_schema text;
BEGIN
    FOREACH service_role IN ARRAY ARRAY[
        'fakebook_auth', 'fakebook_social_graph', 'fakebook_recommendation',
        'fakebook_search', 'fakebook_notification', 'fakebook_messenger',
        'fakebook_payment'
    ]
    LOOP
        FOREACH managed_schema IN ARRAY ARRAY[
            'auth', 'social_graph', 'recommendation', 'search',
            'notification', 'messenger', 'payment'
        ]
        LOOP
            EXECUTE format('REVOKE ALL PRIVILEGES ON SCHEMA %I FROM %I', managed_schema, service_role);
            EXECUTE format('REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA %I FROM %I', managed_schema, service_role);
            EXECUTE format('REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA %I FROM %I', managed_schema, service_role);
            EXECUTE format('REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA %I FROM %I', managed_schema, service_role);
            EXECUTE format(
                'ALTER DEFAULT PRIVILEGES FOR ROLE fakebook IN SCHEMA %I REVOKE ALL ON TABLES FROM %I',
                managed_schema, service_role);
            EXECUTE format(
                'ALTER DEFAULT PRIVILEGES FOR ROLE fakebook IN SCHEMA %I REVOKE ALL ON SEQUENCES FROM %I',
                managed_schema, service_role);
            EXECUTE format(
                'ALTER DEFAULT PRIVILEGES FOR ROLE fakebook IN SCHEMA %I REVOKE ALL ON FUNCTIONS FROM %I',
                managed_schema, service_role);
        END LOOP;
    END LOOP;
END
$$;

DO $$
DECLARE
    service record;
BEGIN
    FOR service IN
        SELECT * FROM (VALUES
            ('fakebook_auth',           'auth'),
            ('fakebook_social_graph',   'social_graph'),
            ('fakebook_recommendation', 'recommendation'),
            ('fakebook_search',         'search'),
            ('fakebook_notification',   'notification'),
            ('fakebook_messenger',      'messenger'),
            ('fakebook_payment',        'payment')
        ) AS t(role_name, schema_name)
    LOOP
        -- Runtime roles can use data in exactly one schema but cannot perform DDL.
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', service.schema_name, service.role_name);
        EXECUTE format(
            'GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO %I',
            service.schema_name, service.role_name);
        EXECUTE format(
            'GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA %I TO %I',
            service.schema_name, service.role_name);
        EXECUTE format(
            'GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO %I',
            service.schema_name, service.role_name);

        -- Objects a later owner-run migration adds receive the same data-only grants.
        EXECUTE format(
            'ALTER DEFAULT PRIVILEGES FOR ROLE fakebook IN SCHEMA %I '
            'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I',
            service.schema_name, service.role_name);
        EXECUTE format(
            'ALTER DEFAULT PRIVILEGES FOR ROLE fakebook IN SCHEMA %I '
            'GRANT USAGE, SELECT ON SEQUENCES TO %I',
            service.schema_name, service.role_name);
        EXECUTE format(
            'ALTER DEFAULT PRIVILEGES FOR ROLE fakebook IN SCHEMA %I '
            'GRANT EXECUTE ON FUNCTIONS TO %I',
            service.schema_name, service.role_name);
    END LOOP;
END
$$;

-- No runtime service may create objects in public. Recommendation alone needs USAGE
-- because the pgvector extension is installed there and recommendation.embedding is a
-- public.vector column.
REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON SCHEMA public FROM fakebook_auth, fakebook_social_graph, fakebook_search,
    fakebook_notification, fakebook_messenger, fakebook_payment;
GRANT USAGE ON SCHEMA public TO fakebook_recommendation;

COMMIT;

-- VERIFY
--
-- Every service role must be able to use exactly one schema. Anything else in the "usable"
-- column is a mistake:
--
--   SELECT r.rolname,
--          string_agg(n.nspname, ', ' ORDER BY n.nspname) FILTER (
--              WHERE has_schema_privilege(r.rolname, n.nspname, 'USAGE')) AS usable
--   FROM pg_roles r
--   CROSS JOIN pg_namespace n
--   WHERE r.rolname LIKE 'fakebook\_%'
--     AND n.nspname IN ('auth','social_graph','recommendation','search',
--                       'notification','messenger','payment')
--   GROUP BY r.rolname ORDER BY r.rolname;
--
-- And none of them may be privileged:
--
--   SELECT rolname, rolsuper, rolcreatedb, rolcreaterole, rolbypassrls
--   FROM pg_roles WHERE rolname LIKE 'fakebook\_%';
--
-- DEPLOYMENT
--
-- docker-compose.yml builds every connection string from the shared DB_USER/DB_PASSWORD in
-- the x-postgres-base anchor. Give each service its own pair instead — for example
-- AUTH_DB_USER/AUTH_DB_PASSWORD — and change that service's connection string to use them.
-- The Recommendation service builds a DATABASE_URL rather than a connection string, so it
-- needs the same treatment in that form.
--
-- Migrations must keep running as `fakebook`, which owns the schemas;
-- scripts/apply-migrations.ps1 reads DB_USER/DB_PASSWORD and so continues to work.
--
-- AFTERWARDS
--
-- Once every service is on its own role, `fakebook` is only used for migrations and should
-- stop being a superuser. Owner rights are enough for the DDL these migrations perform:
--
--   ALTER ROLE fakebook NOSUPERUSER;
--
-- Verify a migration applies cleanly before relying on that, and note that CREATE SCHEMA in
-- a brand-new database needs CREATE on the database, which the owner already has.
