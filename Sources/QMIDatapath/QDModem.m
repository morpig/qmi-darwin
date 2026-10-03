#import "QMIDatapath.h"

#import <IOKit/IOKitLib.h>
#import <IOKit/IOMessage.h>
#import <IOUSBHost/IOUSBHost.h>

#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <unistd.h>

NSErrorDomain const QDErrorDomain = @"QDErrorDomain";

// Datapath sizing (PLAN.md §6: start with 16 reads in flight).
enum {
    kInFlightIn = 32,           // x downlink size = how long a datapath stall can last before
                                // the modem has nowhere to put data
    kOutSlots = 8,              // x uplink size = what can queue ahead of the modem: at 32 x 16 KB
                                // a saturated upload kept ~480 KB queued (110-250 ms) in front of
                                // every packet, IMS too; 8 keeps it near 128 KB
    kMaxPacket = 2048,          // largest IP packet read from a utun (MTU <= 2000)
    kCDCBufferSize = 16384,     // one QMI response; QoS Get QoS Info with 16 filters each way
                                // is ~4.9 KB, and a shorter read cuts the message off
};

// QMAP command frame: name, type in low 2 bits, reserved, txid.
enum { kQMAPFlowDisable = 1, kQMAPFlowEnable = 2 };
enum { kQMAPCmdRequest = 0, kQMAPCmdAck = 1, kQMAPCmdUnsupported = 2 };

typedef struct {
    uint64_t rx_packets, rx_bytes, rx_drops;
    uint64_t tx_packets, tx_bytes, tx_drops;
    uint64_t flow_disable_count;
    uint64_t flow_disabled_since_ns, flow_disabled_total_ns;
    bool flow_disabled;
} qd_mux_stats;

typedef struct {
    uint64_t usb_in_transfers, usb_in_errors, usb_out_transfers, usb_out_errors;
    uint64_t unknown_mux, bad_frames, command_frames, out_starved;
    uint64_t stale_frames;      // arrived before any mux was attached: queued in the modem by an
                                // earlier process (e.g. IPv6 RAs on calls nobody was reading)
    uint64_t usb_in_bytes, usb_out_bytes;
    uint64_t in_full;           // IN transfers within one max packet of the buffer size
    // Window values, reset each time statistics are read:
    int in_posted_min;          // fewest bulk IN reads still posted, as seen when qmid handles a
                                // completion (reads that finished during a stall aren't subtracted
                                // until handled, so it overstates; in_proc_max_ns shows stalls)
    uint64_t in_frames_max, out_frames_max, in_proc_max_ns;
    uint64_t out_wait_max_ns;   // longest enqueue-to-completion of a bulk OUT transfer: how long
                                // a packet (an IMS one too) queues behind earlier uplink data
    uint64_t out_inflight_max;  // most bulk OUT bytes handed to USB and not yet completed
    uint64_t dl_batch_calls, ul_batch_calls;
    uint64_t in_stall_tests;    // simulateInStall calls
} qd_global_stats;

static NSError *QDError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:QDErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSError *QDIOReturnError(IOReturn r, NSString *what) {
    return QDError(r, [NSString stringWithFormat:@"%@ failed (0x%08x)", what, (unsigned)r]);
}

static bool qd_debug(void) {
    static int on = -1;
    if (on < 0) on = getenv("QD_DEBUG") != NULL;
    return on;
}
#define QDLOG(...) do { if (qd_debug()) { fprintf(stderr, "[qd] " __VA_ARGS__); fputc('\n', stderr); } } while (0)

// IOUSBHost raises NSInvalidArgumentException from several methods when a request fails
// (it builds the NSError's userInfo with a nil value), e.g. enqueueing on a pipe of a device
// that was just unplugged. Every pipe/object call goes through these, so a failure is a
// failure and never takes the daemon down.
static BOOL qd_enqueue(IOUSBHostPipe *pipe, NSMutableData *data, IOUSBHostCompletionHandler handler) {
    @try {
        return [pipe enqueueIORequestWithData:data completionTimeout:0 error:nil completionHandler:handler];
    } @catch (NSException *ex) {
        return NO;
    }
}

static void qd_clear_stall(IOUSBHostPipe *pipe) {
    @try { [pipe clearStallWithError:nil]; } @catch (NSException *ex) {}
}

static void qd_abort(IOUSBHostPipe *pipe) {
    @try { [pipe abortWithOption:IOUSBHostAbortOptionSynchronous error:nil]; } @catch (NSException *ex) {}
}

static void qd_destroy(IOUSBHostObject *obj) {
    @try { [obj destroy]; } @catch (NSException *ex) {}
}

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

// Batched socket I/O: sendmsg_x / recvmsg_x are private XNU system calls (bsd/sys/socket.h,
// PRIVATE) that move several datagrams per call. Looked up at runtime; when missing, or when the
// kernel rejects them on a utun socket, the datapath falls back to one write/read per packet.
struct qd_msghdr_x {
    void *msg_name;
    socklen_t msg_namelen;
    struct iovec *msg_iov;
    int msg_iovlen;
    void *msg_control;
    socklen_t msg_controllen;
    int msg_flags;
    size_t msg_datalen;
};
typedef ssize_t (*qd_msg_x_fn)(int, struct qd_msghdr_x *, unsigned int, int);
static qd_msg_x_fn qd_sendmsg_x, qd_recvmsg_x;

static void qd_resolve_batch_calls(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        qd_sendmsg_x = (qd_msg_x_fn)dlsym(RTLD_DEFAULT, "sendmsg_x");
        qd_recvmsg_x = (qd_msg_x_fn)dlsym(RTLD_DEFAULT, "recvmsg_x");
    });
}

// Errors that mean "this socket doesn't do batched I/O" rather than a per-packet failure.
static bool qd_batch_unsupported(int e) {
    return e == ENOTSUP || e == EOPNOTSUPP || e == ENOSYS || e == EINVAL || e == EPROTOTYPE;
}

enum { kDLBatchMax = 64, kULBatchMax = 32 };

