#include "ruby.h"
#include "corkscrews_native.h"

cs_global_t cs_global;

void Init_corkscrews_hooks(VALUE rb_mCorkscrews);
void Init_corkscrews_sampler(VALUE rb_mCorkscrews);
void Init_corkscrews_delay(VALUE rb_mCorkscrews);
void Init_corkscrews_record(VALUE rb_mCorkscrews);
void Init_corkscrews_monitor(VALUE rb_mCorkscrews);

void
Init_corkscrews(void)
{
    VALUE rb_mCorkscrews = rb_define_module("Corkscrews");
    VALUE rb_mNativeExtension = rb_define_module_under(rb_mCorkscrews, "NativeExtension");
    atomic_store(&cs_global.sample_period_ns, 1000000ULL);
    rb_define_const(rb_mNativeExtension, "AVAILABLE", Qtrue);
    Init_corkscrews_hooks(rb_mCorkscrews);
    Init_corkscrews_sampler(rb_mCorkscrews);
    Init_corkscrews_delay(rb_mCorkscrews);
    Init_corkscrews_record(rb_mCorkscrews);
    Init_corkscrews_monitor(rb_mCorkscrews);
}
