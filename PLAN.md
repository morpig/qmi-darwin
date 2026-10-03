# qmi-darwin: a QMI connection manager for macOS

Plan, 2026-09-30. Status: M0–M5 done on the RM551E, qmid runs under launchd with XPC
control and APN sync; M6 (lifecycle) in progress. Protocol findings: `docs/QMI-bearers.md`.
Items still marked **(verify)** are
standard Qualcomm/macOS behaviour not yet confirmed on our hardware.

## Goal

Run the Quectel modem (RM551E-GL, RM520N-EU) in QMI mode (`AT+QCFG="usbnet",0`) and give the
Mac **almost the same thing `en19` gives it today**, without the modem's Linux (QCMAP) in the
data path:

- the internet PDN as a first-class macOS network service: default route, DNS, IPv4 + IPv6,
  and configd choosing between it and Wi-Fi exactly as it does for any other service;
- the IMS PDN as a second, never-primary service with scoped routes, replacing `vlan2`
  and IP passthrough (VLAN for IPv6, IPPT for IPv4);
- more PDNs later with no modem-side changes.

No NAT or MPDN rules on the modem, no kernel extension, no DriverKit entitlement.

What it fixes in the current ECM setup: IPPT_NAT, the `custom_bind_2` host route, `odhcpd`
stuck after re-enumeration, passthrough DNS routes, the `.255`/`.0` DHCP bug, USB
re-enumeration when IPPT starts/stops, and the ECM link recovery after sleep.

## en19 parity

What `en19` gives today and how `qmid` gives it:

| en19 today | qmid | Notes |
|---|---|---|
| Default route; failover with Wi-Fi by service order | Service published in `State:/Network/Service/<id>`, configd (IPMonitor) picks primary; `PrimaryRank` policy | §5. The core of this plan |
| DNS from the modem's DHCP (modem's proxy) | Carrier DNS from WDS runtime settings (PCO) in the service's `DNS` entity | Scoped resolver per service comes free from configd |
| IPv4: modem-NATed private address (or passthrough) | Carrier IPv4 on the utun directly | The Mac is directly on the carrier network, same as IPPT today; macOS firewall matters |
| IPv6 via RA/SLAAC from `odhcpd` | Prefix + IID from WDS, assigned by qmid | Optional RFC 4941-style temporary address (M10) |
| Link up/down from AppleUserECM | utun + service exist only while the PDN is up | |
| Scoped routes (`IP_BOUND_IF` works) | Scoped routes installed by IPMonitor for each published service **(verify)** | IMS depends on it |
| MTU 1500 | Per-PDN MTU from WDS | IMS PDNs often smaller |
| `netstat -I en19` counters | `netstat -I utunN` | Plus WDS packet statistics |
| Shown in System Settings › Network | **Not shown** (State:-only service has no Setup: entry) | Gap. Client apps can show it (§5.4, §8) |
| Usable as Internet Sharing source | **Not available** | Gap. Optional pf NAT in M10 |
| Interface type "Ethernet" to apps | Interface type "other" (utun) | Neither is "cellular". Some apps treat any utun as a VPN |
| Works with no software running | Only while `qmid` runs | launchd `KeepAlive`; crash cleanup is automatic (§5.5) |
| Kernel datapath | User-space datapath | Throughput gate after M4 |

## Non-goals (for now)

- Appearing in System Settings, or as a Network Extension VPN (see Alternatives).
- Anything on the AT port. qmid owns only the QMI interface; AT, IMS AKA, eSIM, SMS and band
  lock stay with whatever software uses the AT port.
- The IMS stack itself (registration, VoLTE, SMS, USSD, IPsec). qmid provides the IMS PDN:
  its interface, address and P-CSCFs; an IMS client does the rest.
- Host-requested QoS (QMI QoS requests, QMAP QoS header). Dedicated bearers are handled by
  the modem (§4.3).

## 1. Decisions

