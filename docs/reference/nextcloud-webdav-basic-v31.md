# NextCloud Enterprise 31 — WebDAV Basic API (reference notes)

> Source: <https://docs.nextcloud.com/server/31/developer_manual/client_apis/WebDAV/basic.html>
> Captured 2026-07-20 for the `lunet-dav` compatibility target.
> This is a *reference capture* of the upstream behaviour we emulate. It is **not**
> the spec of what we build — that is [`../SPEC-v0.1.0.md`](../SPEC-v0.1.0.md).
> Items we deliberately do **not** implement in v0.1.0 are called out inline as `NOT IN v0.1.0`.

## Base URL & authentication

- **Base WebDAV endpoint:** `/remote.php/dav`
- **Files endpoint:** `/remote.php/dav/files/{user}/{path}`
- Authentication: HTTP **Basic auth** (`username:password`), session cookies, or **app
  passwords** (recommended for external/OIDC auth). We target Basic + app password.
- Public share endpoint `/public.php/dav/files/{share_token}` (NC 29+). `NOT IN v0.1.0`.

## HTTP methods

| Method    | Purpose                          | Notes |
|-----------|----------------------------------|-------|
| `PROPFIND`| List folder / read properties    | `Depth: 0` = this resource only; `Depth: 1` = children |
| `GET`     | Download file                    | Folder download via `Accept: application/zip`/`x-tar` → `NOT IN v0.1.0` |
| `HEAD`    | Metadata only                    | |
| `PUT`     | Upload file (overwrites)         | Body = raw bytes. Returns `OC-Etag`, `OC-FileId` |
| `MKCOL`   | Create folder                    | |
| `DELETE`  | Remove file/folder (recursive)   | |
| `MOVE`    | Move/rename                      | `Destination:` header (absolute URL), `Overwrite: T|F` |
| `COPY`    | Duplicate                        | `Destination:` header, `Overwrite: T|F` |
| `PROPPATCH`| Set properties (e.g. favourite) | Favourite needs a user table → `NOT IN v0.1.0` |
| `REPORT`  | Filtered listing (favourites)    | `NOT IN v0.1.0` |

## XML namespaces

| URI                                            | Prefix |
|------------------------------------------------|--------|
| `DAV:`                                          | `d`    |
| `http://owncloud.org/ns`                        | `oc`   |
| `http://nextcloud.org/ns`                       | `nc`   |
| `http://open-collaboration-services.org/ns`     | `ocs`  |
| `http://open-cloud-mesh.org/ns`                 | `ocm`  |

Prefixes are declared on the `d:propfind` root of the request body. When building
`multistatus` responses, prefixes must be declared and matched. We add a private
`lnt` namespace (see SPEC) for debugging — **not** an upstream namespace.

## Request headers (relevant)

| Header            | Purpose                               | Example |
|-------------------|---------------------------------------|---------|
| `X-OC-MTime`      | Client-supplied mtime (unix seconds)  | `1675789581` |
| `X-OC-CTime`      | Client-supplied ctime (unix seconds)  | `1675789581` |
| `OC-Checksum`     | Client checksum, stored not validated | `md5:04c36b75...` |
| `X-Hash`          | Ask server to return a hash           | `sha256` |
| `OC-Total-Length` | Total size during chunked upload      | `4052412` (chunked `NOT IN v0.1.0`) |
| `Depth`           | PROPFIND recursion                    | `0` |
| `Destination`     | MOVE/COPY target (absolute URL)       | `https://host/remote.php/dav/files/u/new` |
| `Overwrite`       | MOVE/COPY overwrite control           | `T` or `F` |

## Response headers (relevant)

| Header          | When                          | Format / example |
|-----------------|-------------------------------|------------------|
| `OC-Etag`       | create, move, copy            | `"50ef2eba7b74aa84feff013efee2a5ef"` (quoted) |
| `OC-FileId`     | create, move, copy            | `<padded-id><instance-id>` e.g. `00000259oczn5x60nrdu` |
| `X-OC-MTime`    | when client sent `X-OC-MTime` | `accepted` |
| `X-OC-CTime`    | when client sent `X-OC-CTime` | `accepted` |
| `X-Hash-SHA256` | when client sent `X-Hash`     | `<hex>` (also `X-Hash-MD5`, `X-Hash-SHA1`) |
| `ETag`          | standard etag                 | `"6436d084d4805"` (quoted) |

**`OC-FileId` observation (IONOS-managed NC E31 instance):** the padded-id portion is a
per-instance monotonic counter over *all* files and folders. On a fresh instance it was
observed as low as `477`. The instance-id suffix is stable per instance. This drives our
`id`→`OC-FileId` derivation (SPEC §Identity).

## PROPFIND properties

### DAV (`d:`)
`creationdate`, `getlastmodified`, `getetag`, `getcontenttype`, `getcontentlength`,
`resourcetype` (`<d:collection/>` for folders), `displayname`,
`quota-available-bytes` (-1 uncomputed, -2 unknown, -3 unlimited), `quota-used-bytes`,
`lockdiscovery`/`supportedlock` (dummy, class-2 stub).

### ownCloud (`oc:`)
`id` (instance-namespaced global id = `OC-FileId`), `fileid` (numeric id),
`permissions` (S/R/M/G/D/NV/W/CK string), `tags`, `favorite`, `size` (recursive),
`checksums`, `owner-id`, `owner-display-name`, `share-types`, `comments-*`,
`downloadURL` (not implemented upstream).

### NextCloud (`nc:`)
`creation_time`, `upload_time`, `mount-type`, `has-preview`,
`contained-folder-count`, `contained-file-count`, `is-encrypted`, `is-mount-root`,
`data-fingerprint`, `lock*` family, `acl*` family, `version-label`, `reminder-due-date`,
`sharees`, `note`. Most are `NOT IN v0.1.0`.

### OCS / OCM
`ocs:share-permissions` (bitmask), `ocm:share-permissions` (JSON). `NOT IN v0.1.0`.

## Behaviours to emulate

- **PUT overwrites** existing files silently.
- **DELETE on a folder** removes contents recursively.
- **MOVE/COPY/DELETE** operate recursively on folders.
- **Response codes:** `201` create, `204` overwrite/delete/no-content,
  `207 Multi-Status` for PROPFIND/PROPPATCH, `404` missing, `405` MKCOL on existing,
  `409` MKCOL where the parent path is missing, `412` failed precondition/`Overwrite: F`.
