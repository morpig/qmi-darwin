# GNSS over QMI (LOC)

What the modem's location service (QMI LOC, service 0x10) does, and how qmid uses it: XTRA
assistance data, and location sessions for client apps (docs/API.md, "GNSS assistance
(XTRA)" and "Location").

Message and TLV numbers follow Qualcomm's QMI IDL (`location_service_v02`). Where libqmi
differs, the IDL is what the modem sends. Everything below was checked on an RM551E-GL
(LOC 2.175), with the direct-mode probes `qmictl loc-survey`, `loc-inject` and `loc-fix`
(qmid stopped). The RM520N-EU (LOC 2.155, firmware RM520NEUDAR03A09M4G) is checked for XTRA only;
its differences are noted below.

## Replies come as indications

A LOC request's response only says the request was accepted. The answer comes about 30 ms
later as an **indication with the same message ID** on the same client. TLV 0x01 of that
indication is a status: 0 success, 1 general failure, 2 unsupported, 3 invalid parameter,
4 engine busy, 5 phone offline, 6 timeout. `QMIClient.requestIndication` waits for it. The
waiter is set before the request is sent, because the indication can arrive right behind the
response.

- Reply indications come **without Register Events**. A short-lived client per call is
  enough for XTRA.
- What the modem sends on its own, such as positions (0x24), satellites (0x25), engine state
  (0x2B) or a request for XTRA (0x29), needs Register Events 0x0021. A session that ran 25 s
  without it delivered none.
- On the RM551E, Register Events is refused (InvalidArgument) unless it carries **TLV 0x11
  client type = 1**. Types 2 and 3 are refused too. Each call replaces the client's mask.
- Get Supported Messages (0x001E) lists every ID from 0x1E to 0xAA, yet Get NMEA Types 0x003F
  answers NotSupported, so the list can't be trusted.

## XTRA

| Message | Use | On the RM551E |
|---|---|---|
| 0x0036 Get Predicted Orbits Data Source | servers, size limits | TLV 0x11: three Qualcomm URLs (u8 count, then u8 length + URL each). **No sizes TLV 0x10.** **The RM520N accepts it and never sends the indication**, with or without a session, though Get Supported Messages lists it. qmid waits 2 s once per modem open, then uses its config or built-in server list. Only one chip and firmware of each tried, so the cause isn't known. |
| 0x0037 Get Predicted Orbits Data Validity | what the modem holds | TLV 0x10: start u64 in **Unix seconds** + u16 hours (168). Matches `AT+QGPSXTRADATA` (minutes, UTC) exactly. Without data: the RM520N answers 1980-01-06, 0 hours. |
| 0x00A7 Inject XTRA Data | load | 1024-byte parts, each acknowledged (TLV 0x10: the part number) |
| 0x0035 Inject Predicted Orbits Data | load, older firmware | **NotSupported** at the response. qmid falls back to it only when 0x00A7 is NotSupported. |

**Loading** (`GNSSAssist.load`):

- Parts: 0x01 total size u32, 0x02 total parts u16, 0x03 part number u16 (from 1), 0x04 the
  data (u16 length, then up to 1024 bytes). 0x0035 also takes 0x10 format u32 = 0 (XTRA).
- One part at a time, each after the previous one's ack. A part takes about 30 ms. The last
  takes about 500 ms while the modem checks the file, and its ack carries an extra TLV 0x11,
  u64 0x1F (0x1B on the RM520N), apparently the constellations used. A 61 KB file (60 parts) loads in
  about 2.4 s, and the validity then moves to the new file's window.
- **A bad file gets no ack at all.** For a 100-byte random file the response is OK, then
  silence (60 s waited), and the data the modem held stays. With no answer to the last part,
  qmid reports that the modem didn't take the file.
- **An abandoned transfer leaves the state stuck.** After 20 of 60 parts, Get Validity fails
  with MalformedMessage at the response, for every client and even after ours is released, and
  `AT+QGPSXTRADATA?` answers ERROR. A complete load from part 1, or a modem reset, clears it.
  The data held before survives. So when a part fails before the last, qmid loads the whole
  file once more from part 1 and never leaves a transfer half done.
- Neither a running GNSS session (`AT+QGPS=1`) nor airplane mode (`AT+CFUN=4`) stops a load:
  no "engine busy", no "phone offline". qmid still retries a part up to 3 times on engine busy.
- The data survives `AT+CFUN=1,1`.
- `AT+QGPSXTRA: 1` (XTRA on), but the modem has not been seen fetching a file by itself: the
  data it held had been loaded from outside. With qmid owning the data connections it may have
  no way to; not checked. qmid therefore keeps it fresh itself (XTRAUpdater: download from the
  servers above, load once the data is older than 24 h; only a file whose Last-Modified is
  after the data's start, so older data never replaces newer).

## Sessions, positions and satellites

`GNSSSession`: one LOC client while some client app wants location; Register Events
(position, engine state, plus satellites / NMEA when asked), then Start with the shortest
interval asked for. An interval change is Stop + Start. When no client wants it: Stop, and the
client is released. After a modem reset or reopen a new session starts; after wake it
registers and starts again. As observed:

- A 4 s Mac sleep: the modem's GNSS kept running (every UTC second of fixes present; delivery
  paused ~1 s), and the Register + Start again after wake caused no gap. A longer sleep, where
  macOS may suspend the modem's USB, is not checked yet.

- Start 0x0022: 0x01 session ID, 0x10 recurrence (1 periodic), 0x12 intermediate reports
  (1 on), 0x13 minimum interval in ms. Stop 0x0023: 0x01 session ID.
- Register Events mask 0x183 (position, satellites, engine state, fix session state) gives
  position reports at 1 Hz. Engine state 0x2B and fix session state 0x2C carry their state in
  TLV 0x01, not a status.
- Time to first fix outdoors with fresh XTRA: 6.6 s (warm), 1–3 s right after an earlier
  session (hot). Accuracy ±5–8 m within 13 s, with 15–20 signals used.
- Fixes work in airplane mode (2.9 s).
- Releasing the client without Stop turns the engine off at once. A session does not survive
  a modem reset: a new client must Start again.
- Time to first fix after a modem reset (outdoors, valid XTRA), the session started by
  qmid 1.4 s after the modem came back: 5.9 s in one run, 99 s in another, with the same
  setup. Started a minute after a reset (direct probe): 5.4 s.
- **A wrong modem clock held up one first fix for 54 s** (RM551E, SUPL position injected,
  no time injected). The position reports said UTC 12.1 h behind, time uncertainty about 100
  years, source 13 (TLV 0x25, 0x28, 0x29). It tracked the same few signals, without elevation or
  azimuth, for 45 s. The clock then jumped to the right time, the first fix came about 2 s
  later, and 33 signals were tracked. What corrected the clock isn't known. One run; it may
  explain the slow runs above.
- So qmid gives the modem the Mac's clock before each new session's Start: Inject UTC Time
  0x0038 (0x01 UTC u64 ms, 0x02 uncertainty u32 ms, 500). One earlier run after a reset: first
  fix 17 s. Mac to modem only. Config `injectTime: false` turns it off, to compare.
- Position reports carry the modem's UTC even when it is wrong: `QMIDLocation.time` is set only
  for a fix or when the source (0x29) isn't 0 or 13.
- An XTRA file loads with a session running, so qmid checks XTRA when a new session starts,
  alongside the search and without delaying Start.
- A session outlives its last client by 45 s. A client stopped and started again 1 s apart, and
  the new session tracked 6 signals where the old one had 10.
- Satellites, 0x0025: the list is **TLV 0x11** with 29-byte entries (libqmi: 0x10 with 28
  bytes). Each entry is valid mask u32, system u32, satellite ID u16, health u8, status u32,
  navigation data u8, elevation, azimuth and C/N0 as floats, then one byte that was always 0.
  System numbers follow the IDL: 1 GPS, 2 Galileo, 3 SBAS, 5 GLONASS, **6 BeiDou, 7 QZSS**,
  8 NavIC. Status: 1 idle, **2 searching, 3 tracking**.
- **TLV 0x12** holds each entry's signal type, a u64 mask in the same order: GPS L1 C/A 0x1,
  L5 0x8; BeiDou B1I 0x200, B1C 0x400, B2a 0x80000; QZSS L1 C/A 0x2000, L5 0x10000. The same
  satellite appears once per signal (dual frequency).
- The position report's TLV 0x2C lists the satellite IDs used in the fix, once per signal:
  GPS 1–32, GLONASS 65–96, QZSS 193–200, BeiDou 201–263, Galileo 301–336.
- With `AT+QGPSCFG="gnssconfig",7` only GPS, BeiDou and QZSS were seen.

## Position from SUPL

After `AT+CFUN=1,1` the modem's first position reports are a country-wide guess (±1268 km,
centred on Indonesia: from the MCC), so it has lost its own position. Inject Position 0x0039
(TLVs 0x10 / 0x11 latitude / longitude as doubles, 0x12 circular uncertainty float m, 0x13
confidence u8, 0x14 reliability u32, 0x1D source u32: 1 cell ID) is **accepted** (status 0,
also on the RM520N).
The position reports don't show it (still ±1268 km until satellites), but the search does: in
one pair of runs right after a reset, outdoors and moving, 21 signals were tracked 8 s after
Start with it, 2 without; first fix 7.6 s against 31.5 s. One pair only, with weaker signals
in the run without.

