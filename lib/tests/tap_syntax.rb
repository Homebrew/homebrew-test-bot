# frozen_string_literal: true

module Homebrew
  module Tests
    class TapSyntax < Test
      def run!(args:)
        test_header(:TapSyntax)

        test "brew", "readall", "--aliases", tap.name, args: args
        broken_xcode_rubygems = MacOS.version == :mojave &&
                                MacOS.active_developer_dir == "/Applications/Xcode.app/Contents/Developer"
        test "brew", "style", tap.name, args: args unless broken_xcode_rubygems
      end
    end
  end
end
