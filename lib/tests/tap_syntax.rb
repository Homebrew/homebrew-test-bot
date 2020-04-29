# frozen_string_literal: true

module Homebrew
  module Tests
    class TapSyntax < Test
      def initialize(tap)
        @tap = tap

        # TODO: refactor into Test initializer exclusively
        @steps = []
      end

      # TODO: rename this when all classes ported.
      def tap_syntax
        return unless @tap

        method_header(__method__, klass: "Tests::TapSyntax")

        test "brew", "readall", "--aliases", @tap.name
        broken_xcode_rubygems = MacOS.version == :mojave &&
                                MacOS.active_developer_dir == "/Applications/Xcode.app/Contents/Developer"
        test "brew", "style", @tap.name unless broken_xcode_rubygems
      end
    end
  end
end
