# frozen_string_literal: true

require "fileutils"
require "json"
require "optparse"
require "securerandom"

require_relative "../corkscrews"
require_relative "report"
require_relative "validate"

module Corkscrews
  class CLI
    def initialize(argv)
      @argv = argv.dup
    end

    def run
      command = @argv.shift

      case command
      when "run"
        run_profile(@argv)
      when "report"
        run_report(@argv)
      when "validate"
        run_validate(@argv)
      when "-h", "--help", nil
        puts help
        0
      else
        warn "unknown command: #{command}"
        warn help
        2
      end
    rescue Error => e
      warn "error: #{e.message}"
      1
    end

    private

    def run_profile(argv)
      options = {
        repeat: 1,
        output: "run.corkscrews.ndjson",
        sample_period_ms: 1.0,
        targets: "lines",
        max_slowdown: nil
      }

      parser = OptionParser.new do |opts|
        opts.banner = "usage: corkscrews run [options] -- ruby script.rb"
        opts.on("--repeat N", Integer, "number of process repetitions") { |value| options[:repeat] = value }
        opts.on("--duration SEC", Float, "advisory duration forwarded to benchmarks") { |value| options[:duration] = value }
        opts.on("--progress NAME", "expected progress point name") { |value| options[:progress] = value }
        opts.on("--targets KIND", "lines, waits, or both") { |value| options[:targets] = value }
        opts.on("--output PATH", "NDJSON output path") { |value| options[:output] = value }
        opts.on("--sample-period-ms MS", Float, "Ruby sampler period") { |value| options[:sample_period_ms] = value }
        opts.on("--max-slowdown PCT", Float, "advisory slowdown budget recorded for reports") { |value| options[:max_slowdown] = value }
      end

      command = parse_command_after_separator(parser, argv)
      raise Error, "missing command after --" if command.empty?

      output = File.expand_path(options[:output])
      FileUtils.rm_f(output)
      run_id = SecureRandom.hex(8)

      options[:repeat].times do |index|
        env = profile_environment(output, run_id, index, options)
        ok = system(env, *command)
        raise Error, "profiled command failed on repeat #{index + 1}: #{command.join(" ")}" unless ok
      end

      puts output
      0
    end

    def run_report(argv)
      options = { html: nil, firefox: nil, limit: 10 }
      parser = OptionParser.new do |opts|
        opts.banner = "usage: corkscrews report [options] run.corkscrews.ndjson"
        opts.on("--html PATH", "write an HTML report") { |value| options[:html] = value }
        opts.on("--firefox PATH", "write a Firefox Profiler compatible aggregate JSON") { |value| options[:firefox] = value }
        opts.on("--limit N", Integer, "number of line targets to show") { |value| options[:limit] = value }
      end
      parser.parse!(argv)

      path = argv.shift
      raise Error, "missing NDJSON path" unless path

      report = Report.new(path)
      puts report.to_text(limit: options[:limit])
      report.write_html(options[:html], limit: options[:limit]) if options[:html]
      report.write_firefox(options[:firefox]) if options[:firefox]
      0
    end

    def run_validate(argv)
      options = { quick: false, benchmark: nil }
      parser = OptionParser.new do |opts|
        opts.banner = "usage: corkscrews validate [options]"
        opts.on("--quick", "use short validation settings") { options[:quick] = true }
        opts.on("--benchmark ID", "run one benchmark") { |value| options[:benchmark] = value }
      end
      parser.parse!(argv)

      result = Validate.run_all(quick: options[:quick], benchmark: options[:benchmark])
      puts JSON.pretty_generate(result.to_h)
      result.ok? ? 0 : 1
    end

    def parse_command_after_separator(parser, argv)
      separator_index = argv.index("--")
      raise Error, "missing -- separator" unless separator_index

      option_args = argv.take(separator_index)
      command = argv.drop(separator_index + 1)
      parser.parse!(option_args)
      command
    end

    def profile_environment(output, run_id, index, options)
      lib_path = File.expand_path("..", __dir__)
      ext_path = File.expand_path("../../ext/corkscrews", __dir__)
      ruby_lib = [lib_path, ext_path, ENV["RUBYLIB"]].compact.reject(&:empty?).join(File::PATH_SEPARATOR)
      ruby_opt = ["-rcorkscrews/boot", ENV["RUBYOPT"]].compact.reject(&:empty?).join(" ")

      {
        "RUBYLIB" => ruby_lib,
        "RUBYOPT" => ruby_opt,
        "CORKSCREWS_PROFILE" => "1",
        "CORKSCREWS_OUTPUT" => output,
        "CORKSCREWS_RUN_ID" => run_id,
        "CORKSCREWS_REPEAT_INDEX" => index.to_s,
        "CORKSCREWS_SAMPLE_PERIOD_MS" => options[:sample_period_ms].to_s,
        "CORKSCREWS_TARGETS" => options[:targets].to_s,
        "CORKSCREWS_PRIMITIVES" => primitive_instrumentation?(options).to_s,
        "CORKSCREWS_MAX_SLOWDOWN" => options[:max_slowdown].to_s,
        "CORKSCREWS_PROGRESS" => options[:progress].to_s,
        "CS_BENCH_DURATION" => options[:duration].to_s
      }
    end

    def primitive_instrumentation?(options)
      %w[waits both].include?(options[:targets].to_s) ? "1" : "0"
    end

    def help
      <<~TEXT
        usage:
          corkscrews run [options] -- ruby script.rb
          corkscrews report [options] run.corkscrews.ndjson
          corkscrews validate [options]
      TEXT
    end
  end
end
