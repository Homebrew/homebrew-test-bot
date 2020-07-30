# frozen_string_literal: true

module Homebrew
  module Tests
    class Setup < Test
      def run!(args:)
        test_header(:Setup)

        test "brew", "install-bundler-gems", args: args

        # Always output `brew config` output even when it doesn't fail.
        test "brew", "config", verbose: true, args: args

        test "brew", "doctor", args: args
      end
    end
  end
end
