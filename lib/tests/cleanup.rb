# frozen_string_literal: true

module Homebrew
  module Tests
    class Cleanup < Test
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
        @tap = tap
        @git = git

        # TODO: refactor everything below into Test initializer exclusively
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

      # TODO: rename this when all classes ported.
      def cleanup_before
        method_header(__method__, klass: "Tests::Cleanup")

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

      # TODO: rename this when all classes ported.
      def cleanup_after
        if ENV["HOMEBREW_GITHUB_ACTIONS"] && !ENV["GITHUB_ACTIONS_HOMEBREW_SELF_HOSTED"]
          # don't need to do post-build cleanup unless testing test-bot itself.
          return if @tap.to_s != "homebrew/test-bot"
        end

        method_header(__method__, klass: "Tests::Cleanup")

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

      private

      def clear_stash_if_needed(repository)
        return if Utils.popen_read(
          @git, "-C", repository, "stash", "list"
        ).strip.empty?

        test @git, "-C", repository, "stash", "clear"
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

      def checkout_branch_if_needed(repository, branch = "master")
        current_branch = Utils.popen_read(
          @git, "-C", repository, "symbolic-ref", "HEAD"
        ).strip
        return if branch == current_branch

        test @git, "-C", repository, "checkout", "-f", branch
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
    end
  end
end
