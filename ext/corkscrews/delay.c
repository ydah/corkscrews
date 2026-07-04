#include "corkscrews_native.h"

#include <stdlib.h>
#include <time.h>

static VALUE stamp_table;
static ID id_aref;
static ID id_aset;
static rb_postponed_job_handle_t settle_job_handle = POSTPONED_JOB_HANDLE_INVALID;
static rb_internal_thread_specific_key_t thread_key = -1;

static void *
nogvl_sleep(void *ptr)
{
    uint64_t ns = *((uint64_t *)ptr);
    struct timespec ts;
    ts.tv_sec = (time_t)(ns / 1000000000ULL);
    ts.tv_nsec = (long)(ns % 1000000000ULL);
    nanosleep(&ts, NULL);
    return NULL;
}

cs_thread_t *
cs_thread_data_for(VALUE thread, int create)
{
    if (thread_key == -1) {
        rb_raise(rb_eRuntimeError, "corkscrews delay storage is not initialized");
    }

    cs_thread_t *data = rb_internal_thread_specific_get(thread, thread_key);
    if (!data && create) {
        data = calloc(1, sizeof(cs_thread_t));
        if (!data) rb_memerror();
        atomic_store(&data->local_delay_ns, atomic_load(&cs_global.global_delay_ns));
        atomic_store(&data->inherited_stamp, 0);
        atomic_store(&data->state, 3);
        atomic_store(&data->state_initialized, 0);
        atomic_store(&data->settle_requested, 0);
        atomic_store(&data->suspended_since_id, 0);
        rb_internal_thread_specific_set(thread, thread_key, data);
    }
    return data;
}

cs_thread_t *
cs_current_thread_data(void)
{
    return cs_thread_data_for(rb_thread_current(), 1);
}

uint64_t
cs_settled_now_for_current_thread(void)
{
    cs_thread_t *data = cs_current_thread_data();
    uint64_t local = atomic_load(&data->local_delay_ns);
    uint64_t inherited = atomic_load(&data->inherited_stamp);
    return local > inherited ? local : inherited;
}

void
cs_delay_set_experiment(uint32_t target_kind, uintptr_t target_iseq, uint32_t target_line, uint32_t speedup_pct)
{
    atomic_fetch_add(&cs_global.experiment_id, 1);
    atomic_store(&cs_global.target_kind, target_kind);
    atomic_store(&cs_global.target_iseq, target_iseq);
    atomic_store(&cs_global.target_line, target_line);
    atomic_store(&cs_global.speedup_pct, speedup_pct);
}

void
cs_delay_clear_experiment(void)
{
    atomic_store(&cs_global.target_kind, 0);
}

void
cs_delay_issue_for_current(uint64_t delay_ns)
{
    /* Paper basis: Coz SOSP'15 Section 3.4 / Figure 3: a target hit
     * virtually speeds that code by charging equivalent delay to other
     * execution while crediting the thread that hit the target.
     * Paper URL: https://arxiv.org/abs/1608.03676 */
    cs_thread_t *self = cs_current_thread_data();
    atomic_fetch_add(&cs_global.global_delay_ns, delay_ns);
    atomic_fetch_add(&self->local_delay_ns, delay_ns);
}

uint64_t
cs_delay_settle_current(void)
{
    /* Paper basis: Coz SOSP'15 Section 3.4 inserts pauses for virtual
     * speedup. The CRuby adaptation pays that debt without holding GVL.
     * Paper URL: https://arxiv.org/abs/1608.03676 */
    cs_thread_t *self = cs_current_thread_data();
    uint64_t global = atomic_load(&cs_global.global_delay_ns);
    uint64_t local = atomic_load(&self->local_delay_ns);
    uint64_t inherited = atomic_load(&self->inherited_stamp);
    uint64_t settled = local > inherited ? local : inherited;
    if (global <= settled) {
        atomic_store(&self->settle_requested, 0);
        return 0;
    }

    uint64_t debt = global - settled;
    rb_thread_call_without_gvl(nogvl_sleep, &debt, RUBY_UBF_IO, NULL);
    atomic_store(&self->local_delay_ns, global);
    atomic_store(&self->settle_requested, 0);
    atomic_fetch_add(&cs_global.debt_settlements, 1);
    atomic_fetch_add(&cs_global.debt_settled_ns, debt);
    return debt;
}

static void
settle_postponed_job(void *arg)
{
    (void)arg;
    cs_delay_settle_current();
}

void
cs_delay_request_settle(void)
{
    cs_thread_t *self = cs_current_thread_data();
    if (atomic_exchange(&self->settle_requested, 1)) return;
    if (settle_job_handle != POSTPONED_JOB_HANDLE_INVALID) {
        rb_postponed_job_trigger(settle_job_handle);
    }
}