| Topic | Decision | Why |
|---|---|---|
| Language | Swift package; the hot datapath (bulk pipe I/O, QMAP (de)aggregation, utun I/O) as a small C target in the same package | C keeps ARC/`Data`/bounds and exclusivity checks out of the per-packet path. Per-packet cost is dominated by syscalls (one utun read/write per packet) and USB completions, not language; the M3/M4 throughput gate decides, and the fallback is a dext (§12), not a rewrite |
| Swift/C boundary | Swift opens the `IOUSBHostInterface` and hands the datapath target the two bulk `IOUSBHostPipe`s; the datapath (C with a thin Objective-C shim for IOUSBHost) owns bulk IN/OUT and the utun fds on its own serial dispatch queue | No Swift/C crossing per transfer or per packet. The datapath exposes only start/stop, per-mux attach/detach, flow control, counters, and a callback for QMAP command frames (rare). Per-packet code is plain C inside the completion blocks |
| USB | `IOUSBHost` framework (macOS 10.15+), `IOUSBHostInterface` on the QMI interface only | Apple's current user-space USB API. Opening an `IOUSBHostInterface` takes exclusive ownership of that interface only, so another process can keep the AT interface open at the same time. Adds: DMA-able unbounced buffers (`ioDataWithCapacity:`), completions on a caller-supplied dispatch queue, an `interestHandler` for termination, `setIdleTimeout:` for USB selective suspend. IOUSBLib isn't deprecated and stays the fallback |
| Process | Standalone root launchd daemon `qmid`, `KeepAlive` | It's in the data path of all traffic, so it must not exit when idle |
| Install | `SMAppService.daemon(plistName:)` (macOS 13+) from a small host app; plist in the app's `Contents/Library/LaunchDaemons/` (§8.2) | One admin approval in System Settings › Login Items at first install, then no password prompts ever: launchd starts qmid as root at boot, user-side tools never need root. Updates signed by the same Developer ID team don't re-prompt. Developer ID + notarization only, no special entitlement. `SMJobBless` is deprecated |
| System integration | SCDynamicStore service entries written as **temporary (session) values** | configd chooses the primary; a crash removes the service, routes and DNS by itself |
| Ownership | qmid is a standalone daemon (own package, own host app). Other apps are clients of its XPC API and status keys; qmid depends on none of them | One owner of the QMI interface, the utuns and the modem's data profiles |
| Default policy | internet `prefer-wifi`, ims `never` | Cellular is backup unless the user asks otherwise; switchable live (`qmictl policy`) |
| Control API | XPC Mach service `com.qmi-darwin.qmid`; peers checked with `NSXPCConnection.setCodeSigningRequirement(_:)` (macOS 13+) against our Team ID | Enforced by the system: only apps signed by our team (host app, qmictl, clients) can send commands. Reads (status) stay open via SCDynamicStore (§5.4) |
| Status for other apps | Read-only keys in SCDynamicStore (§5.4) | Any app can watch them with SCDynamicStore notifications; no XPC needed for reads |
| PDN selection | By role (`internet`, `ims`) resolved against the modem's profile list, or an explicit cid/APN | MBN auto-select can rewrite profiles on SIM change; fixed cids break after eSIM switches |
| Tests | QMUX/TLV/QMAP codecs pure and unit-tested against byte captures | |

## 2. Architecture

```
Modem (usbnet=0)
 ├─ if 0  DM          (not used by qmid)
 ├─ if 2  AT          (not used by qmid)
 └─ if N  QMI  ff/ff/ff  (N confirmed in M0; usually 4)
      control EP  ◄── SEND_ENCAPSULATED_COMMAND / GET_ENCAPSULATED_RESPONSE
      interrupt EP ── RESPONSE_AVAILABLE
      bulk IN/OUT  ── QMAP frames (mux 0x81 internet, 0x82 IMS, …)

qmid (root, launchd)
 ├─ USBTransport   find modem, open IOUSBHostInterface N, control requests + interrupt pipe;
 │                 hands bulk IOUSBHostPipes to Datapath; interestHandler → removal
 ├─ QMUX           framing, TLVs, transaction IDs, client IDs, indication dispatch
 ├─ Services       CTL · WDA · WDS · NAS · DMS · UIM (only messages we use)
 ├─ Datapath (C/ObjC)  own serial queue: async bulk IN pool → QMAP demux → utun per mux;
 │                 kqueue on utun fds → QMAP → bulk OUT; flow control; counters;
 │                 QMAP command frames up to Swift via callback
 ├─ NetConfig      utun create, addresses (ioctl), IPv6 address/prefix
 ├─ ServicePublisher  State:/Network/Service/<id>/{IPv4,IPv6,DNS,…} per PDN
 ├─ Session        per-PDN state machine, backoff, runtime-settings changes
 ├─ Lifecycle      hotplug, sleep/wake, SIM refresh
 └─ ControlXPC     connect/disconnect/status/config reload; qmictl CLI on top
```

Package layout:

```
Package.swift
Sources/QMIKit/          codecs and message definitions (testable, no root)
Sources/QMIHost/         transport, service clients, PDN sessions, utun, ServicePublisher,
                         Manager (state machine), config, XPC protocol; shared by qmid and qmictl
Sources/QMIDatapath/     C + thin ObjC shim: IOUSBHost bulk I/O + QMAP + utun hot loop (small public header for Swift)
Sources/qmid/            daemon: USB, NetConfig, ServicePublisher, XPC
Sources/qmictl/          CLI: status, connect, disconnect, policy, reload (via qmid);
                         probe, modem-status, run (direct to the modem, for development)
scripts/dev-daemon.sh    load/unload the debug qmid under launchd (system domain, until reboot)
Tests/QMIKitTests/       fixtures from byte captures
Sources/QMIDarwinApp/    minimal host app: registers/unregisters qmid via SMAppService, shows approval state
launchd/com.qmi-darwin.qmid.plist   (BundleProgram → Contents/MacOS/qmid, MachServices, KeepAlive)
```

## 3. Modem side

### 3.1 Switching modes

