# qmi-darwin

A QMI connection manager for Quectel 4G/5G modems (RM551E-GL, RM520N) on macOS. No kext, no
DriverKit, no modem-side NAT.

The modem runs in QMI mode. A root daemon, `qmid`, talks QMI to it directly over IOUSBHost and
brings up one data connection (PDN) per APN, such as internet and IMS. It gives each PDN its
own `utun` interface and publishes it to macOS as a network service. configd then takes care
of routes, DNS and Wi-Fi/cellular failover, the same way it does for any other interface.

- The Mac gets the carrier's IPv4 and IPv6 addresses directly, with no double NAT through the
  modem's Linux.
- Several PDNs run side by side, each on its own interface with its own routing policy.
- APN sync: the config file is the source of truth for the modem's profiles.
- Lifecycle handling: hotplug, sleep/wake, modem reset, SIM and eSIM switches, network
  rejects with the 3GPP cause, and backoff.
- Exposes QoS: the QCI and APN-AMBR of each PDN, plus the dedicated bearers with their
  packet filters.
- An XPC API (`QMIDAPI`) and read-only SCDynamicStore keys for client apps.

## How it works

```
  qmictl (CLI)      client apps (QMIDAPI)      QMI Darwin.app (registers qmid)
       │                     │                              │
       └──────────── XPC  com.qmi-darwin.qmid ──────────────┘
                             │   (callers signed by the same team)
┌────────────────────────────▼─────────────────────────────────────────┐
│ qmid  (root LaunchDaemon)                                            │
│                                                                      │
│  Manager ──── device · SIM · registration · per-PDN dial / backoff   │
│    ├─ APN sync ........ qmid.json → modem profiles, attach APN       │
│    ├─ PDNSession ...... WDS call per IP family, on the PDN's mux     │
│    ├─ PDNQoS .......... QCI, APN-AMBR, dedicated bearers             │
│    └─ ServicePublisher ─────────────► SCDynamicStore ──► configd     │
│         │                             (routes, DNS, Wi-Fi failover)  │
│  QMIKit: QMUX / TLV codecs                                           │
│         │                                                            │
│         │ control plane           QMIDatapath (C, own queue)         │
│         │                         QMAP mux/demux ◄──► utun per PDN   │
└─────────┼───────────────────────────────────┼────────────────────────┘
          │ USB control + interrupt EP        │ USB bulk IN/OUT
          │ QMI: CTL WDA WDS NAS DMS UIM QoS  │ QMAP frames, mux 0x81, 0x82, …
┌─────────▼───────────────────────────────────▼────────────────────────┐
│ Quectel modem in QMI mode  (USB interface "RmNet", via IOUSBHost)    │
└──────────────────────────────────────────────────────────────────────┘
```

1. **Transport.** qmid looks at USB devices from a built-in list of modem vendors (Quectel,
   Sierra, Telit, Fibocom, SIMCom, ZTE, Foxconn, Qualcomm), plus any added in the config.
   It picks the QMI port from the USB descriptors alone: vendor-specific class
   **ff/ff/ff** with three endpoints. The AT ports also have three endpoints but report
   ff/00/00. It opens only that port, so the AT ports stay free for other tools. QMI messages go over the USB control
   endpoint, and the interrupt endpoint signals when a response is waiting.
2. **Bring-up.** CTL hands out client IDs and WDA sets the data format (raw IP, QMAP
   aggregation). NAS and UIM report SIM state, registration and operator names.
3. **PDNs.** For each configured PDN, qmid makes sure the modem profile matches the config
   (APN sync), then starts a WDS call per IP family on that PDN's QMAP mux. The runtime
   settings it gets back (addresses, DNS, P-CSCFs, MTU) are applied to a new `utun`.
4. **Data path.** A C data path on its own dispatch queue moves packets between the bulk
   pipes and the utuns. It splits QMAP frames by mux ID and handles aggregation and flow
   control. Swift code never runs per packet.
5. **macOS integration.** Each connected PDN is published as a State:-only network service.
   configd then installs routes and DNS and ranks it against Wi-Fi and Ethernet according
   to its `policy`:

   | Policy | Effect |
   |---|---|
   | `prefer-wifi` | Wi-Fi or Ethernet first, cellular as fallback (default for internet) |
   | `prefer-cellular` | cellular becomes the primary interface |
   | `last-resort` | used only when nothing else is up |
   | `never` | never the default route; apps bind to its utun explicitly (default for IMS) |

6. **Lifecycle.** Calls that drop are redialled with backoff. Permanent 3GPP rejects block
   that IP family until something changes, such as a config reload, a SIM change or
   re-registration. After a modem reset, unplug or wake, qmid reopens the device and
   reconnects.

## Requirements

- macOS 13 or later; Swift 5.9+ (Xcode command line tools).
- A modem with QMI firmware connected over USB. Tested with Quectel (RM551E-GL, RM520N);
  other Qualcomm-based modems from the listed vendors should be found, but are untested.
- An Apple Development or Developer ID signing identity in your keychain, to build the app.

## Install

### 1. Put the modem in QMI mode (once)

Send these AT commands to the modem from any AT terminal:

```
AT+QCFG="usbnet",0        # RMNET/QMI instead of ECM
AT+CFUN=1,1               # reboot; the modem re-enumerates after ~35 s
```

