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
Known older or unparseable versions do not trigger a changelog request. When the API omits the version (for example, an official `:latest` container with empty OCI version labels), Settings verifies support with a read-only changelog request and caches the response for navigation. The UI uses the first published changelog version when available, and shows version unavailable only if both sources are empty. A server reporting
an eligible version but lacking the endpoint shows an unavailable/error state.
The changelog is bundled with the installed server, so it is not a live source of
newer releases. No self-update endpoint is called by this feature.

Sources:
- https://github.com/Finsys/dockhand/blob/1.0.4/src/routes/api/system/+server.ts
- https://github.com/Finsys/dockhand/blob/1.0.4/src/routes/api/changelog/+server.ts
- https://github.com/Finsys/dockhand/blob/v1.0.50/src/routes/api/changelog/+server.ts

This verifies published source compatibility, not live responses from every
historical Docker image or a personal server.
