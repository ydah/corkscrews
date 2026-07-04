#include "corkscrews_native.h"

#include <time.h>

static rb_internal_thread_event_hook_t *thread_hook = NULL;
static uint64_t gc_enter_started_ns = 0;
static int gc_hooks_installed = 0;

static uint64_t
monotonic_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ((uint64_t)ts.tv_sec * 1000000000ULL) + (uint64_t)ts.tv_nsec;
}

static void
increment_state_bucket(uint8_t state)
{
    if (state == 0) atomic_fetch_add(&cs_global.thread_state_running, 1);
    else if (state == 1) atomic_fetch_add(&cs_global.thread_state_ready, 1);
    else if (state == 2) atomic_fetch_add(&cs_global.thread_state_suspended, 1);
    else atomic_fetch_add(&cs_global.thread_state_dead, 1);
}

static void
decrement_state_bucket(uint8_t state)
{
    if (state == 0) atomic_fetch_sub(&cs_global.thread_state_running, 1);
    else if (state == 1) atomic_fetch_sub(&cs_global.thread_state_ready, 1);
    else if (state == 2) atomic_fetch_sub(&cs_global.thread_state_suspended, 1);
    else atomic_fetch_sub(&cs_global.thread_state_dead, 1);
}

static void
update_max_live_threads(uint64_t live)
{
    uint64_t current = atomic_load(&cs_global.thread_max_live_count);
    while (live > current &&
           !atomic_compare_exchange_weak(&cs_global.thread_max_live_count, &current, live)) {
    }
}

static void
transition_thread_state(cs_thread_t *data, uint8_t next_state)
{
    uint8_t initialized = atomic_exchange(&data->state_initialized, 1);
    uint8_t previous = atomic_exchange(&data->state, next_state);

    if (initialized) {
        decrement_state_bucket(previous);
        if (previous != 3 && next_state == 3) {
            atomic_fetch_sub(&cs_global.thread_live_count, 1);
        }
        else if (previous == 3 && next_state != 3) {
            uint64_t live = atomic_fetch_add(&cs_global.thread_live_count, 1) + 1;
            update_max_live_threads(live);
        }
    }
    else if (next_state != 3) {
        uint64_t live = atomic_fetch_add(&cs_global.thread_live_count, 1) + 1;
        update_max_live_threads(live);
    }

    increment_state_bucket(next_state);
}

static void
thread_event_callback(rb_event_flag_t event, const rb_internal_thread_event_data_t *event_data, void *user_data)
{
    (void)user_data;
    cs_thread_t *data = cs_thread_data_for(event_data->thread, event != RUBY_INTERNAL_THREAD_EVENT_EXITED);
    if (!data) return;

    if (event == RUBY_INTERNAL_THREAD_EVENT_STARTED) {
        transition_thread_state(data, 0);
        atomic_fetch_add(&cs_global.thread_events_started, 1);
    }
    else if (event == RUBY_INTERNAL_THREAD_EVENT_READY) {
        transition_thread_state(data, 1);
        atomic_fetch_add(&cs_global.thread_events_ready, 1);
    }
    else if (event == RUBY_INTERNAL_THREAD_EVENT_RESUMED) {
        transition_thread_state(data, 0);
        atomic_fetch_add(&cs_global.thread_events_resumed, 1);
        cs_delay_request_settle();
    }
    else if (event == RUBY_INTERNAL_THREAD_EVENT_SUSPENDED) {
        transition_thread_state(data, 2);
        atomic_store(&data->suspended_since_id, atomic_load(&cs_global.experiment_id));
        atomic_fetch_add(&cs_global.thread_events_suspended, 1);
    }
    else if (event == RUBY_INTERNAL_THREAD_EVENT_EXITED) {
        transition_thread_state(data, 3);
        atomic_fetch_add(&cs_global.thread_events_exited, 1);
    }
}

static void
gc_event_hook(rb_event_flag_t event, VALUE data, VALUE self, ID mid, VALUE klass)
{
    (void)data;
    (void)self;
    (void)mid;
    (void)klass;

    if (event == RUBY_INTERNAL_EVENT_GC_ENTER) {
        gc_enter_started_ns = monotonic_ns();
        atomic_fetch_add(&cs_global.gc_enter_count, 1);
    }
    else if (event == RUBY_INTERNAL_EVENT_GC_EXIT) {
        uint64_t now = monotonic_ns();
        if (gc_enter_started_ns > 0 && now > gc_enter_started_ns) {
            uint64_t pause_ns = now - gc_enter_started_ns;
            atomic_fetch_add(&cs_global.gc_pause_ns, pause_ns);
            uint32_t speedup = atomic_load(&cs_global.speedup_pct);
            if (atomic_load(&cs_global.target_kind) == 2 && speedup > 0) {
                atomic_fetch_add(&cs_global.vclock_credit_ns, pause_ns * speedup / 100);
            }
        }
        atomic_fetch_add(&cs_global.gc_exit_count, 1);
    }
}

static VALUE
hooks_install(VALUE self)
{
    (void)self;
    if (!thread_hook) {
        thread_hook = rb_internal_thread_add_event_hook(
            thread_event_callback,
            RUBY_INTERNAL_THREAD_EVENT_MASK,
            NULL
        );
    }
    if (!gc_hooks_installed) {
        rb_add_event_hook(gc_event_hook, RUBY_INTERNAL_EVENT_GC_ENTER | RUBY_INTERNAL_EVENT_GC_EXIT, Qnil);
        gc_hooks_installed = 1;
    }
    return Qtrue;
}

static VALUE
hooks_available_p(VALUE self)
{
    (void)self;
    return Qtrue;
}

void
Init_corkscrews_hooks(VALUE rb_mCorkscrews)
{
    VALUE rb_mHooks = rb_define_module_under(rb_mCorkscrews, "Hooks");
    rb_define_singleton_method(rb_mHooks, "available?", hooks_available_p, 0);
    rb_define_singleton_method(rb_mHooks, "install!", hooks_install, 0);
}
