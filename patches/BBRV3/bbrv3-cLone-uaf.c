#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define CC "bbr3"

static int fail(const char *what)
{
    fprintf(stderr, "%s: %s\n", what, strerror(errno));
    return 1;
}

int main(int argc, char **argv)
{
    int n = argc > 1 ? atoi(argv[1]) : 4;
    struct sockaddr_in sa;
    socklen_t sl = sizeof sa;
    int lfd, afd, cfd, i;

    if (n < 2)
        n = 2;

    puts("bbr3 clone-UAF repro");
    puts("needs: CONFIG_TCP_CONG_BBR3 + CONFIG_KASAN, and root");
    puts("watch in another shell: dmesg -w");
    puts("expect WITHOUT the ownership fix: KASAN double-free / slab-use-after-free");
    puts("             in bbr3_release+0x..  (kmem_cache_free of bbr3_cache)");
    puts("expect WITH the fix: no KASAN report; children fall back to Reno\n");

    lfd = socket(AF_INET, SOCK_STREAM, 0);
    if (lfd < 0)
        return fail("socket(listen)");

    if (setsockopt(lfd, IPPROTO_TCP, TCP_CONGESTION, CC, strlen(CC)) < 0) {
        fail("setsockopt(TCP_CONGESTION=" CC ") on the listener");
        if (errno == EPERM || errno == EACCES)
            fputs("hint: run as root, or add bbr3 to "
                  "net.ipv4.tcp_allowed_congestion_control\n", stderr);
        if (errno == ENOENT)
            fputs("hint: bbr3 is not registered -- wrong kernel?\n", stderr);
        return 1;
    }
    puts("step 1: listener CC set to " CC);
    puts("        -> bbr3_init() ran ON THE LISTENER, so icsk_ca_initialized=1");
    puts("           and icsk_ca_priv slot 0 holds the listener's heap ctx");

    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    sa.sin_port = 0;
    if (bind(lfd, (struct sockaddr *)&sa, sizeof sa) < 0)
        return fail("bind");
    if (listen(lfd, 64) < 0)
        return fail("listen");
    if (getsockname(lfd, (struct sockaddr *)&sa, &sl) < 0)
        return fail("getsockname");
    printf("step 2: listening on 127.0.0.1:%d\n\n", ntohs(sa.sin_port));

    for (i = 0; i < n; i++) {
        cfd = socket(AF_INET, SOCK_STREAM, 0);
        if (cfd < 0)
            return fail("socket(client)");
        if (connect(cfd, (struct sockaddr *)&sa, sizeof sa) < 0)
            return fail("connect");
        afd = accept(lfd, NULL, NULL);
        if (afd < 0)
            return fail("accept");

        printf("  conn %d accepted  -- clone copied slot 0 + icsk_ca_initialized,\n", i);
        printf("                       so tcp_init_transfer() skipped bbr3_init()\n");
        close(afd);
        close(cfd);
        printf("  conn %d closed    -- bbr3_release() freed the LISTENER's ctx%s\n",
               i, i ? " AGAIN" : "");
    }

    printf("\nstep 3: closing the listener; its ctx was already freed %d time(s)\n", n);
    close(lfd);
    puts("done -- check dmesg for a KASAN report");
    return 0;
}