// Uplink work per turn on the datapath queue (packets read from one utun) before IN/OUT
// completions, flow control and other muxes get their turn. The read source fires again while
// the utun has more.
enum { kULTurnPackets = 64 };

// Packets read from a mux's utun with recvmsg_x that are waiting for an OUT slot (all busy) or
// for flow-enable. One per mux, so a flow-disabled mux's packets don't hold up another's.
typedef struct {
    uint8_t *buf;                       // kULBatchMax x (kMaxPacket + 4)
    struct qd_msghdr_x msgs[kULBatchMax];
    struct iovec iov[kULBatchMax];
    int count, next;
} qd_ul_stage;

static inline bool qd_staged(const qd_ul_stage *st) { return st && st->next < st->count; }

// A mux's packets in one OUT transfer: credited to tx_* when it completes, tx_drops otherwise.
enum { kSlotMuxMax = 4 };
typedef struct { uint8_t mux; uint32_t packets; uint64_t bytes; } qd_slot_share;

static NSNumber *regNumber(io_service_t s, CFStringRef key) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, key, kCFAllocatorDefault, 0);
    if (!v) return nil;
    id obj = CFBridgingRelease(v);
    return [obj isKindOfClass:[NSNumber class]] ? obj : nil;
}

@implementation QDModem {
    IOUSBHostInterface *_iface;
    IOUSBHostPipe *_inPipe, *_outPipe, *_intPipe;
    dispatch_queue_t _ioQueue;      // IOUSBHost completions + all datapath state
    dispatch_queue_t _ctlQueue;     // synchronous GET_ENCAPSULATED_RESPONSE
    void (^_controlHandler)(NSData *);
    BOOL _closed;
    NSUInteger _intMaxPacket;

    // Datapath state: touched only on _ioQueue.
    BOOL _running;
    NSUInteger _dlSize, _ulSize, _ulDatagrams;
    int _fd[256];
    dispatch_source_t _src[256];
    bool _srcActive[256];
    qd_mux_stats _mux[256];
    qd_global_stats _g;
    uint64_t _unknownByMux[256];
    BOOL _everAttached;

    uint8_t *_outBuf[kOutSlots];
    int _outFree[kOutSlots];
    uint64_t _outSince[kOutSlots];  // enqueue time (ns, uptime) while in flight, else 0
    int _outFreeCount;
    uint64_t _outInflight;          // bytes in bulk OUT transfers not yet completed
    int _inPosted;                  // bulk IN reads currently queued on the pipe
    BOOL _inClearing;               // a bulk IN stall clear is running (see -recoverIn:)
    qd_slot_share _share[kOutSlots][kSlotMuxMax];
    int _shares[kOutSlots];
    int _curSlot;                   // slot being filled, -1 if none (always between turns)
    size_t _curLen, _curCount, _curLastHeader;
    BOOL _outStarved;
    uint8_t _kickFrom;              // mux to start from when packing staged packets

    // Batched utun I/O (see qd_sendmsg_x). Downlink: one sendmsg_x per IN transfer and mux.
    BOOL _dlBatch, _ulBatch;
    struct qd_msghdr_x _dlMsgs[kDLBatchMax];
    struct iovec _dlIov[kDLBatchMax][2];
    uint32_t _dlAF[kDLBatchMax];
    int _dlCount, _dlFd;
    uint8_t _dlMux;
    // Uplink: recvmsg_x into the mux's stage, then packed into OUT buffers.
    qd_ul_stage *_stage[256];
}

+ (instancetype)openWithVendorID:(uint16_t)vendorID interfaceNumber:(NSInteger)interfaceNumber error:(NSError **)error {
    CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostInterface");
    io_iterator_t it = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &it);
    if (kr != KERN_SUCCESS) {
        if (error) *error = QDIOReturnError(kr, @"IOServiceGetMatchingServices");
        return nil;
    }
    io_service_t found = IO_OBJECT_NULL, s;
    while ((s = IOIteratorNext(it))) {
        NSNumber *vid = regNumber(s, CFSTR("idVendor"));
        NSNumber *num = regNumber(s, CFSTR("bInterfaceNumber"));
        NSNumber *cls = regNumber(s, CFSTR("bInterfaceClass"));
        NSNumber *sub = regNumber(s, CFSTR("bInterfaceSubClass"));
        NSNumber *proto = regNumber(s, CFSTR("bInterfaceProtocol"));
        BOOL ok = vid.unsignedIntValue == vendorID &&
            (interfaceNumber >= 0 ? num.integerValue == interfaceNumber
                                  : (cls.intValue == 0xff && sub.intValue == 0xff && proto.intValue == 0xff));
        if (ok) { found = s; break; }
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    if (!found) {
        if (error) *error = QDError(1, @"QMI interface not found (is the modem in usbnet=0 mode?)");
        return nil;
    }
    // A freshly re-enumerated interface may still be configuring; opening it then fails (and
    // IOUSBHost leaves its user client behind). Wait until IOKit is done with it.
    mach_timespec_t wait = { .tv_sec = 5, .tv_nsec = 0 };
    IOServiceWaitQuiet(found, &wait);
    QDModem *m = [[QDModem alloc] initWithService:found error:error];
    IOObjectRelease(found);
    return m;
}

