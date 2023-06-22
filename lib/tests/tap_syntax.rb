# frozen_string_literal: true

module Homebrew
  module Tests
    class TapSyntax < Test
      def run!(args:)
        test_header(:TapSyntax)
        return unless tap.installed?

        test "brew", "style", tap.name

        return if tap.formula_files.blank? && tap.cask_files.blank?

        test "brew", "readall", "--aliases", tap.name
        test "brew", "audit", "--tap=#{tap.name}"

        return if %w[push merge_group].exclude?(ENV["GITHUB_EVENT_NAME"])
        return if !tap.core_tap? && !tap.name.start_with?("homebrew/cask")

        test_api_generation
      end

      private

      def test_api_generation
        FileUtils.mkdir_p "api"
        Pathname("api").cd do
          if tap.core_tap?
            test "brew", "generate-formula-api"
          else
            test "brew", "generate-cask-api"
          end
        end
      ensure
        FileUtils.rm_rf "api"
      end
    end
  end
end
