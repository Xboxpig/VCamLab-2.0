#ifndef VC_MJPEG_PLAYOUT_H
#define VC_MJPEG_PLAYOUT_H

#include <stdbool.h>
#include <stddef.h>

typedef struct {
    bool primed;
    bool has_started;
    bool memory_limited;
    double next_time;
    double last_interval;
    double arrival_window_start;
    size_t arrival_window_count;
    double estimated_interval;
    unsigned changed_rate_windows;
    int changed_rate_direction;
} VCMJPEGPlayoutState;

typedef enum {
    VCMJPEGPlayoutEmpty = 0,
    VCMJPEGPlayoutWait = 1,
    VCMJPEGPlayoutEmit = 2,
} VCMJPEGPlayoutDecision;

static inline void VCMJPEGPlayoutReset(VCMJPEGPlayoutState *state) {
    *state = (VCMJPEGPlayoutState){0};
}

// Estimate sender cadence separately from queue depth. A short gap or a burst
// should not immediately change playout speed; sustained rate changes relock.
static inline void VCMJPEGPlayoutObserve(VCMJPEGPlayoutState *state, double now) {
    if (state->arrival_window_count == 0) {
        state->arrival_window_start = now;
        state->arrival_window_count = 1;
        return;
    }
    state->arrival_window_count++;
    double elapsed = now - state->arrival_window_start;
    if (elapsed < 0.5) return;
    double rate = (double)(state->arrival_window_count - 1) / elapsed;
    if (rate >= 1.0 && rate <= 240.0) {
        double measured = 1.0 / rate;
        if (state->estimated_interval <= 0) {
            state->estimated_interval = measured;
        } else {
            double ratio = measured / state->estimated_interval;
            if (ratio < 0.75 || ratio > 1.25) {
                int direction = ratio > 1.0 ? 1 : -1;
                if (state->changed_rate_direction != direction) {
                    state->changed_rate_direction = direction;
                    state->changed_rate_windows = 0;
                }
                if (++state->changed_rate_windows >= 2) {
                    state->estimated_interval = measured;
                    state->last_interval = measured;
                    state->changed_rate_windows = 0;
                    state->changed_rate_direction = 0;
                }
            } else {
                state->changed_rate_windows = 0;
                state->changed_rate_direction = 0;
                double minimum = state->estimated_interval * 0.98;
                double maximum = state->estimated_interval * 1.02;
                if (measured < minimum) measured = minimum;
                if (measured > maximum) measured = maximum;
                state->estimated_interval = state->estimated_interval * 0.8 + measured * 0.2;
            }
        }
    }
    state->arrival_window_start = now;
    state->arrival_window_count = 1;
}

// Arrival timestamps and now use the same monotonic clock. Prime for 1.5 s,
// then smooth the measured frame interval so network bursts do not determine
// the display cadence directly.
static inline VCMJPEGPlayoutDecision VCMJPEGPlayoutNext(
    VCMJPEGPlayoutState *state, double now, double oldest, double newest,
    size_t count, bool force_start, double *wait_seconds) {
    if (wait_seconds) *wait_seconds = 0;
    if (count == 0) {
        return VCMJPEGPlayoutEmpty;
    }
    if (force_start) state->memory_limited = true;
    // A short empty queue need not discard the learned sender cadence.  If
    // data arrives well after its deadline, build a smaller recovery reserve.
    if (state->primed && state->next_time > 0 && now - state->next_time > 0.2)
        state->primed = false;
    if (!state->primed) {
        double reserve = state->has_started ? 0.4 : 1.5;
        double remaining = oldest + reserve - now;
        if (!force_start && remaining > 0) {
            if (wait_seconds) *wait_seconds = remaining;
            return VCMJPEGPlayoutWait;
        }
        state->primed = true;
        state->has_started = true;
        state->memory_limited = force_start;
        state->next_time = now;
    }
    if (state->next_time > now) {
        if (wait_seconds) *wait_seconds = state->next_time - now;
        return VCMJPEGPlayoutWait;
    }
    double measured = state->estimated_interval > 0 ? state->estimated_interval :
        (state->last_interval > 0 ? state->last_interval : 1.0 / 30.0);
    if (state->estimated_interval <= 0 && count > 1 && newest > oldest)
        measured = (newest - oldest) / (double)(count - 1);
    if (measured < 1.0 / 120.0) measured = 1.0 / 120.0;
    if (measured > 1.0 / 5.0) measured = 1.0 / 5.0;
    double interval = state->last_interval > 0
        ? state->last_interval * 0.98 + measured * 0.02 : measured;
    state->last_interval = interval;
    double age = now - oldest;
    if (state->memory_limited && age >= 1.4) state->memory_limited = false;
    if (age > 1.8) interval *= 0.98;
    else if (!state->memory_limited && age < 1.2) interval *= 1.02;
    // Anchor deadlines to the previous deadline so timer wake-up latency
    // does not slowly drain the buffer or increase the end-to-end delay.
    double next = state->next_time + interval;
    state->next_time = next < now - interval ? now + interval : next;
    return VCMJPEGPlayoutEmit;
}

#endif
