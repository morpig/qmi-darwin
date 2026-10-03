# qmid client API

How an app talks to `qmid`, the qmi-darwin daemon that owns the modem's data connections.
Nothing here requires changes to qmi-darwin; everything goes through the public `QMIDAPI` library.

## What qmid owns

`qmid` runs as root (launchd daemon), opens the modem's QMI interface over IOUSBHost, dials
the PDNs from its config, and brings each one up as a `utunN` interface that macOS treats as a
normal network service (routes, DNS, primary-interface selection by IPMonitor).

When the modem is used through qmid (QMI mode), other software on the Mac should follow these rules:

- **Do not enable ECM, VLAN or IPPT** (`AT+QCFG="usbnet"` must stay `0`, no
  `AT+QMAP="VLAN"`, no IP passthrough). Those modes put the data path on a different USB
  function and fight qmid for the PDNs.
- **Do not open the QMI interface** (class ff/ff/ff). qmid holds it exclusively. The AT port
  is still free for other software (signal, cell info, SMS, etc.).
- **Do not edit APNs with `AT+CGDCONT`.** qmid's config is the source of truth for the
  modem's data profiles; it checks the modem every 30 s and rewrites profiles that drifted.
  Edit APNs through `setConfig` (below).
- **Do not use `AT+CGACT` / `AT+QNETDEVCTL` to start data.** Use `connect` / `disconnect`.
- `AT+CFUN` cycles and modem resets are fine; qmid notices and redials. USB replug and
  sleep/wake are handled too.

## Adding the library

`QMIDAPI` is a Foundation-only library product (no USB/QMI code, no root). In Xcode:
*File → Add Package Dependencies… → Add Local…* → the qmi-darwin checkout, then link the
**QMIDAPI** product to your target. In `Package.swift`:

```swift
.package(path: "../qmi-darwin"),
// target dependencies:
.product(name: "QMIDAPI", package: "qmi-darwin"),
```

Requirements:

- **Code signing:** a signed (release) qmid only accepts XPC connections from processes
  signed by the same Apple Developer team with an Apple certificate. Sign your app with the
  same team (`codesign -dv` on qmid shows its `TeamIdentifier`; the ID in a certificate's
  name is the certificate's, not the team's). An unsigned dev build of qmid (from
  `swift build`) accepts root and admin-group users instead.
- **No sandbox exception needed** if your app isn't sandboxed. If it is, it needs
  `com.apple.security.temporary-exception.mach-lookup.global-name` = `com.qmi-darwin.qmid`.
- macOS 13+.

## Using the client

```swift
import QMIDAPI

let qmid = QMIDClient()                  // callbacks on the main queue by default

qmid.onAvailabilityChange = { up in      // false when qmid isn't running or restarting
    // show "qmid not running" in the menu
}
qmid.onEvent = { event in
    switch event {
    case .modem(let state, let network, let error):
        // state: "absent" | "opening" | "ready"; network e.g. "registered, ps attached, lte"
    case .pdn(let pdn):
        // full state of one PDN; replace what you had for pdn.name
    case .config:
        // config changed (setConfig or reload); PDNs will redial, re-read getConfig if shown
    case .unknown:
        break                            // newer qmid; ignore
    }
}
qmid.onSIM = { sim in                    // QMIDSIM?, see "SIM and default bearer"
    // nil: no SIM known (modem away or not read yet)
}
qmid.onPLMN = { plmn in                  // QMIDPLMN?, see "Registered network and operator name"
    // nil: not registered
}
qmid.onBearers = { pdn, bearers in       // [QMIDBearer], see "Dedicated bearers and QoS"
    // full list for that PDN; [] when it has none
}
qmid.subscribe()                         // current state arrives immediately as events
```

- Call `subscribe()` once. The client reconnects and resubscribes by itself if qmid restarts,
  and a fresh snapshot (one `.modem`, one `onSIM` and one `onPLMN` call, one `.pdn` per PDN, and one `onBearers` call per connected PDN)
  arrives each time.
- Treat events as **full state, not deltas**: each `.pdn` event carries the whole PDN.
- `status()` returns the same data on demand (plus datapath counters) if you need a pull.
- Every call has a completion-handler form and an `async throws` form:

