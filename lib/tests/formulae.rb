# frozen_string_literal: true

module Homebrew
  module Tests
    class Formulae < TestFormulae
      attr_writer :testing_formulae, :added_formulae, :deleted_formulae

      def initialize(tap:, git:, dry_run:, fail_fast:, verbose:, bottle_output_path:)
        super(tap: tap, git: git, dry_run: dry_run, fail_fast: fail_fast, verbose: verbose)

        @bottle_output_path = bottle_output_path
      end

      def run!(args:)
        sorted_formulae.each do |f|
          formula!(f, args: args)
          puts
        end

        @deleted_formulae.each do |f|
          deleted_formula!(f)
          puts
        end

        return unless ENV["GITHUB_ACTIONS"]

        puts "::set-output name=skipped_or_failed_formulae::#{@skipped_or_failed_formulae.join(",")}"
      end

      private

      def tap_needed_taps(deps)
        deps.each { |d| d.to_formula.recursive_dependencies }
      rescue TapFormulaUnavailableError => e
        raise if e.tap.installed?

        e.tap.clear_cache
        safe_system "brew", "tap", e.tap.name
        retry
      end

      def install_ca_certificates_if_needed
        return if DevelopmentTools.ca_file_handles_most_https_certificates?

        test "brew", "install", "ca-certificates",
             env: { "HOMEBREW_DEVELOPER" => nil }
      end

      def downloads_using_homebrew_curl?(formula)
        [:stable, :head].any? do |spec_name|
          next false unless (spec = formula.send(spec_name))

          spec.using == :homebrew_curl || spec.resources.values.any? { |r| r.using == :homebrew_curl }
        end
      end

      def install_curl_if_needed(formula)
        return unless downloads_using_homebrew_curl?(formula)

        test "brew", "install", "curl",
             env: { "HOMEBREW_DEVELOPER" => nil }
      end

      def install_gcc_if_needed(formula, deps)
        installed_gcc = false
        begin
          deps.each { |dep| CompilerSelector.select_for(dep.to_formula) }
          CompilerSelector.select_for(formula)
        rescue CompilerSelectionError => e
          unless installed_gcc
            test "brew", "install", "gcc",
                 env: { "HOMEBREW_DEVELOPER" => nil }
            installed_gcc = true
            DevelopmentTools.clear_version_cache
            retry
          end
          skipped formula.name, e.message
        end
      end

      def install_mercurial_if_needed(deps, reqs)
        return if (deps | reqs).none? { |d| d.name == "mercurial" && d.build? }

        test "brew", "install", "mercurial",
             env:  { "HOMEBREW_DEVELOPER" => nil }
      end

      def install_subversion_if_needed(deps, reqs)
        return if (deps | reqs).none? { |d| d.name == "subversion" && d.build? }

        test "brew", "install", "subversion",
             env:  { "HOMEBREW_DEVELOPER" => nil }
      end

      def setup_formulae_deps_instances(formula, formula_name, args:)
        conflicts = formula.conflicts
        formula.recursive_dependencies.each do |dependency|
          conflicts += dependency.to_formula.conflicts
        end
        unlink_formulae = conflicts.map(&:name)
        unlink_formulae.uniq.each do |name|
          unlink_formula = Formulary.factory(name)
          next unless unlink_formula.latest_version_installed?
          next unless unlink_formula.linked_keg.exist?

          test "brew", "unlink", name
        end

        info_header "Determining dependencies..."
        installed = Utils.safe_popen_read("brew", "list", "--formula").split("\n")
        dependencies =
          Utils.safe_popen_read("brew", "deps", "--include-build",
                                "--include-test", formula_name)
               .split("\n")
        installed_dependencies = installed & dependencies
        installed_dependencies.each do |name|
          link_formula = Formulary.factory(name)
          next if link_formula.keg_only?
          next if link_formula.linked_keg.exist?

          test "brew", "link", name
        end

        dependencies -= installed
        @unchanged_dependencies = dependencies - @testing_formulae
        test "brew", "fetch", "--retry", *@unchanged_dependencies unless @unchanged_dependencies.empty?

        changed_dependencies = dependencies - @unchanged_dependencies
        unless changed_dependencies.empty?
          test "brew", "fetch", "--retry", "--build-from-source",
               *changed_dependencies

          ignore_failures = changed_dependencies.any? do |dep|
            !bottled?(Formulary.factory(dep), no_older_versions: true)
          end

          # Install changed dependencies as new bottles so we don't have
          # checksum problems. We have to install all `changed_dependencies`
          # in one `brew install` command to make sure they are installed in
          # the right order.
          test "brew", "install", "--build-from-source",
               named_args:      changed_dependencies,
               ignore_failures: ignore_failures
          # Run postinstall on them because the tested formula might depend on
          # this step
          test "brew", "postinstall", named_args: changed_dependencies, ignore_failures: ignore_failures
        end

        runtime_or_test_dependencies =
          Utils.safe_popen_read("brew", "deps", "--include-test", formula_name)
               .split("\n")
        build_dependencies = dependencies - runtime_or_test_dependencies
        @unchanged_build_dependencies = build_dependencies - @testing_formulae
      end

      def cleanup_bottle_etc_var(formula)
        bottle_prefix = formula.opt_prefix/".bottle"
        # Nuke etc/var to have them be clean to detect bottle etc/var
        # file additions.
        Pathname.glob("#{bottle_prefix}/{etc,var}/**/*").each do |bottle_path|
          prefix_path = bottle_path.sub(bottle_prefix, HOMEBREW_PREFIX)
          FileUtils.rm_rf prefix_path
        end
      end

      def bottle_reinstall_formula(formula, new_formula, args:)
        unless build_bottle?(formula, args: args)
          @bottle_filename = nil
          return
        end

        root_url = args.root_url

        # GitHub Releases url
        root_url ||= if tap.present? && !tap.core_tap? && !@test_default_formula
          "#{tap.default_remote}/releases/download/#{formula.name}-#{formula.pkg_version}"
        end

        # This is needed where sparse files may be handled (bsdtar >=3.0).
        # We use gnu-tar with sparse files disabled when --only-json-tab is passed.
        ENV["HOMEBREW_BOTTLE_SUDO_PURGE"] = "1" if MacOS.version >= :catalina && !args.only_json_tab?

        bottle_args = ["--verbose", "--json", formula.full_name]
        bottle_args << "--keep-old" if args.keep_old? && !new_formula
        bottle_args << "--skip-relocation" if args.skip_relocation?
        bottle_args << "--force-core-tap" if @test_default_formula
        bottle_args << "--root-url=#{root_url}" if root_url
        bottle_args << "--only-json-tab" if args.only_json_tab?
        test "brew", "bottle", *bottle_args

        bottle_step = steps.last
        return unless bottle_step.passed?
        return unless bottle_step.output?

        @bottle_output_path.write(bottle_step.output, mode: "a")

        @bottle_filename =
          bottle_step.output
                     .gsub(%r{.*(\./\S+#{HOMEBREW_BOTTLES_EXTNAME_REGEX}).*}om, '\1')
        @bottle_json_filename =
          @bottle_filename.gsub(/\.(\d+\.)?tar\.gz$/, ".json")
        bottle_merge_args =
          ["--merge", "--write", "--no-commit", @bottle_json_filename]
        bottle_merge_args << "--keep-old" if args.keep_old? && !new_formula

        test "brew", "bottle", *bottle_merge_args
        test "brew", "uninstall", "--force", formula.full_name

        bottle_json = JSON.parse(File.read(@bottle_json_filename))
        root_url = bottle_json.dig(formula.full_name, "bottle", "root_url")
        filename = bottle_json.dig(formula.full_name, "bottle", "tags").values.first["filename"]

        download_strategy = CurlDownloadStrategy.new("#{root_url}/#{filename}", formula.name, formula.version)
        download_strategy.cached_location.parent.mkpath
        FileUtils.ln @bottle_filename, download_strategy.cached_location, force: true
        FileUtils.ln_s download_strategy.cached_location.relative_path_from(download_strategy.symlink_location),
                       download_strategy.symlink_location,
                       force: true

        @testing_formulae.delete(formula.name)

        unless @unchanged_build_dependencies.empty?
          test "brew", "uninstall", "--force", *@unchanged_build_dependencies
          @unchanged_dependencies -= @unchanged_build_dependencies
        end

        test "brew", "install", "--only-dependencies", @bottle_filename
        test "brew", "install", @bottle_filename
      end

      def build_bottle?(formula, args:)
        # Build and runtime dependencies must be bottled on the current OS,
        # but accept an older compatible bottle for test dependencies.
        return false if formula.deps.any? do |dep|
          !bottled?(dep.to_formula, no_older_versions: !dep.test?) &&
          @added_formulae.exclude?(dep.name)
        end

        !formula.bottle_disabled? && !args.build_from_source?
      end

      def formula!(formula_name, args:)
        cleanup_during!(args: args)

        test_header(:Formulae, method: "formula!(#{formula_name})")

        formula = Formulary.factory(formula_name)
        if formula.disabled?
          skipped formula_name, "#{formula.full_name} has been disabled!"
          return
        end

        deps_without_compatible_bottles = formula.deps
                                                 .map(&:to_formula)
                                                 .reject { |dep| bottled?(dep) }
        bottled_on_current_version = bottled?(formula, no_older_versions: true)

        if deps_without_compatible_bottles.present? && !bottled_on_current_version
          message = <<~EOS
            #{formula_name} has dependencies without compatible bottles:
              #{deps_without_compatible_bottles * "\n  "}
          EOS
          skipped formula_name, message
          return
        end

        new_formula = @added_formulae.include?(formula_name)
        ignore_failures = !bottled_on_current_version && !new_formula

        deps = []
        reqs = []

        build_flag = if build_bottle?(formula, args: args)
          "--build-bottle"
        else
          if ENV["GITHUB_ACTIONS"].present?
            puts GitHub::Actions::Annotation(
              :warning,
              "#{formula} has unbottled dependencies, so a bottle will not be built.",
              title: "No bottle built for #{formula}!",
              file:  formula.path.to_s.delete_prefix("#{repository}/"),
            )
          else
            onoe "Not building a bottle for #{formula} because it has unbottled dependencies."
          end

          "--build-from-source"
        end

        # Online checks are a bit flaky and less useful for PRs that modify multiple formulae.
        skip_online_checks = args.skip_online_checks? || (@testing_formulae.count > 5)

        fetch_args = [formula_name]
        fetch_args << build_flag
        fetch_args << "--force" if args.cleanup?

        livecheck_args = [formula_name]
        livecheck_args << "--full-name"
        livecheck_args << "--debug"

        audit_args = [formula_name]
        audit_args << "--online" unless skip_online_checks
        if new_formula
          audit_args << "--new-formula"
        else
          audit_args << "--git" << "--skip-style"
        end

        # This needs to be done before any network operation.
        install_ca_certificates_if_needed

        if (messages = unsatisfied_requirements_messages(formula))
          test "brew", "fetch", "--retry", *fetch_args
          test "brew", "audit", *audit_args

          skipped formula_name, messages
          return
        end

        deps |= formula.deps.to_a.reject(&:optional?)
        reqs |= formula.requirements.to_a.reject(&:optional?)

        tap_needed_taps(deps)
        install_curl_if_needed(formula)
        install_mercurial_if_needed(deps, reqs)
        install_subversion_if_needed(deps, reqs)
        setup_formulae_deps_instances(formula, formula_name, args: args)

        info_header "Starting build of #{formula_name}"

        test "brew", "fetch", "--retry", *fetch_args

        test "brew", "uninstall", "--force", formula_name if formula.latest_version_installed?

        install_args = ["--verbose"]
        install_args << build_flag

        # Don't care about e.g. bottle failures for dependencies.
        test "brew", "install", "--only-dependencies", *install_args, formula_name,
             env: { "HOMEBREW_DEVELOPER" => nil }

        # Do this after installing dependencies to avoid skipping formulae
        # that build with and declare a dependency on GCC. See discussion at
        # https://github.com/Homebrew/homebrew-core/pull/86826
        install_gcc_if_needed(formula, deps)

        env = {}
        env["HOMEBREW_GIT_PATH"] = nil if deps.any? do |d|
          d.name == "git" && (!d.test? || d.build?)
        end
        test "brew", "install", *install_args,
             named_args:      formula_name,
             env:             env.merge({ "HOMEBREW_DEVELOPER" => nil }),
             ignore_failures: ignore_failures
        install_step = steps.last

        if formula.livecheckable? && !formula.livecheck.skip? && !skip_online_checks
          test "brew", "livecheck", *livecheck_args
        end

        test "brew", "audit", *audit_args unless formula.deprecated?
        unless install_step.passed?
          if ignore_failures
            skipped formula_name, "install failed"
          else
            failed formula_name, "install failed"
          end

          return
        end

        bottle_reinstall_formula(formula, new_formula, args: args)
        test "brew", "linkage", "--test", named_args: formula_name, ignore_failures: ignore_failures
        failed_linkage_or_test_messages ||= []
        failed_linkage_or_test_messages << "linkage failed" unless steps.last.passed?

        if steps.last.passed?
          # Check for opportunistic linkage. Ignore failures because
          # they can be unavoidable but we still want to know about them.
          test "brew", "linkage", "--cached", "--test", "--strict",
               named_args:      formula_name,
               ignore_failures: true
        end

        test "brew", "install", "--only-dependencies", "--include-test", formula_name

        if formula.test_defined?
          env = {}
          env["HOMEBREW_GIT_PATH"] = nil if deps.any? do |d|
            d.name == "git" && (!d.build? || d.test?)
          end

          # Intentionally not passing --retry here to avoid papering over
          # flaky tests when a formula isn't being pulled in as a dependent.
          test "brew", "test", "--verbose", named_args: formula_name, env: env, ignore_failures: ignore_failures
          failed_linkage_or_test_messages << "test failed" unless steps.last.passed?
        end

        # Move bottle and don't test dependents if the formula linkage or test failed.
        if failed_linkage_or_test_messages.present?
          if @bottle_filename
            failed_dir = "#{File.dirname(@bottle_filename)}/failed"
            FileUtils.mkdir failed_dir unless File.directory? failed_dir
            FileUtils.mv [@bottle_filename, @bottle_json_filename], failed_dir
          end

          if ignore_failures
            skipped formula_name, failed_linkage_or_test_messages.join(", ")
          else
            failed formula_name, failed_linkage_or_test_messages.join(", ")
          end
        end
      ensure
        cleanup_bottle_etc_var(formula) if args.cleanup?

        test "brew", "uninstall", "--force", *@unchanged_dependencies if @unchanged_dependencies.present?
      end

      def deleted_formula!(formula_name)
        test_header(:Formulae, method: "deleted_formula!(#{formula_name})")

        test "brew", "uses", "--include-build",
             "--include-optional",
             "--include-test",
             formula_name
      end

      def sorted_formulae
        changed_formulae_dependents = {}

        @testing_formulae.each do |formula|
          begin
            formula_dependencies =
              Utils.popen_read("brew", "deps", "--full-name",
                               "--include-build",
                               "--include-test", formula)
                   .split("\n")
            # deps can fail if deps are not tapped
            unless $CHILD_STATUS.success?
              Formulary.factory(formula).recursive_dependencies
              # If we haven't got a TapFormulaUnavailableError, then something else is broken
              raise "Failed to determine dependencies for '#{formula}'."
            end
          rescue TapFormulaUnavailableError => e
            raise if e.tap.installed?

            e.tap.clear_cache
            safe_system "brew", "tap", e.tap.name
            retry
          end

          unchanged_dependencies = formula_dependencies - @testing_formulae
          changed_dependencies = formula_dependencies - unchanged_dependencies
          changed_dependencies.each do |changed_formula|
            changed_formulae_dependents[changed_formula] ||= 0
            changed_formulae_dependents[changed_formula] += 1
          end
        end

        changed_formulae = changed_formulae_dependents.sort do |a1, a2|
          a2[1].to_i <=> a1[1].to_i
        end
        changed_formulae.map!(&:first)
        unchanged_formulae = @testing_formulae - changed_formulae
        changed_formulae + unchanged_formulae
      end
    end
  end
end
