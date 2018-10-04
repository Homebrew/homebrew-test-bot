#:  * `test-bot` [options]  <url|formula>:
#:    Tests the full lifecycle of a formula or Homebrew/brew change.
#:
#:    If `--dry-run` is passed, print what would be done rather than doing
#:    it.
#:
#:    If `--keep-logs` is passed, write and keep log files under
#:    `./brewbot/`.
#:
#:    If `--cleanup` is passed, clean all state from the Homebrew
#:    directory. Use with care!
#:
#:    If `--clean-cache` is passed, remove all cached downloads. Use with
#:    care!
#:
#:    If `--skip-setup` is passed, don't check the local system is setup
#:    correctly.
#:
#:    If `--skip-homebrew` is passed, don't check Homebrew's files and
#:    tests are all valid.
#:
#:    If `--junit` is passed, generate a JUnit XML test results file.
#:
#:    If `--no-bottle` is passed, run `brew install` without
#:    `--build-bottle`.
#:
#:    If `--keep-old` is passed, run `brew bottle --keep-old` to build new
#:    bottles for a single platform.
#:
#:    If `--skip-relocation` is passed, run
#:   `brew bottle --skip-relocation` to build new bottles that don't
#:    require relocation.
#:
#:    If `--HEAD` is passed, run `brew install` with `--HEAD`.
#:
#:    If `--local` is passed, ask Homebrew to write verbose logs under
#:    `./logs/` and set `$HOME` to `./home/`.
#:
#:    If `--tap=<tap>` is passed, use the `git` repository of the given
#:    tap.
#:
#:    If `--dry-run` is passed, just print commands, don't run them.
#:
#:    If `--fail-fast` is passed, immediately exit on a failing step.
#:
#:    If `--verbose` (or `-v`) is passed, print test step output in real time. Has
#:    the side effect of passing output as raw bytes instead of
#:    re-encoding in UTF-8.
#:
#:    If `--fast` is passed, don't install any packages, but run e.g.
#:    `brew audit` anyway.
#:
#:    If `--keep-tmp` is passed, keep temporary files written by main
#:    installs and tests that are run.
#:
#:    If `--no-pull` is passed, don't use `brew pull` when possible.
#:
#:    If `--coverage` is passed, generate and uplaod a coverage report.
#:
#:    If `--test-default-formula` is passed, use a default testing formula
#:    when not building a tap and no other formulae are specified.
#:
#:    If `--bintray-org=<bintray-org>` is passed, upload to the given Bintray
#:    organisation.
#:
#:    If `--root-url` is passed, use the specified <URL> as the root of the
#:    bottle's URL instead of Homebrew's default.
#:
#:    If `--git-name=<git-name>` is passed, set the Git
#:    author/committer names to the given name.
#:
#:    If `--git-email=<git-email>` is passed, set the Git
#:    author/committer email to the given email.
#:
#:    If `--or-later` is passed, append _or_later to the bottle tag.
#:
#:    If `--ci-master` is passed, use the Homebrew master branch CI
#:    options. Implies `--cleanup`: use with care!
#:
#:    If `--ci-pr` is passed, use the Homebrew pull request CI options.
#:    Implies `--cleanup`: use with care!
#:
#:    If `--ci-testing` is passed, use the Homebrew testing CI options.
#:    Implies `--cleanup`: use with care!
#:
#:    If `--ci-auto` is passed, automatically pick one of the Homebrew CI
#:    options based on the environment. Implies `--cleanup`: use with care!
#:
#:    If `--ci-upload` is passed, use the Homebrew CI bottle upload
#:    options.
#:
#:    If `--overwrite` is passed, overwrite existing published artifacts on Bintray
#:
#
#:    Influential environment variables include:
#:    `TRAVIS_REPO_SLUG`: same as `--tap`
#:    `GIT_URL`: if set to URL of a tap remote, same as `--tap`

require "formula"
require "formula_installer"
require "utils"
require "date"
require "rexml/document"
require "rexml/xmldecl"
require "rexml/cdata"
require "tap"
require "development_tools"
require "utils/bottles"
require "json"

