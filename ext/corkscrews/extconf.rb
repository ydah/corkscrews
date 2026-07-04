# frozen_string_literal: true

require "mkmf"
require "rubygems"

required_version = Gem::Version.new("3.3")
current_version = Gem::Version.new(RUBY_VERSION)
abort "corkscrews native extension requires Ruby >= #{required_version}" if current_version < required_version

required = %w[
  rb_profile_frames
  rb_thread_call_without_gvl
  rb_add_event_hook
  rb_internal_thread_add_event_hook
  rb_internal_thread_specific_key_create
  rb_internal_thread_specific_get
  rb_internal_thread_specific_set
  rb_postponed_job_preregister
  rb_postponed_job_trigger
]

missing_required = required.reject { |name| have_func(name) }
abort "missing required Ruby C APIs: #{missing_required.join(", ")}" unless missing_required.empty?

create_makefile("corkscrews/corkscrews")
