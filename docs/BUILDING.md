# Building, versioning and installing

## Versions

`VERSION` (repo root) holds the app version, `MAJOR.MINOR.PATCH`. It becomes
`CFBundleShortVersionString` of QMI Darwin.app, and qmid reports it (`qmictl status`, the
`version` key in the XPC status, the "qmid … starting" log line).

**Bump `VERSION` for every build you install**, in the same commit as the change:

| Change | Bump | Example |
|---|---|---|
| Fix, tuning, log/message change | PATCH | 0.5.7 → 0.5.8 |
| New feature, config key, API addition (additive) | MINOR | 0.5.8 → 0.6.0 |
| Incompatible API change (also bump `qmidAPIVersion` in QMIDAPI) | MAJOR | 0.6.0 → 1.0.0 |

The build number (`CFBundleVersion`) is set automatically to the build time
(`YYYYMMDDhhmmss`), so every build is distinct even without a bump. The host app compares the
running qmid's `version (build)` with its own to decide whether qmid needs a restart after an
update.

For throwaway experiments, `VERSION=0.5.8-test scripts/build-app.sh` overrides the file without
editing it; don't commit or keep such builds installed.

## Build

```sh
swift build && swift test             # debug build + tests
scripts/build-app.sh                  # release build, .build/QMI Darwin.app, signed
```

`build-app.sh` builds qmid, qmictl and the host app in release mode, assembles the bundle with
the LaunchDaemon plist, and signs everything with the first Apple Development / Developer ID
identity (`SIGN_IDENTITY=...` to choose). The team of that identity is the team qmid accepts XPC
callers from.

## Install or update

```sh
rm -rf "/Applications/QMI Darwin.app"
cp -R ".build/QMI Darwin.app" /Applications/
"/Applications/QMI Darwin.app/Contents/MacOS/QMI Darwin" register
```

- First install: approve QMI Darwin once in System Settings › General › Login Items.
- Update: `register` (or opening the app) sees the running qmid is an older build and restarts
  it; no new approval. Connections drop for a few seconds.
- If the LaunchDaemon plist changed (e.g. a new launchd key), unregister first so launchd
  reads it again:
  `"…/QMI Darwin" unregister`, copy the new app, then `register`.

## Check

```sh
"/Applications/QMI Darwin.app/Contents/MacOS/QMI Darwin" status   # app vs running qmid version
"/Applications/QMI Darwin.app/Contents/MacOS/qmictl" status
"/Applications/QMI Darwin.app/Contents/MacOS/qmictl" log
```

## Checklist per change

1. Change code, `swift build && swift test`.
2. Bump `VERSION`.
3. `scripts/build-app.sh`, install/update as above, check `status` shows the new version.
4. Commit code and `VERSION` together.