module Homebrew
  module_function

  BYTES_IN_1_MEGABYTE = 1024*1024
  MAX_STEP_OUTPUT_SIZE = BYTES_IN_1_MEGABYTE - (200*1024) # margin of safety

  HOMEBREW_TAP_REGEX = %r{^([\w-]+)/homebrew-([\w-]+)$}

  REQUIRED_TAPS = %w[
    homebrew/core
    linuxbrew/test-bot
    linuxbrew/xorg
  ].freeze

  REQUIRED_TEST_BREW_TAPS = REQUIRED_TAPS + %w[
    homebrew/cask
    homebrew/bundle
    homebrew/services
  ].freeze

  def resolve_test_tap
    if (tap = ARGV.value("tap"))
      return Tap.fetch(tap)
    end

    if (tap = ENV["TRAVIS_REPO_SLUG"]) && (tap =~ HOMEBREW_TAP_REGEX)
      return Tap.fetch(tap)
    end

    if ENV["UPSTREAM_BOT_PARAMS"]
      bot_argv = ENV["UPSTREAM_BOT_PARAMS"].split(" ")
      bot_argv.extend HomebrewArgvExtension
      if tap = bot_argv.value("tap")
        return Tap.fetch(tap)
      end
    end

    # Get tap from Jenkins UPSTREAM_GIT_URL, GIT_URL
    # or Azure Pipelines BUILD_REPOSITORY_URI
    # or CircleCI CIRCLE_REPOSITORY_URL.
    git_url =
      ENV["UPSTREAM_GIT_URL"] ||
      ENV["GIT_URL"] ||
      ENV["CIRCLE_REPOSITORY_URL"] ||
      ENV["BUILD_REPOSITORY_URI"]
    return unless git_url

    url_path = git_url.sub(%r{^https?://github\.com/}, "")
                      .chomp("/")
                      .sub(/\.git$/, "")
    begin
      return Tap.fetch(url_path) if url_path =~ HOMEBREW_TAP_REGEX
    rescue
      # Don't care if tap fetch fails
      nil
    end
  end

  # Wraps command invocations. Instantiated by Test#test.
  # Handles logging and pretty-printing.
  class Step
    attr_reader :command, :name, :status, :output

    # Instantiates a Step object.
    # @param test [Test] The parent Test object
    # @param command [Array<String>] Command to execute and arguments
    # @param options [Hash] Recognized options are:
    #   :repository
    #   :env
    #   :puts_output_on_success
    def initialize(test, command, repository:, env: {}, puts_output_on_success: false)
      @test = test
      @category = test.category
      @command = command
      @puts_output_on_success = puts_output_on_success
      @name = command[1].delete("-")
      @status = :running
      @repository = repository
      @env = env
    end

    def log_file_path
      file = "#{@category}.#{@name}.txt"
      root = @test.log_root
      return file unless root
      root + file
    end

    def command_trimmed
      @command.reject { |arg| arg.to_s.start_with?("--exclude") }
              .join(" ")
              .gsub("#{HOMEBREW_LIBRARY}/Taps/", "")
              .gsub("#{HOMEBREW_PREFIX}/", "")
              .gsub("/home/travis/", "")
    end

    def command_short
      (@command - %W[
        brew
        git
        -C
        #{HOMEBREW_PREFIX}
        #{HOMEBREW_REPOSITORY}
        #{@repository}
        --force
        --retry
        --verbose
        --build-bottle
        --build-from-source
        --json
      ].freeze).join(" ")
    end

    def passed?
      @status == :passed
    end

    def failed?
      @status == :failed
    end

    def self.travis_increment
      @travis_step ||= 0
      @travis_step += 1
    end

    def puts_command
      if ENV["HOMEBREW_TRAVIS_CI"]
        travis_fold_name = @command.first(2).join(".")
        travis_fold_name = "git.#{@command[3]}" if travis_fold_name == "git.-C"
        @travis_fold_id = "#{travis_fold_name}.#{Step.travis_increment}"
        @travis_timer_id = rand(2**32).to_s(16)
        puts "travis_fold:start:#{@travis_fold_id}"
        puts "travis_time:start:#{@travis_timer_id}"
      else
        puts
      end
      puts Formatter.headline(command_trimmed, color: :blue)
    end

    def puts_result
      if ENV["HOMEBREW_TRAVIS_CI"]
        travis_start_time = @start_time.to_i * 1_000_000_000
        travis_end_time = @end_time.to_i * 1_000_000_000
        travis_duration = travis_end_time - travis_start_time
        puts Formatter.headline(Formatter.success("PASSED")) if passed?
        travis_time = "travis_time:end:#{@travis_timer_id}"
        travis_time += ",start=#{travis_start_time}"
        travis_time += ",finish=#{travis_end_time}"
        travis_time += ",duration=#{travis_duration}"
        puts travis_time
        puts "travis_fold:end:#{@travis_fold_id}"
      end
      puts Formatter.headline(Formatter.error("FAILED")) if failed?
    end

    def output?
      @output && !@output.empty?
    end

    # The execution time of the task.
    # Precondition: Step#run has been called.
    # @return [Float] execution time in seconds
    def time
      @end_time - @start_time
    end

    def run
      @start_time = Time.now

      puts_command
      if ARGV.include? "--dry-run"
        @end_time = Time.now
        @status = :passed
        puts_result
        return
      end

      if @command[0] == "git" && !%w[-C clone].include?(@command[1])
        raise "git should always be called with -C!"
      end

      executable, *args = @command

      verbose = ARGV.verbose?

      result = system_command executable, args: args,
                                          print_stdout: verbose,
                                          print_stderr: verbose,
                                          env: @env

      @end_time = Time.now
      @status = result.success? ? :passed : :failed
      puts_result

      output = result.merged_output

      unless output.empty?
        output.force_encoding(Encoding::UTF_8)

        @output = if output.valid_encoding?
          output
        else
          output.encode!(Encoding::UTF_16, invalid: :replace)
          output.encode!(Encoding::UTF_8)
        end

        puts @output if (failed? || @puts_output_on_success) && !verbose
        File.write(log_file_path, @output) if ARGV.include? "--keep-logs"
      end

      exit 1 if ARGV.include?("--fail-fast") && failed?
    end
  end

  class Test
    attr_reader :log_root, :category, :name, :steps

    def initialize(argument, tap: nil, skip_setup: false, skip_homebrew: false, skip_cleanup_before: false, skip_cleanup_after: false)
      @hash = nil
      @url = nil
      @formulae = []
      @added_formulae = []
      @modified_formulae = []
      @deleted_formulae = []
      @steps = []
      @tap = tap
      @repository = if @tap
        @test_bot_tap = @tap.to_s == "homebrew/test-bot"
        @tap.path
      else
        HOMEBREW_REPOSITORY
      end
      @skip_setup = skip_setup
      @skip_homebrew = skip_homebrew
      @skip_cleanup_before = skip_cleanup_before
      @skip_cleanup_after = skip_cleanup_after

      if quiet_system("git", "-C", @repository, "rev-parse",
                             "--verify", "-q", argument)
        @hash = argument
      elsif url_match = argument.match(HOMEBREW_PULL_OR_COMMIT_URL_REGEX)
        @url, _, _, pr = *url_match
        @pr_url = @url if pr
      elsif canonical_formula_name = safe_formula_canonical_name(argument)
        @formulae = [canonical_formula_name]
      else
        raise ArgumentError,
          "#{argument} is not a pull request URL, commit URL or formula name."
      end

      @category = __method__
      @brewbot_root = Pathname.pwd + "brewbot"
      FileUtils.mkdir_p @brewbot_root
    end

    def safe_formula_canonical_name(formula_name)
      Formulary.factory(formula_name).full_name
    rescue TapFormulaUnavailableError => e
      raise if e.tap.installed?
      test "brew", "tap", e.tap.name
      retry unless steps.last.failed?
      onoe e
      puts e.backtrace if ARGV.debug?
    rescue FormulaUnavailableError, TapFormulaAmbiguityError,
           TapFormulaWithOldnameAmbiguityError => e
      onoe e
      puts e.backtrace if ARGV.debug?
    end

    def current_sha1
      Utils.popen_read("git", "-C", @repository,
                              "rev-parse", "--short", "HEAD").strip
    end

    def diff_formulae(start_revision, end_revision, path, filter)
      return unless @tap
      Utils.popen_read(
        "git", "-C", @repository,
               "diff-tree", "-r", "--name-only", "--diff-filter=#{filter}",
               start_revision, end_revision, "--", path
      ).lines.map do |line|
        file = Pathname.new line.chomp
        next unless @tap.formula_file?(file)
        @tap.formula_file_to_name(file)
      end.compact
    end

    def merge_commit?(commit)
      Utils.popen_read("git", "-C", @repository, "rev-list", "--parents", "-n1", commit).count(" ") > 1
    end

    def download
      @category = __method__

      @start_branch = Utils.popen_read(
        "git", "-C", @repository, "symbolic-ref", "HEAD"
      ).gsub("refs/heads/", "").strip

      # Use Jenkins GitHub Pull Request Builder or Jenkins Pipeline plugin
      # variables for pull request jobs.
      if ENV["JENKINS_HOME"] && (ENV["ghprbPullLink"] || ENV["CHANGE_URL"])
        @url = ENV["ghprbPullLink"] || ENV["CHANGE_URL"]
        @hash = nil
        test "git", "-C", @repository, "checkout", "origin/master"
      # Use Jenkins Git plugin variables.
      elsif ENV["JENKINS_HOME"] && ENV["GIT_URL"] && ENV["GIT_BRANCH"]
        git_url = ENV["GIT_URL"].chomp("/").chomp(".git")
        %r{origin/pr/(\d+)/(merge|head)} =~ ENV["GIT_BRANCH"]
        if pr = Regexp.last_match(1)
          @url = "#{git_url}/pull/#{pr}"
          @hash = nil
        end
      # Use Circle CI pull-request variables for pull request jobs.
      elsif !ENV["CI_PULL_REQUEST"].to_s.empty?
        @url = ENV["CI_PULL_REQUEST"]
        @hash = nil
      # Use Azure Pipeline variables for pull request jobs.
      elsif ENV["BUILD_REPOSITORY_URI"] && ENV["SYSTEM_PULLREQUEST_PULLREQUESTNUMBER"]
        @url = "#{ENV["BUILD_REPOSITORY_URI"]}/pull/#{ENV["SYSTEM_PULLREQUEST_PULLREQUESTNUMBER"]}"
        @hash = nil
      end

      # Use Jenkins Git plugin variables for master branch jobs.
      if ENV["GIT_PREVIOUS_COMMIT"] && ENV["GIT_COMMIT"]
        diff_start_sha1 = ENV["GIT_PREVIOUS_COMMIT"]
        diff_end_sha1 = ENV["GIT_COMMIT"]
      # Use Travis CI Git variables for master or branch jobs.
      elsif ENV["TRAVIS_COMMIT_RANGE"]
        diff_start_sha1, diff_end_sha1 = ENV["TRAVIS_COMMIT_RANGE"].split "..."
      # Use Jenkins Pipeline plugin variables for branch jobs.
      elsif ENV["JENKINS_HOME"] && !ENV["CHANGE_URL"] && ENV["CHANGE_TARGET"]
        diff_start_sha1 =
          Utils.popen_read("git", "-C", @repository, "rev-parse",
                                  "--short", ENV["CHANGE_TARGET"]).strip
        diff_end_sha1 = current_sha1
      # Use CircleCI Git variables.
      elsif ENV["CIRCLE_SHA1"]
        diff_start_sha1 = "origin/master"
        diff_end_sha1 = ENV["CIRCLE_SHA1"]
      # Use Azure Pipeline variables for master or branch jobs.
      elsif ENV["SYSTEM_PULLREQUEST_TARGETBRANCH"] && ENV["BUILD_SOURCEVERSION"]
        diff_start_sha1 =
          Utils.popen_read("git", "-C", @repository, "rev-parse",
                                  "--short",
                                  ENV["SYSTEM_PULLREQUEST_TARGETBRANCH"]).strip
        diff_end_sha1 = current_sha1
      # Otherwise just use the current SHA-1 (which may be overriden later)
      else
        diff_end_sha1 = diff_start_sha1 = current_sha1
      end

      if merge_commit? diff_end_sha1
        old_start_sha1 = diff_start_sha1
        diff_start_sha1 = Utils.popen_read("git", "-C", @repository, "rev-parse", "#{diff_end_sha1}^1").strip
        puts "Merge commit: #{old_start_sha1}..#{diff_start_sha1}..#{diff_end_sha1}"
      else
        diff_start_sha1 = Utils.popen_read("git", "-C", @repository, "merge-base",
                                diff_start_sha1, diff_end_sha1).strip
      end

      puts "Testing commits: #{diff_start_sha1}..#{diff_end_sha1}"

      # Handle no arguments being passed on the command-line
      # e.g. `brew test-bot`
      if @hash == "HEAD"
        diff_commit_count = Utils.popen_read(
          "git", "-C", @repository, "rev-list", "--count",
          "#{diff_start_sha1}..#{diff_end_sha1}"
        )
        @name = if (diff_start_sha1 == diff_end_sha1) ||
                   (diff_commit_count.to_i == 1)
          diff_end_sha1
        else
          "#{diff_start_sha1}-#{diff_end_sha1}"
        end
      # Handle formulae arguments being passed on the command-line
      # e.g. `brew test-bot wget fish`
      elsif !@formulae.empty?
        @name = "#{@formulae.first}-#{diff_end_sha1}"
        diff_start_sha1 = diff_end_sha1
      # Handle a hash being passed on the command-line
      # e.g. `brew test-bot 1a2b3c`
      elsif @hash
        test "git", "-C", @repository, "checkout", @hash
        diff_start_sha1 = "#{@hash}^"
        diff_end_sha1 = @hash
        @name = @hash
      # Handle a URL being passed on the command-line or through Jenkins
      # environment variables e.g.
      # `brew test-bot https://github.com/Homebrew/homebrew-core/pull/678`
      elsif @url
        unless ARGV.include?("--no-pull")
          diff_start_sha1 = current_sha1
          test "brew", "pull", "--clean", *[@tap ? "--tap=#{@tap}" : nil, @url].compact
          diff_end_sha1 = current_sha1
        end
        @short_url = @url.gsub("https://github.com/", "")
        @name = if @short_url.include? "/commit/"
          # 7 characters should be enough for a commit (not 40).
          @short_url.gsub!(%r{(commit/\w{7}).*/}, '\1')
          @short_url
        else
          "#{@short_url}-#{diff_end_sha1}"
        end
      else
        raise "Cannot set @name: invalid command-line arguments!"
      end

      @log_root = @brewbot_root + @name
      FileUtils.mkdir_p @log_root

      # Output post-cleanup/download repository revisions.
      brew_version = Utils.popen_read(
        "git", "-C", HOMEBREW_REPOSITORY.to_s,
               "describe", "--tags", "--abbrev", "--dirty"
      ).strip
      brew_commit_subject = Utils.popen_read(
        "git", "-C", HOMEBREW_REPOSITORY.to_s,
               "log", "-1", "--format=%s"
      ).strip
      puts "Homebrew/brew #{brew_version} (#{brew_commit_subject})"
      if @tap.to_s != "homebrew/core"
        core_path = CoreTap.instance.path
        if core_path.exist?
          if ENV["HOMEBREW_TRAVIS_CI"]
            test "git", "-C", core_path.to_s, "fetch", "--depth=1", "origin"
            test "git", "-C", core_path.to_s, "reset", "--hard", "origin/master"
          end
        else
          test "git", "clone", "--depth=1",
               "https://github.com/Homebrew/homebrew-core",
               core_path.to_s
        end

        core_revision = Utils.popen_read(
          "git", "-C", core_path.to_s,
                 "log", "-1", "--format=%h (%s)"
        ).strip
        puts "Homebrew/homebrew-core #{core_revision}"
      end
      if @tap
        tap_origin_master_revision = Utils.popen_read(
          "git", "-C", @tap.path.to_s,
                 "log", "-1", "--format=%h (%s)", "origin/master"
        ).strip
        puts "#{@tap} origin/master #{tap_origin_master_revision}"
        tap_revision = Utils.popen_read(
          "git", "-C", @tap.path.to_s,
                 "log", "-1", "--format=%h (%s)"
        ).strip
        puts "#{@tap} HEAD #{tap_revision}"
      end

      return if diff_start_sha1 == diff_end_sha1
      return if @url && steps.last && !steps.last.passed?

      if @tap && !@test_bot_tap
        formula_path = @tap.formula_dir.to_s
        @added_formulae +=
          diff_formulae(diff_start_sha1, diff_end_sha1, formula_path, "A")
        if merge_commit? diff_end_sha1
          # Test formulae whose bottles were updated.
          summaries = Utils.popen_read("git", "-C", @repository, "log", "--pretty=%s", "#{diff_start_sha1}..#{diff_end_sha1}").lines
          @modified_formulae = summaries.map { |s| s[/^([^:]+): update .* bottle\.$/, 1] }.compact.uniq
        else
          @modified_formulae +=
            diff_formulae(diff_start_sha1, diff_end_sha1, formula_path, "M")
        end
        @deleted_formulae +=
          diff_formulae(diff_start_sha1, diff_end_sha1, formula_path, "D")
        unless @modified_formulae.empty?
          or_later_diff = Utils.popen_read(
            "git", "-C", @repository, "diff",
            "-G    sha256 ['\"][a-f0-9]*['\"] => :\\w+_or_later$",
            "--unified=0", diff_start_sha1, diff_end_sha1
          ).strip.empty?

          # Test rather than build bottles if we're testing a `*_or_later`
          # bottle change.
          ARGV << "--no-bottle" unless or_later_diff
        end
      elsif @formulae.empty? && ARGV.include?("--test-default-formula")
        # Build the default test formula.
        @test_default_formula = true
        @modified_formulae = ["testbottest"]
      end

      @formulae += @added_formulae + @modified_formulae
      @test_brew = (!@tap || @test_bot_tap) &&
                   (@formulae.empty? || @test_default_formula)
    end

    def skip(formula_name)
      puts Formatter.headline("SKIPPING: #{Formatter.identifier(formula_name)}")
    end

    def satisfied_requirements?(formula, spec, dependency = nil)
      f = Formulary.factory(formula.full_name, spec)
      fi = FormulaInstaller.new(f)
      stable_spec = spec == :stable
      fi.build_bottle = stable_spec && !ARGV.include?("--no-bottle")

      unsatisfied_requirements, = fi.expand_requirements
      return true if unsatisfied_requirements.empty?

      name = formula.full_name
      name += " (#{spec})" unless stable_spec
      name += " (#{dependency} dependency)" if dependency
      skip name
      puts unsatisfied_requirements.values.flatten.map(&:message)
      false
    end

    def setup
      @category = __method__
      return if @skip_setup
      # install newer Git when needed
      if OS.mac? && MacOS.version < :sierra
        test "brew", "install", "git"
        ENV["HOMEBREW_FORCE_BREWED_GIT"] = "1"
      end
      test "brew", "doctor"
      test "brew", "--env"
      test "brew", "config"
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
      begin
        deps.each { |dep| CompilerSelector.select_for(dep.to_formula) }
        if formula.devel &&
           formula.stable? &&
           !ARGV.include?("--HEAD") &&
           !ARGV.include?("--fast")
          CompilerSelector.select_for(formula)
          CompilerSelector.select_for(formula.devel)
        elsif ARGV.include?("--HEAD")
          CompilerSelector.select_for(formula.head)
        elsif formula.stable
          CompilerSelector.select_for(formula)
        elsif formula.devel
          CompilerSelector.select_for(formula.devel)
        end
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
        return
      end
    end

    def install_mercurial_if_needed(deps, reqs)
      if (deps | reqs).any? { |d| d.name == "mercurial" && d.build? }
        test "brew", "install", "mercurial",
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
        test "brew", "unlink", "--force", name
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
      unless @unchanged_dependencies.empty?
        test "brew", "fetch", "--retry", *@unchanged_dependencies
      end

      changed_dependencies = dependencies - @unchanged_dependencies
      unless changed_dependencies.empty?
        test "brew", "fetch", "--retry", "--build-from-source",
                              *changed_dependencies
        unless ARGV.include?("--fast")
          # Install changed dependencies as new bottles so we don't have
          # checksum problems.
          test "brew", "install", "--build-from-source", *changed_dependencies
          # Run postinstall on them because the tested formula might depend on
          # this step
          test "brew", "postinstall", *changed_dependencies
        end
      end

      runtime_or_test_dependencies =
        Utils.popen_read("brew", "deps", "--include-test", formula_name)
             .split("\n")
      build_dependencies = dependencies - runtime_or_test_dependencies
      @unchanged_build_dependencies = build_dependencies - @formulae

      args = ["--recursive"] unless OS.linux?
      dependents =
        Utils.popen_read("brew", "uses", *args, formula_name)
             .split("\n")
      dependents -= @formulae
      dependents = dependents.map { |d| Formulary.factory(d) }
      dependents = [] if ARGV.include? "--skip-dependents"

      @bottled_dependents = dependents.select(&:bottled?)
      @testable_dependents = dependents.select do |d|
        d.bottled? && d.test_defined?
      end
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
      return unless ARGV.include? "--cleanup"
      bottle_prefix = formula.opt_prefix/".bottle"
      # Nuke etc/var to have them be clean to detect bottle etc/var
      # file additions.
      Pathname.glob("#{bottle_prefix}/{etc,var}/**/*").each do |bottle_path|
        prefix_path = bottle_path.sub(bottle_prefix, HOMEBREW_PREFIX)
        FileUtils.rm_rf prefix_path
      end
    end

    def bottle_reinstall_formula(formula, new_formula)
      return unless formula.stable?
      return if ARGV.include?("--fast")
      return if ARGV.include?("--no-bottle")
      return if formula.bottle_disabled?

      root_url = ARGV.value("root-url")
      bottle_args = ["--verbose", "--json", formula.name]
      bottle_args << "--keep-old" if ARGV.include?("--keep-old") && !new_formula
      bottle_args << "--skip-relocation" if ARGV.include? "--skip-relocation"
      bottle_args << "--force-core-tap" if @test_default_formula
      bottle_args << "--root-url=#{root_url}" if root_url
      bottle_args << "--or-later" if ARGV.include? "--or-later"
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
      if ARGV.include?("--keep-old") && !new_formula
        bottle_merge_args << "--keep-old"
      end

      test "brew", "bottle", *bottle_merge_args
      test "brew", "uninstall", "--force", formula.name

      bottle_json = JSON.parse(File.read(bottle_json_filename))
      root_url = bottle_json.dig(formula.full_name, "bottle", "root_url")
      filename = bottle_json.dig(formula.full_name, "bottle", "tags").values.first["filename"]

      download_strategy = CurlDownloadStrategy.new("#{root_url}/#{filename}", formula.name, formula.version)

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
      install_args = *("--force-bottle" if @test_default_formula)
      test "brew", "install", *install_args, bottle_filename
    end

    def install_bottled_dependent(dependent)
      unless dependent.installed?
        test "brew", "fetch", "--retry", dependent.name

        return if steps.last.failed?
        unlink_conflicts dependent
        unless ARGV.include?("--fast")
          test "brew", "install", "--only-dependencies", dependent.name,
               env: { "HOMEBREW_DEVELOPER" => nil }
          test "brew", "install", dependent.name,
               env: { "HOMEBREW_DEVELOPER" => nil }
          return if steps.last.failed?
        end
      end
      return unless dependent.installed?
      if !dependent.keg_only? && !dependent.linked_keg.exist?
        unlink_conflicts dependent
        test "brew", "link", dependent.name
      end
      test "brew", "install", "--only-dependencies", dependent.name
      test "brew", "linkage", "--test", dependent.name

      return unless @testable_dependents.include? dependent

      test "brew", "install", "--only-dependencies", "--include-test",
                              dependent.name
      test "brew", "test", "--verbose", dependent.name
    end

    def fetch_formula(fetch_args, audit_args, spec_args = [])
      test "brew", "fetch", "--retry", *spec_args, *fetch_args
      test "brew", "audit", *audit_args
    end

    def formula(formula_name)
      @category = "#{__method__}.#{formula_name}"

      args = ["--recursive"] unless OS.linux?
      test "brew", "uses", *args, formula_name

      formula = Formulary.factory(formula_name)

      deps = []
      reqs = []

      fetch_args = [formula_name]
      if !ARGV.include?("--fast") &&
         !ARGV.include?("--no-bottle") &&
         !formula.bottle_disabled?
        fetch_args << "--build-bottle"
      end
      fetch_args << "--force" if ARGV.include? "--cleanup"
      new_formula = @added_formulae.include?(formula_name)
      audit_args = [formula_name, "--online"]
      if new_formula
        audit_args << "--new-formula"
        if url_match = @url.to_s.match(HOMEBREW_PULL_OR_COMMIT_URL_REGEX)
          _, _, _, pr = *url_match
          ENV["HOMEBREW_NEW_FORMULA_PULL_REQUEST_URL"] = @url if pr
        end
      end

      if formula.stable
        unless satisfied_requirements?(formula, :stable)
          fetch_formula(fetch_args, audit_args)
          return
        end

        deps |= formula.stable.deps.to_a.reject(&:optional?)
        reqs |= formula.stable.requirements.to_a.reject(&:optional?)
      elsif formula.devel
        unless satisfied_requirements?(formula, :devel)
          fetch_formula(fetch_args, audit_args, ["--devel"])
          return
        end
      end
      if formula.devel && !ARGV.include?("--HEAD")
        deps |= formula.devel.deps.to_a.reject(&:optional?)
        reqs |= formula.devel.requirements.to_a.reject(&:optional?)
      end

      tap_needed_taps(deps)
      install_gcc_if_needed(formula, deps)
      install_mercurial_if_needed(deps, reqs)
      setup_formulae_deps_instances(formula, formula_name)

      test "brew", "fetch", "--retry", *fetch_args
      test "brew", "uninstall", "--force", formula_name if formula.installed?

      # shared_*_args are applied to both the main and --devel spec
      shared_install_args = ["--verbose"]
      shared_install_args << "--keep-tmp" if ARGV.keep_tmp?
      if !ARGV.include?("--fast") &&
         !ARGV.include?("--no-bottle") &&
         !formula.bottle_disabled?
        shared_install_args << "--build-bottle"
      end

      # install_args is just for the main (stable, or devel if in a devel-only
      # tap) spec
      install_args = []
      install_args << "--HEAD" if ARGV.include? "--HEAD"

      # Pass --devel or --HEAD to install in the event formulae lack stable.
      # Supports devel-only/head-only.
      # head-only should not have devel, but devel-only can have head.
      # Stable can have all three.
      formula_bottled = if devel_only_tap? formula
        install_args << "--devel"
        false
      elsif head_only_tap? formula
        install_args << "--HEAD"
        false
      else
        formula.bottled?
      end

      install_args += shared_install_args
      install_args << formula_name

      # Don't care about e.g. bottle failures for dependencies.
      install_passed = false
      if !ARGV.include?("--fast") || formula_bottled || formula.bottle_unneeded?
        test "brew", "install", "--only-dependencies", *install_args,
             env: { "HOMEBREW_DEVELOPER" => nil }
        test "brew", "install", *install_args,
             env: { "HOMEBREW_DEVELOPER" => nil }

        install_passed = steps.last.passed?
      end

      test "brew", "audit", *audit_args

      # Only check for style violations if not already shown by
      # `brew audit --new-formula`
      test "brew", "style", formula_name unless new_formula

      test_args = ["--verbose"]
      test_args << "--keep-tmp" if ARGV.keep_tmp?

      if install_passed
        bottle_reinstall_formula(formula, new_formula)

        if formula.test_defined?
          test "brew", "install", "--only-dependencies", "--include-test",
                                  formula_name
          test "brew", "test", formula_name, *test_args
          test "brew", "linkage", "--test", formula_name
        end

        @bottled_dependents.each do |dependent|
          install_bottled_dependent(dependent)
        end
        cleanup_bottle_etc_var(formula)

        test "brew", "uninstall", "--force", formula_name
      end

      if formula.devel &&
         formula.stable? &&
         OS.mac? &&
         !ARGV.include?("--HEAD") &&
         !ARGV.include?("--fast") &&
         satisfied_requirements?(formula, :devel)
        test "brew", "fetch", "--retry", "--devel", *fetch_args

        test "brew", "install", "--devel", "--only-dependencies", formula_name, *shared_install_args,
             env: { "HOMEBREW_DEVELOPER" => nil }
        test "brew", "install", "--devel", formula_name, *shared_install_args,
             env: { "HOMEBREW_DEVELOPER" => nil }
        devel_install_passed = steps.last.passed?

        if devel_install_passed
          test "brew", "postinstall", formula_name

          if formula.test_defined?
            test "brew", "install", "--devel", "--only-dependencies",
                                    "--include-test", formula_name
            test "brew", "test", "--devel", formula_name, *test_args
          end

          cleanup_bottle_etc_var(formula)
          test "brew", "uninstall", "--devel", "--force", formula_name
        end
      end

      return if @unchanged_dependencies.empty?
      test "brew", "uninstall", "--force", *@unchanged_dependencies
    end

    def deleted_formula(formula_name)
      @category = "#{__method__}.#{formula_name}"
      test "brew", "uses", "--include-build",
                           "--include-optional",
                           "--include-test",
                           formula_name
    end

    def homebrew
      @category = __method__
      return if @skip_homebrew

      if @test_brew
        # test update from origin/master to current commit.
        test "brew", "update-test" unless OS.linux? # This test currently fails on Linux.
        # test update from origin/master to current tag.
        test "brew", "update-test", "--to-tag"
        # test no-op update from current commit (to current commit, a no-op).
        test "brew", "update-test", "--commit=HEAD"

        installed_taps = Tap.select(&:installed?).map(&:name)
        (REQUIRED_TEST_BREW_TAPS - installed_taps).each do |tap|
          test "brew", "tap", tap
        end

        test "brew", "tap", "homebrew/cask"
        test "brew", "tap", "homebrew/bundle"

        test "brew", "readall", "--aliases"

        if OS.linux?
          test "brew", "tests", "--no-compat", "--online"
          test "brew", "tests", "--generic", "--online"
        end

        if ARGV.include?("--coverage")
          test "brew", "tests", "--online", "--coverage"
          FileUtils.cp_r "#{HOMEBREW_REPOSITORY}/Library/Homebrew/test/coverage",
                         Dir.pwd
        else
          test "brew", "tests", "--online"
        end

        # these commands use gems installed by `brew tests`
        test "brew", "man", "--fail-if-changed"
        test "brew", "style"
      elsif @tap
        test "brew", "readall", "--aliases", @tap.name
      end
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
        "--exclude=coverage",
        "--exclude=Library/Taps",
        "--exclude=Library/Homebrew/vendor",
        "--exclude=#{@brewbot_root.basename}",
      ]
      return if Utils.popen_read(
        "git", "-C", repository, "clean", "--dry-run", *clean_args
      ).strip.empty?
      test "git", "-C", repository, "clean", "-ff", *clean_args
    end

    def prune_if_needed(repository)
      return unless Utils.popen_read(
        "git -C '#{repository}' -c gc.autoDetach=false gc --auto 2>&1",
      ).include?("git prune")
      test "git", "-C", repository, "prune"
    end

    def checkout_branch_if_needed(repository, branch = "master")
      current_branch = Utils.popen_read(
        "git", "-C", repository, "symbolic-ref", "--short", "HEAD"
      ).strip
      return if branch == current_branch
      checkout_args = [branch]
      checkout_args << "-f" if ARGV.include? "--cleanup"
      test "git", "-C", repository, "checkout", *checkout_args
    end

    def reset_if_needed(repository)
      if system("git", "-C", repository, "diff", "--quiet", "origin/master")
        return
      end

      test "git", "-C", repository, "reset", "--hard", "origin/master"
    end

    def cleanup_shared
      cleanup_git_meta(@repository)
      clean_if_needed(@repository)
      prune_if_needed(@repository)

      Tap.names.each do |tap_name|
        next if tap_name == @tap&.name
        if @test_brew && REQUIRED_TEST_BREW_TAPS.include?(tap_name)
          next
        elsif REQUIRED_TAPS.include?(tap_name)
          next
        end
        test "brew", "untap", tap_name
      end

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
        # don't try to delete osxfuse files
        next if path_string.match?(
          "(include|lib)/(lib|osxfuse/|pkgconfig/)?(osx|mac)?fuse(.*\.(dylib|h|la|pc))?$",
        )
        FileUtils.rm_rf path
      end

      if @tap
        checkout_branch_if_needed(HOMEBREW_REPOSITORY)
        reset_if_needed(HOMEBREW_REPOSITORY)
        clean_if_needed(HOMEBREW_REPOSITORY)
      end

      Pathname.glob("#{HOMEBREW_LIBRARY}/Taps/*/*").each do |git_repo|
        cleanup_git_meta(git_repo)
        next if @repository == git_repo
        checkout_branch_if_needed(git_repo)
        reset_if_needed(git_repo)
        prune_if_needed(git_repo)
      end

      test "brew", "prune"
    end

    def clear_stash_if_needed(repository)
      return if Utils.popen_read(
        "git", "-C", repository, "stash", "list"
      ).strip.empty?

      test "git", "-C", repository, "stash", "clear"
    end

    def cleanup_before
      @category = __method__
      return if @skip_cleanup_before
      return unless ARGV.include? "--cleanup"

      clear_stash_if_needed(@repository)
      quiet_system "git", "-C", @repository, "am", "--abort"
      quiet_system "git", "-C", @repository, "rebase", "--abort"

      unless ARGV.include?("--no-pull")
        checkout_branch_if_needed(@repository)
        reset_if_needed(@repository)
      end

      # FIXME: I have no idea if this change is safe for Circle CI or not,
      # so temporarily make it Mac-only until we can safely experiment.
      Pathname.glob("*.bottle*.*").each(&:unlink) if OS.mac?

      # Cleanup NodeJS headers on Azure Pipeline
      if OS.linux? && ENV["TF_BUILD"]
        test "sudo", "rm", "-rf", "/usr/local/include/node"
      end

      cleanup_shared
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
      @category = __method__
      return if @skip_cleanup_after
      return if ENV["CIRCLECI"]

      if ENV["HOMEBREW_TRAVIS_CI"]
        if OS.mac?
          # For Travis CI build caching.
          test "brew", "install", "md5deep", "libyaml", "gmp", "openssl@1.1"
        end

        return if @tap && @tap.to_s != "homebrew/test-bot"
      end

      unless @start_branch.to_s.empty?
        checkout_branch_if_needed(@repository, @start_branch)
      end

      if ARGV.include?("--cleanup")
        clear_stash_if_needed(@repository)
        reset_if_needed(@repository) unless ENV["HOMEBREW_TRAVIS_CI"]

        test "brew", "cleanup", "--prune=7"

        pkill_if_needed!

        cleanup_shared unless ENV["HOMEBREW_TRAVIS_CI"]

        if ARGV.include? "--local"
          FileUtils.rm_rf ENV["HOMEBREW_HOME"]
          FileUtils.rm_rf ENV["HOMEBREW_LOGS"]
        end
      end

      FileUtils.rm_rf @brewbot_root unless ARGV.include? "--keep-logs"
    end

    def test(*args, **options)
      step = Step.new(self, args, repository: @repository, **options)
      step.run
      steps << step
      step
    end

    def check_results
      steps.all? do |step|
        case step.status
        when :passed  then true
        when :running then raise
        when :failed  then false
        end
      end
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
          unless $CHILD_STATUS.success?
            Formulary.factory(formula).recursive_dependencies
          end
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

    def head_only_tap?(formula)
      return false unless formula.head
      return false if formula.devel
      return false if formula.stable
      formula.tap.to_s.downcase !~ %r{[-/]head-only$}
    end

    def devel_only_tap?(formula)
      return false unless formula.devel
      return false if formula.stable
      formula.tap.to_s.downcase !~ %r{[-/]devel-only$}
    end

    def run
      cleanup_before
      begin
        download
        setup
        homebrew
        formulae.each do |f|
          formula(f)
        end
        @deleted_formulae.each do |f|
          deleted_formula(f)
        end
      ensure
        cleanup_after
      end
      check_results
    end
  end

  def test_ci_upload(tap)
    # Don't trust formulae we're uploading
    ENV["HOMEBREW_DISABLE_LOAD_FORMULA"] = "1"

    bintray_user = ENV["HOMEBREW_BINTRAY_USER"]
    bintray_key = ENV["HOMEBREW_BINTRAY_KEY"]
    if !bintray_user || !bintray_key
      unless ARGV.include?("--dry-run")
        raise "Missing HOMEBREW_BINTRAY_USER or HOMEBREW_BINTRAY_KEY variables!"
      end
    end

    # Ensure that uploading Homebrew bottles on Linux doesn't use Linuxbrew.
    bintray_org = ARGV.value("bintray-org") || "homebrew"
    if bintray_org == "homebrew" && !OS.mac?
      ENV["HOMEBREW_FORCE_HOMEBREW_ORG"] = "1"
    end

    # Don't pass keys/cookies to subprocesses
    ENV.clear_sensitive_environment!

    ARGV << "--verbose"

    bottles = Dir["*.bottle*.*"]
    if bottles.empty?
      jenkins = ENV["JENKINS_HOME"]
      job = ENV["UPSTREAM_JOB_NAME"]
      id = ENV["UPSTREAM_BUILD_ID"]
      if (!job || !id) && !ARGV.include?("--dry-run")
        raise "Missing Jenkins variables!"
      end

      jenkins_dir  = "#{jenkins}/jobs/#{job}/configurations/axis-version/*/"
      jenkins_dir += "builds/#{id}/archive/*.bottle*.*"
      bottles = Dir[jenkins_dir]
      raise "No bottles found!" if bottles.empty? && !ARGV.include?("--dry-run")

      FileUtils.cp bottles, Dir.pwd, verbose: true
    end

    json_files = Dir.glob("*.bottle.json")
    bottles_hash = json_files.reduce({}) do |hash, json_file|
      hash.deep_merge(JSON.parse(IO.read(json_file)))
    end

    if ARGV.include?("--dry-run")
      bottles_hash = {
        "testbottest" => {
          "formula" => {
            "pkg_version" => "1.0.0",
          },
          "bottle" => {
            "rebuild" => 0,
            "tags" => {
              Utils::Bottles.tag => {
                "filename" =>
                  "testbottest-1.0.0.#{Utils::Bottles.tag}.bottle.tar.gz",
                "sha256" =>
                  "20cdde424f5fe6d4fdb6a24cff41d2f7aefcd1ef2f98d46f6c074c36a1eef81e",
              },
            },
          },
          "bintray" => {
            "package" => "testbottest",
            "repository" => "bottles",
          },
        },
      }
    end

    first_formula_name = bottles_hash.keys.first
    tap_name = first_formula_name.rpartition("/").first.chuzzle
    tap_name ||= "homebrew/core"
    tap ||= Tap.fetch(tap_name)

    ENV["GIT_WORK_TREE"] = tap.path
    ENV["GIT_DIR"] = "#{ENV["GIT_WORK_TREE"]}/.git"
    ENV["HOMEBREW_GIT_NAME"] = ARGV.value("git-name") || "BrewTestBot"
    ENV["HOMEBREW_GIT_EMAIL"] = ARGV.value("git-email") ||
                                "homebrew-test-bot@lists.sfconservancy.org"

    if ARGV.include?("--dry-run")
      puts <<~EOS
        git am --abort
        git rebase --abort
        git checkout -f master
        git reset --hard origin/master
        brew update
      EOS
    else
      quiet_system "git", "am", "--abort"
      quiet_system "git", "rebase", "--abort"
      safe_system "git", "checkout", "-f", "master"
      safe_system "git", "reset", "--hard", "origin/master"
      safe_system "brew", "update"
    end

    # These variables are for Jenkins, Jenkins pipeline and
    # Circle CI respectively.
    pr = ENV["UPSTREAM_PULL_REQUEST"] ||
         ENV["CHANGE_ID"] ||
         ENV["CIRCLE_PR_NUMBER"]
    if pr
      pull_pr = "#{tap.default_remote}/pull/#{pr}"
      safe_system "brew", "pull", "--clean", *("--tap=#{tap}" if tap), pull_pr
    end

    if ENV["UPSTREAM_BOTTLE_KEEP_OLD"] ||
       ENV["BOT_PARAMS"].to_s.include?("--keep-old") ||
       ARGV.include?("--keep-old")
      system "brew", "bottle", "--merge", "--write", "--keep-old", *json_files
    elsif !ARGV.include?("--dry-run")
      system "brew", "bottle", "--merge", "--write", *json_files
    else
      puts "brew bottle --merge --write $JSON_FILES"
    end

    # These variables are for Jenkins and Circle CI respectively.
    upstream_number = ENV["UPSTREAM_BUILD_NUMBER"] || ENV["CIRCLE_BUILD_NUM"]
    git_name = ENV["HOMEBREW_GIT_NAME"]
    remote = "git@github.com:#{git_name}/homebrew-#{tap.repo}.git"
    git_tag = if pr
      "pr-#{pr}"
    elsif upstream_number
      "testing-#{upstream_number}"
    elsif (number = ENV["BUILD_NUMBER"])
      "other-#{number}"
    elsif ARGV.include?("--dry-run")
      "$GIT_TAG"
    end

    if git_tag
      if ARGV.include?("--dry-run")
        puts "git push --force #{remote} master:master :refs/tags/#{git_tag}"
      else
        safe_system "git", "push", "--force", remote,
                                   "master:master", ":refs/tags/#{git_tag}"
      end
    end

    formula_packaged = {}

    bottles_hash.each do |formula_name, bottle_hash|
      version = bottle_hash["formula"]["pkg_version"]
      bintray_package = bottle_hash["bintray"]["package"]
      bintray_repo = bottle_hash["bintray"]["repository"]
      bintray_packages_url =
        "https://api.bintray.com/packages/#{bintray_org}/#{bintray_repo}"

      rebuild = bottle_hash["bottle"]["rebuild"]

      bottle_hash["bottle"]["tags"].each do |tag, tag_hash|
        filename = Bottle::Filename.new(formula_name, version, tag, rebuild)
        bintray_url =
          "#{HOMEBREW_BOTTLE_DOMAIN}/#{bintray_repo}/#{filename.bintray}"
        filename_already_published = if ARGV.include?("--dry-run")
          puts "curl -I --output /dev/null #{bintray_url}"
          false
        else
          begin
            system(curl_executable, *curl_args("-I", "--output", "/dev/null",
                   bintray_url))
          end
        end

        if filename_already_published
          raise <<~EOS
            #{filename.bintray} is already published. Please remove it manually from
            https://bintray.com/#{bintray_org}/#{bintray_repo}/#{bintray_package}/view#files
          EOS
        end

        unless formula_packaged[formula_name]
          package_url = "#{bintray_packages_url}/#{bintray_package}"
          package_exists = if ARGV.include?("--dry-run")
            puts "curl --output /dev/null #{package_url}"
            false
          else
            system(curl_executable, *curl_args("--output", "/dev/null", package_url))
          end

          unless package_exists
            package_blob = <<~EOS
              {"name": "#{bintray_package}",
               "public_download_numbers": true,
               "public_stats": true}
            EOS
            if ARGV.include?("--dry-run")
              puts <<~EOS
                curl --user $HOMEBREW_BINTRAY_USER:$HOMEBREW_BINTRAY_KEY
                     --header Content-Type: application/json
                     --data #{package_blob.delete("\n")}
                     #{bintray_packages_url}
              EOS
            else
              curl "--user", "#{bintray_user}:#{bintray_key}",
                   "--header", "Content-Type: application/json",
                   "--data", package_blob, bintray_packages_url
              puts
            end
          end
          formula_packaged[formula_name] = true
        end

        content_url = "https://api.bintray.com/content/#{bintray_org}"
        content_url +=
          "/#{bintray_repo}/#{bintray_package}/#{version}/#{filename.bintray}"
        content_url += "?override=1" if ARGV.include? "--overwrite"

        if ARGV.include?("--dry-run")
          puts <<~EOS
            curl --user $HOMEBREW_BINTRAY_USER:$HOMEBREW_BINTRAY_KEY
                 --upload-file #{filename}
                 #{content_url}
          EOS
        else
          curl "--user", "#{bintray_user}:#{bintray_key}",
               "--upload-file", filename, content_url
          puts
        end
      end
    end

    return unless git_tag

    if ARGV.include?("--dry-run")
      puts "git tag --force #{git_tag}"
      puts "git push --force #{remote} master:master refs/tags/#{git_tag}"
    else
      safe_system "git", "tag", "--force", git_tag
      safe_system "git", "push", "--force", remote, "master:master",
                                                    "refs/tags/#{git_tag}"
    end
  end

  def sanitize_argv_and_env
    if Pathname.pwd == HOMEBREW_PREFIX && ARGV.include?("--cleanup")
      odie "cannot use --cleanup from HOMEBREW_PREFIX as it will delete all output."
    end

    ENV["HOMEBREW_DEVELOPER"] = "1"
    ENV["HOMEBREW_NO_AUTO_UPDATE"] = "1"
    ENV["HOMEBREW_NO_EMOJI"] = "1"
    ENV["HOMEBREW_FAIL_LOG_LINES"] = "150"
    ENV["HOMEBREW_PATH"] = ENV["PATH"] =
      "#{HOMEBREW_PREFIX}/bin:#{HOMEBREW_PREFIX}/sbin:#{ENV["PATH"]}"

    travis = !ENV["TRAVIS"].nil?
    circle = !ENV["CIRCLECI"].nil?
    if travis || circle
      ARGV << "--verbose" << "--ci-auto" << "--no-pull"
      ENV["HOMEBREW_TRAVIS_CI"] = "1"
      ENV["HOMEBREW_TRAVIS_SUDO"] = ENV["TRAVIS_SUDO"]
      ENV["HOMEBREW_COLOR"] = "1"
      ENV["HOMEBREW_VERBOSE_USING_DOTS"] = "1"
    end

    jenkins = !ENV["JENKINS_HOME"].nil?
    ENV["CI"] = "1" if jenkins
    jenkins_pipeline_pr = jenkins && !ENV["CHANGE_URL"].nil?
    jenkins_pipeline_branch = jenkins &&
                              !jenkins_pipeline_pr &&
                              !ENV["BRANCH_NAME"].nil?
    ARGV << "--ci-auto" if jenkins_pipeline_branch || jenkins_pipeline_pr
    ARGV << "--no-pull" if jenkins_pipeline_branch

    azure_pipelines = !ENV["TF_BUILD"].nil?
    if azure_pipelines
      ARGV << "--verbose" << "--ci-auto" << "--no-pull"
      ENV["HOMEBREW_AZURE_PIPELINES"] = "1"
      ENV["CI"] = "1"
      # These cannot be queried at the macOS level on Azure Pipelines.
      ENV["HOMEBREW_LANGUAGES"] = "en-GB"
    end

    ENV["HOMEBREW_CODECOV_TOKEN"] = ENV["CODECOV_TOKEN"]

    # Only report coverage if build runs on macOS and this is indeed Homebrew,
    # as we don't want this to be averaged with inferior Linux test coverage.
    if OS.mac? &&
       MacOS.version == :high_sierra &&
       (ENV["HOMEBREW_CODECOV_TOKEN"] || travis)
      ARGV << "--coverage"
    end

    travis_pr = ENV["TRAVIS_PULL_REQUEST"] &&
                ENV["TRAVIS_PULL_REQUEST"] != "false"
    circle_pr = ENV["CI_PULL_REQUEST"] &&
                !ENV["CI_PULL_REQUEST"].empty?
    jenkins_pr = !ENV["ghprbPullLink"].nil?
    jenkins_pr ||= !ENV["ROOT_BUILD_CAUSE_GHPRBCAUSE"].nil?
    jenkins_pr ||= jenkins_pipeline_pr
    jenkins_branch = !ENV["GIT_COMMIT"].nil?
    jenkins_branch ||= jenkins_pipeline_branch
    azure_pipelines_pr = ENV["BUILD_REASON"] == "PullRequest"

    if ARGV.include?("--ci-auto")
      if travis_pr || jenkins_pr || azure_pipelines_pr || circle_pr
        ARGV << "--ci-pr"
      elsif travis || circle || jenkins_branch
        ARGV << "--ci-master"
      else
        ARGV << "--ci-testing"
      end
    end

    if ARGV.include?("--ci-master") ||
       ARGV.include?("--ci-pr") ||
       ARGV.include?("--ci-testing")
      ARGV << "--cleanup"
      ARGV << "--test-default-formula"
      ARGV << "--local" if jenkins
      ARGV << "--junit" if jenkins || azure_pipelines || circle
    end

    ARGV << "--fast" if ARGV.include?("--ci-master")

    test_bot_revision = Utils.popen_read(
      "git", "-C", Tap.fetch("homebrew/test-bot").path.to_s,
             "log", "-1", "--format=%h (%s)"
    ).strip
    puts "Homebrew/homebrew-test-bot #{test_bot_revision}"
    puts "ARGV: #{ARGV.join(" ")}"

    return unless ARGV.include?("--local")
    ENV["HOMEBREW_HOME"] = ENV["HOME"] = "#{Dir.pwd}/home"
    mkdir_p ENV["HOMEBREW_HOME"]
    ENV["HOMEBREW_LOGS"] = "#{Dir.pwd}/logs"
  end

  def test_bot
    $stdout.sync = true
    $stderr.sync = true

    sanitize_argv_and_env

    tap = resolve_test_tap
    # Tap repository if required, this is done before everything else
    # because Formula parsing and/or git commit hash lookup depends on it.
    # At the same time, make sure Tap is not a shallow clone.
    # bottle rebuild and bottle upload rely on full clone.
    if tap
      if !tap.path.exist?
        safe_system "brew", "tap", tap.name, "--full"
      elsif (tap.path/".git/shallow").exist?
        raise unless quiet_system "git", "-C", tap.path, "fetch", "--unshallow"
      end
    end

    return test_ci_upload(tap) if ARGV.include?("--ci-upload")

    tests = []
    any_errors = false
    skip_setup = ARGV.include?("--skip-setup")
    skip_homebrew = ARGV.include?("--skip-homebrew")
    skip_cleanup_before = false
    if ARGV.named.empty?
      # With no arguments just build the most recent commit.
      current_test = Test.new("HEAD", tap: tap,
                                      skip_setup: skip_setup,
                                      skip_homebrew: skip_homebrew,
                                      skip_cleanup_before: skip_cleanup_before)
      any_errors = !current_test.run
      tests << current_test
    else
      ARGV.named.each do |argument|
        skip_cleanup_after = argument != ARGV.named.last
        test_error = false
        begin
          current_test =
            Test.new(argument, tap: tap,
                               skip_setup: skip_setup,
                               skip_homebrew: skip_homebrew,
                               skip_cleanup_before: skip_cleanup_before,
                               skip_cleanup_after: skip_cleanup_after)
          skip_setup = true
          skip_homebrew = true
          skip_cleanup_before = true
        rescue ArgumentError => e
          test_error = true
          ofail e.message
        else
          test_error = !current_test.run
          tests << current_test
        end
        any_errors ||= test_error
      end
    end

    if ARGV.include? "--junit"
      xml_document = REXML::Document.new
      xml_document << REXML::XMLDecl.new
      testsuites = xml_document.add_element "testsuites"

      tests.each do |test|
        testsuite = testsuites.add_element "testsuite"
        testsuite.add_attribute "name", "brew-test-bot.#{Utils::Bottles.tag}"
        testsuite.add_attribute "tests", test.steps.count

        test.steps.each do |step|
          testcase = testsuite.add_element "testcase"
          testcase.add_attribute "name", step.command_short
          testcase.add_attribute "status", step.status
          testcase.add_attribute "time", step.time

          next unless step.output?
          output = sanitize_output_for_xml(step.output)
          cdata = REXML::CData.new output

          if step.passed?
            elem = testcase.add_element "system-out"
          else
            elem = testcase.add_element "failure"
            elem.add_attribute "message",
                               "#{step.status}: #{step.command.join(" ")}"
          end

          elem << cdata
        end
      end

      open("brew-test-bot.xml", "w") do |xml_file|
        pretty_print_indent = 2
        xml_document.write(xml_file, pretty_print_indent)
      end
    end
  ensure
    if ARGV.include? "--clean-cache"
      HOMEBREW_CACHE.children.each(&:rmtree)
    else
      Dir.glob("*.bottle*.tar.gz") do |bottle_file|
        FileUtils.rm_f HOMEBREW_CACHE/bottle_file
      end
    end

    Homebrew.failed = any_errors
  end

  def sanitize_output_for_xml(output)
    return output if output.empty?

    # Remove invalid XML CData characters from step output.
    invalid_xml_pat =
      /[^\x09\x0A\x0D\x20-\uD7FF\uE000-\uFFFD\u{10000}-\u{10FFFF}]/
    output.gsub!(invalid_xml_pat, "\uFFFD")

    return output if output.bytesize <= MAX_STEP_OUTPUT_SIZE

    # Truncate to 1MB to avoid hitting CI limits
    output =
      truncate_text_to_approximate_size(
        output, MAX_STEP_OUTPUT_SIZE, front_weight: 0.0
      )
    "truncated output to 1MB:\n#{output}"
  end
end

Homebrew.test_bot
