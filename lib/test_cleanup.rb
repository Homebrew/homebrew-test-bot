# frozen_string_literal: true

require "os"
require "tap"

module Homebrew
  class TestCleanup < Test
    protected

    REQUIRED_HOMEBREW_TAPS = %W[
      #{CoreTap.instance.name}
      homebrew/test-bot
    ].freeze

    REQUIRED_LINUXBREW_TAPS = %W[
      #{CoreTap.instance.name}
      homebrew/test-bot
      linuxbrew/xorg
    ].freeze

    REQUIRED_TAPS = if OS.mac? || ENV["HOMEBREW_FORCE_HOMEBREW_ON_LINUX"]
      REQUIRED_HOMEBREW_TAPS
    else
      REQUIRED_LINUXBREW_TAPS
    end.freeze

    ALLOWED_TAPS = (REQUIRED_TAPS + %w[
      homebrew/bundle
      homebrew/cask
      homebrew/cask-versions
      homebrew/services
    ]).freeze

    def reset_if_needed(repository)
      default_ref = default_origin_ref(repository)

      return if system(git, "-C", repository, "diff", "--quiet", default_ref)

      test git, "-C", repository, "reset", "--hard", default_ref
    end

    # Moving files is faster than removing them,
    # so move them if the current runner is ephemeral.
    def delete_or_move(paths)
      return if paths.blank?

      symlinks, paths = paths.partition(&:symlink?)

      FileUtils.rm_f symlinks

      if ENV["HOMEBREW_GITHUB_ACTIONS"] && !ENV["GITHUB_ACTIONS_HOMEBREW_SELF_HOSTED"]
        FileUtils.mv paths, Dir.mktmpdir, force: true
      else
        FileUtils.rm_rf paths
      end
    end

    def cleanup_shared
      cleanup_git_meta(repository)
      clean_if_needed(repository)
      prune_if_needed(repository)

      if HOMEBREW_REPOSITORY != HOMEBREW_PREFIX
        paths_to_delete = []

        info_header "Determining #{HOMEBREW_PREFIX} files to purge..."
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
          if (!path.symlink? || path.resolved_path_exists?) &&
             # don't try to delete other osxfuse files
             path_string.match?("(include|lib)/(lib|osxfuse/|pkgconfig/)?(osx|mac)?fuse(.*\.(dylib|h|la|pc))?$")
            next
          end

          FileUtils.chmod("u+rw", path) if path.owned? && (!path.readable? || !path.writable?)
          paths_to_delete << path
        end

        # Do this in a second pass so that all children have their permissions fixed before we delete the parent.
        info_header "Purging..."
        delete_or_move paths_to_delete
      end

      if tap
        checkout_branch_if_needed(HOMEBREW_REPOSITORY)
        reset_if_needed(HOMEBREW_REPOSITORY)
        clean_if_needed(HOMEBREW_REPOSITORY)
      end

      # Keep all "brew" invocations after HOMEBREW_REPOSITORY operations
      # (which cleans up Homebrew/brew)
      Tap.names.each do |tap_name|
        next if tap_name == tap&.name
        next if ALLOWED_TAPS.include?(tap_name)

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

    def default_origin_ref(repository)
      default_branch = Utils.popen_read(
        git, "-C", repository, "symbolic-ref", "refs/remotes/origin/HEAD", "--short"
      ).strip.presence
      default_branch ||= "origin/master"
      default_branch
    end

    def checkout_branch_if_needed(repository)
      # We limit this to two parts, because branch names can have slashes in
      default_branch = default_origin_ref(repository).split("/", 2).last
      current_branch = Utils.safe_popen_read(
        git, "-C", repository, "symbolic-ref", "HEAD", "--short"
      ).strip
      return if default_branch == current_branch

      test git, "-C", repository, "checkout", "-f", default_branch
    end

    def cleanup_git_meta(repository)
      pr_locks = "#{repository}/.git/refs/remotes/*/pr/*/*.lock"
      Dir.glob(pr_locks) { |lock| FileUtils.rm_f lock }
      FileUtils.rm_f "#{repository}/.git/gc.log"
    end

    def clean_if_needed(repository)
      return if repository == HOMEBREW_PREFIX && HOMEBREW_PREFIX != HOMEBREW_REPOSITORY

      clean_args = [
        "-dx",
        "--exclude=*.bottle*.*",
        "--exclude=Library/Taps",
        "--exclude=Library/Homebrew/vendor",
      ]
      return if Utils.safe_popen_read(
        git, "-C", repository, "clean", "--dry-run", *clean_args
      ).strip.empty?

      test git, "-C", repository, "clean", "-ff", *clean_args
    end

    def prune_if_needed(repository)
      return unless Utils.safe_popen_read(
        "#{git} -C '#{repository}' -c gc.autoDetach=false gc --auto 2>&1",
      ).include?("git prune")

      test git, "-C", repository, "prune"
    end
  end
end
