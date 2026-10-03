# Dockhand server version and changelog

Settings reads the installed Dockhand version from the existing `GET /api/system`
response at `runtime.ownContainer.labels.version`. The Docker daemon version and
Node.js runtime version are separate values. Legacy Dockhand version fields remain
supported. If the server cannot inspect its own container, the installed version
may be unavailable; the app falls back to the first published entry of that server’s bundled changelog, excluding `comingSoon` entries. Docker and Node.js versions are never used as a fallback.

The version appears below the active server URL. Tapping it opens the release
history returned by that same server's `GET /api/changelog`, fetched when the
view opens, or during capability detection when the version is absent. The view records the server name and installed version, handles load
errors and empty results, and omits entries marked `comingSoon`.

## Compatibility evidence

Checked the official Finsys/dockhand Git history and every available release tag
on 2026-10-02 (source checkout `5fd44756fda92b780af6378c95e9e2a4cdc35274`):

- `src/routes/api/system/+server.ts` exposes the own-container OCI version label.
- `src/routes/api/changelog/+server.ts` returns bundled changelog JSON.
- Both are present in all 46 available tags checked, including release `1.0.4`
  and `v1.0.50`. The oldest verifiable source release is 1.0.4. The `v1.0.2` tag
  actually contains VERSION v1.0.23, so it does not establish 1.0.2 compatibility.
- The endpoint returns typed change objects (`type`, `text`); the app also accepts
  plain string changes and optional dates.

The link and network method require a parseable server version >= 1.0.4.
Known older or unparseable versions do not trigger a changelog request. When the API omits the version (for example, an official `:latest` container with empty OCI version labels), Settings verifies support with a read-only changelog request and caches the response for navigation. The Settings task also observes actual environment availability, so reusing a remembered environment ID after switching servers triggers a reload. The UI uses the first published changelog version when available, and shows version unavailable only if both sources are empty. A server reporting
an eligible version but lacking the endpoint shows an unavailable/error state.
The changelog is bundled with the installed server, so it is not a live source of
newer releases. No self-update endpoint is called by this feature.

Sources:
- https://github.com/Finsys/dockhand/blob/1.0.4/src/routes/api/system/+server.ts
- https://github.com/Finsys/dockhand/blob/1.0.4/src/routes/api/changelog/+server.ts
- https://github.com/Finsys/dockhand/blob/v1.0.50/src/routes/api/changelog/+server.ts

This verifies published source compatibility, not live responses from every
historical Docker image or a personal server.

## Container image release notes

Available Updates resolves the active server version from `/api/system`, falling
back to its first published bundled changelog entry. Only versions >= 1.0.43
request `GET /api/containers/{id}/version-notes?env=…&versions=…`.
Official tags 1.0.42 (absent) and 1.0.43 (present) were checked.
The requested versions include the newer target tag and skipped tags returned
in `newerVersion` by pending-updates. Digest-only updates pass an empty list,
which still allows the server to resolve a generic changelog URL.

Each visible pending row shows View changes only for a response containing an
HTTP(S) changelog link or release notes. Empty results and server errors hide
the action. Results are scoped to the server/environment and cancelled on a
scope change. Read-only validation on the Home server confirmed a link for an
existing container; two stale pending IDs returned 500 and were absent from
its current container list. No pending records were changed during validation.

If a pending container ID no longer resolves, the notes request retries using its
container name in the same environment. It does not change pending records or
update-action targets, and does not retry authorization failures or empty notes.
Live validation in Chuwi confirmed Cloudflare returns a changelog link by its
current name while Postgres returns no link or notes.

If Dockhand returns a GitHub release URL without note bodies, the notes sheet
fetches that repository's public release through api.github.com when opened.
Explicit /releases/tag URLs request that tag; generic /releases URLs request
the latest published release, labelled as such rather than as the pending image
update. Non-GitHub changelogs retain the external link. GitHub requests carry no
Dockhand bearer token or custom proxy headers. The sheet has loading, failure,
and retry states. Cloudflared's public release returned a non-empty body during
verification on 2026-10-03.
