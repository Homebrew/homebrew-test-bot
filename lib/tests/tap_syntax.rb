# typed: true
# frozen_string_literal: true

module Homebrew
  module Tests
    class TapSyntax < Test
      def run!(args:)
        test_header(:TapSyntax)
        return unless tap.installed?

        # Run `brew typecheck` if this tap is typed.
        # TODO: consider in future if we want to allow unsupported taps here.
        puts "tap.name: #{tap.name}, tap.path: #{tap.path}" if ENV["HOMEBREW_DEBUG"].present?
        if tap.official? && quiet_system(git, "-C", tap.path.to_s, "grep", "-qE", "^# typed: (true|strict|strong)$")
          test "brew", "typecheck", tap.name
        end

        test "brew", "style", tap.name unless args.stable?

        return if tap.formula_files.blank? && tap.cask_files.blank?

        test "brew", "readall", "--aliases", "--os=all", "--arch=all", tap.name
        return if args.stable?

        test "brew", "audit", "--except=installed", "--tap=#{tap.name}"
      end
    end
  end
end
