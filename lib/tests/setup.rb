# typed: true
# frozen_string_literal: true

module Homebrew
  module Tests
    class Setup < Test
      def run!(args:)
        test_header(:Setup)

        test "brew", "install-bundler-gems", "--add-groups=ast,audit,bottle,formula_test,livecheck,style"

        # Always output `brew config` output even when it doesn't fail.
        test "brew", "config", verbose: true

        test "brew", "doctor"
      end
    end
  end
end
