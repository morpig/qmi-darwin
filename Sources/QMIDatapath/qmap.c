#include "QMIDatapath.h"

#include <string.h>

// QMAP v1 header: [C/D:1 | reserved:1 | pad:6] [mux id] [length, big-endian, incl. pad]

qd_qmap_status qd_qmap_next(const uint8_t *buf, size_t len, size_t *offset, qd_qmap_frame *out) {
    size_t off = *offset;
    if (off >= len) return QD_QMAP_END;
    if (len - off < 4) {
        // Trailing zero filler shorter than a header is not an error.
        for (size_t i = off; i < len; i++) if (buf[i]) return QD_QMAP_TRUNCATED;
        return QD_QMAP_END;
    }

    const uint8_t *h = buf + off;
    size_t frame_len = ((size_t)h[2] << 8) | h[3];
    if (frame_len == 0 && h[0] == 0 && h[1] == 0) return QD_QMAP_END;
    if (frame_len > len - off - 4) return QD_QMAP_TRUNCATED;

    uint8_t pad = h[0] & 0x3f;
    if (pad > frame_len) return QD_QMAP_BAD;

    out->is_command = (h[0] & 0x80) != 0;
    out->mux_id = h[1];
    out->payload = h + 4;
    out->payload_len = frame_len - pad;
    *offset = off + 4 + frame_len;
    return QD_QMAP_OK;
}

void qd_qmap_write_header(uint8_t hdr[4], bool command, uint8_t mux_id, size_t payload_len, uint8_t pad) {
    size_t frame_len = payload_len + pad;
    hdr[0] = (uint8_t)((command ? 0x80 : 0x00) | (pad & 0x3f));
    hdr[1] = mux_id;
    hdr[2] = (uint8_t)(frame_len >> 8);
    hdr[3] = (uint8_t)(frame_len & 0xff);
}