```swift
let s = try await qmid.status()
try await qmid.connect(pdn: "internet")
try await qmid.disconnect(pdn: "internet")
try await qmid.setPolicy(pdn: "internet", policy: "prefer-cellular")
```

Errors are `QMIDError` with a human-readable `message` (e.g. `"no PDN foo"`,
`"modem not ready (absent); will connect when it is"`). Show it as is.

### Calls

| Call | Effect | Persists? |
|---|---|---|
| `status` | modem + PDN state | – |
| `connect(pdn:)` | dials now, clears backoff/blocked state; completes when the attempt has ended (see below) | until qmid restarts or reload |
| `disconnect(pdn:)` | hangs up and stops redialing | until qmid restarts or reload |
| `setPolicy(pdn:policy:)` | changes routing priority, no reconnect | until qmid restarts or reload |
| `reload` | re-reads qmid.json, redials everything | – |
| `getConfig` | qmid.json as JSON `Data` | – |
| `setConfig(_:)` | validates, writes qmid.json, reloads | yes |

`connect` completes once the dial attempt is over: successfully when the PDN is connected,
with an error when it isn't (rejected, not attached, no profile, or cancelled by `disconnect`).
A dial can take up to a minute per IP family when the network doesn't answer. On failure the
`QMIDError` also carries the PDN as the attempt left it, so the cause can be acted on without
parsing the message:

```swift
do {
    try await qmid.connect(pdn: "emergency")
} catch let e as QMIDError {
    if e.pdn?.reason == .notAttached { /* no network: try another way */ }
    if let c = e.pdn?.causes.first(where: \.is3GPP), c.code == 31 { /* rejected by the network */ }
}
```

