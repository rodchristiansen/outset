# Managed State Keeper

A Prefs / Run / Logs window for outset, installed as
`/Applications/Utilities/Managed State Keeper.app`. It leaves the outset engine,
its paths under `/usr/local/outset` and its launchd jobs unchanged.

- **Prefs** edits `/Library/Preferences/io.macadmins.Outset.plist`. A key a
  configuration profile manages shows its managed value, locked.
- **Run** starts one of a fixed set of outset runs: login (privileged),
  on-demand (privileged), on-demand (user) and boot, and streams the output.
- **Logs** lists each run under `/Library/Managed State/logs`.

The window never runs as root. Privileged runs and preference writes go through
`ManagedStateKeeperHelper`, which the package installs as the LaunchDaemon
`io.macadmins.Outset.helper`. The helper accepts only a client signed as
`io.macadmins.Outset.gui` by its own Team ID, runs only the fixed outset
arguments for a named mode, writes only the keys the window edits, and refuses
an outset binary that anyone but root could change. An unsigned build therefore
refuses every client: sign the helper and the app with the same Developer ID
before deployment.

Build and test:

```
swift test
```

```
make pkg
```

Set `SIGNING_IDENTITY_APP` and `SIGNING_IDENTITY_PKG` to sign the app and the
package.
