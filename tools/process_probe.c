// Copyright 2026 Кислов Роман Сергеевич
// SPDX-License-Identifier: Apache-2.0

// macOS process counters. Build: clang -O2 tools/process_probe.c -o build/process_probe
#include <libproc.h>
#include <mach/mach_time.h>
#include <sys/resource.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: process_probe PID [duration_seconds] [interval_seconds]\n"); return 2; }
    int pid = atoi(argv[1]);
    int duration = argc > 2 ? atoi(argv[2]) : 60;
    int interval = argc > 3 ? atoi(argv[3]) : 5;
    if (pid <= 0 || duration < 0 || interval <= 0) return 2;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    for (int elapsed = 0; elapsed <= duration; elapsed += interval) {
        struct rusage_info_v6 r = {0};
        int flavor = RUSAGE_INFO_V6;
        if (proc_pid_rusage(pid, flavor, (rusage_info_t *)&r) != 0) {
            memset(&r, 0, sizeof(r)); flavor = RUSAGE_INFO_V4;
            if (proc_pid_rusage(pid, flavor, (rusage_info_t *)&r) != 0) { perror("proc_pid_rusage"); return 1; }
        }
        struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
        printf("{\"monotonic_s\":%.9f,\"pid\":%d,\"flavor\":%d,\"cpu_ns\":%llu,\"rss_bytes\":%llu,\"footprint_bytes\":%llu,\"idle_wakeups\":%llu,\"interrupt_wakeups\":%llu,\"energy_nj\":%llu,\"billed_energy\":%llu,\"disk_write_bytes\":%llu}\n",
            now.tv_sec + now.tv_nsec / 1e9, pid, flavor,
            (unsigned long long)((unsigned __int128)(r.ri_user_time + r.ri_system_time) * timebase.numer / timebase.denom),
            (unsigned long long)r.ri_resident_size, (unsigned long long)r.ri_phys_footprint,
            (unsigned long long)r.ri_pkg_idle_wkups, (unsigned long long)r.ri_interrupt_wkups,
            (unsigned long long)r.ri_energy_nj, (unsigned long long)r.ri_billed_energy,
            (unsigned long long)r.ri_diskio_byteswritten);
        fflush(stdout);
        if (elapsed + interval <= duration) sleep(interval);
    }
}
