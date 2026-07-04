#include "corkscrews_native.h"

static cs_record_entry_t record_ring[CS_RECORD_RING_SIZE];
static _Atomic uint64_t record_head;
static _Atomic uint64_t record_dropped;

void
cs_record_line_sample(uintptr_t site_key, uint32_t line, uint8_t target_hit, uint64_t delay_ns)
{
    uint64_t sequence = atomic_fetch_add(&record_head, 1);
    if (sequence >= CS_RECORD_RING_SIZE) {
        atomic_fetch_add(&record_dropped, 1);
    }

    cs_record_entry_t *entry = &record_ring[sequence % CS_RECORD_RING_SIZE];
    entry->site_key = site_key;
    entry->line = line;
    entry->target_kind = atomic_load(&cs_global.target_kind);
    entry->speedup_pct = atomic_load(&cs_global.speedup_pct);
    entry->experiment_id = atomic_load(&cs_global.experiment_id);
    entry->delay_ns = delay_ns;
    entry->target_hit = target_hit;
    entry->sequence = sequence;
}

VALUE
cs_record_snapshot(VALUE self)
{
    (void)self;
    VALUE hash = rb_hash_new();
    rb_hash_aset(hash, ID2SYM(rb_intern("global_delay_ns")), ULL2NUM(atomic_load(&cs_global.global_delay_ns)));
    rb_hash_aset(hash, ID2SYM(rb_intern("experiment_id")), ULL2NUM(atomic_load(&cs_global.experiment_id)));
    rb_hash_aset(hash, ID2SYM(rb_intern("target_kind")), UINT2NUM(atomic_load(&cs_global.target_kind)));
    rb_hash_aset(hash, ID2SYM(rb_intern("target_iseq")), ULL2NUM(atomic_load(&cs_global.target_iseq)));
    rb_hash_aset(hash, ID2SYM(rb_intern("target_line")), UINT2NUM(atomic_load(&cs_global.target_line)));
    rb_hash_aset(hash, ID2SYM(rb_intern("speedup_pct")), UINT2NUM(atomic_load(&cs_global.speedup_pct)));
    rb_hash_aset(hash, ID2SYM(rb_intern("vclock_credit_ns")), ULL2NUM(atomic_load(&cs_global.vclock_credit_ns)));
    rb_hash_aset(hash, ID2SYM(rb_intern("samples")), ULL2NUM(atomic_load(&cs_global.samples)));
    rb_hash_aset(hash, ID2SYM(rb_intern("target_hits")), ULL2NUM(atomic_load(&cs_global.target_hits)));
    rb_hash_aset(hash, ID2SYM(rb_intern("thread_events_started")), ULL2NUM(atomic_load(&cs_global.thread_events_started)));
    rb_hash_aset(hash, ID2SYM(rb_intern("thread_events_ready")), ULL2NUM(atomic_load(&cs_global.thread_events_ready)));
    rb_hash_aset(hash, ID2SYM(rb_intern("thread_events_resumed")), ULL2NUM(atomic_load(&cs_global.thread_events_resumed)));
    rb_hash_aset(hash, ID2SYM(rb_intern("thread_events_suspended")), ULL2NUM(atomic_load(&cs_global.thread_events_suspended)));
    rb_hash_aset(hash, ID2SYM(rb_intern("thread_events_exited")), ULL2NUM(atomic_load(&cs_global.thread_events_exited)));
    rb_hash_aset(hash, ID2SYM(rb_intern("thread_state_running")), ULL2NUM(atomic_load(&cs_global.thread_state_running)));
    rb_hash_aset(hash, ID2SYM(rb_intern("thread_state_ready")), ULL2NUM(atomic_load(&cs_global.thread_state_ready)));
    rb_hash_aset(hash, ID2SYM(rb_intern("thread_state_suspended")), ULL2NUM(atomic_load(&cs_global.thread_state_suspended)));
    rb_hash_aset(hash, ID2SYM(rb_intern("thread_state_dead")), ULL2NUM(atomic_load(&cs_global.thread_state_dead)));
    rb_hash_aset(hash, ID2SYM(rb_intern("thread_live_count")), ULL2NUM(atomic_load(&cs_global.thread_live_count)));
    rb_hash_aset(hash, ID2SYM(rb_intern("thread_max_live_count")), ULL2NUM(atomic_load(&cs_global.thread_max_live_count)));
    rb_hash_aset(hash, ID2SYM(rb_intern("gc_enter_count")), ULL2NUM(atomic_load(&cs_global.gc_enter_count)));
    rb_hash_aset(hash, ID2SYM(rb_intern("gc_exit_count")), ULL2NUM(atomic_load(&cs_global.gc_exit_count)));
    rb_hash_aset(hash, ID2SYM(rb_intern("gc_pause_ns")), ULL2NUM(atomic_load(&cs_global.gc_pause_ns)));
    rb_hash_aset(hash, ID2SYM(rb_intern("debt_settlements")), ULL2NUM(atomic_load(&cs_global.debt_settlements)));
    rb_hash_aset(hash, ID2SYM(rb_intern("debt_settled_ns")), ULL2NUM(atomic_load(&cs_global.debt_settled_ns)));
    rb_hash_aset(hash, ID2SYM(rb_intern("monitor_ticks")), ULL2NUM(atomic_load(&cs_global.monitor_ticks)));
    rb_hash_aset(hash, ID2SYM(rb_intern("monitor_signals")), ULL2NUM(atomic_load(&cs_global.monitor_signals)));
    rb_hash_aset(hash, ID2SYM(rb_intern("monitor_signal_failures")), ULL2NUM(atomic_load(&cs_global.monitor_signal_failures)));
    rb_hash_aset(hash, ID2SYM(rb_intern("monitor_start_count")), ULL2NUM(atomic_load(&cs_global.monitor_start_count)));
    rb_hash_aset(hash, ID2SYM(rb_intern("monitor_stop_count")), ULL2NUM(atomic_load(&cs_global.monitor_stop_count)));
    rb_hash_aset(hash, ID2SYM(rb_intern("monitor_running")), atomic_load(&cs_global.monitor_running) ? Qtrue : Qfalse);
    rb_hash_aset(hash, ID2SYM(rb_intern("monitor_target_registered")), atomic_load(&cs_global.monitor_target_registered) ? Qtrue : Qfalse);
    rb_hash_aset(hash, ID2SYM(rb_intern("record_ring_size")), UINT2NUM(CS_RECORD_RING_SIZE));
    rb_hash_aset(hash, ID2SYM(rb_intern("record_head")), ULL2NUM(atomic_load(&record_head)));
    rb_hash_aset(hash, ID2SYM(rb_intern("record_dropped")), ULL2NUM(atomic_load(&record_dropped)));
    return hash;
}

