# frozen_string_literal: true

module Homebrew
  module Tests
    class TapSyntax < Test
      # Eventually these should be all `tap.official?` taps except core & cask?
      SORBET_TAPS = %w[
        homebrew/command-not-found
        homebrew/services
      ].freeze

      def run!(args:)
        test_header(:TapSyntax)
        return unless tap.installed?

        test "brew", "typecheck", tap.name if SORBET_TAPS.include?(tap.name)

        test "brew", "style", tap.name unless args.stable?

        return if tap.formula_files.blank? && tap.cask_files.blank?

        test "brew", "readall", "--aliases", "--os=all", "--arch=all", tap.name
        return if args.stable?

        test "brew", "audit", "--except=installed", "--tap=#{tap.name}"
      end
    end
  end
end
