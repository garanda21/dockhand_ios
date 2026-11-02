# Create Compose stacks

The Stacks toolbar opens a creation form scoped to the selected server and environment. The form accepts a Compose project name, Compose YAML and optional raw `.env` content. It reuses syntax highlighting and existing YAML/environment validation, and requires a non-empty services mapping.

## Request flow

1. Validate the draft and fetch a fresh `GET /api/stacks?env=ID` listing to reject a name already in use. A listing or permission failure stops creation. Dockhand's create endpoint can overwrite existing files, so the cached list alone is insufficient. There is still a server-side race if another client creates the same name between listing and submission; the API provides no atomic create-only precondition.
2. Recheck cancellation and the captured server/environment before `POST /api/stacks?env=ID`, with `name`, `compose`, `rawEnvContent` and explicit `start: false`. The existing authenticated JSON request helper sends bearer and custom proxy headers. A response must explicitly contain `success: true`.
3. **Create** saves without starting. **Create and start** first saves, then calls the existing Compose deployment endpoint with pull/build/force-recreate options and polls a returned job ID. Separate creation and deployment require the corresponding create/start permissions.
4. While creating, replace the form and its action buttons with a visible progress screen. Show validation, file creation, deployment and list-refresh phases; request the job channel explicitly with `Accept: text/event-stream` and render real server status/output with automatic log scrolling. The saved-stack/retry message is only shown after an interrupted or failed operation, never while deployment is running. Once creation succeeds, the draft is locked. If deployment fails, the form explains that the stack already exists and offers **Retry start**, which only repeats deployment. It also refreshes the list to expose the saved stack.
5. Refresh the stack list and dashboard, clear list filters, select the new stack and close the form on success. A changed connection scope stops subsequent operations and prevents selecting a stack in another environment. Closing the view cancels monitoring; cancellation does not undo server-side changes.

The manual service request follows the existing deployment API glue; generated OpenAPI files are unchanged. No credentials, preferences or iCloud behavior are modified.

## Compatibility and validation

The save-only create contract and name validation were inspected in the official Dockhand `v1.0.50` sources and the current main create route:

- [Create route](https://github.com/Finsys/dockhand/blob/v1.0.50/src/routes/api/stacks/%2Bserver.ts)
- [Stack persistence](https://github.com/Finsys/dockhand/blob/v1.0.50/src/lib/server/stacks.ts)

Automated tests cover request routing (including base path), environment, authentication, exact Compose and `.env` preservation, explicit save-only behavior, permission errors, unconfirmed success, duplicate/invalid names and invalid documents. Manual validation on the user’s iPhone confirmed real stack creation and startup. The user also reviewed the sheet presentation, styling and progress changes.

Local verification: both the simulator app build and `build-for-testing` compile successfully with Xcode 27.2. XCTest execution is blocked because the installed CoreSimulator (1174.9.2) is older than the version required by Xcode (1174.21). Simulator runtime UI remains unverified; physical-device validation was performed by the user.
