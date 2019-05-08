# frozen_string_literal: true

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
#:    If `--coverage` is passed, generate and upload a coverage report.
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

TEST_BOT_ROOT = File.expand_path "#{File.dirname(__FILE__)}/.."
TEST_BOT_LIB = Pathname.new(TEST_BOT_ROOT)/"lib"

$LOAD_PATH.unshift(TEST_BOT_LIB)

require "test-bot"

module Homebrew
  module_function

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
      current_test = Test.new("HEAD", tap:                 tap,
                                      skip_setup:          skip_setup,
                                      skip_homebrew:       skip_homebrew,
                                      skip_cleanup_before: skip_cleanup_before)
      any_errors = !current_test.run
      tests << current_test
    else
      ARGV.named.each do |argument|
        skip_cleanup_after = argument != ARGV.named.last
        test_error = false
        begin
          current_test =
            Test.new(argument, tap:                 tap,
                               skip_setup:          skip_setup,
                               skip_homebrew:       skip_homebrew,
                               skip_cleanup_before: skip_cleanup_before,
                               skip_cleanup_after:  skip_cleanup_after)
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
        testsuite.add_attribute "tests", test.steps.select(&:passed?).count
        testsuite.add_attribute "failures", test.steps.select(&:failed?).count
        testsuite.add_attribute "timestamp", test.steps.first.start_time.iso8601

        test.steps.each do |step|
          testcase = testsuite.add_element "testcase"
          testcase.add_attribute "name", step.command_short
          testcase.add_attribute "status", step.status
          testcase.add_attribute "time", step.time
          testcase.add_attribute "timestamp", step.start_time.iso8601

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
    if HOMEBREW_CACHE.exist?
      if ARGV.include? "--clean-cache"
        HOMEBREW_CACHE.children.each(&:rmtree)
      else
        Dir.glob("*.bottle*.tar.gz") do |bottle_file|
          FileUtils.rm_f HOMEBREW_CACHE/bottle_file
        end
      end
    end

    Homebrew.failed = any_errors
  end
end

Homebrew.test_bot
