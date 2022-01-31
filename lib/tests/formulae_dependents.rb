# frozen_string_literal: true

module Homebrew
  module Tests
    class FormulaeDependents < TestFormulae
      attr_writer :testing_formulae

      def run!(args:)
        (@testing_formulae - skipped_or_failed_formulae).each do |f|
          dependent_formulae!(f, args: args)
          puts
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

        # Install formula dependencies. These will have been uninstalled after building.
        test "brew", "install", "--only-dependencies", formula_name,
             env: { "HOMEBREW_DEVELOPER" => nil }
        return if steps.last.failed?

        # Restore etc/var files that may have been nuked in the build stage.
        test "brew", "postinstall", formula_name
        return if steps.last.failed?

        formula = Formulary.factory(formula_name)

        source_dependents, bottled_dependents, testable_dependents =
          dependents_for_formula(formula, formula_name, args: args)

        source_dependents.each do |dependent|
          install_dependent(dependent, testable_dependents, build_from_source: true, args: args)
          install_dependent(dependent, testable_dependents, args: args) if bottled?(dependent)
        end

        bottled_dependents.each do |dependent|
          install_dependent(dependent, testable_dependents, args: args)
        end
      end

      def dependents_for_formula(formula, formula_name, args:)
        info_header "Determining dependents..."

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
        # we should not. The criteria is that a dependent must have bottled dependencies, and
        # either the `--build-dependents-from-source` flag was passed or a dependent has no
        # bottle on the current OS.
        source_dependents, dependents = dependents.partition do |dependent, deps|
          next false if OS.linux? && dependent.requirements.exclude?(LinuxRequirement.new)

          all_deps_bottled_or_built = deps.all? do |d|
            bottled_or_built?(d.to_formula, @testing_formulae - @skipped_or_failed_formulae)
          end
          args.build_dependents_from_source? && all_deps_bottled_or_built
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
        bottled_dependents = dependents.select { |dep| bottled?(dep) }
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
        dependent_was_previously_installed = dependent.latest_version_installed?

        unless dependent_was_previously_installed
          build_args = []

          if build_from_source
            required_dependent_reqs = dependent.requirements.reject(&:optional?)
            install_curl_if_needed(dependent)
            install_mercurial_if_needed(required_dependent_deps, required_dependent_reqs)
            install_subversion_if_needed(required_dependent_deps, required_dependent_reqs)

            build_args << "--build-from-source"
          end

          test "brew", "fetch", *build_args, "--retry", dependent.full_name
          return if steps.last.failed?

          unlink_conflicts dependent

          test "brew", "install", *build_args, "--only-dependencies", dependent.full_name,
               env: { "HOMEBREW_DEVELOPER" => nil }

          env = {}
          env["HOMEBREW_GIT_PATH"] = nil if build_from_source && required_dependent_deps.any? do |d|
            d.name == "git" && (!d.test? || d.build?)
          end
          test "brew", "install", *build_args,
               named_args:      dependent.full_name,
               env:             env.merge({ "HOMEBREW_DEVELOPER" => nil }),
               ignore_failures: build_from_source && !bottled_on_current_version
          install_step = steps.last

          return unless install_step.passed?
        end
        return unless dependent.latest_version_installed?

        if !dependent.keg_only? && !dependent.linked_keg.exist?
          unlink_conflicts dependent
          test "brew", "link", dependent.full_name
        end
        test "brew", "install", "--only-dependencies", dependent.full_name
        test "brew", "linkage", "--test",
             named_args:      dependent.full_name,
             ignore_failures: !bottled_on_current_version
        linkage_step = steps.last

        if linkage_step.passed? && !build_from_source
          # Check for opportunistic linkage. Ignore failures because
          # they can be unavoidable but we still want to know about them.
          test "brew", "linkage", "--cached", "--test", "--strict",
               named_args:      dependent.full_name,
               ignore_failures: true
        end

        if testable_dependents.include? dependent
          test "brew", "install", "--only-dependencies", "--include-test", dependent.full_name

          # Traverse the dependency tree to check for formulae we need to link
          dependencies_to_link = Dependency.expand(
            dependent,
            cache_key: "test-bot-link-#{dependent.full_name}",
          ) do |dep_dependent, dependency|
            next if !dependency.build? && !dependency.test?
            next if dependency.test? && dep_dependent == dependent

            Dependency.prune
          end

          dependencies_to_link.each do |dependency|
            dependency_f = dependency.to_formula
            next if dependency_f.keg_only?
            next if dependency_f.linked?

            unlink_conflicts dependency_f
            test "brew", "link", dependency_f.full_name
          end

          env = {}
          env["HOMEBREW_GIT_PATH"] = nil if required_dependent_deps.any? do |d|
            d.name == "git" && (!d.build? || d.test?)
          end
          test "brew", "test", "--retry", "--verbose",
               named_args:      dependent.full_name,
               env:             env,
               ignore_failures: !bottled_on_current_version
          test_step = steps.last
        end

        test "brew", "uninstall", "--force", dependent.full_name

        return if ENV["GITHUB_ACTIONS"].blank?

        if build_from_source &&
           !bottled_on_current_version &&
           !dependent_was_previously_installed &&
           install_step.passed? &&
           linkage_step.passed? &&
           (testable_dependents.exclude?(dependent) || test_step.passed?) &&
           dependent.deps.all? { |d| bottled?(d.to_formula, no_older_versions: true) }
          os_string = if OS.mac?
            str = +"macOS #{MacOS.version.pretty_name} (#{MacOS.version})"
            str << " on Apple Silicon" if Hardware::CPU.arm?

            str
          else
            OS.kernel_name
          end

          puts GitHub::Actions::Annotation.new(
            :notice,
            "All tests passed.",
            file:  dependent.path.to_s.delete_prefix("#{repository}/"),
            title: "#{dependent} should be bottled for #{os_string}!",
          )
        end
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