- (instancetype)initWithService:(io_service_t)service error:(NSError **)error {
    if (!(self = [super init])) return nil;
    // Every packet goes through this queue, so it runs at the highest QoS: at several hundred
    // Mbps a stall of a few ms uses up the posted bulk IN reads.
    _ioQueue = dispatch_queue_create("qmi.usb.io",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    _ctlQueue = dispatch_queue_create("qmi.usb.control", DISPATCH_QUEUE_SERIAL);
    for (int i = 0; i < 256; i++) _fd[i] = -1;
    _curSlot = -1;

    _vendorID = regNumber(service, CFSTR("idVendor")).unsignedShortValue;
    _productID = regNumber(service, CFSTR("idProduct")).unsignedShortValue;
    _interfaceNumber = regNumber(service, CFSTR("bInterfaceNumber")).unsignedCharValue;

    __weak QDModem *weakSelf = self;
    // Like -sendDeviceRequest:, IOUSBHost can raise while building the NSError for a failed
    // open (seen right after the modem re-enumerates); report it as an error instead.
    IOUSBHostInterface *allocated = [IOUSBHostInterface alloc];
    @try {
        NSError *e = nil;
        _iface = [allocated initWithIOService:service
                                                      options:IOUSBHostObjectInitOptionsNone
                                                        queue:_ioQueue
                                                        error:&e
                                              interestHandler:^(IOUSBHostObject *obj, uint32_t type, void *arg) {
            if (type == kIOMessageServiceIsTerminated) [weakSelf handleTermination];
        }];
        if (!_iface && error) *error = e ?: QDError(5, @"could not open the QMI interface");
    } @catch (NSException *ex) {
        if (error) *error = QDError(5, [NSString stringWithFormat:@"could not open the QMI interface (%@)", ex.name]);
        _iface = nil;
    }
    if (!_iface) {
        // A failed open can leave the user client open, which makes every later open of this
        // interface fail too. Close it.
        qd_destroy(allocated);
        return nil;
    }

    const IOUSBConfigurationDescriptor *cfg = _iface.configurationDescriptor;
    const IOUSBInterfaceDescriptor *ifd = _iface.interfaceDescriptor;
    const IOUSBEndpointDescriptor *ep = NULL;
    while ((ep = IOUSBGetNextEndpointDescriptor(cfg, ifd, (const IOUSBDescriptorHeader *)ep))) {
        uint8_t type = ep->bmAttributes & 0x03;
        uint8_t addr = ep->bEndpointAddress;
        NSUInteger mps = OSSwapLittleToHostInt16(ep->wMaxPacketSize) & 0x7ff;
        if (type == 2 && (addr & 0x80)) { _bulkInAddress = addr; _bulkInMaxPacketSize = mps; }
        else if (type == 2) { _bulkOutAddress = addr; _bulkOutMaxPacketSize = mps; }
        else if (type == 3 && (addr & 0x80)) { _interruptAddress = addr; _intMaxPacket = mps; }
    }
    if (!_bulkInAddress || !_bulkOutAddress || !_interruptAddress) {
        if (error) *error = QDError(2, @"QMI interface is missing a bulk or interrupt endpoint");
        qd_destroy(_iface);
        return nil;
    }
    @try {
        _inPipe = [_iface copyPipeWithAddress:_bulkInAddress error:nil];
        _outPipe = [_iface copyPipeWithAddress:_bulkOutAddress error:nil];
        _intPipe = [_iface copyPipeWithAddress:_interruptAddress error:nil];
    } @catch (NSException *ex) {
        _inPipe = _outPipe = _intPipe = nil;
    }
    if ((!_inPipe || !_outPipe || !_intPipe) && error) *error = QDError(6, @"could not open the QMI interface's pipes");
    if (!_inPipe || !_outPipe || !_intPipe) {
        qd_destroy(_iface);
        return nil;
    }
    return self;
}

- (void)dealloc {
    [self close];
}

- (void)handleTermination {
    // The device is gone: stop feeding its pipes right away (uplink reads would otherwise keep
    // enqueueing on dead pipes until the owner closes us).
    dispatch_async(_ioQueue, ^{
        self->_running = NO;
        for (int m = 0; m < 256; m++) [self updateSource:(uint8_t)m];
    });
    dispatch_async(_ctlQueue, ^{
        void (^h)(void) = self.terminationHandler;
        self.terminationHandler = nil;
        if (h) h();
    });
}

// MARK: - Control plane

// Wraps -sendDeviceRequest: IOUSBHost can throw NSInvalidArgumentException while building the
// NSError for a failed request (seen under launchd: a nil object in the userInfo dictionary),
// so failures are reported as a plain IOReturn-less NSError here and never as an exception.
- (BOOL)deviceRequest:(IOUSBDeviceRequest)req data:(nullable NSMutableData *)data
                 done:(NSUInteger *)done error:(NSError **)error {
    @try {
        NSError *e = nil;
        BOOL ok = [_iface sendDeviceRequest:req data:data bytesTransferred:done completionTimeout:5.0
                                      error:(error ? &e : NULL)];
        if (!ok && error) *error = e ?: QDError(4, @"device request failed");
        return ok;
    } @catch (NSException *ex) {
        QDLOG("device request 0x%02x/0x%02x raised %s", req.bmRequestType, req.bRequest, ex.reason.UTF8String);
        if (error) *error = QDError(4, [NSString stringWithFormat:@"device request failed (%@)", ex.name]);
        return NO;
    }
}

- (BOOL)sendEncapsulatedCommand:(NSData *)message error:(NSError **)error {
    IOUSBDeviceRequest req = {
        .bmRequestType = 0x21,       // host-to-device, class, interface
        .bRequest = 0x00,            // SEND_ENCAPSULATED_COMMAND
        .wValue = 0,
        .wIndex = _interfaceNumber,
        .wLength = (uint16_t)message.length,
    };
    NSMutableData *data = [message mutableCopy];
    NSUInteger done = 0;
    BOOL ok = [self deviceRequest:req data:data done:&done error:error];
    QDLOG("SEND_ENCAPSULATED_COMMAND: %s, %lu bytes", ok ? "ok" : "failed", (unsigned long)done);
    return ok;
}

- (nullable NSData *)getEncapsulatedResponse {
    IOUSBDeviceRequest req = {
        .bmRequestType = 0xA1,       // device-to-host, class, interface
        .bRequest = 0x01,            // GET_ENCAPSULATED_RESPONSE
        .wValue = 0,
        .wIndex = _interfaceNumber,
        .wLength = kCDCBufferSize,
    };
    NSMutableData *data = [NSMutableData dataWithLength:kCDCBufferSize];
    NSUInteger done = 0;
    // An empty queue answers with a stall; that's the normal end of a drain, so no NSError.
    if (![self deviceRequest:req data:data done:&done error:NULL]) {
        QDLOG("GET_ENCAPSULATED_RESPONSE: nothing queued");
        return nil;
    }
    data.length = done;
    QDLOG("GET_ENCAPSULATED_RESPONSE: %lu bytes", (unsigned long)done);
    return data;
}

- (BOOL)startControlChannel:(void (^)(NSData *))handler error:(NSError **)error {
    _controlHandler = [handler copy];

    // SET_CONTROL_LINE_STATE with DTR: recent Qualcomm firmware (Quectel
    // included) stays silent on the control channel until the host raises DTR.
    IOUSBDeviceRequest dtr = {
        .bmRequestType = 0x21, .bRequest = 0x22, .wValue = 0x0001, .wIndex = _interfaceNumber, .wLength = 0,
    };
    NSError *dtrErr = nil;
    NSUInteger dtrDone = 0;
    BOOL dtrOK = [self deviceRequest:dtr data:nil done:&dtrDone error:&dtrErr];
    QDLOG("SET_CONTROL_LINE_STATE(DTR): %s", dtrOK ? "ok" : dtrErr.localizedDescription.UTF8String);

    // Discard whatever an earlier process left queued (responses to its requests, indications),
    // so they can't be matched to ours. Done before any request is sent.
    int stale = 0;
    for (; stale < 64; stale++) {
        NSData *d = [self getEncapsulatedResponse];
        if (d.length == 0) break;
    }
    QDLOG("discarded %d stale control messages", stale);
    [self armInterrupt];
    return YES;
}

// Reads until the modem's queue is empty. One RESPONSE_AVAILABLE can stand for many queued
// messages (a QoS change queues 40+ indications at once), and whatever is left behind waits for
// the next notification, a response included. Batches of 32, so the queue stays fair.
- (void)drainResponses {
    for (int i = 0; i < 32 && !_closed; i++) {
        NSData *d = [self getEncapsulatedResponse];
        if (d.length == 0) return;
        if (_controlHandler) _controlHandler(d);
    }
    if (!_closed) dispatch_async(_ctlQueue, ^{ [self drainResponses]; });
}

- (void)armInterrupt {
    if (_closed) return;
    // Exactly wMaxPacketSize (8 on RM551E): an 8-byte RESPONSE_AVAILABLE fills the packet, so
    // a larger buffer would wait for a short packet that never comes.
    NSMutableData *buf = [NSMutableData dataWithLength:_intMaxPacket ?: 8];
    BOOL ok = qd_enqueue(_intPipe, buf, ^(IOReturn status, NSUInteger n) {
        if (self->_closed || status == kIOReturnAborted || status == kIOReturnNoDevice) return;
        QDLOG("interrupt: status 0x%08x, %lu bytes", status, (unsigned long)n);
        if (status == kIOReturnSuccess) {
            const uint8_t *p = buf.bytes;
            if (n >= 2 && p[0] == 0xA1 && p[1] == 0x01) {          // RESPONSE_AVAILABLE
                dispatch_async(self->_ctlQueue, ^{ [self drainResponses]; });
            }
            [self armInterrupt];
        } else {
            qd_clear_stall(self->_intPipe);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), self->_ioQueue, ^{ [self armInterrupt]; });
        }
    });
    if (!ok) {
        QDLOG("interrupt enqueue failed");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), _ioQueue, ^{ [self armInterrupt]; });
    }
}

