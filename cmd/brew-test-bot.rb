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
#:
#:    If `--skip-recursive-dependents` is passed, only test the direct
#:    dependents.

require_relative "../lib/test_bot"

Homebrew::TestBot.test_bot
