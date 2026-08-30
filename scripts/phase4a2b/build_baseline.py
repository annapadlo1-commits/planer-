#!/usr/bin/env python3
"""Build the neutral Phase 4A.2B baseline from an approved private capture.

The raw capture is deliberately not committed. This builder accepts it as an
external input, verifies its pinned digest and structure, removes the pg_dump
session guards, separates platform-owned objects, and tokenizes the three
environment-bound UAT routines.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from dataclasses import dataclass
from pathlib import Path


RAW_SCHEMA_SHA256 = "7628c7732e0dbc8402cab65fd1f34d3779c7407b0988a0344bb8914891786870"
RAW_SCHEMA_BYTES = 2_679_643
RAW_STATEMENT_COUNT = 4_218
CAPTURE_RUN_ID = 33_301_678_124
CAPTURE_WORKFLOW_COMMIT = "bf577d2df7fdcb9bdd8840117c5c34a601d573b4"
CAPTURE_BASE_COMMIT = "9ce77eeadffcf46a7d8842e914b43f4fbcfddbfc"
CAPTURE_FROZEN_SOURCE_COMMIT = "5565c50370cb9436a76d1e6d7013250eaad2bece"
CAPTURE_FROZEN_SOURCE_TREE = "a8f6148cc0ff8960638553951972ba949b464d84"
PGMQ_INVENTORY_RECORDED_AT_UTC = "2026-08-30T08:50:37Z"
PGMQ_INVENTORY_SHA256 = "e57a3b17aa2be4432b8820168e9d20156a148e338d03654c2e15a82908c7d656"
MANAGED_ACL_INVENTORY_RECORDED_AT_UTC = "2026-08-30T09:12:39Z"
MANAGED_ACL_RECORD_COUNT = 75
MANAGED_ACL_CANONICAL_BYTES = 10_311
MANAGED_ACL_CANONICAL_SHA256 = "c3278105b5071f36da447bb3dd365f2602e3346ffa5eb9560e96bdd9bd9f2ffc"
MANAGED_ACL_SECTION_BYTES = 31_793
MANAGED_ACL_SECTION_SHA256 = "4aeb80754c981402c5eba9b052ee312305113496c354c1e19ec40245b99e3b45"
COMPANION_SERIALIZATION = "phase4a2-companion-v2"
COMPANION_RECORD_COUNT = 56
COMPANION_FINGERPRINT_SHA256 = "e7f678581129e4f5669c668095e076c9e4e62e10f2fd7c913725cb559e4c074d"
DEFAULT_ACL_RECORD_COUNT = 29
DEFAULT_ACL_CANONICAL_BYTES = 3_005
DEFAULT_ACL_CANONICAL_SHA256 = "c86785623e746bdaf24fabcb75b2a6019385b230830284d851ec27ad030933a3"
LOCAL_PLATFORM_DEFAULT_ACL_RECORD_COUNT = 3
LOCAL_PLATFORM_DEFAULT_ACL_CANONICAL_BYTES = 470
LOCAL_PLATFORM_DEFAULT_ACL_CANONICAL_SHA256 = "4e48afbadff3c1f4a2bf8d07c492872b05ba062c59161f708e5a615e04434efe"
PROJECT_REF_TOKEN = "__PHASE4A2B_PROJECT_REF__"
MAX_CORE_CHUNK_BYTES = 420_000

ENVIRONMENT_FUNCTIONS = {
    "uat_full_business_reset_preview_v1",
    "uat_full_business_reset_v1",
    "matrix_v2_create_safe_first_run_uat_v1",
}

EXPECTED_EVENT_TRIGGERS = [
    "issue_graphql_placeholder",
    "issue_pg_cron_access",
    "issue_pg_graphql_access",
    "issue_pg_net_access",
    "pgrst_ddl_watch",
    "pgrst_drop_watch",
]

PLATFORM_MANAGED_ACL_SCHEMAS = {
    "auth",
    "cron",
    "extensions",
    "graphql",
    "graphql_public",
    "pgmq",
    "realtime",
    "storage",
    "vault",
}

PLATFORM_MANAGED_SCHEMA_ACL_NAMES = {
    'SCHEMA "cron"',
    'SCHEMA "public"',
}

PROLOGUE = """-- Generated Phase 4A.2B neutral schema baseline.
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

