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
          bottled = with_env(HOMEBREW_SKIP_OR_LATER_BOTTLES: "1") do
            dependent.bottled?
          end

          install_dependent(
            dependent,
            testable_dependents,
            build_from_source:        true,
            args:                     args,
            check_for_missing_bottle: !bottled
          )

          install_dependent(dependent, testable_dependents, args: args) if bottled
        end

        bottled_dependents.each do |dependent|
          install_dependent(dependent, testable_dependents, args: args)
        end
      end

      def dependents_for_formula(formula, formula_name, args:)
        info_header "Determining dependents..."

        # Only test reverse dependencies for linux-only formulae in linuxbrew-core.
        if tap.present? &&
           tap.full_name == "Homebrew/linuxbrew-core" &&
           args.keep_old? &&
           formula.requirements.exclude?(LinuxRequirement.new)
          return [[], [], []]
        end

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
        bottled_dependents = with_env(HOMEBREW_SKIP_OR_LATER_BOTTLES: "1") do
          if OS.linux? &&
             tap.present? &&
             tap.full_name == "Homebrew/homebrew-core"
            # :all bottles are considered as Linux bottles, but as we did not bottle
            # everything (yet) in homebrew-core, we do not want to test formulae
            # with :all bottles for the time being.
            dependents.select { |dep| dep.bottled? && !dep.bottle_specification.tag?(:all) }
          else
            dependents.select(&:bottled?)
          end
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

      # NOTE: Don't pass `check_for_missing_bottle: true` if `dependent` is bottled.
      def install_dependent(
        dependent,
        testable_dependents,
        args:,
        build_from_source: false,
        check_for_missing_bottle: false
      )
        build_from_source = true if check_for_missing_bottle && !build_from_source

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

        unless dependent.latest_version_installed?
          build_args = []
          build_args << "--build-from-source" if build_from_source

          test "brew", "fetch", *build_args, "--retry", dependent.full_name
          return if steps.last.failed?

          unlink_conflicts dependent

          no_dev_env = { "HOMEBREW_DEVELOPER" => nil }
          # Use `expect_error` here because a formula might be unbottled because it has an unbottled dependency.
          test "brew", "install", *build_args, "--only-dependencies", dependent.full_name,
               env: no_dev_env, expect_error: check_for_missing_bottle, multistage: check_for_missing_bottle

          no_dev_env["HOMEBREW_GIT_PATH"] = nil if build_from_source && required_dependent_deps.any? do |d|
            d.name == "git" && (!d.test? || d.build?)
          end
          test "brew", "install", *build_args, dependent.full_name,
               env: no_dev_env, expect_error: check_for_missing_bottle, multistage: check_for_missing_bottle
          return if steps.last.failed?
        end

        unless dependent.latest_version_installed?
          resolve_pending(passed: true) if check_for_missing_bottle
          return
        end

        if !dependent.keg_only? && !dependent.linked_keg.exist?
          unlink_conflicts dependent
          test "brew", "link", dependent.full_name
        end
        test "brew", "install", "--only-dependencies", dependent.full_name
        test "brew", "linkage", "--test", dependent.full_name,
             expect_error: check_for_missing_bottle, multistage: check_for_missing_bottle

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

          test_env = {}
          test_env["HOMEBREW_GIT_PATH"] = nil if required_dependent_deps.any? do |d|
            d.name == "git" && (!d.build? || d.test?)
          end
          test "brew", "test", "--retry", "--verbose", dependent.full_name,
               env: test_env, expect_error: check_for_missing_bottle, multistage: check_for_missing_bottle
        end

        if check_for_missing_bottle && pending_steps.present?
          # All pending steps are pending fails if they all unexpectedly succeeded.
          if pending_steps.all?(&:pending_fail?)
            resolve_pending
            info_header "#{dependent}: source build unexpectedly succeeded! #{dependent} should be bottled."
          else
            resolve_pending(passed: true)
          end
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