- To QMI: prerequisites (3.2), then `AT+QCFG="usbnet",0`, `AT+CFUN=1,1`.
- Back to ECM: `AT+QCFG="usbnet",1`, `AT+CFUN=1,1`. qmictl gets a `mode ecm|qmi` command
  that does both over the AT port (when nothing else holds it).

### 3.2 Prerequisites before QMI **(verify exact commands on RM551E firmware)**

1. **No PDN held by the modem's own Linux.** Clear MPDN rules and QCMAP autoconnect, so
   `rmnet_data0/1` inside the modem don't keep the internet and IMS profiles up. Otherwise
   the PDN is shared between the embedded call and ours and downlink steering is undefined.
   Check with `adb shell ip -br addr` after the switch: no carrier addresses on `rmnet_data*`.
2. **Modem's built-in IMS stack off** (`AT+QCFG="ims"`).
   With it on, the modem brings up and uses the IMS PDN itself.
3. **`data_interface` is USB**, not PCIe (`AT+QCFG="data_interface"`).
4. Note the USB PID and interface layout in QMI mode. In ECM mode AppleUserECM owns
   interfaces 10/11; in QMI mode nothing should claim the ff/ff/ff interface.

### 3.3 Carrier notes to test against

Known so far: some networks reject extra PDNs on the same APN with #55; some use IPsec for
IMS. All are in the carrier matrix (§10).

## 4. QMI

### 4.1 Control plane

- CDC: `SEND_ENCAPSULATED_COMMAND` (0x21/0x00), interrupt `RESPONSE_AVAILABLE`,
  `GET_ENCAPSULATED_RESPONSE` (0xA1/0x01). Drain until empty on each notification.
- QMUX: `0x01, len, flags, service, client`; service header with 2-byte transaction IDs,
  CTL with 1-byte. One outstanding-request table per client; timeouts per message.
- CTL: Sync (0x0027) at start and after wake, Get Version Info (0x0021), Get/Release Client
  ID (0x0022/0x0023). Record service versions and refuse to start on unknown majors.
- Clean shutdown: Stop Network Interface on each call, release all client IDs.
- Found in M1 on the RM551E:
  - The modem only notifies after `SET_CONTROL_LINE_STATE` with DTR (0x21/0x22, wValue 1),
    as recent Qualcomm firmware generally requires.
  - The interrupt endpoint's wMaxPacketSize is 8, the size of a RESPONSE_AVAILABLE
    notification; the read must be exactly wMaxPacketSize or it waits for a short packet forever.
  - Responses to a previous (killed) process's requests stay queued in the modem and can
    carry the same tx/message IDs, so on open qmid drains `GET_ENCAPSULATED_RESPONSE` until empty
    before sending anything. `GET` on an empty queue fails (stall); that's the end marker.

### 4.2 Bringing up PDNs

1. **WDA Set Data Format** (0x0020), once, before any call:
   - link-layer protocol: raw IP;
   - UL and DL aggregation protocol: QMAP (5), not QMAPv5 (no checksum offload header);
   - QoS format: off;
   - endpoint info TLV (HSUSB, interface N) where firmware requires it **(verify)**;
   - DL max datagrams / max size requested, then use **what the reply grants**.
2. **Per PDN, per IP family, one WDS client:**
   1. Bind Mux Data Port (0x00A2): endpoint HSUSB, interface N, mux ID (0x81, 0x82, …).
   2. Set Client IP Family (0x004D): 4 or 6.
   3. Start Network Interface (0x0020) with the profile index (0x31) or APN (0x14).
      `NO_EFFECT` / call-already-present = success (internet is usually the attach PDN and
      already up); take the packet data handle.
   4. Get Runtime Settings (0x002D) with mask: IP, gateway, DNS, MTU, IPv6 prefix,
      **P-CSCF v4/v6 list**.
   5. Register for packet service status (0x0022) and runtime-settings-change indications.
3. IPv4 and IPv6 of the same PDN are two clients **bound to the same mux ID**: one utun per
   PDN, families told apart by the IP version nibble.
4. Profiles (APN sync, implemented): qmid.json is the source of truth. Each PDN is resolved to
   a modem profile (pinned index, attach profile, saved index, APN match, or created), which
   is rewritten to match the config; PDNs always start by profile index so they are visible
   over AT. Role ims sets pcscf-pco + imcn + APN type ims (P-CSCF needs pcscf-pco). The attach
   profile follows the internet APN (re-attach on change). Checked every 30 s, since this
   firmware sends no Profile Changed indication for AT edits.

### 4.3 Dedicated bearers and QCI

Nothing on the host. A dedicated bearer (the QCI 1 voice bearer) lives inside its PDN and
shares its address. The modem maps uplink packets from a mux to bearers by the network's UL
TFTs and delivers all downlink of the PDN on its mux. Without NAT in the path, the 5-tuple
the host sends is what the TFT sees, so IPv4 IMS voice lands on QCI 1 reliably.

