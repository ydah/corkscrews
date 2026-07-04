#include "corkscrews_native.h"

#define CS_MAX_DEPTH 64

static void
record_line_hit(uintptr_t site_key, uint32_t line)
{
    atomic_fetch_add(&cs_global.samples, 1);

    /* Paper basis: Coz SOSP'15 Section 3.4 implements virtual
     * speedups by sampling and inserting delay when the sampled line
     * matches the current experiment target.
     * Paper URL: https://arxiv.org/abs/1608.03676 */
    uint8_t hit = 0;
    uint64_t delay = 0;
    uint32_t speedup = atomic_load(&cs_global.speedup_pct);
    uint32_t kind = atomic_load(&cs_global.target_kind);
    uint32_t target_line = atomic_load(&cs_global.target_line);
    uintptr_t target_key = atomic_load(&cs_global.target_iseq);
    if (kind == 1 && speedup > 0 && line == target_line && site_key == target_key) {
        uint64_t period = atomic_load(&cs_global.sample_period_ns);
        delay = period * speedup / 100;
        hit = 1;
        atomic_fetch_add(&cs_global.target_hits, 1);
        cs_delay_issue_for_current(delay);
        cs_delay_request_settle();
    }
    cs_record_line_sample(site_key, line, hit, delay);
}

static VALUE
sampler_available_p(VALUE self)
{
    (void)self;
    return Qtrue;
}

static VALUE
sampler_sample_current(VALUE self)
{
    (void)self;
    VALUE frames[CS_MAX_DEPTH];
    int lines[CS_MAX_DEPTH];
    int n = rb_profile_frames(0, CS_MAX_DEPTH, frames, lines);
    VALUE ary = rb_ary_new_capa(n);

    atomic_fetch_add(&cs_global.samples, 1);
    if (n > 0) {
        uint8_t hit = 0;
        uint64_t delay = 0;
        uint32_t speedup = atomic_load(&cs_global.speedup_pct);
        uint32_t kind = atomic_load(&cs_global.target_kind);
        uint32_t target_line = atomic_load(&cs_global.target_line);
        uintptr_t target_key = atomic_load(&cs_global.target_iseq);
        if (kind == 1 && speedup > 0 && target_key == 0 && (uint32_t)lines[0] == target_line) {
            uint64_t period = atomic_load(&cs_global.sample_period_ns);
            delay = period * speedup / 100;
            hit = 1;
            atomic_fetch_add(&cs_global.target_hits, 1);
            cs_delay_issue_for_current(delay);
            cs_delay_request_settle();
        }
        cs_record_line_sample(0, (uint32_t)lines[0], hit, delay);
    }

    for (int i = 0; i < n; i++) {
        VALUE frame = rb_hash_new();
        rb_hash_aset(frame, ID2SYM(rb_intern("frame")), frames[i]);
        rb_hash_aset(frame, ID2SYM(rb_intern("line")), INT2NUM(lines[i]));
        rb_ary_push(ary, frame);
    }
    return ary;
}

static VALUE
sampler_record_line(VALUE self, VALUE line_value)
{
    (void)self;
    record_line_hit(0, NUM2UINT(line_value));
    return Qnil;
}

static VALUE
sampler_record_site(VALUE self, VALUE site_key_value, VALUE line_value)
{
    (void)self;
    record_line_hit((uintptr_t)NUM2ULL(site_key_value), NUM2UINT(line_value));
    return Qnil;
}

void
Init_corkscrews_sampler(VALUE rb_mCorkscrews)
{
    VALUE rb_mSampler = rb_define_module_under(rb_mCorkscrews, "Sampler");
    rb_define_singleton_method(rb_mSampler, "available?", sampler_available_p, 0);
    rb_define_singleton_method(rb_mSampler, "sample_current", sampler_sample_current, 0);
    rb_define_singleton_method(rb_mSampler, "record_line", sampler_record_line, 1);
    rb_define_singleton_method(rb_mSampler, "record_site", sampler_record_site, 2);
}
