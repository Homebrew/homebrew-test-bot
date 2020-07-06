# frozen_string_literal: true

require "os"
require "tap"

module Homebrew
  class TestCleanup < Test
    protected

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

    def initialize(tap:, git:)
      super(tap: tap, git: git)
    end

    def clear_stash_if_needed(repository)
      return if Utils.popen_read(
        git, "-C", repository, "stash", "list"
      ).strip.empty?

      test git, "-C", repository, "stash", "clear"
    end

    def reset_if_needed(repository)
      return if system(git, "-C", repository, "diff", "--quiet", "origin/master")

      test git, "-C", repository, "reset", "--hard", "origin/master"
    end

    def cleanup_shared
      cleanup_git_meta(repository)
      clean_if_needed(repository)
      prune_if_needed(repository)

      paths_to_delete = []

      Keg::MUST_BE_WRITABLE_DIRECTORIES.each(&:mkpath)
      Pathname.glob("#{HOMEBREW_PREFIX}/**/*", File::FNM_DOTMATCH).each do |path|
        next if Keg::MUST_BE_WRITABLE_DIRECTORIES.include?(path)
        next if path == HOMEBREW_PREFIX/"bin/brew"
        next if path == HOMEBREW_PREFIX/"var"
        next if path == HOMEBREW_PREFIX/"var/homebrew"

        basename = path.basename.to_s
        next if basename == "."
        next if basename == ".keepme"

        path_string = path.to_s
        next if path_string.start_with?(HOMEBREW_REPOSITORY.to_s)
        next if path_string.start_with?(Dir.pwd.to_s)

        # allow deleting non-existent osxfuse symlinks.
        if !path.symlink? || path.resolved_path_exists?
          # don't try to delete other osxfuse files
          next if path_string.match?(
            "(include|lib)/(lib|osxfuse/|pkgconfig/)?(osx|mac)?fuse(.*\.(dylib|h|la|pc))?$",
          )
        end

        FileUtils.chmod("u+rw", path) if path.owned? && (!path.readable? || !path.writable?)
        paths_to_delete << path
      end

      # Do this in a second pass so that all children have their permissions fixed before we delete the parent.
      FileUtils.rm_rf paths_to_delete

      if tap
        checkout_branch_if_needed(HOMEBREW_REPOSITORY)
        reset_if_needed(HOMEBREW_REPOSITORY)
        clean_if_needed(HOMEBREW_REPOSITORY)
      end

      # Keep all "brew" invocations after HOMEBREW_REPOSITORY operations
      # (which cleans up Homebrew/brew)
      Tap.names.each do |tap_name|
        next if tap_name == tap&.name
        next if REQUIRED_TAPS.include?(tap_name)

        test "brew", "untap", tap_name
      end

      Pathname.glob("#{HOMEBREW_LIBRARY}/Taps/*/*").each do |git_repo|
        cleanup_git_meta(git_repo)
        next if repository == git_repo

        checkout_branch_if_needed(git_repo)
        reset_if_needed(git_repo)
        prune_if_needed(git_repo)
      end

      test "brew", "cleanup", "--prune=3"
    end

    private

    def checkout_branch_if_needed(repository, branch = "master")
      current_branch = Utils.popen_read(
        git, "-C", repository, "symbolic-ref", "HEAD"
      ).strip
      return if branch == current_branch

      test git, "-C", repository, "checkout", "-f", branch
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
      ]
      return if Utils.popen_read(
        git, "-C", repository, "clean", "--dry-run", *clean_args
      ).strip.empty?

      test git, "-C", repository, "clean", "-ff", *clean_args
    end

    def prune_if_needed(repository)
      return unless Utils.popen_read(
        "#{git} -C '#{repository}' -c gc.autoDetach=false gc --auto 2>&1",
      ).include?("git prune")

      test git, "-C", repository, "prune"
    end
  end
end