Bearer visibility stays outside qmid (AT `+CGEQOSRDP`/`+CGTFTRDP`/`+CGEV`, DM
observation-only). QMI QoS-service indications are a possible later push source, not needed.

### 4.4 Status (minimal)

NAS serving system (0x0024) and its indication, to gate dialing on registration and to
explain failures. DMS/UIM only for `qmictl status`. Signal, cells and bands are out of scope.

## 5. System integration (SCDynamicStore)

This is what makes it behave like `en19` instead of a hand-routed tunnel.

### 5.1 Per-PDN service

Each connected PDN gets a stable service ID (UUID generated once per PDN name, stored in
config) and these keys, all as **temporary values** of qmid's SCDynamicStore session:

```
State:/Network/Service/<uuid>/IPv4
    Addresses      = [ <carrier v4> ]
    DestAddresses  = [ <carrier v4 or WDS gateway> ]     # utun is point-to-point
    Router         = <WDS gateway, else own address>
    InterfaceName  = utunN
State:/Network/Service/<uuid>/IPv6
    Addresses      = [ <prefix>::<iid> ]
    PrefixLength   = [ 64 ]
    Router         = <WDS v6 gateway>
    InterfaceName  = utunN
State:/Network/Service/<uuid>/DNS
    ServerAddresses = [ v4 and v6 DNS from WDS ]
    InterfaceName   = utunN
State:/Network/Service/<uuid>            # service entity
    PrimaryRank    = First | (absent) | Last | Never     # see 5.2
    UserDefinedName = "Cellular (internet)"
```

IPMonitor then does what it does for Wi-Fi and Ethernet: primary selection, the default
route(s), scoped default routes per service, and scoped plus (if primary) global DNS.
qmid does **not** add routes or touch `/etc/resolv.conf` itself.

All entities of a service are written in one `SCDynamicStoreSetMultiple` call (set and
remove together), so IPMonitor never sees a half-published service such as IPv4 without DNS.
Notifications (for our own keys and the Setup: service order) come in on a dispatch queue via
`SCDynamicStoreSetDispatchQueue`.

`PrimaryRank` is **not** in the public SDK (`SCSchemaDefinitions.h` has only
`OverridePrimary`); it's configd's private key, so use the literal string and treat its
behaviour as something M5 has to confirm, not an API contract.

**(verify in M5)** against configd's open-source IPMonitor for this macOS version and by
experiment:
- where IPMonitor reads `PrimaryRank` for a State:-only service (service entity vs. the
  IPv4/IPv6 dicts);
- that `Router` on a point-to-point utun yields a default route via the interface;
- that a service not in `Setup:/Network/Global/IPv4` `ServiceOrder` ranks after ordered
  ones (so Wi-Fi wins by default);
