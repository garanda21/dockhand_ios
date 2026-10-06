# Git stack redeploy

The iOS stack detail shows the paper-plane Redeploy action for Git sources as well as compose stacks. Source type is read from `GET /api/stacks?env=ID`.

## Request flow

1. The sheet explains that Git deployments sync the repository and use the deployment options saved in Dockhand. Compose pull/build/force-recreate toggles are not sent to the Git endpoint.
2. On confirmation, capture the profile/environment and its authenticated service. Fetch `GET /api/git/stacks?env=ID` and resolve one exact stack-name/environment match. Missing, duplicate, unassigned or invalid IDs stop the operation.
3. Recheck cancellation and the active scope before sending `POST /api/git/stacks/{id}/deploy`. The ID comes from that server's listing, not a Docker container ID or stack name. Requests retain profile bearer and custom proxy headers.
4. Request the job response with `Accept: text/event-stream`. Poll `GET /api/jobs/{jobId}`, rendering progress status and compose output lines. A direct JSON success result is also supported. Errors and results without success are rejected.
5. On success, refresh the dashboard and stack list only in the original scope. Git deployments do not clear pending image badges using the unrelated compose sheet's pull toggle; the server owns that state.

Closing a progress sheet stops monitoring, not the server-side deployment. Normal compose deployment behavior is retained.

## Server behavior and compatibility

Official Dockhand source inspected in tags `v1.0.2`, `1.0.23`, `v1.0.43` and `v1.0.50`: Git deploy routes use the job-response channel, with synchronous JSON support. The endpoint checks `stacks:start` for the Git stack's stored environment. The Git listing checks `stacks:view` and supports `env` filtering. Client-side exact environment matching also prevents an unfiltered listing from selecting a namesake on another environment.

The deploy route syncs Git first and uses saved settings (`buildOnDeploy`, `repullImages`, `forceRedeploy`). Manual deployment runs even without a new commit; container recreation is determined by the server/Compose behavior. The app does not alter saved Git settings or call the sync-only endpoint.

References:
- [Dockhand manual](https://dockhand.pro/manual/)
- [Git deploy route, v1.0.50](https://github.com/Finsys/dockhand/blob/v1.0.50/src/routes/api/git/stacks/%5Bid%5D/deploy/%2Bserver.ts)
- [Git listing route, v1.0.50](https://github.com/Finsys/dockhand/blob/v1.0.50/src/routes/api/git/stacks/%2Bserver.ts)

Validation includes mocked HTTP lookup/deploy/job responses, authentication and request routing, same-name stacks in different environments, ambiguous/missing IDs, permission errors, success/failure decoding, and Git action availability for running/stopped/created stacks. No real server deployment is needed to run these tests.
