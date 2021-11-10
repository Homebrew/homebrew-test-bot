# frozen_string_literal: true

module Homebrew
  module Tests
    class FormulaeDependents < TestFormulae
      attr_writer :testing_formulae

      def run!(args:)
        (@testing_formulae - skipped_or_failed_formulae).each do |f|
          dependent_formulae!(f, args: args)
        end
      end

      private

      def dependent_formulae!(formula_name, args:)
        cleanup_during!(args: args)

        test_header(:FormulaeDependents, method: "dependent_formulae!(#{formula_name})")

        if OS.linux? && ENV["HOMEBREW_ON_DEBIAN7"]
          skipped formula_name, "Not testing dependents in Debian Wheezy container"
          return
        end

        formula = Formulary.factory(formula_name)

        source_dependents, bottled_dependents, testable_dependents =
          dependents_for_formula(formula, formula_name, args: args)

        source_dependents.each do |dependent|
          # TODO: Work out how to use this code to identify
          #       dependents that can be bottled. See
          #       https://github.com/Homebrew/homebrew-test-bot/pull/678
          next unless bottled?(dependent, no_older_versions: true)
          next if bottled?(dependent, :all) && dependent.deps.any? { |d| !bottled?(d.to_formula) }

          install_dependent(dependent, testable_dependents, build_from_source: true, args: args)
          install_dependent(dependent, testable_dependents, args: args)
        end

        bottled_dependents.each do |dependent|
          install_dependent(dependent, testable_dependents, args: args)
        end
      end

      def dependents_for_formula(formula, formula_name, args:)
        info_header "Determining dependents..."

        build_dependents_from_source_disabled = OS.linux? && tap.present? && tap.full_name == "Homebrew/homebrew-core"

        uses_args = %w[--formula --include-build --include-test]
        uses_args << "--recursive" unless args.skip_recursive_dependents?
        dependents = with_env(HOMEBREW_STDERR: "1") do
          Utils.safe_popen_read("brew", "uses", *uses_args, formula_name)
               .split("\n")
        end
        dependents -= @testing_formulae
        dependents = dependents.map { |d| Formulary.factory(d) }

        dependents = dependents.zip(dependents.map do |f|
          if args.skip_recursive_dependents?
            f.deps
          else
            begin
              f.recursive_dependencies
            rescue TapFormulaUnavailableError => e
              raise if e.tap.installed?

              e.tap.clear_cache
              safe_system "brew", "tap", e.tap.name
              retry
            end
          end.reject(&:optional?)
        end)

        # Split into dependents that we could potentially be building from source and those
        # we should not. The criteria is that it depends on a formula in the allowlist and
        # that formula has been, or will be, built in this test run.
        source_dependents, dependents = dependents.partition do |_, deps|
          deps.any? do |d|
            full_name = d.to_formula.full_name

            next false if !args.build_dependents_from_source? || build_dependents_from_source_disabled

            @testing_formulae.include?(full_name)
          end
        end

        # From the non-source list, get rid of any dependents we are only a build dependency to
        dependents.select! do |_, deps|
          deps.reject { |d| d.build? && !d.test? }
              .map(&:to_formula)
              .include?(formula)
        end

        dependents = dependents.transpose.first.to_a
        source_dependents = source_dependents.transpose.first.to_a

        testable_dependents = source_dependents.select(&:test_defined?)
        bottled_dependents = dependents.select do |dep|
          # If a dependent has an all bottle, we need to check that the dependent's dependencies
          # have useable bottles. Otherwise, we can check the dependent directly.
          next bottled?(dep, no_older_versions: true) unless bottled?(dep, :all)

          dep.deps.all? { |d| bottled?(d.to_formula) }
        end
        testable_dependents += bottled_dependents.select(&:test_defined?)

        info_header "Source dependents:"
        puts source_dependents

        info_header "Bottled dependents:"
        puts bottled_dependents

        info_header "Testable dependents:"
        puts testable_dependents

        [source_dependents, bottled_dependents, testable_dependents]
      end

      def install_dependent(dependent, testable_dependents, args:, build_from_source: false)
        if (messages = unsatisfied_requirements_messages(dependent))
          skipped dependent, messages
          return
        end

        if dependent.deprecated? || dependent.disabled?
          verb = dependent.deprecated? ? :deprecated : :disabled
          skipped dependent.name, "#{dependent.full_name} has been #{verb}!"
          return
        end

        cleanup_during!(args: args)

        required_dependent_deps = dependent.deps.reject(&:optional?)
        bottled_on_current_version = bottled?(dependent, no_older_versions: true)

        unless dependent.latest_version_installed?
          build_args = []
          build_args << "--build-from-source" if build_from_source

          test "brew", "fetch", *build_args, "--retry", dependent.full_name
          return if steps.last.failed?

          unlink_conflicts dependent

          test "brew", "install", *build_args, "--only-dependencies", dependent.full_name,
               env: { "HOMEBREW_DEVELOPER" => nil }

          env = {}
          env["HOMEBREW_GIT_PATH"] = nil if build_from_source && required_dependent_deps.any? do |d|
            d.name == "git" && (!d.test? || d.build?)
          end
          test "brew", "install", *build_args, dependent.full_name,
               env: env.merge({ "HOMEBREW_DEVELOPER" => nil })
          install_step = steps.last

          if install_step.failed?
            install_step.ignore if build_from_source && !bottled_on_current_version
            return
          end
        end
        return unless dependent.latest_version_installed?

        if !dependent.keg_only? && !dependent.linked_keg.exist?
          unlink_conflicts dependent
          test "brew", "link", dependent.full_name
        end
        test "brew", "install", "--only-dependencies", dependent.full_name
        test "brew", "linkage", "--test", dependent.full_name
        steps.last.ignore if steps.last.failed? && !bottled_on_current_version

        if testable_dependents.include? dependent
          test "brew", "install", "--only-dependencies", "--include-test", dependent.full_name

          dependent.deps.each do |dependency|
            next if dependency.build?

            dependency_f = dependency.to_formula
            next if dependency_f.keg_only?
            next if dependency_f.linked_keg.exist?

            unlink_conflicts dependency_f
            test "brew", "link", dependency_f.full_name
          end

          env = {}
          env["HOMEBREW_GIT_PATH"] = nil if required_dependent_deps.any? do |d|
            d.name == "git" && (!d.build? || d.test?)
          end
          test "brew", "test", "--retry", "--verbose", dependent.full_name, env: env
          steps.last.ignore if steps.last.failed? && !bottled_on_current_version
        end

        test "brew", "uninstall", "--force", dependent.full_name
      end

      def unlink_conflicts(formula)
        return if formula.keg_only?
        return if formula.linked_keg.exist?

        conflicts = formula.conflicts.map { |c| Formulary.factory(c.name) }
                           .select(&:any_version_installed?)
        formula_recursive_dependencies = begin
          formula.recursive_dependencies
        rescue TapFormulaUnavailableError => e
          raise if e.tap.installed?

          e.tap.clear_cache
          safe_system "brew", "tap", e.tap.name
          retry
        end
        formula_recursive_dependencies.each do |dependency|
          conflicts += dependency.to_formula.conflicts.map do |c|
            Formulary.factory(c.name)
          end.select(&:any_version_installed?)
        end
        conflicts.each do |conflict|
          test "brew", "unlink", conflict.name
        end
      end
    end
  end
end