- that `Never` still gets scoped routes and a scoped resolver;
- whether IPMonitor wants `State:/Network/Interface/utunN/Link` (owned by the kernel event
  monitor; we don't write it) or treats utun as active.

Check each with `scutil --nwi`, `scutil --dns`, `netstat -rn`, `route -n get default`,
`route -n get -ifscope utunN default`.

Answered in M5 (configd `Plugins/IPMonitor/ip_plugin.c` + tests on macOS 27.0):
- `PrimaryRank` is read from the service entity `State:/Network/Service/<id>`; a Setup: rank,
  if any, is combined and the stronger assertion wins.
- A service not in `ServiceOrder` gets the maximum index, so it ranks after Wi-Fi: with no
  `PrimaryRank`, en0 stayed primary and utun9 was listed second in `scutil --nwi`.
- IPv4 needs `Router` (or `DestAddresses`); without one IPMonitor demotes the service to Last.
  With the WDS gateway as Router on the point-to-point utun, IPMonitor installs
  `default 10.x.x.x UGScIg utun9` (scoped) and, when primary, the global default.
- `Never` still gets a scoped default route and a scoped resolver (IMS on utun10).
- The interface `Link` entity is only read for the expensive flag; utun needs none.
- `ServiceIndex` in the service entity places an unordered service after the ordered ones
  (not used yet).

### 5.2 Primary policy (config per PDN)

| Policy | Meaning | How |
|---|---|---|
| `prefer-wifi` (default for internet) | Cellular is primary only when no ordered service (Wi-Fi, Ethernet) has a route | No `PrimaryRank`; unordered services rank last |
| `prefer-cellular` | Cellular primary whenever up | `PrimaryRank = First` |
| `last-resort` | Explicitly behind everything | `PrimaryRank = Last` |
| `never` (default for IMS) | Scoped only | `PrimaryRank = Never` |

Switching policy at runtime re-publishes the service entity; no reconnect.

### 5.3 IMS PDN

Published with `Never`, so it never takes the default route or global DNS. An IMS client pins its
sockets to the utun with `IP_BOUND_IF` / `IPV6_BOUND_IF`, relying on the scoped routes IPMonitor
installs (5.1). IPsec SAs set up by an IMS client are address-based and should need no change
**(verify on a network that uses IPsec for IMS)**.

### 5.4 Status keys for other apps

```
State:/Network/QMI/Modem          mode, USB ids, firmware, QMI service versions, qmid state
State:/Network/QMI/PDN/<name>     service uuid, utunN, mux id, profile/cid, APN, IP family,
                                  state, end reason, MTU, P-CSCF v4/v6 list, bearer tech
```

Clients watch `State:/Network/QMI/.*` with SCDynamicStore notifications.

### 5.5 Cleanup

- Graceful: remove keys, Stop Network Interface, release clients, close utun.
- Crash: the SCDynamicStore session dies → configd drops the temporary keys → IPMonitor
  removes routes and DNS; the utun fd closes → the kernel removes the interface. The modem
  keeps the call; the next start adopts it (`NO_EFFECT`) or restarts it.
- Temporary keys: `SCDynamicStoreAddTemporaryValue` only adds a key that doesn't exist yet;
  later updates with `SetValue` from the same session keep it temporary (verified in M5: added,
  updated, process exited without cleanup → key gone). kill -9 of qmictl removed services,
  status keys, utuns, scoped routes and resolvers; the default went back to en0.

### 5.6 Addresses on the utun

- IPv4: `SIOCAIFADDR` with the carrier address and destination.
- IPv6: `SIOCAIFADDR_IN6` with `<prefix>::<iid>` / 64 plus a link-local address; the IID
  from WDS (the network owns the /64, any IID works per RFC 7278).
- MTU from WDS (`SIOCSIFMTU`).
- Optional (M10): mark the interface expensive so NWPath reports `isExpensive`. en19 doesn't
  do this today, so it's an improvement, not parity. **Private API only:** `SIOCSIFEXPENSIVE`
  isn't in the public `sys/sockio.h`, and the functional type (`IFRTYPE_FUNCTIONAL_CELLULAR`)
  has only a getter (`SIOCGIFFUNCTIONALTYPE`), so apps will always see the utun as "other",
  never "cellular". `UTUN_OPT_SET_DELEGATE_INTERFACE` inherits traits from a real interface,
  but there's no real cellular interface to delegate to.

## 6. Datapath

- Downlink: a pool of async bulk IN reads (start with 16 × granted DL size) into buffers from
  `IOUSBHostInterface ioDataWithCapacity:` (DMA-able, not bounced), each buffer split into
  QMAP frames: 4-byte header (C/D bit, pad length, mux ID, big-endian length), pad stripped,
  payload written to that mux's utun with the 4-byte AF header straight from the USB buffer
  (`writev`, no copy); the buffer is re-queued after the last write.
- utun created with `UTUN_OPT_MAX_PENDING_PACKETS` raised (public `net/if_utun.h`) so uplink
  bursts queue in the kernel instead of dropping while a bulk OUT is in flight.
- Uplink: one kqueue over all utun fds; packets framed with a QMAP header (pad to 4 bytes),
  aggregated up to the granted UL size where the modem accepts UL aggregation, sent as bulk
  OUT; zero-length packet when a transfer is a multiple of the max packet size.
- QMAP command frames (C/D = 1) are never forwarded to a utun. Flow disable/enable
  (mux ID + bearer ID) pauses/resumes that mux's uplink; ACK when the command asks for it.
  Unknown commands logged and dropped.
- Unknown mux IDs counted and dropped.
- Counters per mux (packets, bytes, drops, flow-control time) in `qmictl status`.
- USB selective suspend: `setIdleTimeout:` on the interface set explicitly (off while any
  PDN is connected) rather than left to the default, to stay out of the ECM half-suspend class.
- Escalation if throughput isn't enough, in order:
  1. **Batched utun I/O** with `recvmsg_x`/`sendmsg_x` (syscalls 480/481 in the SDK's
     `sys/syscall.h`, no public prototype, so private): up to ~128 packets per call on the
     utun control socket, removing the one-syscall-per-packet cost. Resolved at runtime,
     fallback to `readv`/`writev`. Tailscale measured receiver CPU more than halved with it.
     Try this in M4 if the gate is close, not only in M8.
  2. More bulk reads in flight; larger granted DL aggregation.
  3. Per-direction queues/threads.
  4. utun's channel/netif options (`UTUN_OPT_ENABLE_CHANNEL`, `UTUN_OPT_ENABLE_NETIF`, ring
     sizes; headers are public but they need the private `os_channel` API). Last resort.

## 7. Session and lifecycle (M6)

Device: `absent → opening → ready → (unplugged / reset) → absent …`
Per PDN: `idle → waiting (for SIM/registration) → dialing → connected → backoff → dialing …`,
plus `blocked` (permanent cause, until config or SIM changes) and `idle` when disconnected by
request. Each state and its reason are in `qmictl status` and `State:/Network/QMI/PDN/<name>`.

One-shot PDNs (`redial: false`, 0.9): `idle → dialing → connected → idle`, dialled only by
`connect`; a failed dial or any drop leaves them idle and not wanted (no backoff, no
`blocked`), and `maxUptime` hangs them up. Dials run off the manager queue, one per PDN in
parallel, and `connect` answers when the attempt has ended.