Dials of different PDNs run in parallel: a `connect` never waits for another PDN's dial.
`connect` on a connected PDN completes at once (and restarts its `maxUptime`, see "One-shot
PDNs").

To make a policy or on/off choice permanent, change `policy` / `autoconnect` in the config
with `setConfig`. `setConfig` and `reload` briefly drop **all** PDNs while they redial
(a few seconds); runtime calls don't.

## PDN fields (`QMIDPDN`)

| Field | Meaning |
|---|---|
| `name` | config name, e.g. `internet`, `ims` |
| `state` | `idle`, `waiting` (for the modem/network), `dialing`, `connected`, `backoff` (retry scheduled), `blocked` (network rejected with a permanent cause); `stateName` has the raw string if unknown |
| `policy` | `prefer-wifi`, `prefer-cellular`, `last-resort`, `never` |
| `role` | `internet`, `ims`, `other` |
| `interface` | `utunN` while connected |
| `ipv4`, `ipv6` | addresses; `ipv6` is `addr/prefix`, `ipv6Address` strips the prefix |
| `dns`, `pcscf` | server lists (P-CSCF for IMS) |
| `mtu`, `profile` (modem cid), `apn`, `mux`, `serviceID` | details |
| `wanted` | `false` after `disconnect`, and for a one-shot PDN whenever it is down |
| `uptime` | seconds connected (only in `status`, not in events) |
| `error` | last failure as the cause code with its official name: `3GPP #33: Requested service option not subscribed` (TS 24.301), `internal #210: PDN IPv6 call disallowed` / `CM #2001: no service` (the modem's own names), or `call end reason N: …` without a verbose cause; a code without a known name is shown as the number only. Per family (`ipv4: …; ipv6: …`) unless every family failed alike |
| `reason` | `error` as a word (`QMIDReason`): `notAttached`, `noProfile`, `rejected` (the network or modem ended the call, see `causes`), `failed` (no cause, e.g. a timeout), `dropped` (went down after connecting), `maxUptime`, `modemLost`; `nil` without an error or for a reason this client doesn't know |
| `causes` | `error`'s call end causes, one per family (`QMIDCause`: `family` 4/6, `type` `"3GPP"` / `"internal"` / `"CM"` / … / `"call end reason"`, `code`, `name`); `is3GPP` for TS 24.301 ESM causes. `[]` when there are none |
| `blocked` | per-family rejections qmid won't retry, e.g. `["ipv6: 3GPP #50: PDN type IPv4 only allowed"]`. A 3GPP rejection of the APN itself (#8, #27, #29, #32, #33) blocks every family. Cleared by `connect`, `reload`, re-registration or a different SIM. Never set on a one-shot PDN |
| `qci` | QoS class of the PDN's default bearer while connected, e.g. `6` for internet, `5` for IMS |
| `ambr` | APN-AMBR while connected (`QMIDAMBR`, `uplink` / `downlink` in bits per second), when the modem reports it. The network can change it on a live connection (e.g. following the radio: 500 Mbps on 5G NSA, 100 Mbps on LTE only); each change is a `.pdn` event |
| `bearers` | the PDN's dedicated bearers (`[QMIDBearer]`); only in `status()`, `nil` in `.pdn` events (see "Dedicated bearers and QoS") |

Suggested UI mapping: `connected` → up (show interface and addresses); `dialing` /
`waiting` / `backoff` → connecting (show `error` for backoff); `blocked` → error with the
cause and a "Retry" that calls `connect`; `idle` with `wanted == false` → off (with `error`
when it went down by itself).

## SIM and default bearer (`QMIDSIM`)

qmid identifies the SIM by its **home MCC/MNC** (from the SIM, so it doesn't change while
roaming) and its **ICCID**, and reports how the default internet bearer (the LTE attach APN)
follows it. It arrives through `onSIM` (after `subscribe()` and on every change) and as
`status().sim`. A SIM switch (e.g. between eSIM profiles) shows up as a new `QMIDSIM`, usually
followed by the internet PDN reconnecting.

| Field | Meaning |
|---|---|
| `mccmnc` | home PLMN, `"00101"`, `"001001"` (MNC with 2 or 3 digits as the SIM defines it) |
| `iccidSuffix` | last 4 digits of the ICCID, `"…1234"`; the full ICCID is not exposed |
| `carrier` | name of the matching `carriers` entry in the config; `nil` when none matched (the SIM is on the fallback APN, see "Fallback APN") or none are configured |
| `matchedBy` | why it matched: `"iccid 8900"` (ICCID prefix) or `"mccmnc 00101"` |
| `attachAPN` | APN of the default bearer as the modem attached (`nil` until attached) |
| `attachAPNFromNetwork` | `true` when the network chose `attachAPN` (the attach profile had an empty APN) |

Suggested UI: show the carrier name (or the MCC/MNC when `carrier` is `nil`) and the
`attachAPN`. When `carrier` is `nil` and `attachAPNFromNetwork` is `true`, the SIM runs on the
network's default APN; offering "save as carrier" with `mccmnc` and `attachAPN` is a natural
action (add an entry to `carriers` with `setConfig`).

Without `onSIM` (older client code), the same event reaches `onEvent` as `.unknown(type: "sim")`.

## Registered network and operator name (`QMIDPLMN`)

The network the modem is registered on, with the operator's long and short name. It arrives
through `onPLMN` (after `subscribe()` and on every change) and as `status().plmn`; `nil` while
not registered. Unlike `QMIDSIM.mccmnc` (the SIM's home network), this changes when roaming.

| Field | Meaning |
|---|---|
| `mccmnc` | registered PLMN, `"00101"`; for matching, not for display |
| `longName` | operator long name, e.g. `"Example Mobile Network"` |
| `shortName` | operator short name, e.g. `"ExampleNet"` |
| `nameFromNetwork` | `true`: the network sent names for this PLMN (NITZ, in the EMM/MM Information message); `false`: the names come from the SIM or the modem |
| `displayName` | `longName`, else `shortName`; `nil` when there is neither |
| `emergencyBearers` | LTE: whether the network supports emergency bearers (EMC BS in the Attach/TAU Accept, TS 24.301). A UE shouldn't request an emergency PDN when it is `false`. `nil` when the modem doesn't say (not registered, not LTE). Networks differ: some `true`, many `false` |
| `emergencyAccessBarred` | LTE: emergency access is barred on the cell; `nil` when unknown |

- Each name comes from the first source that has it:
  1. the network (NITZ),
  2. the SIM's service provider name (EF_SPN), only while on the SIM's home network; one
     name, used for both,
  3. the SIM's name for the registered network (EF_OPL/EF_PNN),
  4. the modem's own (firmware operator table), e.g. `"ExampleNet"` / `"EX"`.
- The network sends its names once, usually a few seconds after attach. Until then, and on
  networks that never send them, the other sources fill in; an update follows when the
  network's arrive.
- Either name, or both, can be `nil` (no source has one). The MCC/MNC is never filled in as
  a name; show nothing (or "Cellular") rather than `mccmnc`.
- Long names may not fit a menu bar; prefer `shortName` where space is tight.

Without `onPLMN` (older client code), the same event reaches `onEvent` as `.unknown(type: "plmn")`.

## Policies

`policy` decides how macOS ranks the cellular service against Wi-Fi/Ethernet. It only
changes routing; the PDN stays connected in every case.

| Policy | Behaviour |
|---|---|
| `prefer-wifi` (default for internet) | normal service order: Wi-Fi/Ethernet win when present |
| `prefer-cellular` | cellular becomes the primary interface |
| `last-resort` | used only when nothing else is up |
| `never` | never primary, no default route (IMS uses this; apps must bind to the interface) |

These services are published as runtime-only (`State:`) services, so they **don't appear in
System Settings → Network**; a client app is the place to show them.

## IMS

The `ims` PDN (modem profile 2, role `ims`, IPv6, policy `never`) comes up on its own `utun`
with no default route. An IMS/VoLTE client should:

- take `interface`, `ipv6Address` and `pcscf` from the `ims` PDN event,
- bind its sockets to that interface (`IP_BOUND_IF` / `IPV6_BOUND_IF`) or source address,
- re-register when a new `.pdn` event for `ims` shows a different address or P-CSCF list
  (the network may re-assign them after a reconnect).

qmid sets up the IMS profile (P-CSCF request, IM CN flag, APN type ims) itself.

## Dedicated bearers and QoS

Besides its default bearer, a PDN can have **dedicated EPS bearers** that the network sets up
for some of its traffic, each with its own QoS class, bit rates and traffic flow template
(TFT: the packet filters that decide which packets go on it). Operators use them for VoLTE
media (QCI 1) and for products like zero-rated or boosted apps. They can come and go within
seconds: a network may, for example, create a QCI 4 bearer when traffic to a CDN starts, add a
filter per CDN prefix it sees, and remove the bearer about 10 s after the traffic stops.

```swift
qmid.onBearers = { pdn, bearers in      // full list for that PDN, [] when there are none
    for b in bearers {
        // b.qci, b.isGBR, b.uplink.max / .guaranteed (bps), b.uplinkFilters, b.downlinkFilters
    }
}
let s = try await qmid.status()
s.pdn("internet")?.qci                   // 6 (default bearer)
s.pdn("internet")?.ambr                  // QMIDAMBR(uplink: 2000000000, downlink: 2000000000)
s.pdn("internet")?.bearers               // [QMIDBearer], same as the last onBearers
```

- **Push:** `onBearers(pdn, bearers)` after `subscribe()` for every connected PDN, then on
  every change (bearer created, filters or rates modified, bearer deleted). Like every other
  event it's full state: replace what you had for that PDN. A PDN going down pushes `[]` if
  it had bearers. Without `onBearers`, the event reaches `onEvent` as `.unknown(type: "bearers")`.
- **Pull:** `status()` has `bearers` in each connected PDN.
- QCI and AMBR are part of the PDN itself: they arrive in `.pdn` events (which are only sent
  on changes) and in `status()`, and are published in SCDynamicStore as `QCI` and
  `AMBR` (`Uplink`, `Downlink`) in the PDN's key.
- Bearers the device asks for itself are not possible: the modem refuses device-initiated
  QoS, so every bearer comes from the network.
- The network reports a bearer's whole TFT whenever it creates or changes it. A bearer that
  already exists when the PDN connects (or when the Mac wakes) shows its QCI and rates at once
  and its filters with its next change; until then `uplinkFilters` / `downlinkFilters` are
  empty.

### `QMIDBearer`

| Field | Meaning |
|---|---|
| `id` | opaque, stable while the bearer lives; a re-created bearer gets a new one. Use it to follow a bearer across events, not across reconnects |
| `qci` | QoS class identifier (1–4 GBR: 1 voice, 2 video, 3 gaming, 4 buffered video; 5 IMS signalling; 6–9 non-GBR); 5G QoS identifier on a 5G SA cell |
| `networkInitiated` | `true` when the modem said the network set it up; `nil` when it didn't say |
| `uplink`, `downlink` | `QMIDBitrates`: `max` (MBR) and `guaranteed` (GBR) in bits per second; `nil` where the network set no value |
| `isGBR` | a guaranteed rate is set in either direction |
| `uplinkFilters`, `downlinkFilters` | `[QMIDPacketFilter]`, lowest precedence first |

### `QMIDPacketFilter`

| Field | Meaning |
|---|---|
| `id` | 3GPP packet filter identifier, 0–15 |
| `precedence` | evaluation order, lowest first |
| `ipVersion` | `4` or `6` |
| `source`, `destination` | `"203.0.113.0/27"`, `"2001:db8:0:c0::/59"`; uplink filters usually set `destination`, downlink ones `source` |
| `ipProtocol` | `6` TCP, `17` UDP, … |
| `sourcePorts`, `destinationPorts` | `ClosedRange<Int>`; a single port is `443...443` |

Unset fields match anything. Filters can name the exact remote address and ports of one of
the Mac's connections; treat them like the log (nothing is redacted).

### IP families

A PDN may be up as IPv4 only, IPv6 only or dual-stack, depending on what the network grants
(seen so far: IPv4 only for both internet and IMS on some networks, dual-stack internet with
IPv6-only IMS on others). The fields above are the same in every case: a dual-stack PDN
still has one default bearer and one set of dedicated bearers, and their filters cover both
families (`ipVersion` per filter).

## Editing APNs (config)

`getConfig` returns qmid.json; edit it and send it back with `setConfig`. Keep unknown keys
as they are (decode into a dictionary, not a fixed struct), so newer fields survive.

```json
{
  "pdns": [
    { "name": "internet", "role": "internet", "apn": "internet", "family": "ipv4v6",
      "policy": "prefer-wifi", "autoconnect": true },
    { "name": "ims", "role": "ims", "apn": "ims", "profile": 2, "family": "ipv6",
      "policy": "never", "autoconnect": true }
  ]
}
```

| Key | Meaning |
|---|---|
| `name` | unique, required |
| `apn` / `profile` | at least one; `profile` pins the modem cid (1–255), otherwise matched by APN or created |
| `family` | `ipv4`, `ipv6`, `ipv4v6` (default) |
| `policy` | see Policies |
| `autoconnect` | dial when qmid starts / the modem appears |
| `role` | `internet`, `ims`, `other`; defaults from the name |
| `attach` | this PDN's APN is the LTE attach APN (default: true for role internet; at most one PDN) |
| `username`, `password`, `auth` | `auth`: `none`, `pap`, `chap`, `pap-chap` |
| `apnType` | APN type names written to the modem profile: `default`, `ims`, `mms`, `dun`, `supl`, `ia`, `emergency`, `ut`. Replaces the role's (`ims` for role ims, `default` for internet); without it, other roles leave the profile's as it is |
| `redial` | `false` makes the PDN one-shot (see below); default `true` |
| `maxUptime` | seconds a one-shot PDN stays connected before qmid hangs up |

### One-shot PDNs (`redial: false`)

For a PDN an app brings up only while it needs it (an emergency PDN dialled when the user
places an emergency call, for example). qmid then never dials it on its own:

- It is dialled only by `connect`; `autoconnect` defaults to `false` (`true` is refused).
- A failed dial isn't retried: the PDN goes `idle` with `wanted == false`, `error`, `reason`
  and `causes` (no `backoff`, no `blocked`).
- Any drop qmid wasn't asked for (network release, detach, a SIM change, the modem going
  away, a profile change, `reload`) leaves it `idle` and not wanted. In particular it is not
  redialled on whatever network the modem registers on next.
- `connect` while the modem isn't attached fails at once (`reason == .notAttached`) instead of
  waiting for the attach.
- `maxUptime` (optional, needs `redial: false`): after that many seconds connected, qmid
  hangs up (`reason == .maxUptime`). `connect` on the connected PDN starts the time again, so
  an app that still needs the PDN calls `connect` before it runs out; one that crashed or
  forgot can't hold it open.

```json
{ "name": "emergency", "profile": 3, "apn": "sos", "policy": "never",
  "redial": false, "maxUptime": 300 }
```

### Per-SIM default bearer (`carriers`)

`carriers` (optional, top level) sets the **attach PDN's** APN per SIM, i.e. the default
internet bearer. Every other PDN, IMS included, stays as configured on every SIM.

```json
{
  "pdns": [
    { "name": "internet", "role": "internet", "profile": 1 },
    { "name": "ims", "role": "ims", "apn": "ims", "profile": 2 }
  ],
  "carriers": [
    { "name": "Example", "mccmnc": ["00101"], "apn": "internet" },
    { "name": "Example 2", "mccmnc": ["00102", "001002"], "apn": "example" },
    { "name": "Travel eSIM", "iccid": ["8900"], "apn": "travel" },
    { "name": "Corp", "mccmnc": ["99999"], "apn": "corp", "username": "u", "password": "p", "auth": "chap" }
  ]
}
```

| Key | Meaning |
|---|---|
| `name` | shown as `QMIDSIM.carrier`, required |
| `mccmnc` | home PLMNs this entry applies to, 5 or 6 digits |
| `iccid` | ICCID prefixes (digits); for MVNOs and travel eSIMs that share or borrow a PLMN |
| `apn` | attach APN; absent or `""` = the network's default |
| `username`, `password`, `auth` | credentials for the attach APN; absent = none |

- Each entry needs `mccmnc` or `iccid` (or both).
- **Matching:** the most specific entry wins: an ICCID prefix beats an MCC/MNC, a longer prefix
  beats a shorter one, and between equals the first in the list wins.
- **No match:** the fallback APN applies, see below.
- **Without `carriers`** qmid behaves as before: the attach PDN's settings apply to every SIM.
- A SIM change costs one LTE re-attach when the new SIM needs a different attach APN (the
  modem attaches with the old one before qmid can rewrite it): all PDNs drop for a few seconds.
  The same SIM after a restart needs none.

#### Fallback APN (SIMs no entry matches)

With `carriers` set, the attach PDN's own `apn` / `username` / `password` / `auth` (the
`internet` PDN, usually) are no longer "the APN": they are the **fallback** for every SIM that
no `carriers` entry matches. A carrier-specific APN there is applied to every unknown SIM,
which often can't attach with it.

- **Recommended: leave the attach PDN without an `apn`.** An unmatched SIM then gets an empty
  APN, and the network assigns its default bearer (reported as `attachAPN` with
  `attachAPNFromNetwork == true`). Most networks attach fine this way.
- **A specific SIM or carrier needs its APN as a `carriers` entry**, by `mccmnc` or, for
  MVNOs and travel eSIMs, by `iccid` prefix; not as the fallback.
- **"No match" needs the home MCC/MNC.** Until the modem reports it (it can't while
  registering), a SIM that no `iccid` entry matches is not yet identified, and qmid leaves the
  attach profile as it is. The fallback applies once the MCC/MNC is read and matches nothing.
- **Telling from `QMIDSIM`:** `carrier == nil` with `mccmnc` set means the SIM is on the
  fallback; `attachAPNFromNetwork` then says whether that was the network's default (empty
  fallback) or the configured fallback APN.