static VALUE
record_events(VALUE self)
{
    (void)self;
    uint64_t head = atomic_load(&record_head);
    uint64_t start = head > CS_RECORD_RING_SIZE ? head - CS_RECORD_RING_SIZE : 0;
    VALUE ary = rb_ary_new_capa((long)(head - start));

    for (uint64_t sequence = start; sequence < head; sequence++) {
        cs_record_entry_t *entry = &record_ring[sequence % CS_RECORD_RING_SIZE];
        if (entry->sequence != sequence) continue;

        VALUE hash = rb_hash_new();
        rb_hash_aset(hash, ID2SYM(rb_intern("sequence")), ULL2NUM(entry->sequence));
        rb_hash_aset(hash, ID2SYM(rb_intern("site_key")), ULL2NUM(entry->site_key));
        rb_hash_aset(hash, ID2SYM(rb_intern("line")), UINT2NUM(entry->line));
        rb_hash_aset(hash, ID2SYM(rb_intern("target_kind")), UINT2NUM(entry->target_kind));
        rb_hash_aset(hash, ID2SYM(rb_intern("speedup_pct")), UINT2NUM(entry->speedup_pct));
        rb_hash_aset(hash, ID2SYM(rb_intern("experiment_id")), ULL2NUM(entry->experiment_id));
        rb_hash_aset(hash, ID2SYM(rb_intern("delay_ns")), ULL2NUM(entry->delay_ns));
        rb_hash_aset(hash, ID2SYM(rb_intern("target_hit")), entry->target_hit ? Qtrue : Qfalse);
        rb_ary_push(ary, hash);
    }
    return ary;
}

static VALUE
record_available_p(VALUE self)
{
    (void)self;
    return Qtrue;
}

void
Init_corkscrews_record(VALUE rb_mCorkscrews)
{
    VALUE rb_mRecord = rb_define_module_under(rb_mCorkscrews, "Record");
    rb_define_singleton_method(rb_mRecord, "available?", record_available_p, 0);
    rb_define_singleton_method(rb_mRecord, "snapshot", cs_record_snapshot, 0);
    rb_define_singleton_method(rb_mRecord, "events", record_events, 0);
}