Already in place (M5/M7 part 1): redial with 2 s → 5 min backoff on a dropped call; device
termination → teardown and reopen; stale-indication filtering after reload; APN sync at start,
reload and every 30 s.

| Case | qmid behaviour | Test (who) | Done when |
|---|---|---|---|
| Call dropped by the network | Classify the WDS end reason: **permanent** 3GPP causes (8 operator barred, 27 unknown APN, 29 auth failed, 32/33 not supported/subscribed, 50/51/52 PDN type not allowed for that family) → `blocked` for that family, no retries until config reload or SIM change; network back-off (T3396 / cause 26 with timer) honoured; everything else → backoff | `AT+CGACT=0,<cid>` via adb (me); IPv4 on an IPv6-only IMS APN gives cause 51 | IMS with `family: ipv4v6` comes up IPv6-only and never retries IPv4; a forced drop redials once |
| Registration gate | NAS serving-system indication: don't dial while not registered / PS-detached; dial when attached (no blind retries) | via airplane mode (me) | `waiting` shown while detached; no WDS starts while detached |
| Airplane mode (`CFUN=4` → `1`) | Calls end → `waiting`; redial on PS attach | adb (me) | both PDNs back within ~5 s of attach, no manual step |
| Modem reset (`CFUN=1,1`) | Termination → teardown; **IOKit arrival notification** reopens (replaces 2 s polling); stale control messages drained; APN sync; redial | adb (me) | back without help after re-enumeration (~35 s) |
| USB replug | Same path as reset | physical (user) | same |
| Sleep / wake × 10 | Sleep (IOPMrootDomain notification): stop bulk IN reads, keep calls; wake: if the same device, CTL Sync-free check (Get Packet Service Status per call), re-read runtime settings, resume reads; if anything is off or the device re-enumerated → full restart. Covers the half-failed USB suspend seen with ECM | user sleeps the Mac; I watch the log | 10 cycles, traffic within ~5 s of wake each time |
| Runtime settings change | Packet-service indication with "reconfiguration required" or changed runtime settings → update utun addresses and the service in place, republish P-CSCF | only if the network does it | addresses on utun match WDS after the change |
| SIM pull / insert | UIM card-status indication: SIM gone → teardown, `waiting`; SIM ready + registered → APN sync (new SIM may bring new carrier profiles), redial | physical (user) | back without help after reinsert |
| eSIM switch (refreshFlag 1) | Same as SIM change; APN sync rewrites profiles the new carrier config changed | user, or me with an OK | done: A → B → A, PDNs back ~4 s after each switch; per-family blocks cleared on re-registration |
| Profile edits outside qmid | APN sync restores the config (source of truth), reconnects affected PDNs (done) | AT+CGDCONT (me) | done: restored within ~20 s |

Rules: never hammer the carrier (backoff cap, permanent-cause block, network timers); every
teardown removes utun, service and status keys the same way as a crash would.

## 8. Control API

### 8.1 qmid control (XPC) and qmictl

qmid is standalone: its XPC API and status keys are the only way other software (qmictl,
client apps) reaches the modem's data side.

