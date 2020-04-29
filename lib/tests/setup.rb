# frozen_string_literal: true

module Homebrew
  module Tests
    class Setup < Test
      def initialize
        # TODO: refactor into Test initializer exclusively
        @steps = []
      end

      # TODO: rename this when all classes ported.
      def setup
        method_header(__method__, klass: "Tests::Setup")

        # Always output `brew config` output even when it doesn't fail.
        test "brew", "config", verbose: true

        test "brew", "doctor"
      end
    end
  end
end
