#include "corkscrews_native.h"

#include <pthread.h>
#include <signal.h>
#include <time.h>

static pthread_t monitor_thread;
static pthread_t target_thread;
static _Atomic int monitor_thread_started;

static void
sleep_for_sample_period(void)
{
    uint64_t ns = atomic_load(&cs_global.sample_period_ns);
    if (ns == 0) ns = 1000000ULL;

    struct timespec ts;
    ts.tv_sec = (time_t)(ns / 1000000000ULL);
    ts.tv_nsec = (long)(ns % 1000000000ULL);
    nanosleep(&ts, NULL);
}

static void *
monitor_loop(void *arg)
{
    (void)arg;
    while (atomic_load(&cs_global.monitor_running)) {
        sleep_for_sample_period();
        atomic_fetch_add(&cs_global.monitor_ticks, 1);
        if (atomic_load(&cs_global.monitor_target_registered)) {
            if (pthread_kill(target_thread, SIGPROF) == 0) {
                atomic_fetch_add(&cs_global.monitor_signals, 1);
            }
            else {
                atomic_fetch_add(&cs_global.monitor_signal_failures, 1);
            }
        }
    }
    return NULL;
}

static VALUE
monitor_register_current_thread(VALUE self)
{
    (void)self;
    target_thread = pthread_self();
    atomic_store(&cs_global.monitor_target_registered, 1);
    return Qtrue;
}

static VALUE
monitor_clear_current_thread(VALUE self)
{
    (void)self;
    atomic_store(&cs_global.monitor_target_registered, 0);
    return Qtrue;
}

static VALUE
monitor_start(VALUE self)
{
    (void)self;
    if (atomic_exchange(&cs_global.monitor_running, 1)) {
        return Qfalse;
    }

    if (pthread_create(&monitor_thread, NULL, monitor_loop, NULL) != 0) {
        atomic_store(&cs_global.monitor_running, 0);
        rb_raise(rb_eRuntimeError, "failed to start corkscrews monitor thread");
    }

    atomic_store(&monitor_thread_started, 1);
    atomic_fetch_add(&cs_global.monitor_start_count, 1);
    return Qtrue;
}

static VALUE
monitor_stop(VALUE self)
{
    (void)self;
    if (!atomic_exchange(&cs_global.monitor_running, 0)) {
        return Qfalse;
    }

    if (atomic_exchange(&monitor_thread_started, 0)) {
        pthread_join(monitor_thread, NULL);
    }

    atomic_fetch_add(&cs_global.monitor_stop_count, 1);
    return Qtrue;
}

static VALUE
monitor_running_p(VALUE self)
{
    (void)self;
    return atomic_load(&cs_global.monitor_running) ? Qtrue : Qfalse;
}

static VALUE
monitor_available_p(VALUE self)
{
    (void)self;
    return Qtrue;
}

void
Init_corkscrews_monitor(VALUE rb_mCorkscrews)
{
    VALUE rb_mMonitor = rb_define_module_under(rb_mCorkscrews, "Monitor");
    rb_define_singleton_method(rb_mMonitor, "available?", monitor_available_p, 0);
    rb_define_singleton_method(rb_mMonitor, "register_current_thread!", monitor_register_current_thread, 0);
    rb_define_singleton_method(rb_mMonitor, "clear_current_thread!", monitor_clear_current_thread, 0);
    rb_define_singleton_method(rb_mMonitor, "start!", monitor_start, 0);
    rb_define_singleton_method(rb_mMonitor, "stop!", monitor_stop, 0);
    rb_define_singleton_method(rb_mMonitor, "running?", monitor_running_p, 0);
}
