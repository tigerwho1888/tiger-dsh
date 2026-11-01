# TigerDSH

A native iPhone app for a DSH host running on your own Mac, reached over Tailscale.

It is a client for DSH's own `/api`: `POST /api/<method>` for calls and one multiplexed
WebSocket (`/api/remote.mux`) for streams. There is no plugin on the host side and
nothing to install on the Mac.

Each person signs in with their own link — the one `dsh web` prints
(`https://<your-mac>.<your-tailnet>.ts.net/?token=…`). The link is exchanged once for
DSH's own year-long sign-in cookie, which is kept in the Keychain. Nothing is
hard-coded: no host name, no token.

## How it works

```
iPhone                          Tailscale              your Mac
┌─────────────┐                (private net)        ┌──────────────┐
│  TigerDSH   │ ─── HTTPS ───────────────────────▶ │  dsh web     │
│             │ ◀── WebSocket (remote.mux) ─────── │  /api        │
└─────────────┘                                     └──────────────┘
```

Four facts explain the whole design:

1. **The Mac does the work.** The phone holds no model, no keys and no data of its
   own. It draws what the host sends.
2. **Tailscale is the network.** The phone and the Mac must be signed in to the same
   tailnet. Nothing is exposed to the public internet.
3. **One sign-in, kept once.** `dsh web` prints a URL carrying a launch token. The app
   trades it for DSH's own cookie and stores that in the Keychain. The launch token
   changes on every DSH restart; the cookie lasts a year.
4. **One socket for everything.** Streaming replies, tool output, approvals and
   scheduler events all travel on a single multiplexed WebSocket, so the app
   reconnects once rather than per stream.

## What you can do

| screen | what it does |
|---|---|
| **Chat list** | every chat and project, with filters and search |
| **Chat** | stream a reply, fold long tool output, jump to the bottom |
| **Composer** | queue messages, answer the agent's questions, attach files, dictate |
| **Approvals** | approve or deny a tool call the agent is waiting on |
| **Scheduler** | see and arm the host's scheduled cards |
| **Plugins** | read the host's installed plugins |

## Requirements

- Xcode 27 with the iOS 27 SDK (the app builds against it; it still runs on iOS 18 and up).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`.
- On the phone: Tailscale, signed in to the same tailnet as the Mac.
- On the Mac: `dsh web` running.

## Build and run

```sh
xcodegen generate                    # after adding or removing a source file
open TigerDSH.xcodeproj              # then Run, or:
xcodebuild -project TigerDSH.xcodeproj -scheme TigerDSH \
  -sdk iphonesimulator -configuration Debug \
  -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build
```

To install on a real phone, open the project in Xcode, pick your team under Signing &
Capabilities, and Run with the phone connected (or paired over the same Wi-Fi).

Installing on a phone for the first time takes about fifteen minutes of hands-on work,
once:

1. Xcode ▸ Settings ▸ Accounts ▸ add your Apple ID (a free account works; the app then
   runs for seven days at a time).
2. Plug the iPhone into the Mac with a cable and tap Trust on the phone. On the phone,
   turn on Settings ▸ Privacy & Security ▸ Developer Mode, which needs a restart.
3. In Xcode, select the TigerDSH target ▸ Signing & Capabilities ▸ Team: your Apple ID
   (a personal team is fine). The bundle id may need a suffix such as `.you` if the
   plain one is already taken.
4. Choose the phone as the run destination and press Run. The first launch is refused
   with "Untrusted Developer"; allow it in Settings ▸ General ▸ VPN & Device Management.

## Signing in

Start `dsh web` on the Mac and copy the URL it prints. Type or paste it into the first
screen of the app and tap Connect.

The link changes every time DSH restarts; the sign-in it buys lasts a year. If the app
stops working after a restart of the host, paste the new link — that is the normal
behaviour, not a fault.

Debug builds can also read the link from `Documents/dsh-link.txt` inside the app's own
container, which is how the UI tests sign in unattended. The file is deleted as soon as
it is read, and the code that reads it is inside `#if DEBUG`.

## Tests

The UI tests drive the app in the Simulator against a real DSH host. Two things matter:

- The app must already be signed in. `xcodebuild test` reinstalls the app, and the
  Simulator drops an ad-hoc-signed app's Keychain items on reinstall, so the sign-in is
  lost. Write the link file **immediately before** the test run and do not launch the app
  in between:

  ```sh
  D=<simulator UDID>
  xcodebuild build-for-testing -project TigerDSH.xcodeproj -scheme TigerDSH \
    -destination "id=$D" -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO
  xcrun simctl install $D build/dd/Build/Products/Debug-iphonesimulator/TigerDSH.app
  C=$(xcrun simctl get_app_container $D com.tigerwho.dshphone data)
  printf 'https://<your-mac>.<your-tailnet>.ts.net/?token=%s' "$(cat ~/.dsh/logs/dsh-launch-token.txt)" > "$C/Documents/dsh-link.txt"
  xcodebuild test-without-building -project TigerDSH.xcodeproj -scheme TigerDSH \
    -destination "id=$D" -derivedDataPath build/dd \
    -only-testing:TigerDSHUITests/SmokeTests CODE_SIGNING_ALLOWED=NO
  ```

- `TEST_RUNNER_DSH_GEOM=1` (scroll geometry into `Documents/geom.log`) and
  `TEST_RUNNER_DSH_PERF=1` (the frame overlay) switch on diagnostics. Never pass the link
  through an environment variable: launch environments are written to the system log.

## Layout

```
TigerDSH/
  App/      TigerDSHApp.swift      — the app, the routes, the sign-in screen
  Core/     DSHClient.swift        — sign-in, RPC, the cookie
            Mux.swift              — the multiplexed WebSocket: reconnect, heartbeat, streams
            ChatModel.swift        — one chat: history, streaming, folds, queues
            AppModel.swift         — the chat list, projects, filters, permissions
            Keychain.swift, JSON.swift, Models.swift, Markdown.swift, ToolText.swift, FrameMonitor.swift
  Views/    NativeStyle.swift      — the iOS 26/27 chrome, with iOS 18 kept working
            HomeView.swift         — chat list, filters, search
            ChatView.swift         — the chat: scroll behaviour, folds, jump-to-bottom
            Composer.swift         — the dock: queue, run bar, questions, field, attachments, voice
            MessageViews.swift, ChatSheets.swift, MarkdownView.swift
            SettingsView.swift, SchedulerView.swift, PluginsView.swift, NewChatSheet.swift
  Resources/Info.plist, Assets.xcassets
TigerDSHUnitTests/                 — pure unit tests, no host needed
TigerDSHUITests/                   — UI tests that run against a real host
```

## Security

The app stores one item in the Keychain: DSH's own sign-in cookie. It holds no model
key, no Tailscale key, and no copy of your data.

Report a vulnerability privately through the **Security** tab, not a public issue. See
[SECURITY.md](SECURITY.md).

## What the app does not do

No Android app, no host-side plugin, no analytics, and no data of its own: it shows what
the host it is signed in to sends it.

## License

MIT. See [LICENSE](LICENSE).
