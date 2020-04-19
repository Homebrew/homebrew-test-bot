# frozen_string_literal: true

require_relative "step"
require_relative "test"

require "date"
require "json"
require "rexml/document"
require "rexml/xmldecl"
require "rexml/cdata"

require "development_tools"
require "formula"
require "formula_installer"
require "os"
require "tap"
require "utils"
require "utils/bottles"

module Homebrew
  module TestBot
    module_function

    GIT = "/usr/bin/git"
    CURL = "/usr/bin/curl"

    BYTES_IN_1_MEGABYTE = 1024*1024
    MAX_STEP_OUTPUT_SIZE = BYTES_IN_1_MEGABYTE - (200*1024) # margin of safety

    HOMEBREW_TAP_REGEX = %r{^([\w-]+)/homebrew-([\w-]+)$}.freeze

    def resolve_test_tap
      if (tap = Homebrew.args.tap)
        return Tap.fetch(tap)
      end

      return Tap.fetch(tap) if HOMEBREW_TAP_REGEX.match?(tap)

      if ENV["UPSTREAM_BOT_PARAMS"]
        bot_argv = ENV["UPSTREAM_BOT_PARAMS"].split(" ")
        bot_argv.extend HomebrewArgvExtension
        if (tap = bot_argv.value("tap"))
          return Tap.fetch(tap)
        end
      end

      # Get tap from Jenkins UPSTREAM_GIT_URL, GIT_URL or
      # GitHub Actions GITHUB_REPOSITORY
      git_url =
        ENV["UPSTREAM_GIT_URL"] ||
        ENV["GIT_URL"] ||
        ENV["GITHUB_REPOSITORY"]
      return unless git_url

      url_path = git_url.sub(%r{^https?://.*github\.com/}, "")
                        .chomp("/")
                        .sub(/\.git$/, "")
      begin
        return Tap.fetch(url_path) if url_path.match?(HOMEBREW_TAP_REGEX)
      rescue
        # Don't care if tap fetch fails
        nil
      end
    end

    def copy_bottles_from_jenkins
      jenkins = ENV["JENKINS_HOME"]
      job = ENV["UPSTREAM_JOB_NAME"]
      id = ENV["UPSTREAM_BUILD_ID"]
      raise "Missing Jenkins variables!" unless (job && id) || Homebrew.args.dry_run?

      jenkins_dir  = "#{jenkins}/jobs/#{job}/configurations/axis-version/*/"
      jenkins_dir += "builds/#{id}/archive/*.bottle*.*"
      bottles = Dir[jenkins_dir]

      raise "No bottles found in #{jenkins_dir}!" if bottles.empty? && !Homebrew.args.dry_run?

      FileUtils.cp bottles, Dir.pwd, verbose: true
    end

    def test_ci_upload(tap)
      # Don't trust formulae we're uploading
      ENV["HOMEBREW_DISABLE_LOAD_FORMULA"] = "1"

      bintray_user = ENV["HOMEBREW_BINTRAY_USER"]
      bintray_key = ENV["HOMEBREW_BINTRAY_KEY"]
      if !bintray_user || !bintray_key
        raise "Missing HOMEBREW_BINTRAY_USER or HOMEBREW_BINTRAY_KEY variables!" unless Homebrew.args.dry_run?
      end

      # Ensure that uploading Homebrew bottles on Linux doesn't use Linuxbrew.
      bintray_org = Homebrew.args.bintray_org || "homebrew"
      ENV["HOMEBREW_FORCE_HOMEBREW_ON_LINUX"] = "1" if bintray_org == "homebrew" && !OS.mac?

      # Don't pass keys/cookies to subprocesses
      ENV.clear_sensitive_environment!

      copy_bottles_from_jenkins unless ENV["JENKINS_HOME"].nil?

      raise "No bottles found in #{Dir.pwd}!" if Dir["*.bottle*.*"].empty? && !Homebrew.args.dry_run?

      json_files = Dir.glob("*.bottle.json")
      bottles_hash = json_files.reduce({}) do |hash, json_file|
        hash.deep_merge(JSON.parse(IO.read(json_file)))
      end

      if Homebrew.args.dry_run?
        bottles_hash = {
          "testbottest" => {
            "formula" => {
              "pkg_version" => "1.0.0",
            },
            "bottle"  => {
              "rebuild" => 0,
              "tags"    => {
                Utils::Bottles.tag => {
                  "filename" =>
                                "testbottest-1.0.0.#{Utils::Bottles.tag}.bottle.tar.gz",
                  "sha256"   =>
                                "20cdde424f5fe6d4fdb6a24cff41d2f7aefcd1ef2f98d46f6c074c36a1eef81e",
                },
              },
            },
            "bintray" => {
              "package"    => "testbottest",
              "repository" => "bottles",
            },
          },
        }
      end

      first_formula_name = bottles_hash.keys.first
      tap_name = first_formula_name.rpartition("/").first.chuzzle
      tap_name ||= CoreTap.instance.name
      tap ||= Tap.fetch(tap_name)

      ENV["GIT_WORK_TREE"] = tap.path
      ENV["GIT_DIR"] = "#{ENV["GIT_WORK_TREE"]}/.git"

      # This variable is for Jenkins.
      if (pr = ENV["UPSTREAM_PULL_REQUEST"])
        if Homebrew.args.dry_run?
          puts <<~EOS
            #{GIT} am --abort
            #{GIT} rebase --abort
            #{GIT} checkout -f master
            #{GIT} reset --hard origin/master
            brew update
          EOS
        else
          quiet_system GIT, "am", "--abort"
          quiet_system GIT, "rebase", "--abort"
          safe_system GIT, "checkout", "-f", "master"
          safe_system GIT, "reset", "--hard", "origin/master"
          safe_system "brew", "update"
        end
        pull_pr = "#{tap.default_remote}/pull/#{pr}"
        safe_system "brew", "pull", "--clean", pull_pr
      end

      if ENV["UPSTREAM_BOTTLE_KEEP_OLD"] ||
         ENV["BOT_PARAMS"].to_s.include?("--keep-old") ||
         Homebrew.args.keep_old?
        system "brew", "bottle", "--merge", "--write", "--keep-old", *json_files
      elsif !Homebrew.args.dry_run?
        system "brew", "bottle", "--merge", "--write", *json_files
      else
        puts "brew bottle --merge --write $JSON_FILES"
      end

      # This variable is for Jenkins.
      upstream_number = ENV["UPSTREAM_BUILD_NUMBER"]
      git_name = ENV["HOMEBREW_GIT_NAME"]
      remote = "git@github.com:#{git_name}/homebrew-#{tap.repo}.git"
      git_tag = if pr
        "pr-#{pr}"
      elsif upstream_number
        "testing-#{upstream_number}"
      elsif (number = ENV["BUILD_NUMBER"])
        "other-#{number}"
      elsif Homebrew.args.dry_run?
        "$GIT_TAG"
      end

      if git_tag
        if Homebrew.args.dry_run?
          puts "#{GIT} push --force #{remote} origin/master:master :refs/tags/#{git_tag}"
        else
          safe_system GIT, "push", "--force", remote, "origin/master:master",
                                                      ":refs/tags/#{git_tag}"
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

        bottle_hash["bottle"]["tags"].each do |tag, _tag_hash|
          filename = Bottle::Filename.new(formula_name, version, tag, rebuild)
          bintray_url =
            "#{Homebrew::EnvConfig.bottle_domain}/#{bintray_repo}/#{filename.bintray}"
          filename_already_published = if Homebrew.args.dry_run?
            puts "#{CURL} -I --output /dev/null #{bintray_url}"
            false
          else
            begin
              system CURL, *curl_args("-I", "--output", "/dev/null",
                                      bintray_url)
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
            package_exists = if Homebrew.args.dry_run?
              puts "#{CURL} --output /dev/null #{package_url}"
              false
            else
              system CURL, *curl_args("--output", "/dev/null", package_url)
            end

            unless package_exists
              package_blob = <<~EOS
                {"name": "#{bintray_package}",
                "public_download_numbers": true,
                "public_stats": true}
              EOS
              if Homebrew.args.dry_run?
                puts <<~EOS
                  #{CURL} --user $HOMEBREW_BINTRAY_USER:$HOMEBREW_BINTRAY_KEY
                      --header Content-Type: application/json
                      --data #{package_blob.delete("\n")}
                      #{bintray_packages_url}
                EOS
              else
                system_curl "--user", "#{bintray_user}:#{bintray_key}",
                            "--header", "Content-Type: application/json",
                            "--data", package_blob, bintray_packages_url,
                            secrets: [bintray_key]
                puts
              end
            end
            formula_packaged[formula_name] = true
          end

          content_url = "https://api.bintray.com/content/#{bintray_org}"
          content_url +=
            "/#{bintray_repo}/#{bintray_package}/#{version}/#{filename.bintray}"
          if Homebrew.args.dry_run?
            puts <<~EOS
              #{CURL} --user $HOMEBREW_BINTRAY_USER:$HOMEBREW_BINTRAY_KEY
                  --upload-file #{filename}
                  #{content_url}
            EOS
          else
            system_curl "--user", "#{bintray_user}:#{bintray_key}",
                        "--upload-file", filename, content_url,
                        secrets: [bintray_key]
            puts
          end
        end

        next unless Homebrew.args.publish?

        publish_url = "https://api.bintray.com/content/#{bintray_org}"
        publish_url += "/#{bintray_repo}/#{bintray_package}/#{version}/publish"

        if Homebrew.args.dry_run?
          puts <<~EOS
            #{CURL} --user $HOMEBREW_BINTRAY_USER:$HOMEBREW_BINTRAY_KEY --request POST
                #{publish_url}
          EOS
        else
          system_curl "--user", "#{bintray_user}:#{bintray_key}",
                      publish_url, "--request", "POST",
                      secrets: [bintray_key]
        end
      end

      return unless git_tag

      if Homebrew.args.dry_run?
        puts "#{GIT} tag --force #{git_tag}"
        puts "#{GIT} push --force #{remote} origin/master:master refs/tags/#{git_tag}"
      else
        safe_system GIT, "tag", "--force", git_tag
        safe_system GIT, "push", "--force", remote, "origin/master:master",
                                                    "refs/tags/#{git_tag}"
      end
    end

    def system_curl(*args, secrets: [], **options)
      system_command! CURL,
                      args:         curl_args(*args, **options),
                      print_stdout: true,
                      secrets:      secrets
    end

    def run!
      $stdout.sync = true
      $stderr.sync = true

      if Pathname.pwd == HOMEBREW_PREFIX && Homebrew.args.cleanup?
        odie "cannot use --cleanup from HOMEBREW_PREFIX as it will delete all output."
      end

      ENV["HOMEBREW_DEVELOPER"] = "1"
      ENV["HOMEBREW_NO_AUTO_UPDATE"] = "1"
      ENV["HOMEBREW_NO_EMOJI"] = "1"
      ENV["HOMEBREW_FAIL_LOG_LINES"] = "150"
      ENV["HOMEBREW_PATH"] = ENV["PATH"] =
        "#{HOMEBREW_PREFIX}/bin:#{HOMEBREW_PREFIX}/sbin:#{ENV["PATH"]}"

      test_bot_revision = Utils.popen_read(
        GIT, "-C", Tap.fetch("homebrew/test-bot").path.to_s,
             "log", "-1", "--format=%h (%s)"
      ).strip
      puts "Homebrew/homebrew-test-bot #{test_bot_revision}"
      puts "ARGV: #{ARGV.join(" ")}"
      puts "Homebrew.args: #{Homebrew.args}"

      tap = resolve_test_tap
      # Tap repository if required, this is done before everything else
      # because Formula parsing and/or git commit hash lookup depends on it.
      # At the same time, make sure Tap is not a shallow clone.
      # bottle rebuild and bottle upload rely on full clone.
      if tap
        if !tap.path.exist?
          safe_system "brew", "tap", tap.name, "--full"
        elsif (tap.path/".git/shallow").exist?
          raise unless quiet_system GIT, "-C", tap.path, "fetch", "--unshallow"
        end
      end

      ENV["HOMEBREW_GIT_NAME"] = Homebrew.args.git_name || "BrewTestBot"
      ENV["HOMEBREW_GIT_EMAIL"] = Homebrew.args.git_email ||
                                  "homebrew-test-bot@lists.sfconservancy.org"

      return test_ci_upload(tap) if Homebrew.args.ci_upload?

      tests = []
      any_errors = false
      skip_setup = Homebrew.args.skip_setup?
      skip_cleanup_before = false
      if Homebrew.args.named.empty?
        # With no arguments just build the most recent commit.
        current_test = Test.new("HEAD", tap:                 tap,
                                        git:                 GIT,
                                        skip_setup:          skip_setup,
                                        skip_cleanup_before: skip_cleanup_before)
        any_errors = !current_test.run
        tests << current_test
      else
        Homebrew.args.named.each do |argument|
          skip_cleanup_after = argument != Homebrew.args.named.last
          test_error = false
          begin
            current_test =
              Test.new(argument, tap:                 tap,
                                 git:                 GIT,
                                 skip_setup:          skip_setup,
                                 skip_cleanup_before: skip_cleanup_before,
                                 skip_cleanup_after:  skip_cleanup_after)
            skip_setup = true
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

      if Homebrew.args.junit?
        xml_document = REXML::Document.new
        xml_document << REXML::XMLDecl.new
        testsuites = xml_document.add_element "testsuites"

        tests.each do |test|
          testsuite = testsuites.add_element "testsuite"
          testsuite.add_attribute "name", "brew-test-bot.#{Utils::Bottles.tag}"
          testsuite.add_attribute "tests", test.steps.count(&:passed?)
          testsuite.add_attribute "failures", test.steps.count(&:failed?)
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
        if Homebrew.args.clean_cache?
          HOMEBREW_CACHE.children.each(&:rmtree)
        else
          Dir.glob("*.bottle*.tar.gz") do |bottle_file|
            FileUtils.rm_f HOMEBREW_CACHE/bottle_file
          end
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
end
