#ifndef QMIDATAPATH_H
#define QMIDATAPATH_H

// Hot path of qmi-darwin (PLAN.md §2, §6): the QMI interface's USB pipes, QMAP framing and
// the utun fds. Swift sees only this header; nothing here exposes IOUSBHost types.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// MARK: - QMAP (pure C, unit-tested)

typedef struct {
    uint8_t mux_id;
    bool is_command;
    const uint8_t *_Nullable payload;   // points into the buffer; padding already stripped
    size_t payload_len;
} qd_qmap_frame;

typedef enum {
    QD_QMAP_OK = 0,
    QD_QMAP_END = 1,          // no more frames (end of buffer or zero filler)
    QD_QMAP_TRUNCATED = 2,    // header or payload runs past the buffer
    QD_QMAP_BAD = 3           // pad longer than the frame
} qd_qmap_status;

// Parses the frame at buf + *offset and advances *offset past header, payload and pad.
qd_qmap_status qd_qmap_next(const uint8_t *_Nonnull buf, size_t len, size_t *_Nonnull offset, qd_qmap_frame *_Nonnull out);

// Writes a QMAP header for payload_len bytes followed by pad zero bytes.
void qd_qmap_write_header(uint8_t hdr[_Nonnull 4], bool command, uint8_t mux_id, size_t payload_len, uint8_t pad);

static inline uint8_t qd_qmap_pad_for(size_t payload_len) {
    return (uint8_t)((4 - (payload_len & 3)) & 3);
}

// MARK: - utun

// Creates a utun interface; returns its non-blocking control socket or -1 with errno set.
// ifname receives the interface name (e.g. "utun9").
int qd_utun_open(char ifname[_Nonnull 16]);

// UTUN_OPT_MAX_PENDING_PACKETS; returns 0 or an errno value.
int qd_utun_set_max_pending(int fd, int packets);

// MARK: - Modem

#ifdef __OBJC__
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const QDErrorDomain;

@interface QDModem : NSObject

// Opens the first interface of vendorID with class ff/ff/ff, or exactly interfaceNumber if >= 0.
+ (nullable instancetype)openWithVendorID:(uint16_t)vendorID
                          interfaceNumber:(NSInteger)interfaceNumber
                                    error:(NSError **)error;

@property (readonly) uint8_t interfaceNumber;
@property (readonly) uint16_t vendorID;
@property (readonly) uint16_t productID;
@property (readonly) uint8_t bulkInAddress;
@property (readonly) uint8_t bulkOutAddress;
@property (readonly) uint8_t interruptAddress;
@property (readonly) NSUInteger bulkInMaxPacketSize;
@property (readonly) NSUInteger bulkOutMaxPacketSize;

// Called once, on an internal queue, when the interface goes away (unplug, modem reset).
@property (nullable, copy) void (^terminationHandler)(void);

// MARK: Control plane: CDC SEND/GET_ENCAPSULATED on EP0, RESPONSE_AVAILABLE on the interrupt pipe.

- (BOOL)sendEncapsulatedCommand:(NSData *)message error:(NSError **)error;

// Starts listening for responses; handler runs on an internal serial queue, one QMUX message each.
- (BOOL)startControlChannel:(void (^)(NSData *message))handler error:(NSError **)error;

// MARK: Datapath

// downlinkSize: granted DL aggregation size (bytes per bulk IN transfer).
// uplinkSize/uplinkDatagrams: granted UL aggregation; 0 means no UL aggregation.
- (BOOL)startDatapathWithDownlinkSize:(NSUInteger)downlinkSize
                           uplinkSize:(NSUInteger)uplinkSize
                      uplinkDatagrams:(NSUInteger)uplinkDatagrams
                                error:(NSError **)error;

// Batched utun I/O (private sendmsg_x/recvmsg_x: one system call per IN transfer downlink, up to
// 32 packets per read uplink). Set before starting the datapath. Falls back to one write/read
// per packet by itself when the calls are missing or the kernel rejects them, per direction;
// batchFallbackHandler (datapath queue) says why. Counters: utun_batch_dl/_ul, *_batch_calls.
@property BOOL batchUtunIO;
@property (nullable, copy) void (^batchFallbackHandler)(NSString *reason);

// Routes mux muxID to/from a utun fd from qd_utun_open. The fd stays owned by the caller;
// close it only after detachMux (or close) returns, which waits for the fd's read source to go.
// Not to be called from the datapath queue (handlers).
- (void)attachMux:(uint8_t)muxID fd:(int)fd;
- (void)detachMux:(uint8_t)muxID;

// Applies a QMAP flow-disable/enable to muxID as if the modem had sent it (no ACK, no
// commandFrameHandler), for testing uplink backpressure on firmware that never sends one.
- (void)simulateFlowControl:(BOOL)disabled mux:(uint8_t)muxID;

// Clears a stall on the bulk IN pipe as the error path does, aborting every posted read; they
// must all be re-posted (in_posted_now back to 32). Counted in in_stall_tests.
- (void)simulateInStall;

// Per-mux counters keyed by mux ID, plus key 0 for datapath-wide counters. tx_packets/tx_bytes
// count packets in completed OUT transfers; tx_drops those in failed or unsubmitted transfers
// and those still staged when the mux detached. usb_out_bytes likewise counts completed bytes.
- (NSDictionary<NSNumber *, NSDictionary<NSString *, NSNumber *> *> *)statistics;
// Age in ms of the oldest bulk OUT transfer the modem hasn't completed (0 if none in flight).
// A modem whose data path hung keeps USB up but never completes them.
- (uint64_t)oldestPendingOutMs;

// QMAP command frames seen on the downlink (after flow control has been applied).
@property (nullable, copy) void (^commandFrameHandler)(uint8_t muxID, uint8_t command, uint8_t type);

- (void)close;

@end

NS_ASSUME_NONNULL_END

#endif // __OBJC__

#endif
