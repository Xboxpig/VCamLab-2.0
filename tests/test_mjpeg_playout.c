#include "../src/VCMJPEGPlayout.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static int compare_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static void simulate(unsigned initial_fps, int changes_rate, double outage) {
    VCMJPEGPlayoutState state = {0};
    double arrivals[8192], gaps[8192];
    size_t read = 0, write = 0, output = 0, gap_count = 0, pending = 0;
    double next_source = 0, first_output = -1, last_output = -1;
    double max_age = 0;
    for (unsigned tick = 0; tick < 30000; tick++) {
        double now = (double)tick / 1000.0;
        unsigned fps = initial_fps;
        if (changes_rate) fps = now < 8 ? 60 : (now < 16 ? 30 : 60);
        while (next_source <= now + 1e-9) {
            pending++;
            next_source += 1.0 / fps;
        }
        int blocked = outage > 0 && now >= 12 && now < 12 + outage;
        if (!blocked) {
            while (pending) {
                assert(write < sizeof(arrivals) / sizeof(arrivals[0]));
                arrivals[write++] = now;
                VCMJPEGPlayoutObserve(&state, now);
                pending--;
            }
        }
        double wait = 0;
        VCMJPEGPlayoutDecision decision = VCMJPEGPlayoutNext(
            &state, now, read < write ? arrivals[read] : 0,
            read < write ? arrivals[write - 1] : 0, write - read, false, &wait);
        if (decision == VCMJPEGPlayoutEmit) {
            if (first_output < 0) first_output = now;
            if (last_output >= 0) gaps[gap_count++] = now - last_output;
            double age = now - arrivals[read];
            if (age > max_age) max_age = age;
            last_output = now;
            read++;
            output++;
        }
    }
    assert(first_output >= 1.5 && first_output < 1.55);
    assert(output > initial_fps * 20);
    assert(gap_count > 100);
    qsort(gaps, gap_count, sizeof(gaps[0]), compare_double);
    printf("%ufps change=%d outage=%.1f p99=%.3f max=%.3f max_age=%.3f queue=%zu\n",
           initial_fps, changes_rate, outage, gaps[gap_count * 99 / 100],
           gaps[gap_count - 1], max_age, write - read);
    assert(gaps[gap_count * 99 / 100] < 0.08);
    assert(gaps[gap_count - 1] < 0.20);
    assert(max_age < 2.5);
}

int main(void) {
    VCMJPEGPlayoutState state = {0};
    double wait = 0;
    assert(VCMJPEGPlayoutNext(&state, 0.2, 0, 0, 1, false, &wait) == VCMJPEGPlayoutWait);
    assert(fabs(wait - 1.3) < 0.0001);
    assert(VCMJPEGPlayoutNext(&state, 0.2, 0, 0, 1, true, &wait) == VCMJPEGPlayoutEmit);
    state.estimated_interval = 1.0 / 30;
    assert(VCMJPEGPlayoutNext(&state, 0.3, 0, 0, 0, false, &wait) == VCMJPEGPlayoutEmpty);
    assert(state.primed && state.estimated_interval == 1.0 / 30);
    assert(VCMJPEGPlayoutNext(&state, 1.0, 1.0, 1.0, 1, false, &wait) == VCMJPEGPlayoutWait);
    assert(fabs(wait - 0.4) < 0.0001);
    simulate(30, 0, 0);
    simulate(60, 0, 0);
    simulate(60, 1, 0);
    simulate(60, 0, 0.2);
    simulate(60, 0, 0.8);
    simulate(60, 0, 1.4);
    puts("MJPEG playout tests passed");
    return 0;
}
