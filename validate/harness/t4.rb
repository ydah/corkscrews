# frozen_string_literal: true

require_relative "../../lib/corkscrews/validate"

module Corkscrews
  module Validate
    module T4
      module_function

      def check!(manifest, profile, actual)
        Validate.t4_overhead_check(manifest, profile, actual)
      end
    end
  end
end
