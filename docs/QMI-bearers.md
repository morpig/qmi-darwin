# Bearers, QoS, TFTs and AMBR over QMI

What the modem (RM551E-GL) reports about each PDN's bearers, and how qmid reads it. qmid
exposes the QCI, APN-AMBR and dedicated bearers (docs/API.md, "Dedicated bearers and QoS").

Message and TLV numbers follow Qualcomm's QMI IDL (`quality_of_service_v01`,
`wireless_data_service_v01`, `network_access_service_v01`); every one used below was checked
against the live modem.

## What to expect

- Default bearers: typically QCI 6 or 9 on internet, QCI 5 on IMS. APN-AMBR varies widely
  between networks and APNs (from ~5 Mbps on IMS to 2 Gbps on internet).
- A network can change the APN-AMBR on a live connection, e.g. following the radio (5G NSA
  vs LTE only). The modem reports it with the AMBR indication, so qmid's value moves with it
  (a `pdn` event per change).
- Dedicated bearers are created by the network: GBR bearers on internet while traffic to
  certain CDNs or hosts flows (the TFT changes with the traffic), a QCI 1 GBR bearer on IMS
  for the RTP/RTCP of a VoLTE call (created when the call starts, deleted ~10 s after).
- PDN families differ per network: some refuse IPv4 on IMS (3GPP #51 or #208), some IPv6 on
  everything (internal #210).

## How qmid reads them

Per connected PDN (`PDNQoS`):

1. **One QoS client** bound to the PDN's mux, Set Client IP Pref to a family whose call is
   up (IPv4 when it is), **Set Event Report** 0x0001 TLV 0x10 = 1. A bearer is one EPS
   bearer whatever the family, and the Event Reports carry both families' filters, so one
   client is enough for IPv4-only, IPv6-only and dual-stack PDNs.
2. **Dedicated bearers follow the Event Reports.** Each create (state 1) or modify (2)
   report holds the whole bearer: granted flows both ways and both filter lists, complete.
   Delete (3) removes it; flow control (5/6) and the modem's duplicate copies change nothing.
   No query is needed per change.
3. **Snapshot** at connect and after wake (on its own queue, results merged with reports
   that arrived meanwhile): WDS Get AMBR Info (and the AMBR indication), Get QoS Info for
   QoS ID 0 (default bearer QCI, ~180 bytes), Get QoS IDs and Get Granted QoS per bearer
   (QCI and rates). A bearer that exists before the snapshot gets its filters with its
   next report.

What ruled out the alternatives:

- **Get QoS Info is unusable for busy bearers.** It answers in 149-byte records per filter,
  and the modem never sends an answer over ~4 KB (largest seen 4061 bytes): a bearer with
  ~26 filters across both directions (reached within seconds on busy CDN bearers) gets no
  answer at all. Its downlink list is also split by family per client (below) and was seen
  short even when complete in the same moment's Event Report.
- **Global QoS Flow 0x0031** has the same 149-byte records. It is the documented message,
  but adds nothing the Event Report doesn't have.
- The modem can take over a second to answer anything while the network is changing a
  bearer, which is why the snapshot doesn't run on the Manager's queue.
- Two transport fixes came out of this: the control channel now reads until the modem's
  queue is empty after each RESPONSE_AVAILABLE (it stopped at 32 messages, and a bearer
  change queues 40+ indications, leaving responses behind until the next notification), and
  the response buffer is 16 KB instead of 4 KB.

## QoS service (QMI QoS 0x04, version 1.22)

### Setup per PDN

1. Allocate a QoS client, **Bind Data Port** 0x002B (TLV 0x10 endpoint type 2 + interface,
   TLV 0x11 mux ID).
2. **Set Client IP Pref** 0x002A (TLV 0x01: 4 or 6) to a family whose call is up. A QoS
   client finds its call by mux + family and defaults to IPv4, so on an IPv6-only PDN every
   query answers `OutOfCall` until this is sent.
3. **Set Event Report** 0x0001 TLV 0x10 = 1 (global flows) and **Indication Register**
   0x002F TLV 0x10 = 1. TLV 0x11 = 1 is meant to suppress the flow enable/disable reports
   (not yet confirmed: the request that carried it also had TLV 0x13, report
   global flows ex, and the modem rejected the whole request with error 0x0046).

### Queries

| Message | Use |
|---|---|
| Get QoS IDs 0x0036 | the PDN's dedicated flows (u8 count + u32 IDs); default bearer is ID 0 |
| Get QoS Info 0x0033 (TLV 0x01 qos_id) | 0x11/0x12 Tx/Rx flow, 0x13/0x14 Tx/Rx filters |
| Get Granted QoS 0x0025 | nested-TLV flow spec; works for dedicated IDs, not ID 0 |
| Get Client Binding 0x0038 | mux, endpoint, IP preference of the client |
| Get QoS Info Ex 0x0035 | NotSupported on this firmware |

Flow record (77 bytes): u64 valid-params mask, u32 traffic class, **u64 max rate and u64
guaranteed rate in bps at offsets 12 and 20**, …, **LTE QCI in the last u32**.

Filter record (149 bytes): u8 IP version, IPv4 block (u64 mask, src addr/mask, dst
addr/mask, TOS), IPv6 block at 27 (u64 mask, src addr + prefix, dst addr + prefix at 52/68,
traffic class, flow label), u32 protocol at 75, TCP block at 79 (u64 mask, src port/range
at 87, dst port/range at 91), UDP/ICMP/ESP/AH blocks, then **u16 filter ID and u16
precedence**. The filter ID's low byte is the 3GPP packet filter ID (0–15); the high byte
is the family the client queries through (01 IPv4, 02 IPv6).

### Indications

- **Global QoS Flow 0x0031**: TLV 0x01 = u32 qos_id, u8 new flag, u32 state (0 activated,
  1 modified, 2 deleted, 3 suspended, 4 enabled, 5 disabled, 6 rebind), then the same flow
  and filter TLVs as 0x0033. The IDL also defines 0x14 flow type (network/UE initiated),
  0x15 EPS bearer ID, 0x17/0x18 5G QCI and 0x1B match-all filters.
- **Event Report 0x0001** (legacy; not in the IDL, decoded from captures): one TLV 0x10
  per flow, holding nested TLVs:

  | Nested TLV | Content |
  |---|---|
  | 0x10 | u32 QoS ID, u8 new flag, u8 state: 1 activated, 2 modified, 3 deleted, 4 suspended, 5/6 flow control |
  | 0x11 / 0x12 | uplink / downlink granted flow: a nested 0x10 holding 0x11 traffic class, 0x12 max + guaranteed (two u32 bps), 0x20 the same as two u64, 0x1F QCI |
  | 0x13 / 0x14 | uplink / downlink filters, each a nested 0x10: 0x23 ID (u8 + per-view byte), 0x22 precedence u16, 0x11 IP version, 0x12 / 0x13 IPv4 src / dst (addr + mask), 0x16 / 0x17 IPv6 src / dst (addr + prefix), 0x14 protocol, 0x1B / 0x1C TCP src / dst port + range, 0x1D / 0x1E UDP src / dst port + range |
  | 0x15 | flow type, 1 = network-initiated (creation only) |
  | 0x16 | bearer ID as the modem reports it, 0x37 (creation only) |

  About 40–50 bytes per filter, so even a full bearer (16 filters each way) stays far below
  the ~4 KB the modem will send.
- Steady state is a stream of flow enable/disable pairs (states 4/5) every few seconds:
  flow control, not bearer changes.

### Per-family views

On a dual-stack PDN the IPv4 and IPv6 QoS clients see the same EPS bearer under
**different QoS IDs**, with the same QCI, rates and Tx filter list (both families' filters
in each). 0x0033's **Rx filters are split by family**: each view blanks the other family's
entries (records with IP version 0). The 0x0001 indication has the complete Rx list through
either view.

This is why qmid takes filters from the Event Reports instead, through a single client.

### Bearer lifecycle

A network-created bearer, as seen from a fresh attach:

1. Within a second of matching traffic the network creates a GBR bearer. 0x0031 says
   `activated` with the new-flow flag, **0x14 flow type = 1 (network-initiated)** and
   **0x15 bearer ID = 0x37**. Before that, a 0x0031 for the same QoS ID may come with
   state 5 (disabled) then 6 (rebind).
2. Filters are added one per modification, about one a second.
3. About 10 s after the traffic stops the network deletes the bearer (0x0031 state 2,
   0x0001 state 03), and Get QoS IDs is empty again.

Also seen:

- **Two bearers.** Once the first bearer holds ~14 filters a network may open a second one
  with the same QoS for the overflow (a TFT holds at most 16 packet filters).
- **Hold-off.** After deleting the bearer a network may not create a new one for ~80 s,
  whatever the traffic.
- The bearer persists across reconnects (new QoS ID each time).
- The bearer ID 0x37 is not a plain 3GPP EPS bearer ID (5–15); what it encodes is open.

### UE-initiated QoS (Request QoS Ex 0x0030)

QCI 4 GBR with Tx+Rx flows and filters, Tx only, QCI 8 without rates, and rates without
QCI were all refused at once with `Internal (0x0003)`: no QoS ID, no per-field error TLVs,
no status indication, flow list unchanged. The modem declines locally before any
signalling, so device-initiated bearers are not available on this firmware/configuration;
network-created bearers are the only kind to expect.

## Default bearer QCI and APN-AMBR

- QCI: Get QoS Info 0x0033 with qos_id 0.
- APN-AMBR: **WDS Get AMBR Info 0x011F**, empty request on the PDN's own call client; TLV
  0x10 uplink, 0x11 downlink, u64 bps. Change indication 0x011E, enabled with WDS
  Indication Register 0x0003 TLV 0x3B = 1. The value matches `AT+QNWCFG="lte_ambr"`. Not
  part of Get Runtime Settings (all mask bits checked).

## WDS / NAS survey

Read-only queries and indication registrations only; setters, the emergency PDN and
anything that changes modem state were left out.

| Message | Result | Note |
|---|---|---|
| Get Data Bearer Tech Ex 0x0091 | internet 5G (NR), ims LTE | per-PDN radio technology |
| Get Data Bearer Type 0x00F3 | internet UL/DL 4G+5G split, ims 4G | EN-DC split bearer on internet |
| Get LTE Attach Params 0x0085 | APN, IP type, OTA attach performed, addresses | indication via Indication Register 0x22 |
| Get LTE Attach PDN List 0x0094 / max 0x0092 | profile 1 / 56 | |
| Get Capabilities 0x00A9 (request flags 0x10–0x17 = 1) | CLAT supported, PDN throttle and roaming info capable | |
| Get PDN Throttle Info 0x006C (TLV 0x01 tech type, **1 byte**) | nothing throttled; indication 0x00D4 arrives | 4-byte tech type is MalformedMessage |
| Get Dormancy Status 0x0030, Global Dormancy indication 0x0113 | active | |
| Get Throttled PDN Reject Timer 0x00D0 | 0 | |
| Get LTE Emergency Attach Params 0x00E4 | null algorithm not used | |
| TD Info indication 0x010E | traffic descriptors: DNN `ims` precedence 1, `sos` precedence 2 | |
| Rebind Default Flow indication 0x0102, LTE Attach Failure Info 0x0103 | arrive after registering | |
| Get Packet Statistics 0x0024 / Ex 0x0112 | per-client counters | qmid counts in its datapath already |
| Get APN MSISDN 0x00CB, Op Reserved PCO 0x00C9 | error 0x004A | only when the network sends them |
| Downlink Throughput 0x00BD / 0x00B4 / 0x00C2 | errors | probably need reporting enabled first (a setter) |
| Call Throttle 0x005F, APN Rate Control 0x00FA, LADN 0x00FF, Attach PDN List Lite 0x013D, Data Bearer Technology 0x0037 | unsupported or not applicable | |
| NAS Get Sys Info 0x004D | TLV 0x39 LTE emergency bearer support, 0x3E emergency access barred | indication 0x004E carries them as 0x3A/0x3F. Both 4-byte enums: 0 no, 1 yes, 2 while searching |
| NAS Get System Selection Pref 0x0034 | TLV 0x10 emergency mode = off | |

Emergency PDNs: a profile marks emergency use with WDS profile TLV 0x36 (Support
Emergency Calls). The firmware's `sos` profile (cid 3) already has it set, and APN type
`emergency` (0x200); qmid leaves both as they are. Where the network supports emergency
bearers the `sos` PDN came up in under a second, IPv4 only, QCI 5, with P-CSCFs; elsewhere
it was rejected with 3GPP #31 on both families. Whether the modem sends request type
emergency isn't visible over QMI.

## Open

- What the bearer ID value (0x37) encodes.
- Filters of bearers that exist before qmid connects arrive only with their next change.
- A video call (QCI 2).