"""

# pg_dump records the pgmq extension in its target schema but omits the
# extension-owned schema declaration. A fresh Supabase local database does not
# pre-create that namespace, so bootstrap the observed UAT schema identity and
# ACL before CREATE EXTENSION runs.
PGMQ_SCHEMA_BOOTSTRAP = '''-- Required target namespace for the non-relocatable pgmq extension.
CREATE SCHEMA IF NOT EXISTS "pgmq" AUTHORIZATION "postgres";
GRANT USAGE ON SCHEMA "pgmq" TO "pg_monitor";

'''

# Supabase's fresh local platform can install ambient postgres/public defaults
# for functions, tables and sequences that include API roles. pg_dump emits
# each object's ACL relative to PostgreSQL's built-in creation defaults, so
# normalize to that base before application objects are created. The final UAT
# default ACL is replayed only after all restored objects exist.
APP_OBJECT_DEFAULT_ACL_PRELUDE = '''-- Normalize object defaults to PostgreSQL's built-in creation base.
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public"
  REVOKE ALL ON FUNCTIONS FROM PUBLIC, "postgres", "anon", "authenticated", "service_role";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public"
  GRANT ALL ON FUNCTIONS TO PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public"
  GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public"
  REVOKE ALL ON TABLES FROM PUBLIC, "postgres", "anon", "authenticated", "service_role";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public"
  GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public"
  REVOKE ALL ON SEQUENCES FROM PUBLIC, "postgres", "anon", "authenticated", "service_role";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public"
  GRANT ALL ON SEQUENCES TO "postgres";

'''

# Restore the captured application-owned default ACL from a deterministic empty
# base. These statements run after every restored object, immediately before
# the eleven pg_dump GRANT statements captured from UAT.
APP_DEFAULT_ACL_FINALIZE = '''-- Normalize application defaults before replaying captured UAT grants.
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public"
  REVOKE ALL ON FUNCTIONS FROM PUBLIC, "postgres", "anon", "authenticated", "service_role";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public"
  REVOKE ALL ON TABLES FROM PUBLIC, "postgres", "anon", "authenticated", "service_role";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public"
  REVOKE ALL ON SEQUENCES FROM PUBLIC, "postgres", "anon", "authenticated", "service_role";

'''

PLATFORM_POSTLUDE = r'''-- pg_dump omits owner-equivalent schema ACL entries. Restore the explicit
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
'''

SECTION_RE = re.compile(
    r"(?m)^--\n-- Name: (.+?); Type: (.+?); Schema: (.*?); Owner: (.*?)\n--\n"
)
RESTORE_GUARD_RE = re.compile(
    r"(?m)^\\(restrict|unrestrict) ([A-Za-z0-9]{32,128})\r?$"
)
PROJECT_REF_RE = re.compile(r"^[a-z]{20}$")


@dataclass(frozen=True)
class Section:
    name: str
    object_type: str
    schema: str
    owner: str
    text: str


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def parse_sections(raw: str) -> tuple[str, list[Section], str]:
    matches = list(SECTION_RE.finditer(raw))
    if len(matches) != 2_602:
        raise SystemExit(f"expected 2602 pg_dump sections, got {len(matches)}")
    dump_complete = raw.find("--\n-- PostgreSQL database dump complete", matches[-1].start())
    if dump_complete < 0:
        raise SystemExit("pg_dump completion marker missing")

    sections: list[Section] = []
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else dump_complete
        name, object_type, schema, owner = match.groups()
        sections.append(Section(name, object_type, schema, owner, raw[match.start():end]))
    return raw[: matches[0].start()], sections, raw[dump_complete:]


def section_mentions_environment_function(section: Section) -> bool:
    return any(
        section.name.startswith(f"{name}(")
        or section.name.startswith(f'FUNCTION "{name}"(')
        for name in ENVIRONMENT_FUNCTIONS
    )


def write_text(path: Path, text: str) -> dict[str, object]:
    data = text.encode("utf-8")
    path.write_bytes(data)
    return {
        "path": path.name,
        "bytes": len(data),
        "sha256": sha256_bytes(data),
    }


def chunk_core(sections: list[Section]) -> list[str]:
    chunks: list[str] = []
    current: list[str] = []
    current_bytes = len(PROLOGUE.encode("utf-8"))
    for section in sections:
        section_bytes = len(section.text.encode("utf-8"))
        if current and current_bytes + section_bytes > MAX_CORE_CHUNK_BYTES:
            chunks.append(PROLOGUE + "".join(current))
            current = []
            current_bytes = len(PROLOGUE.encode("utf-8"))
        current.append(section.text)
        current_bytes += section_bytes
    if current:
        chunks.append(PROLOGUE + "".join(current))
    if not chunks or any(len(chunk.encode("utf-8")) > MAX_CORE_CHUNK_BYTES for chunk in chunks):
        raise SystemExit("core chunking invariant failed")
    return chunks


def build(raw_path: Path, output_dir: Path, source_project_ref: str) -> None:
    if not PROJECT_REF_RE.fullmatch(source_project_ref):
        raise SystemExit("source project ref must be exactly 20 lowercase ASCII letters")
    if output_dir.exists() and any(output_dir.iterdir()):
        raise SystemExit(f"output directory must be empty: {output_dir}")
    output_dir.mkdir(parents=True, exist_ok=True)

    raw_bytes = raw_path.read_bytes()
    if len(raw_bytes) != RAW_SCHEMA_BYTES:
        raise SystemExit(f"raw schema byte count changed: {len(raw_bytes)}")
    if sha256_bytes(raw_bytes) != RAW_SCHEMA_SHA256:
        raise SystemExit("raw schema SHA-256 changed")
    raw = raw_bytes.decode("utf-8", errors="strict")
    prefix, sections, tail = parse_sections(raw)

    guards = list(RESTORE_GUARD_RE.finditer(prefix + tail))
    if [match.group(1) for match in guards] != ["restrict", "unrestrict"]:
        raise SystemExit(f"expected one pg_dump restore guard pair, got {guards}")
    if guards[0].group(2) != guards[1].group(2):
        raise SystemExit("pg_dump restore guard tokens do not match")
    if "Dumped by pg_dump version 17.11" not in prefix:
        raise SystemExit("unexpected pg_dump producer")
    if raw.count(source_project_ref) != 5:
        raise SystemExit("source project ref distribution changed")

    core: list[Section] = []
    extensions: list[Section] = []
    extension_comments: list[Section] = []
    environment: list[Section] = []
    app_default_acl: list[Section] = []
    managed_default_acl: list[Section] = []
    platform_managed_acl: list[Section] = []
    event_triggers: list[Section] = []

    for section in sections:
        if section.object_type == "EXTENSION":
            extensions.append(section)
        elif section.object_type == "COMMENT" and "COMMENT ON EXTENSION" in section.text:
            extension_comments.append(section)
        elif section.object_type == "EVENT TRIGGER":
            event_triggers.append(section)
        elif section.object_type == "DEFAULT ACL":
            if section.owner == "postgres":
                app_default_acl.append(section)
            else:
                managed_default_acl.append(section)
        elif section.object_type == "ACL" and (
            section.schema in PLATFORM_MANAGED_ACL_SCHEMAS
            or section.name in PLATFORM_MANAGED_SCHEMA_ACL_NAMES
        ):
            platform_managed_acl.append(section)
        elif section.object_type in {"FUNCTION", "ACL", "COMMENT"} and section_mentions_environment_function(section):
            environment.append(section)
        else:
            core.append(section)

    expected_counts = {
        "core": 2_505,
        "extensions": 6,
        "extension_comments": 6,
        "environment": 6,
        "app_default_acl": 3,
        "managed_default_acl": 3,
        "platform_managed_acl": 67,
        "event_triggers": 6,
    }
    actual_counts = {
        "core": len(core),
        "extensions": len(extensions),
        "extension_comments": len(extension_comments),
        "environment": len(environment),
        "app_default_acl": len(app_default_acl),
        "managed_default_acl": len(managed_default_acl),
        "platform_managed_acl": len(platform_managed_acl),
        "event_triggers": len(event_triggers),
    }
    if actual_counts != expected_counts:
        raise SystemExit(f"section routing changed: {actual_counts}")

    managed_acl_section_bytes = "".join(
        section.text for section in platform_managed_acl
    ).encode("utf-8")
    if len(managed_acl_section_bytes) != MANAGED_ACL_SECTION_BYTES:
        raise SystemExit("platform-managed ACL section byte count changed")
    if sha256_bytes(managed_acl_section_bytes) != MANAGED_ACL_SECTION_SHA256:
        raise SystemExit("platform-managed ACL section fingerprint changed")

    observed_event_names = [section.name for section in event_triggers]
    if observed_event_names != EXPECTED_EVENT_TRIGGERS:
        raise SystemExit(f"event trigger inventory changed: {observed_event_names}")

    extension_text = (
        PROLOGUE
        + PGMQ_SCHEMA_BOOTSTRAP
        + APP_OBJECT_DEFAULT_ACL_PRELUDE
        + "".join(section.text for section in extensions)
    )
    environment_text = PROLOGUE + "".join(section.text for section in environment)
    if environment_text.count(source_project_ref) != 5:
        raise SystemExit("environment function ref count changed")
    environment_text = environment_text.replace(source_project_ref, PROJECT_REF_TOKEN)
    if environment_text.count(PROJECT_REF_TOKEN) != 5:
        raise SystemExit("environment tokenization failed")

    core_text = "".join(section.text for section in core)
    if source_project_ref in core_text:
        raise SystemExit("source project ref leaked into core baseline")
    if "EVENT TRIGGER" in core_text:
        raise SystemExit("platform event trigger leaked into core baseline")
    if "ALTER DEFAULT PRIVILEGES FOR ROLE \"supabase_admin\"" in core_text:
        raise SystemExit("platform-managed default ACL leaked into core baseline")

    files: list[dict[str, object]] = []
    files.append(write_text(output_dir / "00_platform_extensions.sql", extension_text))
    for index, chunk in enumerate(chunk_core(core), start=1):
        files.append(write_text(output_dir / f"10_core_{index:02d}.sql", chunk))
    files.append(
        write_text(
            output_dir / "90_environment_uat_functions.sql.tmpl", environment_text
        )
    )
    # The three postgres/public default-ACL sections are application-owned
    # recovery state and are applied last, after every restored object. The
    # supabase_admin/managed sections remain platform-owned and observe-only.
    platform_text = (
        PROLOGUE
        + PLATFORM_POSTLUDE
        + "\n"
        + APP_DEFAULT_ACL_FINALIZE
        + "".join(section.text for section in app_default_acl)
    )
    files.append(write_text(output_dir / "99_platform_companion.sql", platform_text))

    for entry in files:
        if int(entry["bytes"]) > 500_000:
            raise SystemExit(f"generated file exceeds review ceiling: {entry}")

    manifest = {
        "format": "phase4a2b-neutral-baseline-v1",
        "capture": {
            "run_id": CAPTURE_RUN_ID,
            "workflow_commit": CAPTURE_WORKFLOW_COMMIT,
            "base_commit": CAPTURE_BASE_COMMIT,
            "frozen_source_commit": CAPTURE_FROZEN_SOURCE_COMMIT,
            "frozen_source_tree": CAPTURE_FROZEN_SOURCE_TREE,
            "raw_schema_bytes": RAW_SCHEMA_BYTES,
            "raw_schema_sha256": RAW_SCHEMA_SHA256,
            "raw_statement_count": RAW_STATEMENT_COUNT,
        },
        "routing": {
            "section_counts": actual_counts,
            "restore_guard_pairs_removed": 1,
            "source_project_ref_occurrences_tokenized": 5,
            "environment_function_count": 3,
            "environment_function_names": sorted(ENVIRONMENT_FUNCTIONS),
            "event_triggers_observe_only": observed_event_names,
            "app_default_acl_sections_replayed_last": len(app_default_acl),
            "managed_default_acl_sections_observe_only": len(managed_default_acl),
            "platform_managed_acl_sections_observe_only": len(platform_managed_acl),
            "platform_managed_acl_section_bytes": MANAGED_ACL_SECTION_BYTES,
            "platform_managed_acl_section_sha256": MANAGED_ACL_SECTION_SHA256,
            "extension_comment_sections_observe_only": len(extension_comments),
            "cron_jobs_replayed": 0,
            "cron_reason": "command text was intentionally not captured; replay requires separate authorization",
        },
        "platform_companion": {
            "source_attestation": {
                "serialization": COMPANION_SERIALIZATION,
                "record_count": COMPANION_RECORD_COUNT,
                "fingerprint_sha256": COMPANION_FINGERPRINT_SHA256,
                "category_counts": {
                    "managed_policy": 4,
                    "managed_policy_table": 1,
                    "storage_bucket": 1,
                    "realtime_publication": 1,
                    "realtime_publication_member": 2,
                    "realtime_publication_schema": 0,
                    "event_trigger": 6,
                    "cron_job": 1,
                    "extension": 7,
                    "user_schema": 4,
                    "default_acl": DEFAULT_ACL_RECORD_COUNT,
                },
            },
            "restore_expectation": {
                "cron_job": 0,
                "cron_status": "deferred-no-command-text-captured",
                "platform_default_acl_compatibility": {
                    "schema": "supabase_functions",
                    "grantor": "supabase_admin",
                    "source_uat_schema_exists": False,
                    "source_uat_records": 0,
                    "restore_records": LOCAL_PLATFORM_DEFAULT_ACL_RECORD_COUNT,
                    "canonical_bytes": LOCAL_PLATFORM_DEFAULT_ACL_CANONICAL_BYTES,
                    "canonical_sha256": LOCAL_PLATFORM_DEFAULT_ACL_CANONICAL_SHA256,
                    "treatment": "observe-and-assert-only",
                },
                "all_other_source_attestation_categories": "exact",
            },
            "extensions": [
                "pg_cron",
                "pg_stat_statements",
                "pgcrypto",
                "pgmq",
                "plpgsql",
                "supabase_vault",
                "uuid-ossp",
            ],
            "storage_policies": [
                "profile_avatars_self_delete_v1",
                "profile_avatars_self_insert_v1",
                "profile_avatars_self_select_v1",
                "profile_avatars_self_update_v1",
            ],
            "storage_bucket": "profile-avatars",
            "realtime_publication": "supabase_realtime",
            "realtime_members": [
                "public.optimization_run_strategies_v2",
                "public.optimization_runs_v2",
            ],
            "pgmq_queues": [
                {
                    "queue_name": "schedule_optimizer_v2",
                    "is_partitioned": False,
                    "is_unlogged": False,
                    "queue_table_persistence": "permanent",
                    "archive_table_persistence": "permanent",
                    "rls_enabled": False,
                }
            ],
            "storage_bucket_provisioning": "Storage API",
            "default_acl_replay": {
                "postgres_public_sections": len(app_default_acl),
                "order": "last",
                "supabase_admin_and_extension_managed": "observe-only",
                "observed_total_records": DEFAULT_ACL_RECORD_COUNT,
                "restore_total_records": (
                    DEFAULT_ACL_RECORD_COUNT
                    + LOCAL_PLATFORM_DEFAULT_ACL_RECORD_COUNT
                ),
                "canonical_bytes": DEFAULT_ACL_CANONICAL_BYTES,
                "canonical_sha256": DEFAULT_ACL_CANONICAL_SHA256,
            },
        },
        "supplemental_read_only_inventory": {
            "pgmq_recorded_at_utc": PGMQ_INVENTORY_RECORDED_AT_UTC,
            "pgmq_canonical_json_bytes": 664,
            "pgmq_canonical_json_sha256": PGMQ_INVENTORY_SHA256,
            "message_rows_read": 0,
            "uat_mutations": 0,
            "managed_acl_catalog": {
                "serialization": "phase4a2b-managed-acl-v1",
                "recorded_at_utc": MANAGED_ACL_INVENTORY_RECORDED_AT_UTC,
                "uat_identity_verified": True,
                "record_count": MANAGED_ACL_RECORD_COUNT,
                "canonical_bytes": MANAGED_ACL_CANONICAL_BYTES,
                "canonical_sha256": MANAGED_ACL_CANONICAL_SHA256,
                "business_rows_read": 0,
                "uat_mutations": 0,
            },
            "publication_catalog": {
                "recorded_at_utc": "2026-08-30T09:18:00Z",
                "uat_identity_verified": True,
                "record_count": 1,
                "names": ["supabase_realtime"],
                "business_rows_read": 0,
                "uat_mutations": 0,
            },
            "security_definer_search_paths": {
                "recorded_at_utc": "2026-08-30T09:23:23Z",
                "uat_identity_verified": True,
                "routine_count": 519,
                "distribution": {
                    "search_path=\"\"": 458,
                    "search_path=public": 55,
                    "search_path=public, pg_temp": 5,
                    "search_path=public, solver_private, pg_temp": 1,
                },
                "business_rows_read": 0,
                "uat_mutations": 0,
            },
        },
        "files": files,
    }
    manifest_bytes = (json.dumps(manifest, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    (output_dir / "manifest.json").write_bytes(manifest_bytes)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--source-project-ref", required=True)
    args = parser.parse_args()
    build(args.raw, args.output, args.source_project_ref)


if __name__ == "__main__":
    main()