If the modem's own connection manager (QCMAP) auto-connects PDNs, turn that off too. On
modems that support it, `AT+QMAP="auto_connect",<rule>,0` does this for each rule. Otherwise
the modem holds the PDNs itself and qmid can't use them.

### 2. Build and install the app

```sh
git clone <this repo> qmi-darwin && cd qmi-darwin
swift build && swift test
scripts/build-app.sh                      # → .build/QMI Darwin.app, signed
cp -R ".build/QMI Darwin.app" /Applications/
open "/Applications/QMI Darwin.app"       # registers qmid with launchd (SMAppService)
```

Approve **QMI Darwin** once in System Settings › General › Login Items. After that, launchd
starts qmid as root at boot, and you won't see password prompts again.

`build-app.sh` uses the first Apple Development or Developer ID identity it finds. Set
`SIGN_IDENTITY="…"` to choose a different one. A signed qmid only accepts XPC callers signed
by the same team.

### 3. Configure (optional)

Without a config file, qmid runs internet on profile 1 and IMS on profile 2. To change that,
write `/Library/Application Support/qmi-darwin/qmid.json`:

```json
{
  "pdns": [
    { "name": "internet", "role": "internet", "apn": "internet", "family": "ipv4v6", "policy": "prefer-wifi" },
    { "name": "ims", "role": "ims", "apn": "ims", "family": "ipv6", "policy": "never" }
  ],
  "carriers": [
    { "name": "Example", "mccmnc": ["00101"], "apn": "internet" }
  ]
}
```

Then run `qmictl reload`, or `qmictl config set FILE`, which validates the file and applies
it. `carriers` sets the attach APN for each SIM, matched by MCC/MNC or ICCID prefix. If the modem isn't
found, add its USB vendor ID with `"vendorIDs": ["1234"]`. If its QMI port isn't
ff/ff/ff, also set `"interface": N`. All keys
are documented in [docs/API.md](docs/API.md) and `Sources/QMIHost/Config.swift`.

### 4. Check

```sh
Q="/Applications/QMI Darwin.app/Contents/MacOS/qmictl"
"$Q" status                               # modem, SIM, network, PDNs, addresses, counters
"$Q" log                                  # qmid's log (--level debug for the QMI trace)
scutil --nwi                              # what macOS made of it
```

### Update and uninstall

- **Update:** bump `VERSION`, rebuild, replace the app in /Applications, then open it (or run
  `"…/QMI Darwin" register`). It notices that qmid is an older build and restarts it, without
  a new approval. Details are in [docs/BUILDING.md](docs/BUILDING.md).
- **Uninstall:** run `"/Applications/QMI Darwin.app/Contents/MacOS/QMI Darwin" unregister`,
  then delete the app. To switch the modem back to ECM, send `AT+QCFG="usbnet",1` and
  `AT+CFUN=1,1`.

## Usage

```
qmictl status                               PDNs, addresses, counters
qmictl connect NAME | disconnect NAME
qmictl policy NAME prefer-wifi|prefer-cellular|last-resort|never
qmictl events                               stream qmid's events
qmictl log [--level debug]                  recent log lines, then live
qmictl config get | config set FILE
qmictl sync                                 APN sync report: PDN ↔ modem profile
qmictl reload | restart
```

With qmid stopped, `qmictl probe | modem-status | profiles | plmn-name | profile-write | run`
talk to the modem directly, for development. Run `qmictl --help` to see all options.

Client apps use the `QMIDAPI` library (XPC: status, events, connect/disconnect, policy,
config, logs). Apps that only need to read state can watch the SCDynamicStore keys instead.
Both are described in [docs/API.md](docs/API.md).

## Development

```sh
swift build && swift test
sudo scripts/dev-daemon.sh load           # run the debug qmid under launchd until reboot
scripts/dev-daemon.sh log                 # follow its log
.build/debug/qmictl status                # unsigned dev qmid accepts root/admin callers
sudo scripts/dev-daemon.sh unload
```

The dev daemon uses the same launchd label as the app. Unregister the app before loading it.

## Layout

| Path | What |
|---|---|
| `Sources/QMIKit` | QMUX/TLV codecs and QMI message definitions (pure, unit-tested) |
| `Sources/QMIDatapath` | C + Objective-C: IOUSBHost pipes, QMAP, utun |
| `Sources/QMIHost` | transport, clients, PDN sessions, QoS, APN sync, service publishing, the state machine |
| `Sources/qmid` | the root LaunchDaemon (XPC `com.qmi-darwin.qmid`) |
| `Sources/qmictl` | CLI: talks to qmid, or directly to the modem for development |
| `Sources/QMIDAPI` | qmid's XPC API for client apps |
| `Sources/QMIDarwinApp` | `QMI Darwin.app` host: registers qmid with SMAppService |
| `launchd/` | production LaunchDaemon plist |
| `scripts/` | `build-app.sh` (signed app bundle), `dev-daemon.sh` (debug daemon) |
| `docs/` | [API](docs/API.md), [building and versioning](docs/BUILDING.md), [bearers and QoS over QMI](docs/QMI-bearers.md) |
| `PLAN.md` | design notes and milestones |