XPC (`com.qmi-darwin.qmid`), implemented: `status`, `connect <pdn>`, `disconnect <pdn>`,
`setPolicy <pdn> <policy>`, `reload`, `profiles` (APN sync report).
Also implemented: event subscription (PDN up/down, address/P-CSCF changes) and config
read/write (APN edits go to qmid's config, the source of truth, instead of CGDCONT); client
guide in `docs/API.md`. Planned: `mode ecm|qmi`. `raw <service> <msg> <tlvs>` for debugging.

qmictl: `status | connect | disconnect | policy | reload | sync` through qmid;
`probe | modem-status | profiles | profile-write | run` directly on the modem (qmid stopped).

Config `/Library/Application Support/qmi-darwin/qmid.json` (details in `Sources/QMIHost/Config.swift`):

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

Optional per PDN: `username`, `password`, `auth` (none | pap | chap | pap-chap), `attach`,
`apnType`, `redial`, `maxUptime`.
`state.json` next to it holds the PDN → profile index mapping qmid resolved.

### 8.1a Logs

qmid logs to the unified log (subsystem `com.qmi-darwin.qmid`), no log file, so macOS caps and
ages it out. Levels: `error` and `notice` (connects, drops, retries, network and config
changes) are kept on disk by macOS; `info` (routine lines) is live/in-memory only; `debug` is
the QMI message trace, formatted only while someone collects it. Nothing is redacted,
anywhere: messages and trace are logged public, and go to XPC clients as is (the trace can
carry profile credentials and SIM identifiers; access is limited to team-signed callers).

Over XPC (implemented): `subscribeLogs(level, since)` / `unsubscribeLogs`; lines arrive as
`log` events (batches of `time`, `level`, `category`, `message`) only on connections that
asked, so the change is additive and `qmidAPIVersion` stays 1.

- History: in-memory rings (2000 lines of info and above, 2000 of trace) sent first, newer
  than `since`, so a log view opened later sees the recent past, including the info lines
  macOS doesn't keep. After a qmid restart the client continues from its last line.
- A `debug` subscriber turns the trace on; it turns off when the last one goes (verified).
- Backpressure: one batch (≤ 500 lines) in flight per client; the queue is capped at 5000
  lines, then the oldest are dropped and reported as `dropped` (not yet exercised live).
- `qmictl log [--level L] [--no-history]` uses it and falls back to `log stream` when qmid
  can't be reached.

### 8.2 Install and privileges

No password prompt on launch: qmid is the only root component and launchd starts it; everything
the user launches (host app, qmictl, client apps) runs as the user and talks to qmid over XPC.

```
QMI Darwin.app/Contents/
  MacOS/QMI Darwin          host app (user)
  MacOS/qmid                daemon (root, launched by launchd)
  MacOS/qmictl              CLI (user); symlinked to /usr/local/bin on request
  Library/LaunchDaemons/com.qmi-darwin.qmid.plist
```

- First run: host app calls `SMAppService.daemon(plistName: "com.qmi-darwin.qmid.plist").register()`.
  Status `.requiresApproval` → `SMAppService.openSystemSettingsLoginItems()` and explain the
  one-time approval. `.enabled` → done; qmid starts now and at every boot.
- Uninstall: `unregister()`, which stops qmid; its temporary SCDynamicStore keys and utuns go
  with it (§5.5). Config in `/Library/Application Support/qmi-darwin/` is left in place.
- Updates: replace the app bundle; launchd picks up the new `qmid` on next start. The host app
  compares the running qmid's build (`version` in status) with its own and calls `restart`
  (clean exit; launchd relaunches) when they differ. Tested: no new approval, ~2.5 s.
- Signing: Developer ID Application for all three binaries, hardened runtime, notarized app.
  The daemon plist's `BundleProgram` is relative to the app bundle, so the app must stay in
  `/Applications` (moving it breaks the daemon; the host app checks and warns).
- XPC: qmid sets a code-signing requirement on each incoming connection
  (`anchor apple generic and certificate leaf[subject.OU] = "<TEAMID>"` plus the bundle IDs of
  the host app, qmictl and client apps), so no other local process can connect/disconnect PDNs.

## 9. Milestones

| # | Milestone | Est. | Status | Done when |
|---|---|---|---|---|
| M0 | Modem prep and inspection | 0.5–1 d | **done** (RM551E; RM520N not yet) | §3.2 prerequisites done and written down; QMI interface number, endpoints, PID documented for RM551E and RM520N; no driver on the interface; rollback to ECM tested |
| M1 | USB transport, QMUX, CTL | 2 d | **done** (fixtures hand-built) | `qmictl probe` lists services and versions; get/release a WDS client cleanly; codec unit tests pass; `IOUSBHostInterface` open on the QMI interface coexists with another process holding the AT interface open (both working at once, either started first) |
| M2 | Minimal status | 1 d | **done** | `qmictl status`: SIM ready, registration, RAT |
| M3 | One IPv4 PDN, raw IP, utun, addresses set by hand | 2–3 d | **done** (throughput deferred) | utun address equals the modem's PDP address (public IP is carrier NAT); ICMP + HTTPS over the utun. Quick iperf3 vs ECM |
| M4 | QMAP, multiple PDNs, dual-stack | 3–4 d | **done** except flow control under load and the throughput gate (deferred) | internet + IMS up at once on two utuns, carrier addresses; QMAP flow-control frames handled. **Throughput go/no-go:** within ~20% of ECM on the same cell, acceptable CPU (with batched utun I/O, §6, if the plain path is close) |
| M5 | SCDynamicStore services | 3–4 d | **done** | all §5.1 verify items answered; with Wi-Fi on/off/on the primary follows the policy; `scutil --nwi`/`--dns` correct; IMS never primary but reachable with `IP_BOUND_IF`; kill -9 qmid removes routes and DNS |
| M5b | APN sync (added) | — | **done** | config is the source of truth for modem profiles; PDNs start by profile; IMS profile gets P-CSCF flags; external edits restored |
| M6 | Lifecycle | 3 d | **in progress** | every case in §7: dropped call, permanent causes, airplane mode, modem reset, USB replug, 10 sleep/wake cycles, SIM pull, eSIM switch — recovered without help |
| M7 | XPC control, qmictl, SMAppService packaging | 2–3 d | part 1 **done** (launchd dev load, XPC, live policy, reload, clean shutdown); part 2 **done** (QMIDAPI library, events, config get/set); part 3 **done** (app bundle registered via SMAppService with one Login Items approval; unsigned XPC callers refused with a clear error and logged; clients reconnect across a qmid restart, one snapshot each; app update in place keeps the approval and the app restarts the outdated qmid); open: reboot, notarization (needs a Developer ID certificate) | host app registers qmid via `SMAppService` with one Login Items approval and no password prompt afterwards (including across reboot and an app update); XPC rejects an unsigned client; notarized build |
| M8 | Throughput tuning | 2–3 d | **done** for now: 480 / 94 Mbps on 5G NSA with 0 drops, ~0.4 core; network-limited. Batched utun I/O only if aiming near 1 Gbps | numbers documented (DL/UL, CPU) vs ECM; QMAP flow control seen under load |
| M9 | IMS PDN for clients | — | **done** | the IMS APN is up on its own utun (`never`, no default route) with address and P-CSCFs in status, events and the SCDynamicStore keys. IMS itself (registration, VoLTE, SMS, USSD, IPsec) is the client app's job and out of scope for qmid |
| M10 | Optional | — | — | expensive flag (private ioctl), IPv6 temporary addresses, pf NAT sharing. QMI QoS **done** (0.8): per-PDN QCI and APN-AMBR, dedicated bearers with their TFTs as `bearers` events and in status (docs/API.md, docs/QMI-bearers.md). The 2026-09-30 attempt only listened for indications and saw none during a VoLTE call |

First estimate was 4.5–6 weeks to M9 (21.5–29 working days); M0–M5 took one day of
work. The throughput gate is deferred by decision, not passed.

## 10. Testing

- Unit: QMUX/TLV/QMAP encode/decode against byte captures; QMAP deaggregation
  with padding, command frames, truncated buffers; session state machine with a fake transport.
- Cross-check: same modem on another host OS for message sequences and expected replies
  (Bind Mux Data Port TLVs, data format grants).
- On the Mac: `scutil --nwi`, `scutil --dns`, `netstat -rn`, `route -n get`, test-ipv6,
  iperf3 against a public server, `netstat -I`.
- Carrier matrix: every available network × {internet v4v6, IMS v4, IMS v6,
  IMS IPsec, VoLTE call with QCI 1 bearer, SMS, USSD}.
- Logging: every QMI message decoded at debug level; per-mux counters.

## 11. Risks

| Risk | Mitigation |
|---|---|
| User-space throughput well below ECM at 5G speeds | Measure at M3, gate at M4, tune in M8; escalation list in §6 |
| IPMonitor treats State:-only services differently than assumed (PrimaryRank location, utun routes, Link); `PrimaryRank` is a private key and can change between macOS releases | M5 starts by reading configd's IPMonitor source for this macOS and testing each item; fallback: qmid installs scoped routes itself and uses `OverridePrimary` for `prefer-cellular` |
| Modem's own Linux or IMS stack still holds a PDN in QMI mode | §3.2 prerequisites; detect `NO_EFFECT` with a mismatched address and report it |
| QMI firmware differences (RM551E vs RM520N, Bind Mux TLVs, QMAP vs QMAPv5) | Small message set, version check in M1, cross-check on another host OS |
| Sleep/wake USB problems (the ECM half-suspend class) | M6 test loop; full restart path on any inconsistency |
| No internet when qmid isn't running | launchd `KeepAlive`; `qmictl mode ecm` as the escape hatch |
| Apps treating utun as VPN | Documented; not fixable with this approach (see Alternatives) |
| Private APIs (`recvmsg_x`/`sendmsg_x`, `SIOCSIFEXPENSIVE`, `PrimaryRank`) change or disappear | Each resolved or feature-checked at runtime with a public fallback; none is needed for basic operation |
| Carrier punishes rapid redial | Backoff with permanent-cause stop (§7) |

## 12. Alternatives considered

- **NetworkExtension packet tunnel:** real system service, shown in System Settings, but as a
  VPN: one at a time, conflicts with real VPNs, VPN icon, needs NE entitlement. Rejected.
- **DriverKit dext (USBDriverKit + NetworkingDriverKit)** presenting an Ethernet interface
  (`enX`) per PDN, optionally with WDA 802.3 link mode: true en19 parity including System
  Settings and Internet Sharing, kernel-grade datapath. Needs Apple-granted DriverKit
  entitlements (`com.apple.developer.driverkit.transport.usb`,
  `com.apple.developer.driverkit.family.networking`), or SIP off for development. The strongest
  option if the M4 throughput gate fails or System Settings visibility turns out to matter;
  much of QMIKit would carry over. Limit: NetworkingDriverKit supports **Ethernet only**, so
  it shows as Ethernet (en19 parity), never as a cellular interface.
- **Stay on ECM:** zero software for internet, kernel speed; IMS keeps the IPPT/VLAN issues
  that need workarounds.

## 13. Open questions

Decided 2026-09-30:
- Default internet policy: `prefer-wifi`.
- qmid ships on its own (own host app) and offers an XPC API for client apps.
- qmid's config is the source of truth for the modem's data profiles; missing profiles are
  created automatically.

Open:
1. RM520N-EU: when?
2. Is M10 sharing (pf NAT) wanted at all?
3. Non-data profiles (not in qmid's config): leave them to AT, or manage them through the API?