void
cs_stamp_write(VALUE object)
{
    /* Paper basis: Coz SOSP'15 Section 3.4 uses delayed execution as
     * the virtual-speedup mechanism. Stamp inheritance is the CRuby
     * synchronization adaptation that prevents double-paying delay.
     * Paper URL: https://arxiv.org/abs/1608.03676 */
    rb_funcall(stamp_table, id_aset, 2, object, ULL2NUM(cs_settled_now_for_current_thread()));
}

void
cs_stamp_inherit(VALUE object)
{
    VALUE stored = rb_funcall(stamp_table, id_aref, 1, object);
    if (NIL_P(stored)) return;

    cs_thread_t *self = cs_current_thread_data();
    uint64_t stamp = NUM2ULL(stored);
    uint64_t inherited = atomic_load(&self->inherited_stamp);
    if (stamp > inherited) {
        atomic_store(&self->inherited_stamp, stamp);
    }
}

static VALUE
delay_available_p(VALUE self)
{
    (void)self;
    return Qtrue;
}

static VALUE
delay_set_experiment(VALUE self, VALUE kind, VALUE iseq, VALUE line, VALUE speedup)
{
    (void)self;
    cs_delay_set_experiment(NUM2UINT(kind), (uintptr_t)NUM2ULL(iseq), NUM2UINT(line), NUM2UINT(speedup));
    return Qnil;
}

static VALUE
delay_set_sample_period(VALUE self, VALUE period_ns)
{
    (void)self;
    atomic_store(&cs_global.sample_period_ns, NUM2ULL(period_ns));
    return Qnil;
}

static VALUE
delay_clear_experiment(VALUE self)
{
    (void)self;
    cs_delay_clear_experiment();
    return Qnil;
}

static VALUE
delay_settle_current(VALUE self)
{
    (void)self;
    return ULL2NUM(cs_delay_settle_current());
}

static VALUE
delay_request_settle(VALUE self)
{
    (void)self;
    cs_delay_request_settle();
    return Qnil;
}

static VALUE
delay_debt_current(VALUE self)
{
    (void)self;
    uint64_t global = atomic_load(&cs_global.global_delay_ns);
    uint64_t settled = cs_settled_now_for_current_thread();
    return ULL2NUM(global > settled ? global - settled : 0);
}

static VALUE
delay_settled_now(VALUE self)
{
    (void)self;
    return ULL2NUM(cs_settled_now_for_current_thread());
}

static VALUE
delay_stamp_write(VALUE self, VALUE object)
{
    (void)self;
    cs_stamp_write(object);
    return Qnil;
}

static VALUE
delay_stamp_inherit(VALUE self, VALUE object)
{
    (void)self;
    cs_stamp_inherit(object);
    return Qnil;
}

void
Init_corkscrews_delay(VALUE rb_mCorkscrews)
{
    VALUE rb_mDelay = rb_define_module_under(rb_mCorkscrews, "Delay");
    VALUE rb_mObjectSpace = rb_const_get(rb_cObject, rb_intern("ObjectSpace"));
    VALUE rb_cWeakMap = rb_const_get(rb_mObjectSpace, rb_intern("WeakMap"));

    if (thread_key == -1) {
        thread_key = rb_internal_thread_specific_key_create();
    }

    id_aref = rb_intern("[]");
    id_aset = rb_intern("[]=");
    stamp_table = rb_funcall(rb_cWeakMap, rb_intern("new"), 0);
    rb_global_variable(&stamp_table);
    settle_job_handle = rb_postponed_job_preregister(0, settle_postponed_job, NULL);

    rb_define_singleton_method(rb_mDelay, "available?", delay_available_p, 0);
    rb_define_singleton_method(rb_mDelay, "set_experiment", delay_set_experiment, 4);
    rb_define_singleton_method(rb_mDelay, "set_sample_period", delay_set_sample_period, 1);
    rb_define_singleton_method(rb_mDelay, "clear_experiment", delay_clear_experiment, 0);
    rb_define_singleton_method(rb_mDelay, "settle_current", delay_settle_current, 0);
    rb_define_singleton_method(rb_mDelay, "request_settle", delay_request_settle, 0);
    rb_define_singleton_method(rb_mDelay, "debt_current", delay_debt_current, 0);
    rb_define_singleton_method(rb_mDelay, "settled_now", delay_settled_now, 0);
    rb_define_singleton_method(rb_mDelay, "stamp_write", delay_stamp_write, 1);
    rb_define_singleton_method(rb_mDelay, "stamp_inherit", delay_stamp_inherit, 1);
}
