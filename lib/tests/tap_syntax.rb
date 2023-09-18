# frozen_string_literal: true

module Homebrew
  module Tests
    class TapSyntax < Test
      def run!(args:)
        test_header(:TapSyntax)
        return unless tap.installed?

        test "brew", "style", tap.name

        if tap.core_tap? || tap.core_cask_tap?
          if %w[push merge_group].include?(ENV["GITHUB_EVENT_NAME"])
            test "brew", "readall", "--aliases", "--os=all", "--arch=all", tap.name
            test "brew", "audit", "--tap=#{tap.name}"
          end

          test_api_generation
        elsif tap.formula_files.present? || tap.cask_files.present?
          test "brew", "readall", "--aliases", "--os=all", "--arch=all", tap.name
          test "brew", "audit", "--tap=#{tap.name}"
        end
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