Suggested UI: when `carriers` is set, label the attach PDN's APN field "Fallback APN (SIMs
without a carrier entry)" and suggest leaving it empty. For a SIM on the fallback, offer "add
a carrier entry" with its `mccmnc` (and the network's `attachAPN`, when
`attachAPNFromNetwork`) rather than editing the fallback. Double-check MCC/MNC values against
the carrier: neighbours in the same country are easy to mix up (510-10 and 510-11 are
different operators).

qmid validates before writing and rejects bad configs with a message, e.g.
`config: x needs profile or apn`, `config: only one PDN can be the attach PDN`,
`config: internet bad policy fast`, `config: two PDNs pin the same profile`,
`config: carrier Example: mccmnc 0010 is not 5 or 6 digits`. At most 8 PDNs.

Changing the attach APN makes the modem re-attach to LTE: all PDNs drop for a few seconds.
qmid skips the re-attach when the default bearer already uses the new APN, and re-attaches at
most once a minute. A profile qmid uses that something else edits (an AT command) is put back;
if it keeps being changed (more than 3 times in 10 minutes), qmid stops rewriting it until
`reload` or the modem reopens.

## Reading state without XPC

qmid mirrors its state into SCDynamicStore, readable by any process (e.g. for a widget or a
quick check with `scutil`):

