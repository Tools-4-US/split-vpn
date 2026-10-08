# Geleit for macOS

Native SwiftUI menu bar app. macOS 14 (Sonoma) or later.

## Requirements

- [Homebrew](https://brew.sh) and `brew install openfortivpn` (tested version in [`OPENFORTIVPN_VERSION`](OPENFORTIVPN_VERSION))
- Xcode command line tools (Swift 6) to build

## Build and install

```bash
./build.sh            # → build/Geleit.app
./build.sh --install  # also copies it to /Applications
```

The app is signed ad hoc for local use. Then install the privileged helper once:

```bash
sudo "/Applications/Geleit.app/Contents/Resources/install-helper.sh"
# remove later with: sudo ".../install-helper.sh" --uninstall
```

The app shows the same command in a banner until the helper is installed.

## Usage

- **Menu bar**: *Connect to <name>* for each saved connection; *Disconnect*, live status and *Open Geleit console*.
- **Console**: create and edit connections, connect/disconnect, live traffic, session details and connection log ("Copy log" is handy for bug reports).
- Geleit does not start at login; open it from Spotlight or Launchpad when you need it.

## Custom icons

`build.sh` bundles whatever it finds in `Resources/`:

| File | Use |
|---|---|
| `AppIcon.png` (1024×1024) or `AppIcon.icns` | App icon |
| `MenuBarIcon.(pdf\|svg\|png)` | Disconnected |
| `MenuBarIconConnecting.*` | Connecting / reconnecting |
| `MenuBarIconConnected.*` | Connected |
| `MenuBarIconError.*` | Failure |

Menu bar icons are drawn as template images (single color, transparent background, 18×18 pt). Missing files fall back to SF Symbols.

## Layout

| Path | Contents |
|---|---|
| `Sources/Geleit/TunnelController.swift` | Connection lifecycle, routes/DNS, reconnection |
| `Sources/Geleit/SAMLAuth.swift`, `RawHTTPS.swift` | Browser SSO and cookie exchange (see [`spec/`](../../spec/fortigate-ssl-vpn.md)) |
| `Sources/Geleit/PennantMark.swift` | In-app emblem (vector pennant, stripe follows the connection state) |
| `Sources/Geleit/TrafficMonitor.swift` | 64-bit interface counters via `sysctl(NET_RT_IFLIST2)` |
| `helper/geleit-helper` | The only code that runs as root; validates every argument |
| `install-helper.sh` | Installs the helper and its `sudoers` rule |

## Debug screenshots

Debug builds can render the console with fake data. Demo mode never calls the privileged helper, so it is safe to run while a real tunnel is up.

```bash
swift build
GELEIT_DEMO=connected GELEIT_RENDER=/tmp/geleit.png .build/debug/Geleit     # offscreen, works with the screen locked
GELEIT_DEMO=connected GELEIT_SNAPSHOT=/tmp/geleit.png .build/debug/Geleit   # captures the real window (screen unlocked)
```

`GELEIT_DEMO` accepts `connected`, `reconnecting`, `failed` or `idle`.