// MARK: - Datapath

- (BOOL)startDatapathWithDownlinkSize:(NSUInteger)downlinkSize
                           uplinkSize:(NSUInteger)uplinkSize
                      uplinkDatagrams:(NSUInteger)uplinkDatagrams
                                error:(NSError **)error {
    __block BOOL ok = YES;
    __block NSError *err = nil;
    dispatch_sync(_ioQueue, ^{
        if (self->_running) return;
        self->_dlSize = downlinkSize ?: 16384;
        // Without granted UL aggregation, send one datagram per transfer.
        BOOL agg = uplinkSize >= kMaxPacket + 16 && uplinkDatagrams > 1;
        self->_ulSize = agg ? uplinkSize : kMaxPacket + 16;
        self->_ulDatagrams = agg ? uplinkDatagrams : 1;

        for (int i = 0; i < kOutSlots; i++) {
            self->_outBuf[i] = malloc(self->_ulSize + 8);
            self->_outFree[i] = i;
        }
        self->_outFreeCount = kOutSlots;

        qd_resolve_batch_calls();
        self->_dlBatch = self.batchUtunIO && qd_sendmsg_x != NULL;
        self->_ulBatch = self.batchUtunIO && qd_recvmsg_x != NULL;
        if (self.batchUtunIO && !(self->_dlBatch && self->_ulBatch)) {
            [self batchOff:@"sendmsg_x/recvmsg_x not found in libSystem" downlink:NO uplink:NO];
        }
        self->_running = YES;

        for (int i = 0; i < kInFlightIn; i++) {
            NSError *e = nil;
            NSMutableData *b = [self->_iface ioDataWithCapacity:self->_dlSize error:&e];
            if (!b) b = [NSMutableData dataWithLength:self->_dlSize];
            if (![self submitIn:b]) { ok = NO; err = QDError(3, @"could not queue bulk IN reads"); }
        }
        self->_g.in_posted_min = self->_inPosted;
        for (int m = 0; m < 256; m++) [self updateSource:(uint8_t)m];
    });
    if (!ok && error) *error = err;
    return ok;
}

- (BOOL)submitIn:(NSMutableData *)buf {
    if (!_running) return NO;
    BOOL ok = qd_enqueue(_inPipe, buf, ^(IOReturn status, NSUInteger n) {
        self->_inPosted--;
        if (self->_inPosted < self->_g.in_posted_min) self->_g.in_posted_min = self->_inPosted;
        [self inCompleted:buf status:status length:n];
    });
    if (ok) _inPosted++;
    if (!ok) {
        _g.usb_in_errors++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), _ioQueue, ^{ [self submitIn:buf]; });
    }
    return ok;
}