qmid gets the position from a SUPL 2.0 server: `supl.google.com:7275` (TLS, verified
certificate) answers a SET-initiated, SET-based session for an LTE cell with an LPP Provide
Assistance Data. Asked for the reference location only, that is 20 bytes: an ellipsoid point
with altitude, ±201 m (68%) for the cells tried, 34 m from the GPS fix at the time. Asked for
more, it also sends GPS reference time, ephemeris for all 32 GPS satellites, the ionosphere
model and UTC models (qmid doesn't ask). Asked for each constellation's navigation model in one
session: GPS 32, BeiDou 37, Galileo 30, QZSS 6, GLONASS 12 satellites. It accepted a test IMSI (001-01) as the SET identity.
`SUPL.swift` hand-encodes the few ULP messages (unaligned PER), checked against pycrate.

The modem has its own SUPL client too: Get Server 0x0043 (UMTS SLP) answers with an empty
URL, Get Operation Mode 0x004B says 4 (standalone), Get Engine Lock 0x003B 3, and
`AT+QGPSCFG="lbsapn"` is empty. qmid leaves it unconfigured: it would send the SIM's IMSI and
need a data path qmid doesn't manage. The modem sent no Inject Position / Time / XTRA requests
(0x2A, 0x28, 0x29) with those events registered.

