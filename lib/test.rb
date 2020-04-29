# frozen_string_literal: true

require "os"
require "tap"

module Homebrew
  class Test
    REQUIRED_HOMEBREW_TAPS = [CoreTap.instance.name] + %w[
      homebrew/test-bot
    ].freeze

    REQUIRED_LINUXBREW_TAPS = REQUIRED_HOMEBREW_TAPS + %w[
      linuxbrew/xorg
    ].freeze

    REQUIRED_TAPS = if OS.mac? || ENV["HOMEBREW_FORCE_HOMEBREW_ON_LINUX"]
      REQUIRED_HOMEBREW_TAPS
    else
      REQUIRED_LINUXBREW_TAPS
    end

    attr_reader :log_root, :category, :name, :steps

    def initialize(argument, tap:, git:, skip_cleanup_before:, skip_cleanup_after:)
      @argument = argument
      @tap = tap
      @git = git
      @skip_cleanup_before = skip_cleanup_before
      @skip_cleanup_after = skip_cleanup_after

      @steps = []

      @repository = if @tap
        @test_bot_tap = @tap.to_s == "homebrew/test-bot"
        @tap.path
      else
        CoreTap.instance.path
      end

      @brewbot_root = Pathname.pwd + "brewbot"
      FileUtils.mkdir_p @brewbot_root
    end

    def method_header(method, klass: "Test")
      @category = method
      puts
      puts Formatter.headline("Running #{klass}##{method}", color: :magenta)
    end

    def safe_formula_canonical_name(formula_name)
      Formulary.factory(formula_name).full_name
    rescue TapFormulaUnavailableError => e
      raise if e.tap.installed?

      test "brew", "tap", e.tap.name
      retry unless steps.last.failed?
      onoe e
      puts e.backtrace if Homebrew.args.debug?
    rescue FormulaUnavailableError, TapFormulaAmbiguityError,
           TapFormulaWithOldnameAmbiguityError => e
      onoe e
      puts e.backtrace if Homebrew.args.debug?
    end

    def current_sha1
      Utils.popen_read(@git, "-C", @repository,
                             "rev-parse", "HEAD").strip
    end

    def diff_formulae(start_revision, end_revision, path, filter)
      return unless @tap

      Utils.popen_read(
        @git, "-C", @repository,
              "diff-tree", "-r", "--name-only", "--diff-filter=#{filter}",
              start_revision, end_revision, "--", path
      ).lines.map do |line|
        file = Pathname.new line.chomp
        next unless @tap.formula_file?(file)

        @tap.formula_file_to_name(file)
      end.compact
    end

    def detect_formulae
      method_header(__method__)

      hash = nil
      url = nil

      if @argument == "HEAD"
        # Use GitHub Actions variables for pull request jobs.
        hash = if ENV["GITHUB_REF"] && ENV["GITHUB_REPOSITORY"] &&
                  %r{refs/pull/(?<pr>\d+)/merge} =~ ENV["GITHUB_REF"]
          url = "https://github.com/#{ENV["GITHUB_REPOSITORY"]}/pull/#{pr}/checks"
          nil
        else
          "HEAD"
        end
      elsif (canonical_formula_name = safe_formula_canonical_name(@argument))
        @formulae = [canonical_formula_name]
      else
        raise UsageError,
          "#{@argument} is not detected from GitHub Actions or a formula name!"
      end

      @start_branch = Utils.popen_read(
        @git, "-C", @repository, "symbolic-ref", "HEAD"
      ).gsub("refs/heads/", "").strip

      # Use GitHub Actions variables for master or branch jobs.
      if ENV["GITHUB_BASE_REF"] && ENV["GITHUB_SHA"]
        diff_start_sha1 =
          Utils.popen_read(@git, "-C", @repository, "rev-parse",
                                 "origin/#{ENV["GITHUB_BASE_REF"]}").strip
        diff_end_sha1 = ENV["GITHUB_SHA"]
      # Otherwise just use the current SHA-1 (which may be overriden later)
      else
        if !ENV["GITHUB_REF"] && !ENV["GITHUB_BASE_REF"]
          onoe <<~EOS
            No known CI provider detected! If you are using GitHub Actions then we cannot find the expected  environment variables! Check you have e.g. exported them to a Docker container.
          EOS
        end
        diff_end_sha1 = diff_start_sha1 = current_sha1
      end

      if diff_start_sha1.present? && diff_end_sha1.present?
        diff_start_sha1 =
          Utils.popen_read(@git, "-C", @repository, "merge-base",
                                 diff_start_sha1, diff_end_sha1).strip
      end
      diff_start_sha1 = current_sha1 if diff_start_sha1.blank?
      diff_end_sha1 = current_sha1 if diff_end_sha1.blank?

      # Handle no arguments being passed on the command-line e.g.
      #   brew test-bot
      name = if hash == "HEAD"
        diff_commit_count = Utils.popen_read(
          @git, "-C", @repository, "rev-list", "--count",
          "#{diff_start_sha1}..#{diff_end_sha1}"
        )
        if (diff_start_sha1 == diff_end_sha1) || (diff_commit_count.to_i == 1)
          diff_end_sha1
        else
          "#{diff_start_sha1}-#{diff_end_sha1}"
        end
      # Handle formulae arguments being passed on the command-line e.g.
      #   brew test-bot wget fish
      elsif @formulae.present?
        diff_start_sha1 = diff_end_sha1
        "#{@formulae.first}-#{diff_end_sha1}"
      # Handle a URL being detected from GitHub Actions environment variables.
      elsif url
        short_url = url.gsub("https://github.com/", "")
        "#{short_url}-#{diff_end_sha1}"
      else
        raise UsageError, "Cannot set name: invalid command-line arguments!"
      end

      log_root = @brewbot_root + name
      FileUtils.mkdir_p log_root

      if @tap.to_s != CoreTap.instance.name
        core_revision = Utils.popen_read(
          @git, "-C", CoreTap.instance.path.to_s,
                "log", "-1", "--format=%h (%s)"
        ).strip
        puts Formatter.headline("Using #{CoreTap.instance.full_name} #{core_revision}", color: :cyan)
      end

      if @tap
        tap_origin_master_revision = Utils.popen_read(
          @git, "-C", @tap.path.to_s,
                "log", "-1", "--format=%h (%s)", "origin/master"
        ).strip
        tap_revision = Utils.popen_read(
          @git, "-C", @tap.path.to_s,
                "log", "-1", "--format=%h (%s)"
        ).strip
        puts Formatter.headline("Testing #{@tap.full_name} #{tap_revision}:", color: :cyan)
      end

      puts <<-EOS
    url             #{url.blank? ? "(undefined)" : url}
    origin/master   #{tap_origin_master_revision.blank? ? "(undefined)" : tap_origin_master_revision}
    diff_start_sha1 #{diff_start_sha1.blank? ? "(undefined)" : diff_start_sha1}
    diff_end_sha1   #{diff_end_sha1.blank? ? "(undefined)" : diff_end_sha1}
    HEAD            #{tap_revision.blank? ? "(undefined)" : tap_revision}
      EOS

      @formulae ||= []
      @added_formulae = []
      @deleted_formulae = []
      @built_formulae = []

      return if diff_start_sha1 == diff_end_sha1

      modified_formulae = nil

      if @tap && !@test_bot_tap
        formula_path = @tap.formula_dir.to_s
        @added_formulae +=
          diff_formulae(diff_start_sha1, diff_end_sha1, formula_path, "A")
        modified_formulae =
          diff_formulae(diff_start_sha1, diff_end_sha1, formula_path, "M")
        @deleted_formulae +=
          diff_formulae(diff_start_sha1, diff_end_sha1, formula_path, "D")
      elsif @formulae.empty? && Homebrew.args.test_default_formula?
        # Build the default test formula.
        @test_default_formula = true
        modified_formulae = ["testbottest"]
      end

      @formulae += @added_formulae + modified_formulae

      puts Formatter.headline("Testing Formula changes:", color: :cyan)
      puts <<-EOS
    added    #{@added_formulae.blank? ? "(empty)" : @added_formulae.join(" ")}
    modified #{modified_formulae.blank? ? "(empty)" : modified_formulae.join(" ")}
    deleted  #{@deleted_formulae.blank? ? "(empty)" : @deleted_formulae.join(" ")}
      EOS
    end

    def skip(formula_name)
      puts Formatter.headline("#{Formatter.warning("SKIPPED")} #{Formatter.identifier(formula_name)}", color: :yellow)
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

    def install_gcc_if_needed(formula, deps)
      installed_gcc = false
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
      skip formula.name
      puts e.message
    end

    def install_mercurial_if_needed(deps, reqs)
      if (deps | reqs).any? { |d| d.name == "mercurial" && d.build? }
        test "brew", "install", "mercurial",
             env: { "HOMEBREW_DEVELOPER" => nil }
      end
    end

    def install_subversion_if_needed(deps, reqs)
      if (deps | reqs).any? { |d| d.name == "subversion" && d.build? }
        test "brew", "install", "subversion",
             env: { "HOMEBREW_DEVELOPER" => nil }
      end
    end

    def setup_formulae_deps_instances(formula, formula_name)
      conflicts = formula.conflicts
      formula.recursive_dependencies.each do |dependency|
        conflicts += dependency.to_formula.conflicts
      end
      unlink_formulae = conflicts.map(&:name)
      unlink_formulae.uniq.each do |name|
        unlink_formula = Formulary.factory(name)
        next unless unlink_formula.installed?
        next unless unlink_formula.linked_keg.exist?

        test "brew", "unlink", name
      end

      installed = Utils.popen_read("brew", "list").split("\n")
      dependencies =
        Utils.popen_read("brew", "deps", "--include-build",
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
      @unchanged_dependencies = dependencies - @formulae
      test "brew", "fetch", "--retry", *@unchanged_dependencies unless @unchanged_dependencies.empty?

      changed_dependencies = dependencies - @unchanged_dependencies
      unless changed_dependencies.empty?
        test "brew", "fetch", "--retry", "--build-from-source",
                              *changed_dependencies
        # Install changed dependencies as new bottles so we don't have
        # checksum problems.
        test "brew", "install", "--build-from-source", *changed_dependencies
        # Run postinstall on them because the tested formula might depend on
        # this step
        test "brew", "postinstall", *changed_dependencies
      end

      runtime_or_test_dependencies =
        Utils.popen_read("brew", "deps", "--include-test", formula_name)
             .split("\n")
      build_dependencies = dependencies - runtime_or_test_dependencies
      @unchanged_build_dependencies = build_dependencies - @formulae

      if Homebrew.args.keep_old?
        @testable_dependents = @bottled_dependents = @source_dependents = []
        return
      end

      build_dependents_from_source_whitelist = %w[
        cabal-install
        docbook-xsl
        ghc
        go
        ocaml
        ocaml-findlib
        ocaml-num
        openjdk
        rust
      ]

      uses_args = []
      uses_args << "--recursive" unless Homebrew.args.skip_recursive_dependents?
      dependents =
        Utils.popen_read("brew", "uses", "--include-build", "--include-test", *uses_args, formula_name)
             .split("\n")
      dependents -= @formulae
      dependents = dependents.map { |d| Formulary.factory(d) }

      dependents = dependents.zip(dependents.map do |f|
        if Homebrew.args.skip_recursive_dependents?
          f.deps
        else
          f.recursive_dependencies
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

    def unlink_conflicts(formula)
      return if formula.keg_only?
      return if formula.linked_keg.exist?

      conflicts = formula.conflicts.map { |c| Formulary.factory(c.name) }
                         .select(&:installed?)
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
        end.select(&:installed?)
      end
      conflicts.each do |conflict|
        test "brew", "unlink", conflict.name
      end
    end

    def cleanup_bottle_etc_var(formula)
      return unless Homebrew.args.cleanup?

      bottle_prefix = formula.opt_prefix/".bottle"
      # Nuke etc/var to have them be clean to detect bottle etc/var
      # file additions.
      Pathname.glob("#{bottle_prefix}/{etc,var}/**/*").each do |bottle_path|
        prefix_path = bottle_path.sub(bottle_prefix, HOMEBREW_PREFIX)
        FileUtils.rm_rf prefix_path
      end
    end

    def bottle_reinstall_formula(formula, new_formula)
      return if formula.bottle_disabled?

      ENV["HOMEBREW_BOTTLE_SUDO_PURGE"] = "1" if MacOS.version >= :catalina
      root_url = Homebrew.args.root_url
      bottle_args = ["--verbose", "--json", formula.name]
      bottle_args << "--keep-old" if Homebrew.args.keep_old? && !new_formula
      bottle_args << "--skip-relocation" if Homebrew.args.skip_relocation?
      bottle_args << "--force-core-tap" if @test_default_formula
      bottle_args << "--root-url=#{root_url}" if root_url
      bottle_args << "--or-later" if Homebrew.args.or_later?
      test "brew", "bottle", *bottle_args

      bottle_step = steps.last
      return unless bottle_step.passed?
      return unless bottle_step.output?

      bottle_filename =
        bottle_step.output
                   .gsub(%r{.*(\./\S+#{Utils::Bottles.native_regex}).*}m, '\1')
      bottle_json_filename =
        bottle_filename.gsub(/\.(\d+\.)?tar\.gz$/, ".json")
      bottle_merge_args =
        ["--merge", "--write", "--no-commit", bottle_json_filename]
      bottle_merge_args << "--keep-old" if Homebrew.args.keep_old? && !new_formula

      test "brew", "bottle", *bottle_merge_args
      test "brew", "uninstall", "--force", formula.name

      bottle_json = JSON.parse(File.read(bottle_json_filename))
      root_url = bottle_json.dig(formula.full_name, "bottle", "root_url")
      filename = bottle_json.dig(formula.full_name, "bottle", "tags").values.first["filename"]

      download_strategy = CurlDownloadStrategy.new("#{root_url}/#{filename}", formula.name, formula.version)

      HOMEBREW_CACHE.mkpath
      FileUtils.ln bottle_filename, download_strategy.cached_location, force: true
      FileUtils.ln_s download_strategy.cached_location.relative_path_from(download_strategy.symlink_location),
                     download_strategy.symlink_location,
                     force: true

      @formulae.delete(formula.name)

      unless @unchanged_build_dependencies.empty?
        test "brew", "uninstall", "--force", *@unchanged_build_dependencies
        @unchanged_dependencies -= @unchanged_build_dependencies
      end

      test "brew", "install", "--only-dependencies", bottle_filename
      test "brew", "install", bottle_filename
    end

    def install_dependent_from_source(dependent)
      return unless satisfied_requirements?(dependent, :stable)

      if dependent.deprecated? || dependent.disabled?
        verb = dependent.deprecated? ? :deprecated : :disabled
        puts "#{dependent.full_name} has been #{verb}!"
        skip dependent.name
        return
      end

      cleanup_during

      unless dependent.installed?
        test "brew", "fetch", "--retry", dependent.full_name
        return if steps.last.failed?

        unlink_conflicts dependent
        test "brew", "install", "--build-from-source", "--only-dependencies",
             dependent.full_name, env: { "HOMEBREW_DEVELOPER" => nil }
        test "brew", "install", "--build-from-source", dependent.full_name,
             env: { "HOMEBREW_DEVELOPER" => nil }
        return if steps.last.failed?
      end
      return unless dependent.installed?

      if !dependent.keg_only? && !dependent.linked_keg.exist?
        unlink_conflicts dependent
        test "brew", "link", dependent.full_name
      end
      test "brew", "install", "--only-dependencies", dependent.full_name
      test "brew", "linkage", "--test", dependent.full_name

      if @testable_dependents.include? dependent
        test "brew", "install", "--only-dependencies", "--include-test",
                                dependent.full_name
        test "brew", "test", "--verbose", dependent.full_name
      end

      test "brew", "uninstall", "--force", dependent.full_name
    end

    def install_bottled_dependent(dependent)
      return unless satisfied_requirements?(dependent, :stable)

      if dependent.deprecated? || dependent.disabled?
        verb = dependent.deprecated? ? :deprecated : :disabled
        puts "#{dependent.full_name} has been #{verb}!"
        skip dependent.name
        return
      end

      cleanup_during

      unless dependent.installed?
        test "brew", "fetch", "--retry", dependent.full_name
        return if steps.last.failed?

        unlink_conflicts dependent

        test "brew", "install", "--only-dependencies", dependent.full_name,
              env: { "HOMEBREW_DEVELOPER" => nil }
        test "brew", "install", dependent.full_name,
              env: { "HOMEBREW_DEVELOPER" => nil }
        return if steps.last.failed?
      end
      return unless dependent.installed?

      if !dependent.keg_only? && !dependent.linked_keg.exist?
        unlink_conflicts dependent
        test "brew", "link", dependent.full_name
      end
      test "brew", "install", "--only-dependencies", dependent.full_name
      test "brew", "linkage", "--test", dependent.full_name

      if @testable_dependents.include? dependent
        test "brew", "install", "--only-dependencies", "--include-test",
                                dependent.full_name
        test "brew", "test", "--verbose", dependent.full_name
      end

      test "brew", "uninstall", "--force", dependent.full_name
    end

    def fetch_formula(fetch_args, audit_args, spec_args = [])
      test "brew", "fetch", "--retry", *spec_args, *fetch_args
      test "brew", "audit", *audit_args
    end

    def formula(formula_name)
      cleanup_during

      method_header("#{__method__}.#{formula_name}")

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
      fetch_args << "--force" if Homebrew.args.cleanup?

      new_formula = @added_formulae.include?(formula_name)
      audit_args = [formula_name, "--online"]
      audit_args << "--new-formula" if new_formula

      unless satisfied_requirements?(formula, :stable)
        fetch_formula(fetch_args, audit_args)
        return
      end

      deps |= formula.deps.to_a.reject(&:optional?)
      reqs |= formula.requirements.to_a.reject(&:optional?)

      tap_needed_taps(deps)
      install_gcc_if_needed(formula, deps)
      install_mercurial_if_needed(deps, reqs)
      install_subversion_if_needed(deps, reqs)
      setup_formulae_deps_instances(formula, formula_name)

      test "brew", "fetch", "--retry", *fetch_args
      test "brew", "uninstall", "--force", formula_name if formula.installed?

      install_args = ["--verbose"]
      install_args << "--build-bottle" unless formula.bottle_disabled?
      install_args << formula_name

      # Don't care about e.g. bottle failures for dependencies.
      test "brew", "install", "--only-dependencies", *install_args,
            env: { "HOMEBREW_DEVELOPER" => nil }
      test "brew", "install", *install_args,
            env: { "HOMEBREW_DEVELOPER" => nil }
      install_passed = steps.last.passed?

      test "brew", "audit", "--skip-style", *audit_args

      if install_passed
        bottle_reinstall_formula(formula, new_formula)
        test "brew", "linkage", "--test", formula_name

        if formula.test_defined?
          test "brew", "install", "--only-dependencies", "--include-test",
                                  formula_name
          test "brew", "test", "--verbose", formula_name
        end

        @source_dependents.each do |dependent|
          install_dependent_from_source(dependent)

          bottled = with_env(HOMEBREW_SKIP_OR_LATER_BOTTLES: "1") do
            dependent.bottled?
          end
          install_bottled_dependent(dependent) if bottled
        end
        @bottled_dependents.each do |dependent|
          install_bottled_dependent(dependent)
        end
        cleanup_bottle_etc_var(formula)
      end

      return if @unchanged_dependencies.empty?

      test "brew", "uninstall", "--force", *@unchanged_dependencies
    end

    def deleted_formula(formula_name)
      method_header("#{__method__}.#{formula_name}")

      test "brew", "uses", "--include-build",
                           "--include-optional",
                           "--include-test",
                           formula_name
    end

    def cleanup_git_meta(repository)
      pr_locks = "#{repository}/.git/refs/remotes/*/pr/*/*.lock"
      Dir.glob(pr_locks) { |lock| FileUtils.rm_f lock }
      FileUtils.rm_f "#{repository}/.git/gc.log"
    end

    def clean_if_needed(repository)
      return if repository == HOMEBREW_PREFIX

      clean_args = [
        "-dx",
        "--exclude=*.bottle*.*",
        "--exclude=Library/Taps",
        "--exclude=Library/Homebrew/vendor",
        "--exclude=#{@brewbot_root.basename}",
      ]
      return if Utils.popen_read(
        @git, "-C", repository, "clean", "--dry-run", *clean_args
      ).strip.empty?

      test @git, "-C", repository, "clean", "-ff", *clean_args
    end

    def prune_if_needed(repository)
      return unless Utils.popen_read(
        "#{@git} -C '#{repository}' -c gc.autoDetach=false gc --auto 2>&1",
      ).include?("git prune")

      test @git, "-C", repository, "prune"
    end

    def checkout_branch_if_needed(repository, branch = "master")
      current_branch = Utils.popen_read(
        @git, "-C", repository, "symbolic-ref", "HEAD"
      ).strip
      return if branch == current_branch

      checkout_args = [branch]
      checkout_args << "-f" if Homebrew.args.cleanup?
      test @git, "-C", repository, "checkout", *checkout_args
    end

    def reset_if_needed(repository)
      return if system(@git, "-C", repository, "diff", "--quiet", "origin/master")

      test @git, "-C", repository, "reset", "--hard", "origin/master"
    end

    def cleanup_shared
      cleanup_git_meta(@repository)
      clean_if_needed(@repository)
      prune_if_needed(@repository)

      Keg::MUST_BE_WRITABLE_DIRECTORIES.each(&:mkpath)
      Pathname.glob("#{HOMEBREW_PREFIX}/**/*").each do |path|
        next if Keg::MUST_BE_WRITABLE_DIRECTORIES.include?(path)
        next if path == HOMEBREW_PREFIX/"bin/brew"
        next if path == HOMEBREW_PREFIX/"var"
        next if path == HOMEBREW_PREFIX/"var/homebrew"

        path_string = path.to_s
        next if path_string.start_with?(HOMEBREW_REPOSITORY.to_s)
        next if path_string.start_with?(@brewbot_root.to_s)
        next if path_string.start_with?(Dir.pwd.to_s)

        # allow deleting non-existent osxfuse symlinks.
        if !path.symlink? || path.resolved_path_exists?
          # don't try to delete other osxfuse files
          next if path_string.match?(
            "(include|lib)/(lib|osxfuse/|pkgconfig/)?(osx|mac)?fuse(.*\.(dylib|h|la|pc))?$",
          )
        end

        FileUtils.rm_rf path
      end

      if @tap
        checkout_branch_if_needed(HOMEBREW_REPOSITORY)
        reset_if_needed(HOMEBREW_REPOSITORY)
        clean_if_needed(HOMEBREW_REPOSITORY)
      end

      # Keep all "brew" invocations after HOMEBREW_REPOSITORY operations
      # (which cleans up Homebrew/brew)
      Tap.names.each do |tap_name|
        next if tap_name == @tap&.name
        next if REQUIRED_TAPS.include?(tap_name)

        test "brew", "untap", tap_name
      end

      Pathname.glob("#{HOMEBREW_LIBRARY}/Taps/*/*").each do |git_repo|
        cleanup_git_meta(git_repo)
        next if @repository == git_repo

        checkout_branch_if_needed(git_repo)
        reset_if_needed(git_repo)
        prune_if_needed(git_repo)
      end
    end

    def clear_stash_if_needed(repository)
      return if Utils.popen_read(
        @git, "-C", repository, "stash", "list"
      ).strip.empty?

      test @git, "-C", repository, "stash", "clear"
    end

    def cleanup_before
      return if @skip_cleanup_before
      return unless Homebrew.args.cleanup?

      method_header(__method__)

      unless @test_bot_tap
        clear_stash_if_needed(@repository)
        quiet_system @git, "-C", @repository, "am", "--abort"
        quiet_system @git, "-C", @repository, "rebase", "--abort"
      end

      if @tap.to_s != CoreTap.instance.name
        core_path = CoreTap.instance.path
        if core_path.exist?
          test @git, "-C", core_path.to_s, "fetch", "--depth=1", "origin"
          reset_if_needed(core_path.to_s)
        else
          test @git, "clone", "--depth=1",
               CoreTap.instance.default_remote,
               core_path.to_s
        end
      end

      Pathname.glob("*.bottle*.*").each(&:unlink)

      # Keep all "brew" invocations after cleanup_shared
      # (which cleans up Homebrew/brew)
      cleanup_shared

      installed_taps = Tap.select(&:installed?).map(&:name)
      (REQUIRED_TAPS - installed_taps).each do |tap|
        test "brew", "tap", tap
      end

      # install newer Git when needed
      if OS.mac? && MacOS.version < :sierra
        test "brew", "install", "git"
        ENV["HOMEBREW_FORCE_BREWED_GIT"] = "1"
        @git = "git"
      end

      brew_version = Utils.popen_read(
        @git, "-C", HOMEBREW_REPOSITORY.to_s,
              "describe", "--tags", "--abbrev", "--dirty"
      ).strip
      brew_commit_subject = Utils.popen_read(
        @git, "-C", HOMEBREW_REPOSITORY.to_s,
              "log", "-1", "--format=%s"
      ).strip
      puts
      puts Formatter.headline("Using Homebrew/brew #{brew_version} (#{brew_commit_subject})", color: :cyan)
    end

    def pkill_if_needed!
      pgrep = ["pgrep", "-f", HOMEBREW_CELLAR.to_s]
      if quiet_system(*pgrep)
        test "pkill", "-f", HOMEBREW_CELLAR.to_s
        if quiet_system(*pgrep)
          sleep 1
          test "pkill", "-9", "-f", HOMEBREW_CELLAR.to_s if system(*pgrep)
        end
      end
    end

    def cleanup_after
      return if @skip_cleanup_after

      if ENV["HOMEBREW_GITHUB_ACTIONS"] && !ENV["GITHUB_ACTIONS_HOMEBREW_SELF_HOSTED"]
        # don't need to do post-build cleanup unless testing test-bot itself.
        return if @tap.to_s != "homebrew/test-bot"
      end

      method_header(__method__)

      # Needed even when --cleanup not set to ensure we go back to the
      # user's start branch.
      checkout_branch_if_needed(@repository, @start_branch) unless @start_branch.to_s.empty?

      return unless Homebrew.args.cleanup?

      unless @test_bot_tap
        clear_stash_if_needed(@repository)
        reset_if_needed(@repository)
      end

      pkill_if_needed!

      cleanup_shared

      # Keep all "brew" invocations after cleanup_shared
      # (which cleans up Homebrew/brew)
      test "brew", "cleanup", "--prune=3"

      if Homebrew.args.local?
        FileUtils.rm_rf ENV["HOMEBREW_HOME"]
        FileUtils.rm_rf ENV["HOMEBREW_LOGS"]
      end
    end

    def cleanup_during
      return unless Homebrew.args.cleanup?
      return unless HOMEBREW_CACHE.exist?

      used_percentage = Utils.popen_read("df", HOMEBREW_CACHE.to_s)
                             .lines[1] # HOMEBREW_CACHE
                             .split[4] # used %
                             .to_i
      return if used_percentage < 95

      method_header(__method__)

      test "brew", "cleanup", "--prune=0"

      # remove any leftovers manually
      HOMEBREW_CACHE.children.each(&:rmtree)
    end

    def test(*args, env: {}, verbose: Homebrew.args.verbose?)
      step = Step.new(args, env: env, verbose: verbose)
      step.run
      steps << step
      step
    end

    def formulae
      changed_formulae_dependents = {}

      @formulae.each do |formula|
        begin
          formula_dependencies =
            Utils.popen_read("brew", "deps", "--full-name",
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

    def test_formulae
      detect_formulae
      formulae.each do |f|
        formula(f)
      end
      @deleted_formulae.each do |f|
        deleted_formula(f)
      end
    end
  end
end
