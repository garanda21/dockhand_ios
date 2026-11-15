# Privacy Policy

_Last updated: November 9, 2026_

Dockhand Mobile ("the app") is an independent, open-source client for self-hosted [Dockhand](https://github.com/Finsys/dockhand) servers. This policy explains how the app handles your information.

## Data we collect

**None.** The developer does not collect, store, sell or share any personal data. The app contains no analytics, advertising, tracking or crash-reporting SDKs, and it does not require an account.

## Data stored on your device

To work, the app stores the following information locally on your device:

- Server URLs and names you add.
- API tokens and optional custom HTTP headers, stored in the iOS Keychain.
- App preferences, such as the selected server and environment.

If you enable iCloud sync, server names, addresses and order also sync through your iCloud account. API tokens and custom HTTP headers sync separately through iCloud Keychain. Sync is optional and off by default. The developer cannot access this data.

The selected server, selected environment and cached server responses stay local. Turning sync off lets you keep the local server records or remove them from that device, without removing the shared iCloud records. Removing a server while sync is enabled propagates the deletion to your other participating devices.

## Network connections

The app connects to the Dockhand servers that you configure and, when you enable sync, uses Apple iCloud services. All requests (container, stack, image, log, backup and terminal data) go directly from your device to your server. The developer has no access to your servers or to any of this traffic.

Any data handled by your Dockhand server is governed by that server's configuration and by whoever operates it.

## Children

The app is not directed to children and does not knowingly collect information from anyone.

## Deleting your data

Removing a server in the app deletes its stored settings and credentials. Uninstalling the app does not delete shared iCloud records, and Keychain items may survive uninstall. To remove shared server records, delete those servers while sync is enabled.

## Changes

Updates to this policy will be published in this file in the project's repository.

## Contact

Questions about this policy can be sent through [GitHub Issues](https://github.com/garanda21/dockhand_ios/issues) or by email to garanda21@gmail.com.
