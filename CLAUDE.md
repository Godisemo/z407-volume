# z407-volume

macOS menu bar app (Swift 6, SwiftPM, no Xcode project) that maps the volume keys to Logitech Z407 BLE volume
commands, connecting just in time and releasing the speaker after 5 s idle so a second computer can use it.

- Build: `./build.sh` (assembles `build/Z407Volume.app` from the SwiftPM binary + `Resources/Info.plist`). `./build.sh run` installs to `~/Applications` and relaunches.
- Protocol constants live only in `Sources/Z407Volume/Z407Protocol.swift`; source of truth is freundTech's `doc/Protocol.md` plus its PR #2.
- Runtime needs Bluetooth + Accessibility TCC grants. `build.sh` signs with the self-signed "Z407Volume Local Signing" identity from `~/Library/Keychains/z407-signing.keychain-db` (made by `setup-signing.sh`) so grants survive rebuilds; ad-hoc signing would invalidate them. The login keychain can't be used from a non-GUI session — codesign gets errSecInternalComponent there.
- A key tap only sees input from the login session on screen; test key handling with the app's account in front.
- Debugging: the app writes `~/Library/Logs/Z407Volume.log` (key presses, state changes, raw BLE bytes); read it directly rather than relying on `log show`.
- The Z407 has no absolute volume or readback (verified with `--probe`, see README); slider levels are estimates counted from written steps. Step counts (volume 32, bass 16) were counted by ear.
- `--probe` / `--speed-probe` run as a second instance (`open -n … --args --probe`) and need the menu app idle or quit, since the speaker takes one client.
- Speaker acks (`c0 xx`) prove receipt only: unpaced steps are acked but not applied, so judge anything timing-related by ear.
- `./build.sh run` relaunches the app, which triggers the startup sync (audible dip) unless Sync on Startup is off.
- Machine-specific notes, if any, live in the git-ignored `CLAUDE.local.md`.
