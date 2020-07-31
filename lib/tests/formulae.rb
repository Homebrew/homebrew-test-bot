# frozen_string_literal: true

module Homebrew
  module Tests
    class Formulae < Test
      def initialize(argument, tap:, git:)
        super(tap: tap, git: git)

        @argument = argument

        @formulae = []
        @added_formulae = []
        @deleted_formulae = []
        @built_formulae = []
      end

      def run!(args:)
        detect_formulae!(args: args)
        formulae.each do |f|
          formula!(f, args: args)
        end
        @deleted_formulae.each do |f|
          deleted_formula!(f, args: args)
        end
      end

      private

      def safe_formula_canonical_name(formula_name, args:)
        Formulary.factory(formula_name).full_name
      rescue TapFormulaUnavailableError => e
        raise if e.tap.installed?

        test "brew", "tap", e.tap.name, args: args
        retry unless steps.last.failed?
        onoe e
        puts e.backtrace if args.debug?
      rescue FormulaUnavailableError, TapFormulaAmbiguityError,
             TapFormulaWithOldnameAmbiguityError => e
        onoe e
        puts e.backtrace if args.debug?
      end

      def rev_parse(ref)
        Utils.safe_popen_read(git, "-C", repository, "rev-parse", "--verify", ref).strip
      end

      def current_sha1
        rev_parse("HEAD")
      end

      def diff_formulae(start_revision, end_revision, path, filter)
        return unless tap

        Utils.safe_popen_read(
          git, "-C", repository,
                "diff-tree", "-r", "--name-only", "--diff-filter=#{filter}",
                start_revision, end_revision, "--", path
        ).lines.map do |line|
          file = Pathname.new line.chomp
          next unless tap.formula_file?(file)

          tap.formula_file_to_name(file)
        end.compact
      end

      def detect_formulae!(args:)
        test_header(:Formulae, method: :detect_formulae!)

        url = nil

        if @argument == "HEAD"
          # Use GitHub Actions variables for pull request jobs.
          if ENV["GITHUB_REF"].present? && ENV["GITHUB_REPOSITORY"].present? &&
             %r{refs/pull/(?<pr>\d+)/merge} =~ ENV["GITHUB_REF"]
            url = "https://github.com/#{ENV["GITHUB_REPOSITORY"]}/pull/#{pr}/checks"
          end
        elsif (canonical_formula_name = safe_formula_canonical_name(@argument, args: args))
          @formulae = [canonical_formula_name]
        else
          raise UsageError,
            "#{@argument} is not detected from GitHub Actions or a formula name!"
        end

        # Use GitHub Actions variables for pull request jobs.
        if ENV["GITHUB_BASE_REF"].present? && ENV["GITHUB_SHA"].present?
          diff_start_sha1 = rev_parse("origin/#{ENV["GITHUB_BASE_REF"]}")
          if diff_start_sha1.blank?
            test git, "-C", repository, "fetch", "--depth=1",
                 "origin", "+refs/heads/#{ENV["GITHUB_BASE_REF"]}",
                 args: args
            diff_start_sha1 = rev_parse("origin/#{ENV["GITHUB_BASE_REF"]}")
          end
          diff_end_sha1 = ENV["GITHUB_SHA"]
        # Use GitHub Actions variables for branch jobs.
        elsif ENV["GITHUB_SHA"].present?
          diff_end_sha1 = diff_start_sha1 = ENV["GITHUB_SHA"]
        # Otherwise just use the current SHA-1 (which may be overriden later)
        else
          if ENV["CI"] || ENV["GITHUB_ACTIONS"]
            onoe <<~EOS
              No known CI provider detected! If you are using GitHub Actions then we cannot find the expected  environment variables! Check you have e.g. exported them to a Docker container.
            EOS
          end
          diff_end_sha1 = diff_start_sha1 = current_sha1
        end

        if diff_start_sha1.present? && diff_end_sha1.present?
          merge_base_sha1 =
            Utils.safe_popen_read(git, "-C", repository, "merge-base",
                                   diff_start_sha1, diff_end_sha1).strip
          diff_start_sha1 = merge_base_sha1 if merge_base_sha1.present?
        end

        diff_start_sha1 = current_sha1 if diff_start_sha1.blank?
        diff_end_sha1 = current_sha1 if diff_end_sha1.blank?

        diff_start_sha1 = diff_end_sha1 if @formulae.present?

        if tap.to_s != CoreTap.instance.name
          core_revision = Utils.safe_popen_read(
            git, "-C", CoreTap.instance.path.to_s,
                  "log", "-1", "--format=%h (%s)"
          ).strip
          puts Formatter.headline("Using #{CoreTap.instance.full_name} #{core_revision}", color: :cyan)
        end

        if tap
          tap_origin_master_revision = Utils.safe_popen_read(
            git, "-C", tap.path.to_s,
                  "log", "-1", "--format=%h (%s)", "origin/master"
          ).strip
          tap_revision = Utils.safe_popen_read(
            git, "-C", tap.path.to_s,
                  "log", "-1", "--format=%h (%s)"
          ).strip
          puts Formatter.headline("Testing #{tap.full_name} #{tap_revision}:", color: :cyan)
        end

        puts <<-EOS
    url             #{url.blank? ? "(undefined)" : url}
    origin/master   #{tap_origin_master_revision.blank? ? "(undefined)" : tap_origin_master_revision}
    HEAD            #{tap_revision.blank? ? "(undefined)" : tap_revision}
    diff_start_sha1 #{diff_start_sha1.blank? ? "(undefined)" : diff_start_sha1}
    diff_end_sha1   #{diff_end_sha1.blank? ? "(undefined)" : diff_end_sha1}
        EOS

        modified_formulae = []

        if tap && diff_start_sha1 != diff_end_sha1
          formula_path = tap.formula_dir.to_s
          @added_formulae +=
            diff_formulae(diff_start_sha1, diff_end_sha1, formula_path, "A")
          modified_formulae +=
            diff_formulae(diff_start_sha1, diff_end_sha1, formula_path, "M")
          @deleted_formulae +=
            diff_formulae(diff_start_sha1, diff_end_sha1, formula_path, "D")
        end

        if args.test_default_formula?
          # Build the default test formula.
          @test_default_formula = true
          modified_formulae << "testbottest"
        end

        @formulae += @added_formulae + modified_formulae

        return if @added_formulae.blank? && modified_formulae.blank? && @deleted_formulae.blank?

        puts Formatter.headline("Testing Formula changes:", color: :cyan)
        puts <<-EOS
    added    #{@added_formulae.blank? ? "(empty)" : @added_formulae.join(" ")}
    modified #{modified_formulae.blank? ? "(empty)" : modified_formulae.join(" ")}
    deleted  #{@deleted_formulae.blank? ? "(empty)" : @deleted_formulae.join(" ")}
        EOS
      end

      def skip(formula_name)
        puts Formatter.headline(
          "#{Formatter.warning("SKIPPED")} #{Formatter.identifier(formula_name)}",
          color: :yellow,
        )
      end

      def satisfied_requirements?(formula, spec, dependency = nil)
        f = Formulary.factory(formula.full_name, spec)
        fi = FormulaInstaller.new(f)
        stable_spec = spec == :stable
        fi.build_bottle = stable_spec

        unsatisfied_requirements, = fi.expand_requirements
        return true if unsatisfied_requirements.empty?

        name = formula.full_name
        name += " (#{spec})" unless stable_spec
        name += " (#{dependency} dependency)" if dependency
        skip name
        puts unsatisfied_requirements.values.flatten.map(&:message)
        false
      end

      def tap_needed_taps(deps)
        deps.each { |d| d.to_formula.recursive_dependencies }
      rescue TapFormulaUnavailableError => e
        raise if e.tap.installed?

        e.tap.clear_cache
        safe_system "brew", "tap", e.tap.name
        retry
      end

      def install_gcc_if_needed(formula, deps, args:)
        installed_gcc = false
        deps.each { |dep| CompilerSelector.select_for(dep.to_formula) }
        CompilerSelector.select_for(formula)
      rescue CompilerSelectionError => e
        unless installed_gcc
          test "brew", "install", "gcc",
                env:  { "HOMEBREW_DEVELOPER" => nil },
                args: args
          installed_gcc = true
          DevelopmentTools.clear_version_cache
          retry
        end
        skip formula.name
        puts e.message
      end

      def install_mercurial_if_needed(deps, reqs, args:)
        if (deps | reqs).any? { |d| d.name == "mercurial" && d.build? }
          test "brew", "install", "mercurial",
               env:  { "HOMEBREW_DEVELOPER" => nil },
               args: args
        end
      end

      def install_subversion_if_needed(deps, reqs, args:)
        if (deps | reqs).any? { |d| d.name == "subversion" && d.build? }
          test "brew", "install", "subversion",
               env:  { "HOMEBREW_DEVELOPER" => nil },
               args: args
        end
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

          test "brew", "unlink", name, args: args
        end

        installed = Utils.safe_popen_read("brew", "list").split("\n")
        dependencies =
          Utils.safe_popen_read("brew", "deps", "--include-build",
                                           "--include-test", formula_name)
               .split("\n")
        installed_dependencies = installed & dependencies
        installed_dependencies.each do |name|
          link_formula = Formulary.factory(name)
          next if link_formula.keg_only?
          next if link_formula.linked_keg.exist?

          test "brew", "link", name, args: args
        end

        dependencies -= installed
        @unchanged_dependencies = dependencies - @formulae
        test "brew", "fetch", "--retry", *@unchanged_dependencies, args: args unless @unchanged_dependencies.empty?

        changed_dependencies = dependencies - @unchanged_dependencies
        unless changed_dependencies.empty?
          test "brew", "fetch", "--retry", "--build-from-source",
                                *changed_dependencies,
                                args: args
          # Install changed dependencies as new bottles so we don't have
          # checksum problems.
          test "brew", "install", "--build-from-source", *changed_dependencies, args: args
          # Run postinstall on them because the tested formula might depend on
          # this step
          test "brew", "postinstall", *changed_dependencies, args: args
        end

        runtime_or_test_dependencies =
          Utils.safe_popen_read("brew", "deps", "--include-test", formula_name)
               .split("\n")
        build_dependencies = dependencies - runtime_or_test_dependencies
        @unchanged_build_dependencies = build_dependencies - @formulae

        if args.keep_old?
          @testable_dependents = @bottled_dependents = @source_dependents = []
          return
        end

        build_dependents_from_source_whitelist = %w[
          cabal-install
          docbook-xsl
          erlang
          ghc
          go
          ocaml
          ocaml-findlib
          ocaml-num
          openjdk
          rust
        ]

        uses_args = []
        uses_args << "--recursive" unless args.skip_recursive_dependents?
        dependents =
          Utils.safe_popen_read("brew", "uses", "--include-build", "--include-test", *uses_args, formula_name)
               .split("\n")
        dependents -= @formulae
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

        # Defer formulae which could be tested later
        # i.e. formulae that also depend on something else yet to be built in this test run.
        dependents.select! do |_, deps|
          still_to_test = @formulae - @built_formulae
          (deps.map { |d| d.to_formula.full_name } & still_to_test).empty?
        end

        # Split into dependents that we could potentially be building from source and those
        # we should not. The criteria is that it depends on a formula in the whitelist and
        # that formula has been, or will be, built in this test run.
        @source_dependents, dependents = dependents.partition do |_, deps|
          deps.any? do |d|
            full_name = d.to_formula.full_name

            next false unless build_dependents_from_source_whitelist.include?(full_name)

            @formulae.include?(full_name)
          end
        end

        # From the non-source list, get rid of any dependents we are only a build dependency to
        dependents.select! do |_, deps|
          deps.reject { |d| d.build? && !d.test? }
              .map(&:to_formula)
              .include?(formula)
        end

        dependents = dependents.transpose.first.to_a
        @source_dependents = @source_dependents.transpose.first.to_a

        @testable_dependents = @source_dependents.select(&:test_defined?)
        @bottled_dependents = with_env(HOMEBREW_SKIP_OR_LATER_BOTTLES: "1") do
          dependents.select(&:bottled?)
        end
        @testable_dependents += @bottled_dependents.select(&:test_defined?)
      end

      def unlink_conflicts(formula, args:)
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
          test "brew", "unlink", conflict.name, args: args
        end
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
        if formula.bottle_disabled?
          @bottle_filename = nil
          return
        end

        ENV["HOMEBREW_BOTTLE_SUDO_PURGE"] = "1" if MacOS.version >= :catalina
        root_url = args.root_url
        bottle_args = ["--verbose", "--json", formula.name]
        bottle_args << "--keep-old" if args.keep_old? && !new_formula
        bottle_args << "--skip-relocation" if args.skip_relocation?
        bottle_args << "--force-core-tap" if @test_default_formula
        bottle_args << "--root-url=#{root_url}" if root_url
        bottle_args << "--or-later" if args.or_later?
        test "brew", "bottle", *bottle_args, args: args

        bottle_step = steps.last
        return unless bottle_step.passed?
        return unless bottle_step.output?

        @bottle_filename =
          bottle_step.output
                     .gsub(%r{.*(\./\S+#{Utils::Bottles.native_regex}).*}m, '\1')
        bottle_json_filename =
          @bottle_filename.gsub(/\.(\d+\.)?tar\.gz$/, ".json")
        bottle_merge_args =
          ["--merge", "--write", "--no-commit", bottle_json_filename]
        bottle_merge_args << "--keep-old" if args.keep_old? && !new_formula

        test "brew", "bottle", *bottle_merge_args, args: args
        test "brew", "uninstall", "--force", formula.name, args: args

        bottle_json = JSON.parse(File.read(bottle_json_filename))
        root_url = bottle_json.dig(formula.full_name, "bottle", "root_url")
        filename = bottle_json.dig(formula.full_name, "bottle", "tags").values.first["filename"]

        download_strategy = CurlDownloadStrategy.new("#{root_url}/#{filename}", formula.name, formula.version)

        HOMEBREW_CACHE.mkpath
        FileUtils.ln @bottle_filename, download_strategy.cached_location, force: true
        FileUtils.ln_s download_strategy.cached_location.relative_path_from(download_strategy.symlink_location),
                       download_strategy.symlink_location,
                       force: true

        @formulae.delete(formula.name)

        unless @unchanged_build_dependencies.empty?
          test "brew", "uninstall", "--force", *@unchanged_build_dependencies, args: args
          @unchanged_dependencies -= @unchanged_build_dependencies
        end

        test "brew", "install", "--only-dependencies", @bottle_filename, args: args
        test "brew", "install", @bottle_filename, args: args
      end

      def install_dependent_from_source(dependent, args:)
        return unless satisfied_requirements?(dependent, :stable)

        if dependent.deprecated? || dependent.disabled?
          verb = dependent.deprecated? ? :deprecated : :disabled
          puts "#{dependent.full_name} has been #{verb}!"
          skip dependent.name
          return
        end

        cleanup_during!(args: args)

        unless dependent.latest_version_installed?
          test "brew", "fetch", "--retry", dependent.full_name, args: args
          return if steps.last.failed?

          unlink_conflicts dependent, args: args
          test "brew", "install", "--build-from-source", "--only-dependencies", dependent.full_name,
               env:  { "HOMEBREW_DEVELOPER" => nil },
               args: args
          test "brew", "install", "--build-from-source", dependent.full_name,
               env:  { "HOMEBREW_DEVELOPER" => nil },
               args: args
          return if steps.last.failed?
        end
        return unless dependent.latest_version_installed?

        if !dependent.keg_only? && !dependent.linked_keg.exist?
          unlink_conflicts dependent, args: args
          test "brew", "link", dependent.full_name, args: args
        end
        test "brew", "install", "--only-dependencies", dependent.full_name, args: args
        test "brew", "linkage", "--test", dependent.full_name, args: args

        if @testable_dependents.include? dependent
          test "brew", "install", "--only-dependencies", "--include-test",
                                  dependent.full_name,
                                  args: args
          test "brew", "test", "--retry", "--verbose", dependent.full_name, args: args
        end

        test "brew", "uninstall", "--force", dependent.full_name, args: args
      end

      def install_bottled_dependent(dependent, args:)
        return unless satisfied_requirements?(dependent, :stable)

        if dependent.deprecated? || dependent.disabled?
          verb = dependent.deprecated? ? :deprecated : :disabled
          puts "#{dependent.full_name} has been #{verb}!"
          skip dependent.name
          return
        end

        cleanup_during!(args: args)

        unless dependent.latest_version_installed?
          test "brew", "fetch", "--retry", dependent.full_name, args: args
          return if steps.last.failed?

          unlink_conflicts dependent, args: args

          test "brew", "install", "--only-dependencies", dependent.full_name,
                env:  { "HOMEBREW_DEVELOPER" => nil },
                args: args
          test "brew", "install", dependent.full_name,
                env:  { "HOMEBREW_DEVELOPER" => nil },
                args: args
          return if steps.last.failed?
        end
        return unless dependent.latest_version_installed?

        if !dependent.keg_only? && !dependent.linked_keg.exist?
          unlink_conflicts dependent, args: args
          test "brew", "link", dependent.full_name, args: args
        end
        test "brew", "install", "--only-dependencies", dependent.full_name, args: args
        test "brew", "linkage", "--test", dependent.full_name, args: args

        if @testable_dependents.include? dependent
          test "brew", "install", "--only-dependencies", "--include-test",
                                  dependent.full_name,
                                  args: args
          test "brew", "test", "--retry", "--verbose", dependent.full_name, args: args
        end

        test "brew", "uninstall", "--force", dependent.full_name, args: args
      end

      def fetch_formula(fetch_args, audit_args, spec_args = [], args:)
        test "brew", "fetch", "--retry", *spec_args, *fetch_args, args: args
        test "brew", "audit", *audit_args, args: args
      end

      def formula!(formula_name, args:)
        cleanup_during!(args: args)

        test_header(:Formulae, method: "formula!(#{formula_name})")

        @built_formulae << formula_name

        formula = Formulary.factory(formula_name)
        if formula.disabled?
          ofail "#{formula.full_name} has been disabled!"
          skip formula.name
          return
        end

        deps = []
        reqs = []

        fetch_args = [formula_name]
        fetch_args << "--build-bottle" unless formula.bottle_disabled?
        fetch_args << "--force" if args.cleanup?

        new_formula = @added_formulae.include?(formula_name)
        audit_args = [formula_name, "--online"]
        if new_formula
          audit_args << "--new-formula"
        else
          audit_args << "--git" << "--skip-style"
        end

        unless satisfied_requirements?(formula, :stable)
          fetch_formula(fetch_args, audit_args, args: args)
          return
        end

        deps |= formula.deps.to_a.reject(&:optional?)
        reqs |= formula.requirements.to_a.reject(&:optional?)

        tap_needed_taps(deps)
        install_gcc_if_needed(formula, deps, args: args)
        install_mercurial_if_needed(deps, reqs, args: args)
        install_subversion_if_needed(deps, reqs, args: args)
        setup_formulae_deps_instances(formula, formula_name, args: args)

        test "brew", "fetch", "--retry", *fetch_args, args: args

        test "brew", "uninstall", "--force", formula_name, args: args if formula.latest_version_installed?

        install_args = ["--verbose"]
        install_args << "--build-bottle" unless formula.bottle_disabled?
        install_args << formula_name

        # Don't care about e.g. bottle failures for dependencies.
        test "brew", "install", "--only-dependencies", *install_args,
              env:  { "HOMEBREW_DEVELOPER" => nil },
              args: args

        test "brew", "install", *install_args,
              env:  { "HOMEBREW_DEVELOPER" => nil },
              args: args
        install_passed = steps.last.passed?

        test "brew", "audit", *audit_args, args: args
        return unless install_passed

        bottle_reinstall_formula(formula, new_formula, args: args)
        test "brew", "linkage", "--test", formula_name, args: args
        failed_linkage_or_test = steps.last.failed?

        test "brew", "install", "--only-dependencies", "--include-test",
                                formula_name,
                                args: args

        if formula.test_defined?
          # Intentionally not passing --retry here to avoid papering over
          # flaky tests when a formula isn't being pulled in as a dependent.
          test "brew", "test", "--verbose", formula_name, args: args
          failed_linkage_or_test ||= steps.last.failed?
        end

        # Don't test dependents or keep bottle if the formula linkage or test failed.
        if failed_linkage_or_test
          FileUtils.rm_rf @bottle_filename if @bottle_filename
          return
        end

        @source_dependents.each do |dependent|
          install_dependent_from_source(dependent, args: args)

          bottled = with_env(HOMEBREW_SKIP_OR_LATER_BOTTLES: "1") do
            dependent.bottled?
          end
          install_bottled_dependent(dependent, args: args) if bottled
        end

        @bottled_dependents.each do |dependent|
          install_bottled_dependent(dependent, args: args)
        end
      ensure
        cleanup_bottle_etc_var(formula) if args.cleanup?

        test "brew", "uninstall", "--force", *@unchanged_dependencies, args: args if @unchanged_dependencies.present?
      end

      def deleted_formula!(formula_name, args:)
        test_header(:Formulae, method: "deleted_formula!(#{formula_name})")

        test "brew", "uses", "--include-build",
                             "--include-optional",
                             "--include-test",
                             formula_name,
                             args: args
      end

      def cleanup_during!(args:)
        return unless args.cleanup?
        return unless HOMEBREW_CACHE.exist?

        used_percentage = Utils.safe_popen_read("df", HOMEBREW_CACHE.to_s)
                               .lines[1] # HOMEBREW_CACHE
                               .split[4] # used %
                               .to_i
        return if used_percentage < 95

        test_header(:Formulae, method: :cleanup_during!)

        test "rm", "-rf", HOMEBREW_CACHE.to_s
      end

      def formulae
        changed_formulae_dependents = {}

        @formulae.each do |formula|
          begin
            formula_dependencies =
              Utils.safe_popen_read("brew", "deps", "--full-name",
                                               "--include-build",
                                               "--include-test", formula)
                   .split("\n")
            # deps can fail if deps are not tapped
            Formulary.factory(formula).recursive_dependencies unless $CHILD_STATUS.success?
          rescue TapFormulaUnavailableError => e
            raise if e.tap.installed?

            e.tap.clear_cache
            safe_system "brew", "tap", e.tap.name
            retry
          end

          unchanged_dependencies = formula_dependencies - @formulae
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
        unchanged_formulae = @formulae - changed_formulae
        changed_formulae + unchanged_formulae
      end
    end
  end
end
