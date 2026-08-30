-- Generated Phase 4A.2B neutral schema baseline.
-- Apply only to a fresh, isolated Supabase project through the reviewed runner.

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

-- pg_dump omits owner-equivalent schema ACL entries. Restore the explicit
-- application-owned catalog state observed on UAT.
GRANT ALL ON SCHEMA "authorization_private" TO "postgres";
GRANT ALL ON SCHEMA "solver_private" TO "postgres";

-- The bucket itself is provisioned through the Storage API by the restore runner.
-- Direct writes to storage.buckets are intentionally forbidden.
CREATE POLICY "profile_avatars_self_delete_v1"
ON "storage"."objects" AS PERMISSIVE FOR DELETE TO "authenticated"
USING (
  "bucket_id" = 'profile-avatars'::text
  AND ("storage"."foldername"("name"))[1] = (SELECT "auth"."uid"())::text
);

CREATE POLICY "profile_avatars_self_insert_v1"
ON "storage"."objects" AS PERMISSIVE FOR INSERT TO "authenticated"
WITH CHECK (
  "bucket_id" = 'profile-avatars'::text
  AND ("storage"."foldername"("name"))[1] = (SELECT "auth"."uid"())::text
);

CREATE POLICY "profile_avatars_self_select_v1"
ON "storage"."objects" AS PERMISSIVE FOR SELECT TO "authenticated"
USING (
  "bucket_id" = 'profile-avatars'::text
  AND ("storage"."foldername"("name"))[1] = (SELECT "auth"."uid"())::text
);

CREATE POLICY "profile_avatars_self_update_v1"
ON "storage"."objects" AS PERMISSIVE FOR UPDATE TO "authenticated"
USING (
  "bucket_id" = 'profile-avatars'::text
  AND ("storage"."foldername"("name"))[1] = (SELECT "auth"."uid"())::text
)
WITH CHECK (
  "bucket_id" = 'profile-avatars'::text
  AND ("storage"."foldername"("name"))[1] = (SELECT "auth"."uid"())::text
);

ALTER PUBLICATION "supabase_realtime"
  ADD TABLE ONLY "public"."optimization_run_strategies_v2";
ALTER PUBLICATION "supabase_realtime"
  ADD TABLE ONLY "public"."optimization_runs_v2";

-- Read-only UAT inventory captured one ordinary logged, non-partitioned queue.
-- pgmq.create() is required because CREATE EXTENSION does not create queues.
SELECT "pgmq"."create"('schedule_optimizer_v2');
GRANT SELECT ON TABLE
  "pgmq"."q_schedule_optimizer_v2",
  "pgmq"."a_schedule_optimizer_v2"
TO "pg_monitor";
GRANT SELECT ON SEQUENCE
  "pgmq"."q_schedule_optimizer_v2_msg_id_seq"
TO "pg_monitor";

--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";


