#include "QMIDatapath.h"

#include <errno.h>
#include <fcntl.h>
#include <net/if_utun.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/kern_control.h>
#include <sys/socket.h>
#include <sys/sys_domain.h>
#include <unistd.h>

int qd_utun_open(char ifname[16]) {
    int fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (fd < 0) return -1;

    struct ctl_info info;
    memset(&info, 0, sizeof info);
    strlcpy(info.ctl_name, UTUN_CONTROL_NAME, sizeof info.ctl_name);
    if (ioctl(fd, CTLIOCGINFO, &info) < 0) goto fail;

    struct sockaddr_ctl sc;
    memset(&sc, 0, sizeof sc);
    sc.sc_len = sizeof sc;
    sc.sc_family = AF_SYSTEM;
    sc.ss_sysaddr = AF_SYS_CONTROL;
    sc.sc_id = info.ctl_id;
    sc.sc_unit = 0;                                   // kernel picks the next free utunN
    if (connect(fd, (struct sockaddr *)&sc, sizeof sc) < 0) goto fail;

    socklen_t name_len = 16;
    if (getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, ifname, &name_len) < 0) goto fail;

    int size = 4 << 20;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, sizeof size);
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, sizeof size);

    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) goto fail;
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    return fd;

fail:;
    int saved = errno;
    close(fd);
    errno = saved;
    return -1;
}

int qd_utun_set_max_pending(int fd, int packets) {
    if (setsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_MAX_PENDING_PACKETS, &packets, sizeof packets) < 0) return errno;
    return 0;
}