- `State:/Network/QMI/Modem` (keys `State`, `Network`, `VendorID`, `ProductID`, `Interface`,
  `LastError`, `SIM`: a dictionary with the `QMIDSIM` keys above, and `PLMN`: one with the
  `QMIDPLMN` keys)
- `State:/Network/QMI/PDN/<name>` (keys `ServiceID`, `InterfaceName`, `MuxID`, `State`,
  `Policy`, `Profile`, `APN`, `MTU`, `IPv4Address`, `IPv6Address`, `PCSCFv4`, `PCSCFv6`)

The key names are in `QMIDStoreKey`. XPC events are the preferred source; this is a fallback.

## Logs

qmid's log is available over the same connection, including the verbose QMI message trace.
Nothing is redacted: lines can contain addresses, APNs, profile credentials and SIM
identifiers, so treat them accordingly in your app.

```swift
qmid.onLog = { entry in
    // entry.time, entry.level (.debug/.info/.notice/.error), entry.category ("qmid", "trace"),
    // entry.message
}
qmid.subscribeLogs(level: .info)          // recent history first, then live
qmid.subscribeLogs(level: .debug)         // same call changes the level; debug adds the trace
qmid.unsubscribeLogs()
```

- qmid keeps about 2000 recent lines (plus 2000 trace lines) in memory and sends those first
  (`history: false` skips them). After a qmid restart the subscription is renewed and continues
  from the last line received.
