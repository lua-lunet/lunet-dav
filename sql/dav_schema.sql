-- lunet-dav metadata schema (PostgreSQL 16)
-- Metadata for a NextCloud-Enterprise-31 work-alike WebDAV server.
-- Object bytes live in an S3-compatible store (content-addressed by sha256,
-- mandatory bucket versioning); this table is the metadata / identity layer.
--
-- Concurrency model: mutations are single-statement CAS UPDATEs guarded by `version`
-- with a RETURNING clause. Multi-statement work (e.g. MOVE overwrite) uses
-- `db.transaction` (pinned connection, BEGIN/COMMIT/ROLLBACK; abort-by-nil).
-- See docs/DESIGN.md §3.

-- Render a timestamptz as ISO 8601 UTC (reused from the chassis convention),
-- e.g. "2026-07-20T18:09:44.754Z" for d:getlastmodified / d:creationdate.
CREATE OR REPLACE FUNCTION iso8601(ts timestamptz) RETURNS text
LANGUAGE sql IMMUTABLE STRICT
AS $$ SELECT to_char(ts AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') $$;

-- Files and collections (folders) share this table.
--   * is_collection = true  -> a flat top-level "team folder" (MKCOL); s3_* are NULL
--   * is_collection = false -> a file with content in S3
CREATE TABLE IF NOT EXISTS dav_files (
    -- Stable identity. Drives OC-FileId = lpad(id,8,'0') || <instance-id>.
    -- Survives content overwrite and MOVE, like an inode. Per-instance monotonic
    -- counter over all files and folders (matches observed nc counter).
    id              BIGSERIAL PRIMARY KEY,

    is_collection   BOOLEAN     NOT NULL DEFAULT false,

    -- Flat namespace: collection is a single top-level segment ('' = root).
    -- name is the file/folder display name. Together they are the logical path.
    collection      TEXT        NOT NULL DEFAULT '',
    name            TEXT        NOT NULL,

    -- Content address + storage locator (NULL for collections).
    sha256          TEXT,                 -- lowercase hex; == basename of s3_key
    s3_bucket       TEXT,
    s3_key          TEXT,                 -- e.g. '_landing/<sha256>'
    s3_version_id   TEXT,                 -- S3 VersionId (versioning is mandatory)

    -- nc-facing metadata.
    etag            TEXT,                 -- S3 ETag, emitted quoted as OC-Etag
    mime_type       TEXT,
    size            BIGINT      NOT NULL DEFAULT 0,

    -- CAS guard: bumped by +1 on every metadata write; guarded in the WHERE clause.
    version         INTEGER     NOT NULL DEFAULT 0,

    -- Server-set timestamps. mtime is returned by the CAS RETURNING clause.
    ctime           TIMESTAMPTZ NOT NULL DEFAULT now(),
    mtime           TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Open bag for miscellaneous metadata that must ride under the same CAS.
    -- Carries the op-log (info.oplog: JSON array of [ts, who, type, data]
    -- rows) and the materialized tag set (info.tags). Tags/labels fold
    -- set-label/unset-label ops in order (docs/DESIGN.md §3.3).
    info            JSONB       NOT NULL DEFAULT '{}'::jsonb,

    -- Logical path uniqueness in the flat namespace.
    CONSTRAINT dav_files_path_unique UNIQUE (collection, name),

    -- System prefix is reserved (e.g. _landing); no folder may start with '_'.
    CONSTRAINT dav_files_no_reserved_name CHECK (name !~ '^_'),

    -- Flat namespace: no slashes in names.
    CONSTRAINT dav_files_no_slash CHECK (name !~ '/' AND collection !~ '/')
);

-- Listing a collection (PROPFIND Depth: 1) is the hot path.
CREATE INDEX IF NOT EXISTS dav_files_collection_idx ON dav_files (collection);

-- Content-address lookups / dedup checks.
CREATE INDEX IF NOT EXISTS dav_files_sha256_idx ON dav_files (sha256);

-- Example CAS overwrite (parameters filled by the app):
--   UPDATE dav_files
--      SET version = version + 1,
--          sha256 = $2, s3_key = $3, s3_version_id = $4, etag = $5,
--          size = $6, mime_type = $7, mtime = now(),
--          info = $8::jsonb
--    WHERE id = $1 AND version = $9
--   RETURNING id, version, mtime, etag;
