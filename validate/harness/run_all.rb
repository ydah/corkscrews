# frozen_string_literal: true

lib = File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require "corkscrews/validate"

quick = ARGV.delete("--quick")
benchmark = nil
if (index = ARGV.index("--benchmark"))
  benchmark = ARGV.fetch(index + 1)
end

result = Corkscrews::Validate.run_all(quick: quick, benchmark: benchmark)
puts JSON.pretty_generate(result.to_h)
exit(result.ok? ? 0 : 1)
