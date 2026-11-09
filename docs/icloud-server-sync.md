# iCloud server sync

The feature is opt-in, requires iOS 26+, and uses the same signed app identifier on iPhone, iPad and Mac (Designed for iPad).

## Data and protection

- Server UUID, name, address and position are stored in separate `NSUbiquitousKeyValueStore` records. Each device retains its local copy.
- Tokens and all custom headers are encoded together in immutable, versioned synchronizable Keychain items. Cloud records reference a credential version; they never contain credential values.
- Local credentials use a separate `AfterFirstUnlockThisDeviceOnly` mirror. Synchronized items use `AfterFirstUnlock`, because `ThisDeviceOnly` is incompatible with synchronization.
- Selection, environments, caches, logs and operations stay local.
- Existing credentials are read with explicit error handling before copying. A failed copy preserves local data and queues the local edit. Enabling sync does not delete the original local credentials.

## Reconciliation

Content conflicts resolve by modification date, then a deterministic mutation identifier. Order has its own modification date and mutation identifier, so moving a server does not revert an independently edited address or token. Equal positions resolve by server UUID. Clock skew can influence conflicts, as with any wall-clock last-writer policy.

Deletion writes a tombstone. Tombstones are retained, and older offline edits cannot recreate a deleted server. Deletion also removes that server's synchronized credential revisions when a participating device processes the tombstone. Historical credential versions of live servers remain in Keychain to support delayed record delivery; they are removed when that server is deleted.

Profiles and credentials travel independently. Until the matching credential version is available and installed, the server is marked pending and connection loading is blocked. Foreground polling checks delayed Keychain delivery; it does not assert that a successful local write means another device has received it. `synchronize()` is used on enable/foreground, not as a forced upload.

A changed or missing iCloud identity disables participation and retains local records. Re-enabling is explicit. Turning sync off offers to keep or remove local records; neither choice deletes the shared iCloud records. Removing local records clears the app's profile journal and local credential mirrors; Apple-managed iCloud caches and synchronizable Keychain copies are not remotely deleted by this action.

## Signing and deployment

`DockhandMobile.entitlements` declares `com.apple.developer.ubiquity-kvstore-identifier` using the signed team prefix and bundle identifier. The existing App ID and provisioning profile must support iCloud key-value storage. CloudKit containers, database schemas and a third-party sync framework are not required. The existing Keychain service identifiers are preserved.

## Required real-device acceptance

Use two devices signed with the same application identity, Apple Account and iCloud Keychain enabled:

1. Begin with different local servers. Enable sync and confirm both libraries combine without losing authentication or custom proxy headers.
2. Change names, addresses and secrets. Verify the receiving device waits for the matching credential revision before connecting.
3. Reorder servers; verify order converges. Concurrently reorder on one device and edit credentials on the other; verify the credentials are preserved.
4. Edit offline, delete the same server elsewhere, then reconnect. An older edit must not resurrect it.
5. Turn sync off and cancel; participation must continue. Repeat and keep local records; verify they remain usable. Repeat and remove records; verify other devices retain them.
6. Restart, lock/unlock, disable iCloud Keychain and change the iCloud account. Verify pending/error presentation and preservation of local data.
7. Check quota errors and interrupted credential writes. Never include credential values in diagnostics.

Simulator tests cover local regression behavior but cannot establish real iCloud delivery or cross-device Keychain behavior.

## Apple references

- https://developer.apple.com/documentation/security/ksecattrsynchronizable
- https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore
- https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore/synchronize()

## Implementation validation

- iOS 26.5 simulator: 100 tests executed, 3 optional integration tests skipped, 0 failures.
- Signed device build: passed with the existing development certificate and a new `Dockhand iCloud Development` profile. The signed app contains `8DA225EN79.garanda.dockhand.mobile` as its key-value store identifier; strict signature verification passed.
- iCloud capability was enabled on the existing App ID. No App Store submission or distribution-profile rotation was performed.
- Real cross-device iCloud/Keychain delivery remains an acceptance check on physical devices.
