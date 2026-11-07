# Reload resource lists when a server becomes ready

When switching servers, the app restores the remembered environment ID before fetching that server's environments. Previously the list task ran while the resolved environment was nil, cleared its data and never ran again if the remembered ID was still valid after connection. Pull to refresh was needed to populate Containers, Stacks or Images.

Resource task identities now include the resolved environment as well as the selected profile/environment IDs. Environment arrival changes that identity even if the remembered selection stays the same, triggering an automatic load. Server-details and pending-update screens use the same identity helper.

Each resource load has a token and checks its captured destination before publishing data or errors. A destination change clears old rows, while same-destination refreshes retain them. Containers are published as soon as their main request completes, without waiting for optional update badges. Environment discovery also rejects obsolete responses after another server selection.

The header keeps a single instance of each picker using `AnyLayout`: the environment stays to the right of the server when width permits, and moves below on narrow layouts or larger text sizes. Layout selection depends on measured available width rather than changing server labels; space for the connection indicator is reserved. Menus are no longer duplicated across alternative `ViewThatFits` layouts during dismissal. Lists show loading while environments/resources are being fetched rather than prematurely claiming no data.

Regression tests cover arrival of a remembered environment without a raw scope-ID change, and delayed old-server list results/errors after the new server loads. Explicit test URLSession injection is honored by both manual requests and the generated client; default production sessions are unchanged.

Validation: 94 app tests, 3 optional integration tests skipped, 0 failures on iOS 26.5.
