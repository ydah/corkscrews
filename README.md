# Corkscrews

Corkscrews is a Ruby causal-profiling toolkit for bottleneck experiments. It
records progress points, line samples, latency spans, Ruby-level wait targets,
and validation benchmark results, then reports virtual speedup curves for likely
bottlenecks.

The gem includes a portable Ruby engine and a native CRuby extension for thread
hooks, GC hooks, delay accounting, sampling handoff, stamp inheritance, native
monitor ticks, native sample ring flushes, thread-state gauges, adaptive
line/wait experiment rounds, and runtime snapshots.

## Installation

Install the gem and add it to the application's Gemfile by executing:

```sh
bundle add corkscrews
```

If Bundler is not being used to manage dependencies, install the gem by
executing:

```sh
gem install corkscrews
```

Corkscrews requires CRuby 3.3 or newer. The native extension is compiled during
installation when the required CRuby APIs are available; otherwise the Ruby
engine remains the portable fallback.

## Usage

Profile an existing Ruby command with the CLI:

```sh
corkscrews run --repeat 3 --targets both --output run.corkscrews.ndjson -- ruby app.rb
```

Generate reports from the recorded NDJSON file:

```sh
corkscrews report --html report.html --firefox profile.json run.corkscrews.ndjson
```

`--firefox` writes an aggregate Firefox Profiler JSON with thread, sample,
stack, frame, function, marker, and string tables. It includes target summary
markers and round timeline markers derived from Corkscrews' NDJSON records.

### Progress Points

Application code can provide throughput and latency points:

```ruby
require "corkscrews"

Corkscrews.latency_begin(:request)
do_work
Corkscrews.progress(:request)
Corkscrews.latency_end(:request)
```

`--targets lines` records line targets. `--targets waits` or `--targets both`
also enables Ruby-level wrappers for `Mutex`, `Thread::Queue`,
`Thread::SizedQueue`, `Thread::ConditionVariable`, `Kernel.sleep`, and `IO`.

### Native Signal Source

The default signal source is Ruby's `setitimer` path. The native monitor can
deliver `SIGPROF` to the registered profiling thread by setting
`CORKSCREWS_NATIVE_SIGNALS=1`; this path is recorded in native counters and kept
opt-in because direct pthread signal delivery can conflict with platform signal
handling in embedded Ruby processes.

## Validation

Run the bundled validation harness:

```sh
corkscrews validate --quick
corkscrews validate
```

The validation harness includes benchmark manifests for serial CPU hotspots,
false hotspots under concurrency, I/O wait, lock contention, GVL contention, GC
pressure, queue pipeline behavior, and native-call attribution smoke coverage.

## Development

After checking out the repo, install dependencies:

```sh
bundle install
```

Compile the native extension and run the test suite:

```sh
bundle exec rake compile
bundle exec rake
```

Install the gem locally from the checkout:

```sh
bundle exec rake install
```

Run validation locally:

```sh
ruby -Ilib exe/corkscrews validate --quick
ruby -Ilib exe/corkscrews validate
python3 validate/harness/stats_check.py
```

For local CLI testing without installing the gem, use:

```sh
ruby -Ilib exe/corkscrews run --repeat 1 --output run.corkscrews.ndjson -- ruby app.rb
```

## Contributing

Bug reports and pull requests are welcome. Please include a focused reproduction
or validation benchmark when changing profiling behavior.

## License

The gem is available as open source under the terms of the MIT License.