- The trace is only produced while at least one client subscribes at `debug`; unsubscribe or
  lower the level when the view closes.
- If your app stops reading, qmid drops the oldest queued lines (cap 5000) and you get a
  `notice` entry from category `client` saying how many.
- Without XPC: `log stream --predicate 'subsystem == "com.qmi-darwin.qmid"' --level debug`
  (macOS itself keeps only notice and error lines).

## Versioning

`apiVersion` is `1`. It changes only on incompatible changes; new keys and event types are
added without a bump, so ignore unknown keys and `.unknown` events.

Added in qmid 0.6 (API still 1): `QMIDSIM` (`onSIM`, `status().sim`, event type `sim`,
`SIM` in the store's modem key) and the `carriers` config key.

Added in qmid 0.7 (API still 1): `QMIDPLMN` (`onPLMN`, `status().plmn`, event type `plmn`,
`PLMN` in the store's modem key).

Added in qmid 0.9 (API still 1): `reason` / `causes` in PDNs (`QMIDReason`, `QMIDCause`),
`QMIDError.pdn`, the `redial`, `maxUptime` and `apnType` config keys; `connect` completes when
the attempt has ended and dials run in parallel; `QMIDPLMN.emergencyBearers` and
`emergencyAccessBarred`.

## Testing from the command line

`qmictl` uses the same client:

```
qmictl status                       # includes the sim and operator lines
qmictl sync                         # APN sync, SIM match, default bearer APNs seen per MCC/MNC
qmictl events                       # live events
qmictl log [--level debug]          # qmid's log over XPC: recent lines, then live
qmictl connect ims | disconnect ims
qmictl policy internet prefer-cellular
qmictl config get > qmid.json && qmictl config set qmid.json
```