- (void)inCompleted:(NSMutableData *)buf status:(IOReturn)status length:(NSUInteger)n {
    if (!_running || status == kIOReturnNoDevice) return;
    if (status != kIOReturnSuccess) {
        // Aborted while running: our own stall clear cancelled this read (close and unplug stop
        // the datapath first). It goes back on the pipe like the one that failed, or the reads
        // posted would shrink to one for good.
        if (status != kIOReturnAborted) _g.usb_in_errors++;
        [self recoverIn:buf];
        return;
    }
    _g.usb_in_transfers++;
    _g.usb_in_bytes += n;
    if (n + 1600 >= _dlSize) _g.in_full++;
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    uint64_t frames = 0;

    const uint8_t *p = buf.bytes;
    size_t off = 0;
    qd_qmap_frame f;
    for (;;) {
        qd_qmap_status st = qd_qmap_next(p, n, &off, &f);
        if (st == QD_QMAP_END) break;
        if (st != QD_QMAP_OK) { _g.bad_frames++; break; }
        if (f.is_command) { [self handleCommand:&f]; continue; }
        int fd = _fd[f.mux_id];
        if (fd < 0) {
            if (!_everAttached) {
                _g.stale_frames++;
                QDLOG("stale frame on mux 0x%02x before any attach: %zu bytes", f.mux_id, f.payload_len);
                continue;
            }
            _g.unknown_mux++;
            _unknownByMux[f.mux_id]++;
            if (qd_debug()) {
                char hex[3 * 48 + 1] = {0};
                size_t k = f.payload_len < 48 ? f.payload_len : 48;
                for (size_t i = 0; i < k; i++) snprintf(hex + 3 * i, 4, "%02x ", f.payload[i]);
                QDLOG("unknown mux 0x%02x: %zu bytes: %s", f.mux_id, f.payload_len, hex);
            }
            continue;
        }
        if (f.payload_len == 0) continue;
        frames++;

        // Payloads point into `buf`, so the batch is flushed before `buf` is re-posted.
        if (_dlCount && (_dlFd != fd || _dlCount == kDLBatchMax)) [self flushDownlink];
        int i = _dlCount++;
        _dlFd = fd;
        _dlMux = f.mux_id;
        _dlAF[i] = htonl((f.payload[0] >> 4) == 6 ? AF_INET6 : AF_INET);
        _dlIov[i][0] = (struct iovec){ .iov_base = &_dlAF[i], .iov_len = 4 };
        _dlIov[i][1] = (struct iovec){ .iov_base = (void *)f.payload, .iov_len = f.payload_len };
    }
    [self flushDownlink];
    if (frames > _g.in_frames_max) _g.in_frames_max = frames;
    uint64_t took = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0;
    if (took > _g.in_proc_max_ns) _g.in_proc_max_ns = took;
    [self submitIn:buf];
}

// Re-posts buf after a failed or aborted read, clearing the stall once per error burst (the
// clear aborts every other posted read; they come back here as aborted).
- (void)recoverIn:(NSMutableData *)buf {
    [self clearInStall];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC), _ioQueue, ^{ [self submitIn:buf]; });
}

- (void)clearInStall {
    if (_inClearing) return;
    _inClearing = YES;
    qd_clear_stall(_inPipe);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC), _ioQueue, ^{ self->_inClearing = NO; });
}

- (void)simulateInStall {
    dispatch_async(_ioQueue, ^{
        if (!self->_running) return;
        self->_g.in_stall_tests++;
        [self clearInStall];
    });
}

// Hands the queued downlink packets (one mux) to its utun: one sendmsg_x when batching works,
// otherwise (and for whatever a batch didn't take) one writev each.
- (void)flushDownlink {
    int n = _dlCount;
    if (n == 0) return;
    _dlCount = 0;
    qd_mux_stats *s = &_mux[_dlMux];
    int sent = 0;
    if (_dlBatch) {
        for (int i = 0; i < n; i++) {
            _dlMsgs[i] = (struct qd_msghdr_x){ .msg_iov = _dlIov[i], .msg_iovlen = 2 };
        }
        ssize_t r = qd_sendmsg_x(_dlFd, _dlMsgs, (unsigned)n, 0);
        _g.dl_batch_calls++;
        if (r > 0) {
            sent = r > n ? n : (int)r;
        } else if (r < 0 && qd_batch_unsupported(errno)) {
            [self batchOff:[NSString stringWithFormat:@"sendmsg_x on utun: %s", strerror(errno)] downlink:YES uplink:NO];
        }
    }
    for (int i = 0; i < sent; i++) {
        s->rx_packets++;
        s->rx_bytes += _dlIov[i][1].iov_len;
    }
    for (int i = sent; i < n; i++) {
        if (writev(_dlFd, _dlIov[i], 2) < 0) {
            s->rx_drops++;
        } else {
            s->rx_packets++;
            s->rx_bytes += _dlIov[i][1].iov_len;
        }
    }
}

// Turns batched I/O off for a direction (after an unsupported-call error) and reports why.
- (void)batchOff:(NSString *)reason downlink:(BOOL)dl uplink:(BOOL)ul {
    if (dl) _dlBatch = NO;
    if (ul) _ulBatch = NO;
    void (^h)(NSString *) = self.batchFallbackHandler;
    if (h) h(reason);
}

- (void)handleCommand:(const qd_qmap_frame *)f {
    _g.command_frames++;
    if (f->payload_len < 8) return;
    uint8_t name = f->payload[0];
    uint8_t type = f->payload[1] & 0x03;

    if (type == kQMAPCmdRequest) {
        if (name == kQMAPFlowDisable) [self setFlowDisabled:true mux:f->mux_id];
        else if (name == kQMAPFlowEnable) [self setFlowDisabled:false mux:f->mux_id];

        // Reply with the same frame, type ACK for flow control, UNSUPPORTED otherwise.
        size_t len = f->payload_len;
        uint8_t pad = qd_qmap_pad_for(len);
        uint8_t *frame = calloc(1, 4 + len + pad);
        memcpy(frame + 4, f->payload, len);
        frame[5] = (frame[5] & ~0x03) |
            ((name == kQMAPFlowDisable || name == kQMAPFlowEnable) ? kQMAPCmdAck : kQMAPCmdUnsupported);
        qd_qmap_write_header(frame, true, f->mux_id, len, pad);
        NSMutableData *d = [NSMutableData dataWithBytesNoCopy:frame length:4 + len + pad freeWhenDone:YES];
        qd_enqueue(_outPipe, d, ^(IOReturn st, NSUInteger done) { (void)d; });
    }
    void (^h)(uint8_t, uint8_t, uint8_t) = self.commandFrameHandler;
    if (h) h(f->mux_id, name, type);
}

