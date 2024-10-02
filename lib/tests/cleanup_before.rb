# typed: true
# frozen_string_literal: true

module Homebrew
  module Tests
    class CleanupBefore < TestCleanup
      def run!(args:)
        test_header(:CleanupBefore)

        if tap.to_s != CoreTap.instance.name && CoreTap.instance.installed?
          reset_if_needed(CoreTap.instance.path.to_s)
        end

        Pathname.glob("*.bottle*.*").each(&:unlink)

        on_github_hosted_runner = ENV["HOMEBREW_GITHUB_ACTIONS"] && !ENV["GITHUB_ACTIONS_HOMEBREW_SELF_HOSTED"]
        if on_github_hosted_runner
          # minimally fix brew doctor failures (a full clean takes ~5m)
          if OS.linux?
            # brew doctor complains
            bad_paths = %w[
              /usr/local/include/node/
              /opt/pipx_bin/ansible-config
            ].map { |path| Pathname.new(path) }

            delete_or_move bad_paths, sudo: true
          elsif OS.mac?
            delete_or_move HOMEBREW_CELLAR.glob("*")

            frameworks_dir = Pathname("/Library/Frameworks")
            frameworks = %w[
              Mono.framework
              PluginManager.framework
              Python.framework
              R.framework
              Xamarin.Android.framework
              Xamarin.Mac.framework
              Xamarin.iOS.framework
            ].map { |framework| frameworks_dir/framework }

            delete_or_move frameworks, sudo: true
          end

          test "brew", "cleanup", "--prune-prefix"
        end

        # Keep all "brew" invocations after cleanup_shared
        # (which cleans up Homebrew/brew)
        cleanup_shared

        installed_taps = Tap.select(&:installed?).map(&:name)
        if on_github_hosted_runner && tap.to_s == CoreTap.instance.name
          (installed_taps - REQUIRED_TAPS).each do |tap|
            test "brew", "untap", tap
          end
        end
        (REQUIRED_TAPS - installed_taps).each do |tap|
          test "brew", "tap", tap
        end
      end
    end
  end
end
