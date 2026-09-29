# Dockhand iOS

Dockhand iOS is an open-source SwiftUI client for managing [Dockhand](https://github.com/Finsys/dockhand) servers from iPhone.

It is built for people who run containers across multiple Dockhand environments and want a native, focused mobile app for the daily operations: checking status, switching environments, viewing logs, editing stacks, pulling images, pruning unused resources and running safe actions against the selected server.

> [!IMPORTANT]
> Dockhand iOS is an independent, community-developed, unofficial client for
> [Dockhand](https://github.com/Finsys/dockhand). It is not affiliated with,
> endorsed by, or maintained by the official Dockhand project or its maintainers.

## TestFlight

You can try the latest beta build on TestFlight here:

[Join Dockhand iOS on TestFlight](https://testflight.apple.com/join/FFE3aDxR)

## Releases

Every stable version is published on the [GitHub Releases page](https://github.com/garanda21/dockhand_ios/releases). Release notes are generated from merged pull requests and include the relevant changes and contributors.

To publish a version, update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, merge the release commit into `main`, then push a matching tag:

```sh
git tag v1.1.1
git push origin v1.1.1
```

Pushing a `v*` tag that points to `main` creates the GitHub Release automatically. Tags with a suffix such as `v1.2.0-beta.1` are published as pre-releases.

## Screenshots

| Dashboard | Containers | Stacks | Images |
| --- | --- | --- | --- |
| ![Dashboard](docs/images/dashboard.png) | ![Containers](docs/images/containers.png) | ![Stacks](docs/images/stacks.png) | ![Images](docs/images/images.png) |

## What It Can Do

- Manage multiple [Dockhand](https://github.com/Finsys/dockhand) servers from one app.
- Keep each server isolated with its own URL, token and selected environment.
- Send per-server custom HTTP headers to authenticate with reverse proxies such as Pangolin or Cloudflare Access.
- Switch quickly between Dockhand environments from the main header.
- View environment dashboard data such as container health, CPU, memory, images, volumes, networks, stacks and events when the Dockhand API exposes it.
- List containers, filter and sort them by state.
- Start, stop, restart and pause/unpause containers where the current state allows it.
- View container logs, including live streaming logs when available.
- List stacks, filter and sort them by state.
- Open a stack detail view with its related containers and run container actions from there.
- Edit stack compose content and `.env` files.
- Validate compose YAML and `.env` format before saving.
- Redeploy stacks with options such as pulling images, building images and force recreate.
- Start, stop, restart, bring down and delete stacks using Dockhand API operations.
- List images and inspect image details, tags, labels, digests and usage.
- Pull images, tag images, delete images or tags where supported by Dockhand.
- Prune dangling images or unused images for the selected environment.

## Project Status

This is an early app. The current goal is to cover the core [Dockhand](https://github.com/Finsys/dockhand) workflows with a clean native UI and a small, reviewable codebase.

The app already talks to a real [Dockhand](https://github.com/Finsys/dockhand) instance and uses the Dockhand REST API for containers, stacks, images, environments, logs and dashboard data. Some Dockhand API behavior is still being validated as the app grows, especially around destructive operations and endpoint differences across Dockhand versions.

Contributions are welcome, especially in these areas:

- API coverage and OpenAPI improvements.
- Safer handling of destructive operations.
- UI polish for compact iPhone layouts.
- Better error messages for Dockhand API failures.
- Tests around request construction and data decoding.
- Documentation and screenshots.

## Architecture

The repository is split into two main parts:

- `DockhandMobile`: the SwiftUI iOS app.
- `DockhandAPI`: a Swift package generated from [Dockhand's](https://github.com/Finsys/dockhand) OpenAPI schema.

The app uses:

- SwiftUI for the interface.
- Swift Observation for app state.
- URLSession plus Apple Swift OpenAPI Runtime for API calls.
- Keychain for per-server API tokens.
- UserDefaults for non-secret preferences such as server profiles and selected environments.

The generated API package lives in `DockhandAPI/Sources/DockhandAPI/Generated`. Manual API glue and client setup live next to it.

## Server And Environment Model

[Dockhand](https://github.com/Finsys/dockhand) is organized around environments, and the app mirrors that model.

Each configured server has:

- A display name.
- A Dockhand base URL.
- An optional API token.
- Its own selected environment.

This separation is intentional. Actions such as stopping containers, deleting stacks or pruning images must always target the currently selected server and environment. The app keeps those selections scoped so data and actions from different Dockhand servers do not get mixed.

## Authentication

[Dockhand](https://github.com/Finsys/dockhand) can be used with authentication enabled or disabled.

If your [Dockhand](https://github.com/Finsys/dockhand) server has authentication disabled, leave the token field empty. The app will call the API without an `Authorization` header.

If authentication is enabled, create an API key in [Dockhand](https://github.com/Finsys/dockhand) and paste it into the server profile. The token is stored in the iOS Keychain and sent as:

```http
Authorization: Bearer <token>
```

Use the least privileged token that fits your workflow. Read-only tokens are enough for browsing. Container, stack and image actions require a token with write/control permissions.

### Reverse proxy headers

If Dockhand sits behind an authenticating reverse proxy, add the proxy credentials as **Custom headers** in the server profile instead of creating a bypass rule. They are sent with every request to that server: API calls, polling, long-running jobs, live log streams and shell WebSockets. The Dockhand bearer token keeps working as before.

Presets fill in the header names:

| Proxy | Headers |
| --- | --- |
| Pangolin | `P-Access-Token-Id`, `P-Access-Token` |
| Cloudflare Access (service token) | `CF-Access-Client-Id`, `CF-Access-Client-Secret` |

Any other header can be added by name. How values are handled:

- Values are stored in the iOS Keychain (this device only, never synced or backed up) and are hidden after saving. They can be replaced or removed individually.
- Headers managed by the app or iOS (`Authorization`, `Host`, `Content-*`, `Accept`, `Connection`, `Upgrade`, `Proxy-*`, `Sec-*`, ...) cannot be overridden. Values with line breaks or control characters are rejected.
- Redirects to a different host, port or scheme are never followed, so the token and headers are not forwarded to a sign-in page. When the proxy answers with a redirect or an HTML page, the app says the proxy is asking for authentication.
- **Test connection** checks a draft configuration before saving it.

## Local Setup

Requirements:

- macOS with Xcode.
- iOS Simulator or a physical iPhone.
- A reachable [Dockhand](https://github.com/Finsys/dockhand) server.
- Swift package resolution enabled in Xcode.

Clone the repository:

```sh
git clone https://github.com/garanda21/dockhand_ios.git
cd dockhand_ios
```

Open the project:

```sh
open DockhandMobile.xcodeproj
```

Then:

1. Select the `DockhandMobile` scheme.
2. Choose a simulator or physical device.
3. Build and run.
4. Open Settings in the app.
5. Add your Dockhand server URL, for example `http://your-host:3230`.
6. Add an API token only if your [Dockhand](https://github.com/Finsys/dockhand) instance requires one.
7. Select the active server and environment.

No default personal server should be required. Every user should configure their own Dockhand URL from inside the app.

## API Generation

[Dockhand](https://github.com/Finsys/dockhand) exposes an OpenAPI/Swagger specification. This app keeps a generated Swift client under `DockhandAPI`.

The current package depends on:

- `swift-openapi-runtime`
- `swift-openapi-urlsession`

The OpenAPI source file is:

```text
DockhandAPI/Sources/DockhandAPI/openapi.yaml
```

Generated files are located at:

```text
DockhandAPI/Sources/DockhandAPI/Generated/
```

When the [Dockhand](https://github.com/Finsys/dockhand) API changes, the expected workflow is:

1. Update `openapi.yaml` from the Dockhand API docs.
2. Regenerate the Swift OpenAPI client.
3. Review generated diffs.
4. Adjust app service code in `DockhandMobile/Services/DockhandService.swift`.
5. Test against a real Dockhand server before merging.

## Safety Notes

The app can perform destructive operations.

Examples:

- Stop or restart containers.
- Bring stacks down.
- Delete stacks.
- Delete images or tags.
- Prune unused images.

The UI should always make the active server and environment visible before those actions run. When contributing, avoid shortcuts that pass display names or labels where the Dockhand API expects stable identifiers. Destructive actions should use the correct server, environment and API identifier every time.

## Repository Hygiene

Do not commit:

- API tokens.
- Personal [Dockhand](https://github.com/Finsys/dockhand) URLs or IP addresses.
- Xcode user data.
- DerivedData or build products.
- Local signing team changes unless they are intentionally part of the project configuration.

The app should start with no bundled personal server configuration.

## Roadmap

Short-term:

- Add stable screenshots to the README.
- Expand stack workflows around deploy/down/delete behavior.
- Improve dashboard live refresh.
- Add more request-level tests for critical Dockhand actions.
- Improve log rendering and filtering.

Later:

- Support more Dockhand automation endpoints.
- Add safer batch operations.
- Add better offline and unreachable-server states.
- Explore iPad layout support.
- Improve generated API update workflow.

## Contributing

Issues and pull requests are welcome.

Good first contributions:

- Fix a UI layout issue.
- Improve an error message.
- Add screenshots or documentation.
- Add a small test around API request construction.
- Validate one Dockhand endpoint and document the result.

Before opening a pull request:

1. Keep the change focused.
2. Avoid committing personal configuration.
3. Test against a [Dockhand](https://github.com/Finsys/dockhand) server when the change touches API behavior.
4. Include screenshots for UI changes.
5. Mention any [Dockhand](https://github.com/Finsys/dockhand) version or API behavior you validated.

## License

Dockhand iOS is released under the [MIT License](LICENSE).