- (void)setFlowDisabled:(bool)off mux:(uint8_t)mux {
    qd_mux_stats *s = &_mux[mux];
    if (off == s->flow_disabled) return;
    s->flow_disabled = off;
    if (off) {
        s->flow_disable_count++;
        s->flow_disabled_since_ns = now_ns();
    } else {
        s->flow_disabled_total_ns += now_ns() - s->flow_disabled_since_ns;
    }
    [self updateSource:mux];
    // Staged packets don't make the utun readable again: send them once enabled. Later on the
    // queue, not from inside the downlink parse this may be called from.
    if (!off && qd_staged(_stage[mux])) {
        dispatch_async(_ioQueue, ^{ if (!self->_outStarved) [self uplinkBatch:mux]; });
    }
}

- (void)simulateFlowControl:(BOOL)disabled mux:(uint8_t)muxID {
    dispatch_async(_ioQueue, ^{ [self setFlowDisabled:disabled mux:muxID]; });
}

// Whether mux may send: checked where packets are packed, not only by its read source (OUT
// completions pack staged packets directly).
- (bool)canSend:(uint8_t)mux {
    return _running && _fd[mux] >= 0 && !_mux[mux].flow_disabled;
}

// A mux's read source runs only while the datapath runs, the mux isn't flow-disabled and
// there is an OUT buffer to fill.
- (void)updateSource:(uint8_t)mux {
    dispatch_source_t src = _src[mux];
    if (!src) return;
    bool want = _running && !_mux[mux].flow_disabled && !_outStarved;
    if (want && !_srcActive[mux]) { dispatch_resume(src); _srcActive[mux] = true; }
    else if (!want && _srcActive[mux]) { dispatch_suspend(src); _srcActive[mux] = false; }
}

- (void)attachMux:(uint8_t)muxID fd:(int)fd {
    dispatch_group_t gone = dispatch_group_create();
    dispatch_sync(_ioQueue, ^{
        [self detachMuxLocked:muxID group:gone];
        self->_fd[muxID] = fd;
        self->_everAttached = YES;
        memset(&self->_mux[muxID], 0, sizeof(qd_mux_stats));
        const size_t stride = kMaxPacket + 4;
        qd_ul_stage *st = calloc(1, sizeof *st);
        st->buf = malloc(stride * kULBatchMax);
        for (int i = 0; i < kULBatchMax; i++) {
            st->iov[i] = (struct iovec){ .iov_base = st->buf + i * stride, .iov_len = stride };
        }
        self->_stage[muxID] = st;
        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, self->_ioQueue);
        dispatch_source_set_event_handler(src, ^{ [self uplinkReadable:muxID]; });
        self->_src[muxID] = src;
        self->_srcActive[muxID] = false;
        [self updateSource:muxID];
    });
    dispatch_group_wait(gone, DISPATCH_TIME_FOREVER);
}

// Returns once the mux's read source is gone, so the caller may close the fd: closing it
// before the source's cancellation has run lets a new fd with the same number collide with it.
- (void)detachMux:(uint8_t)muxID {
    dispatch_group_t gone = dispatch_group_create();
    dispatch_sync(_ioQueue, ^{ [self detachMuxLocked:muxID group:gone]; });
    dispatch_group_wait(gone, DISPATCH_TIME_FOREVER);
}

// The source's cancellation handler leaves `gone` (on _ioQueue, after this block): wait on it
// off the queue.
- (void)detachMuxLocked:(uint8_t)muxID group:(dispatch_group_t)gone {
    qd_ul_stage *st = _stage[muxID];
    if (st) {
        _mux[muxID].tx_drops += (uint64_t)(st->count - st->next);   // its utun is gone
        free(st->buf);
        free(st);
        _stage[muxID] = NULL;
    }
    dispatch_source_t src = _src[muxID];
    if (src) {
        dispatch_group_enter(gone);
        dispatch_source_set_cancel_handler(src, ^{ dispatch_group_leave(gone); });
        dispatch_source_cancel(src);
        if (!_srcActive[muxID]) dispatch_resume(src);   // a suspended source must be resumed before release
        _src[muxID] = nil;
        _srcActive[muxID] = false;
    }
    _fd[muxID] = -1;
}

// Makes a free OUT slot the current one. NO when every slot is in flight: sources are
// suspended until a completion frees one.
- (BOOL)takeSlot {
    if (_curSlot >= 0) return YES;
    if (_outFreeCount == 0) {
        _outStarved = YES;
        _g.out_starved++;
        for (int m = 0; m < 256; m++) [self updateSource:(uint8_t)m];
        return NO;
    }
    _curSlot = _outFree[--_outFreeCount];
    _curLen = 0;
    _curCount = 0;
    _shares[_curSlot] = 0;
    return YES;
}

// Whether the current slot can record one more packet of mux.
- (BOOL)shareRoom:(uint8_t)mux {
    int n = _shares[_curSlot];
    for (int i = 0; i < n; i++) if (_share[_curSlot][i].mux == mux) return YES;
    return n < kSlotMuxMax;
}

