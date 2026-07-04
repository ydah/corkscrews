#ifndef CORKSCREWS_NATIVE_H
#define CORKSCREWS_NATIVE_H

#include "ruby.h"
#include "ruby/debug.h"
#include "ruby/thread.h"
#include "ruby/internal/event.h"

#include <stdatomic.h>
#include <stdint.h>

#define CS_RECORD_RING_SIZE 8192

typedef struct {
    _Atomic uint64_t global_delay_ns;
    _Atomic uint64_t experiment_id;
    _Atomic uintptr_t target_iseq;
    _Atomic uint32_t target_line;
    _Atomic uint32_t target_kind;
    _Atomic uint32_t speedup_pct;
    _Atomic uint64_t sample_period_ns;
    _Atomic uint64_t vclock_credit_ns;
    _Atomic uint64_t samples;
    _Atomic uint64_t target_hits;
    _Atomic uint64_t thread_events_started;
    _Atomic uint64_t thread_events_ready;
    _Atomic uint64_t thread_events_resumed;
    _Atomic uint64_t thread_events_suspended;
    _Atomic uint64_t thread_events_exited;
    _Atomic uint64_t thread_state_running;
    _Atomic uint64_t thread_state_ready;
    _Atomic uint64_t thread_state_suspended;
    _Atomic uint64_t thread_state_dead;
    _Atomic uint64_t thread_live_count;
    _Atomic uint64_t thread_max_live_count;
    _Atomic uint64_t gc_enter_count;
    _Atomic uint64_t gc_exit_count;
    _Atomic uint64_t gc_pause_ns;
    _Atomic uint64_t debt_settlements;
    _Atomic uint64_t debt_settled_ns;
    _Atomic uint64_t monitor_ticks;
    _Atomic uint64_t monitor_signals;
    _Atomic uint64_t monitor_signal_failures;
    _Atomic uint64_t monitor_start_count;
    _Atomic uint64_t monitor_stop_count;
    _Atomic uint8_t monitor_running;
    _Atomic uint8_t monitor_target_registered;
} cs_global_t;

typedef struct {
    _Atomic uint64_t local_delay_ns;
    _Atomic uint64_t inherited_stamp;
    _Atomic uint8_t state;
    _Atomic uint8_t state_initialized;
    _Atomic uint8_t settle_requested;
    _Atomic uint64_t suspended_since_id;
} cs_thread_t;

typedef struct {
    uint64_t sequence;
    uintptr_t site_key;
    uint32_t line;
    uint32_t target_kind;
    uint32_t speedup_pct;
    uint64_t experiment_id;
    uint64_t delay_ns;
    uint8_t target_hit;
} cs_record_entry_t;

extern cs_global_t cs_global;

cs_thread_t *cs_thread_data_for(VALUE thread, int create);
cs_thread_t *cs_current_thread_data(void);
uint64_t cs_settled_now_for_current_thread(void);
void cs_stamp_write(VALUE object);
void cs_stamp_inherit(VALUE object);
void cs_delay_set_experiment(uint32_t target_kind, uintptr_t target_iseq, uint32_t target_line, uint32_t speedup_pct);
void cs_delay_clear_experiment(void);
void cs_delay_issue_for_current(uint64_t delay_ns);
uint64_t cs_delay_settle_current(void);
void cs_delay_request_settle(void);
VALUE cs_record_snapshot(VALUE self);
void cs_record_line_sample(uintptr_t site_key, uint32_t line, uint8_t target_hit, uint64_t delay_ns);

#endif
