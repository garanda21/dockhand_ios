# Container update progress

The Available Updates screen shows a persistent progress indicator as soon as an update starts. It displays the current container/stage, real completed-container counts and recent server output; the bottom status remains visible when updating from farther down a long list. Selected rows also show activity indicators.

## API and compatibility

The dashboard submits `POST /api/containers/batch-update-stream?env=ID` with the selected `containerIds`, then polls `GET /api/jobs/{jobId}`. Both requests preserve profile bearer and custom proxy headers. Stages and pull logs come from the server, including scanning when the server has scanners configured. Completed counts advance only for terminal per-container events.

Only an HTTP 404/405 from the initial streaming-route request falls back to the existing synchronous batch endpoint. On older servers, an indeterminate activity indicator remains visible with explanatory text. Permissions, timeouts, job-polling errors and malformed results never trigger a second update request. The active connection scope is checked during polling and before fallback, refresh and result presentation.

The final response must contain a terminal complete result and one terminal event for every selected container. Failed, blocked and skipped containers are reported as unsuccessful, alongside successful updates. An incomplete or lost job is reported as unconfirmed; the UI advises refreshing before another attempt.

Official endpoint reviewed: [Dockhand v1.0.50 batch-update-stream route](https://github.com/Finsys/dockhand/blob/v1.0.50/src/routes/api/containers/batch-update-stream/%2Bserver.ts).

## Validation

Four mocked HTTP tests cover actual stages and partial failures, legacy fallback, authentication and environment/base-path routing, authorization/polling/incomplete-result failures, fatal job errors without a progress-event type, and cancellation before fallback. The full app test suite passed on iOS 26.5: 91 tests, 3 optional integration tests skipped, 0 failures. No live containers were updated by these tests.