// Bookkeeping for a packet just written at _curLen (header + payload + pad = frame bytes).
- (void)packed:(uint8_t)mux payload:(size_t)plen frame:(size_t)frame {
    _curLastHeader = _curLen;
    _curLen += frame;
    _curCount++;
    qd_slot_share *sh = _share[_curSlot];
    int n = _shares[_curSlot], i = 0;
    while (i < n && sh[i].mux != mux) i++;
    if (i == n) { sh[i] = (qd_slot_share){ .mux = mux }; _shares[_curSlot] = n + 1; }
    sh[i].packets++;
    sh[i].bytes += plen;
    if (_curCount >= _ulDatagrams) [self flushOut];
}

- (void)uplinkReadable:(uint8_t)mux {
    if (![self canSend:mux]) return;
    if (_ulBatch || qd_staged(_stage[mux])) { [self uplinkBatch:mux]; return; }
    int fd = _fd[mux];
    for (int reads = 0; reads < kULTurnPackets; reads++) {
        if (![self takeSlot]) return;
        uint8_t *base = _outBuf[_curSlot];
        if (_ulSize - _curLen < kMaxPacket + 8 || ![self shareRoom:mux]) { [self flushOut]; reads--; continue; }

        // utun's 4-byte AF header lands exactly where the QMAP header goes.
        ssize_t r = read(fd, base + _curLen, kMaxPacket + 4);
        if (r < 0) break;                              // EAGAIN: drained
        if (r <= 4) continue;
        size_t plen = (size_t)r - 4;
        uint8_t pad = qd_qmap_pad_for(plen);
        memset(base + _curLen + r, 0, pad);
        qd_qmap_write_header(base + _curLen, false, mux, plen, pad);
        [self packed:mux payload:plen frame:4 + plen + pad];
    }
    [self flushOut];
}

// Batched uplink: packs this mux's staged packets, then stages more from its utun with
// recvmsg_x, up to kULTurnPackets per turn, until it's drained or every OUT slot is busy.
- (void)uplinkBatch:(uint8_t)mux {
    qd_ul_stage *st = _stage[mux];
    if (!st || ![self canSend:mux]) return;
    for (int reads = 0;; reads++) {
        if (!qd_staged(st)) {
            if (!_ulBatch || reads * kULBatchMax >= kULTurnPackets) break;
            for (int i = 0; i < kULBatchMax; i++) {
                st->msgs[i] = (struct qd_msghdr_x){ .msg_iov = &st->iov[i], .msg_iovlen = 1 };
            }
            ssize_t r = qd_recvmsg_x(_fd[mux], st->msgs, kULBatchMax, MSG_DONTWAIT);
            _g.ul_batch_calls++;
            if (r <= 0) {
                if (r < 0 && qd_batch_unsupported(errno)) {
                    [self batchOff:[NSString stringWithFormat:@"recvmsg_x on utun: %s", strerror(errno)] downlink:NO uplink:YES];
                    [self flushOut];
                    [self uplinkReadable:mux];                  // per-packet path from here on
                    return;
                }
                break;                                          // EAGAIN: drained
            }
            st->count = (int)r;
            st->next = 0;
        }
        if (![self packStaged:mux]) return;                     // goes on from flushOut's completion
    }
    [self flushOut];
}

// Packs mux's staged packets into OUT slots. NO when the slots ran out first.
- (BOOL)packStaged:(uint8_t)mux {
    qd_ul_stage *st = _stage[mux];
    const size_t stride = kMaxPacket + 4;
    while (st->next < st->count) {
        if (![self takeSlot]) return NO;
        size_t r = st->msgs[st->next].msg_datalen;
        if (r <= 4 || r > stride) { st->next++; continue; }
        size_t plen = r - 4;
        if (_ulSize - _curLen < plen + 12 || ![self shareRoom:mux]) { [self flushOut]; continue; }
        uint8_t *base = _outBuf[_curSlot];
        memcpy(base + _curLen + 4, st->buf + (size_t)st->next * stride + 4, plen);
        uint8_t pad = qd_qmap_pad_for(plen);
        memset(base + _curLen + 4 + plen, 0, pad);
        qd_qmap_write_header(base + _curLen, false, mux, plen, pad);
        st->next++;
        [self packed:mux payload:plen frame:4 + plen + pad];
    }
    return YES;
}

// After a starved moment: staged packets don't make their utun readable again, so pack them
// here, muxes in turn (the one that ran out last time goes last).
- (void)packAllStaged {
    for (int i = 0; i < 256; i++) {
        uint8_t m = (uint8_t)(_kickFrom + i);
        if (!qd_staged(_stage[m]) || ![self canSend:m]) continue;
        if (![self packStaged:m]) { _kickFrom = (uint8_t)(m + 1); return; }
    }
    [self flushOut];
}

// Credits a finished OUT transfer's packets to their muxes, or counts them lost.
- (void)settleSlot:(int)slot sent:(BOOL)sent {
    for (int i = 0; i < _shares[slot]; i++) {
        qd_slot_share sh = _share[slot][i];
        qd_mux_stats *s = &_mux[sh.mux];
        if (sent) {
            s->tx_packets += sh.packets;
            s->tx_bytes += sh.bytes;
        } else {
            s->tx_drops += sh.packets;
        }
    }
    _shares[slot] = 0;
}

