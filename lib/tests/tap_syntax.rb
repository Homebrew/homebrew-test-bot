# frozen_string_literal: true

module Homebrew
  module Tests
    class TapSyntax < Test
      def run!(args:)
        test_header(:TapSyntax)
        return unless tap.installed?

        test "brew", "style", tap.name

        return if tap.formula_files.blank? && tap.cask_files.blank?

        test "brew", "readall", "--aliases", "--os=all", "--arch=all", tap.name
        test "brew", "audit", "--except=installed", "--tap=#{tap.name}"
      end
    end
  end
end
