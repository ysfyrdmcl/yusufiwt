# Data deletion

## Local Mac

In macOS Privacy choose **Delete Completed History**. It transactionally removes
completed sessions/events while preserving the append-only security audit. The
retention action removes older rows in bounded batches. Uninstalling alone does
not silently delete the local database.

## Companion account and relay

On iPhone choose **Settings → Delete Account and Relay Data** and confirm. The
authenticated `DELETE /v1/account` cascades devices, refresh/APNs/Live Activity
tokens, pairing sessions, and pending encrypted envelopes. Sockets close and
access tokens immediately fail device authentication. After server confirmation
the app removes device-only Keychain and protected app-group state.

If the app is unavailable, email support@agentcontrol.app from the associated
address/Apple relay address. Support verifies control first. Live data is
deleted immediately; encrypted backups expire under backup retention and are
not selectively restored except for disaster recovery.