- (void)flushOut {
    int slot = _curSlot;
    if (slot < 0) return;
    size_t len = _curLen;
    _curSlot = -1;
    uint8_t *base = _outBuf[slot];
    if (len == 0) { _outFree[_outFreeCount++] = slot; return; }

    // A transfer that is an exact multiple of wMaxPacketSize would need a ZLP; grow the last
    // frame's padding by 4 bytes instead (always room: 8 spare bytes per buffer).
    if (_bulkOutMaxPacketSize && len % _bulkOutMaxPacketSize == 0) {
        uint8_t *h = base + _curLastHeader;
        uint8_t pad = (h[0] & 0x3f) + 4;
        size_t frame_len = (((size_t)h[2] << 8) | h[3]) + 4;
        memset(base + len, 0, 4);
        h[0] = (h[0] & 0xc0) | (pad & 0x3f);
        h[2] = (uint8_t)(frame_len >> 8);
        h[3] = (uint8_t)(frame_len & 0xff);
        len += 4;
    }

    NSMutableData *d = [NSMutableData dataWithBytesNoCopy:base length:len freeWhenDone:NO];
    _outSince[slot] = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if ((uint64_t)_curCount > _g.out_frames_max) _g.out_frames_max = (uint64_t)_curCount;
    BOOL ok = qd_enqueue(_outPipe, d, ^(IOReturn status, NSUInteger n) {
        (void)d;
        uint64_t waited = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - self->_outSince[slot];
        if (waited > self->_g.out_wait_max_ns) self->_g.out_wait_max_ns = waited;
        self->_outSince[slot] = 0;
        self->_outInflight -= len;
        if (status == kIOReturnSuccess) {
            self->_g.usb_out_transfers++;
            self->_g.usb_out_bytes += len;
        } else if (status != kIOReturnAborted) {
            self->_g.usb_out_errors++;
            qd_clear_stall(self->_outPipe);
        }
        // Not resent: an errored transfer may have partly reached the modem.
        [self settleSlot:slot sent:status == kIOReturnSuccess];
        self->_outFree[self->_outFreeCount++] = slot;
        if (self->_outStarved) {
            self->_outStarved = NO;
            for (int m = 0; m < 256; m++) [self updateSource:(uint8_t)m];
            [self packAllStaged];
        }
    });
    if (ok) {
        _outInflight += len;
        if (_outInflight > _g.out_inflight_max) _g.out_inflight_max = _outInflight;
    } else {
        _g.usb_out_errors++;
        _outSince[slot] = 0;
        [self settleSlot:slot sent:NO];
        _outFree[_outFreeCount++] = slot;
    }
}

- (uint64_t)oldestPendingOutMs {
    __block uint64_t oldest = 0;
    dispatch_sync(_ioQueue, ^{
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        for (int i = 0; i < kOutSlots; i++) {
            if (self->_outSince[i] && now - self->_outSince[i] > oldest) oldest = now - self->_outSince[i];
        }
    });
    return oldest / 1000000;
}

- (NSDictionary<NSNumber *, NSDictionary<NSString *, NSNumber *> *> *)statistics {
    __block NSMutableDictionary *out = [NSMutableDictionary dictionary];
    dispatch_sync(_ioQueue, ^{
        out[@0] = @{
            @"usb_in_transfers": @(self->_g.usb_in_transfers), @"usb_in_errors": @(self->_g.usb_in_errors),
            @"usb_out_transfers": @(self->_g.usb_out_transfers), @"usb_out_errors": @(self->_g.usb_out_errors),
            @"unknown_mux": @(self->_g.unknown_mux), @"bad_frames": @(self->_g.bad_frames),
            @"command_frames": @(self->_g.command_frames), @"out_starved": @(self->_g.out_starved),
            @"stale_frames": @(self->_g.stale_frames),
            @"usb_in_bytes": @(self->_g.usb_in_bytes), @"usb_out_bytes": @(self->_g.usb_out_bytes),
            @"in_full": @(self->_g.in_full), @"in_posted_now": @(self->_inPosted),
            @"in_posted_min": @(self->_g.in_posted_min), @"in_frames_max": @(self->_g.in_frames_max),
            @"out_frames_max": @(self->_g.out_frames_max), @"in_proc_max_us": @(self->_g.in_proc_max_ns / 1000),
            @"utun_batch_dl": @(self->_dlBatch), @"utun_batch_ul": @(self->_ulBatch),
            @"dl_batch_calls": @(self->_g.dl_batch_calls), @"ul_batch_calls": @(self->_g.ul_batch_calls),
            @"in_stall_tests": @(self->_g.in_stall_tests),
            @"out_wait_max_us": @(self->_g.out_wait_max_ns / 1000),
            @"out_inflight_bytes": @(self->_outInflight), @"out_inflight_max": @(self->_g.out_inflight_max),
        }.mutableCopy;
        // Window values start over after each read.
        self->_g.in_posted_min = self->_inPosted;
        self->_g.in_frames_max = 0;
        self->_g.out_frames_max = 0;
        self->_g.in_proc_max_ns = 0;
        self->_g.out_wait_max_ns = 0;
        self->_g.out_inflight_max = self->_outInflight;
        for (int m = 0; m < 256; m++) {
            if (self->_unknownByMux[m]) {
                ((NSMutableDictionary *)out[@0])[[NSString stringWithFormat:@"unknown_mux_0x%02x", m]] = @(self->_unknownByMux[m]);
            }
        }
        for (int m = 1; m < 256; m++) {
            if (self->_fd[m] < 0 && self->_mux[m].rx_packets == 0) continue;
            qd_mux_stats s = self->_mux[m];
            uint64_t fc = s.flow_disabled_total_ns + (s.flow_disabled ? now_ns() - s.flow_disabled_since_ns : 0);
            out[@(m)] = @{
                @"rx_packets": @(s.rx_packets), @"rx_bytes": @(s.rx_bytes), @"rx_drops": @(s.rx_drops),
                @"tx_packets": @(s.tx_packets), @"tx_bytes": @(s.tx_bytes), @"tx_drops": @(s.tx_drops),
                @"flow_disables": @(s.flow_disable_count), @"flow_disabled_ms": @(fc / 1000000),
                @"flow_disabled": @(s.flow_disabled),
            };
        }
    });
    return out;
}

- (void)close {
    if (_closed) return;
    _closed = YES;
    dispatch_group_t gone = dispatch_group_create();
    dispatch_sync(_ioQueue, ^{
        self->_running = NO;
        for (int m = 0; m < 256; m++) [self detachMuxLocked:(uint8_t)m group:gone];
    });
    dispatch_group_wait(gone, DISPATCH_TIME_FOREVER);
    qd_abort(_inPipe);
    qd_abort(_outPipe);
    qd_abort(_intPipe);
    qd_destroy(_iface);
    dispatch_sync(_ioQueue, ^{
        for (int i = 0; i < kOutSlots; i++) { free(self->_outBuf[i]); self->_outBuf[i] = NULL; }
    });
}

@end
