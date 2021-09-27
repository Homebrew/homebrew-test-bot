# frozen_string_literal: true

module Homebrew
  module Tests
    class TapSyntax < Test
      def run!(args:)
        test_header(:TapSyntax)

        test "brew", "readall", "--aliases", tap.name

        broken_xcode_rubygems = MacOS.version == :mojave &&
                                MacOS.active_developer_dir == "/Applications/Xcode.app/Contents/Developer"
        test "brew", "style", tap.name unless broken_xcode_rubygems

        test "brew", "audit", "--tap=#{tap.name}", "--except=version"

        return if OS.mac?

        with_env(HOMEBREW_SIMULATE_MACOS_ON_LINUX: "1") do
          # Follow macOS dependency graph too.
          test "brew", "audit", "--tap=#{tap.name}", "--only=deps"
        end
      end
    end
  end
end
