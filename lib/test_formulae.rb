# frozen_string_literal: true

module Homebrew
  module Tests
    class TestFormulae < Test
      attr_accessor :skipped_or_failed_formulae

      def initialize(tap:, git:, dry_run:, fail_fast:, verbose:)
        super

        @skipped_or_failed_formulae = []
      end

      protected

      def bottled?(formula, tag = nil, no_older_versions: false)
        formula.bottle_specification.tag?(Utils::Bottles.tag(tag), no_older_versions: no_older_versions)
      end

      def skipped(formula_name, reason)
        @skipped_or_failed_formulae << formula_name

        puts Formatter.headline(
          "#{Formatter.warning("SKIPPED")} #{Formatter.identifier(formula_name)}",
          color: :yellow,
        )
        opoo reason
      end

      def failed(formula_name, reason)
        @skipped_or_failed_formulae << formula_name

        puts Formatter.headline(
          "#{Formatter.error("FAILED")} #{Formatter.identifier(formula_name)}",
          color: :red,
        )
        onoe reason
      end

      def unsatisfied_requirements_messages(formula)
        f = Formulary.factory(formula.full_name)
        fi = FormulaInstaller.new(f)
        fi.build_bottle = true

        unsatisfied_requirements, = fi.expand_requirements
        return if unsatisfied_requirements.blank?

        unsatisfied_requirements.values.flatten.map(&:message).join("\n").presence
      end

      def cleanup_during!(args:)
        return unless args.cleanup?
        return unless HOMEBREW_CACHE.exist?

        free_gb = Utils.safe_popen_read({ "BLOCKSIZE" => (1000 ** 3).to_s }, "df", HOMEBREW_CACHE.to_s)
                       .lines[1] # HOMEBREW_CACHE
                       .split[3] # free GB
                       .to_i
        return if free_gb > 10

        test_header(:TestFormulae, method: :cleanup_during!)

        FileUtils.chmod_R "u+rw", HOMEBREW_CACHE, force: true
        test "rm", "-rf", HOMEBREW_CACHE.to_s
      end
    end
  end
end
