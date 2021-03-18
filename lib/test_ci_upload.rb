# frozen_string_literal: true

require "github_releases"

module Homebrew
  module TestCiUpload
    module_function

    CURL = "/usr/bin/curl"

    def system_curl(*args, secrets: [], **options)
      system_command! CURL,
                      args:         curl_args(*args, **options),
                      print_stdout: true,
                      secrets:      secrets
    end

    def run!(tap, args:)
      # Don't trust formulae we're uploading
      ENV["HOMEBREW_DISABLE_LOAD_FORMULA"] = "1"

      bintray_user = ENV["HOMEBREW_BINTRAY_USER"]
      bintray_key = ENV["HOMEBREW_BINTRAY_KEY"]
      if (!bintray_user || !bintray_key) && !args.dry_run?
        raise "Missing HOMEBREW_BINTRAY_USER or HOMEBREW_BINTRAY_KEY variables!"
      end

      # Ensure that uploading Homebrew bottles on Linux doesn't use Linuxbrew.
      bintray_org = args.bintray_org || "homebrew"
      ENV["HOMEBREW_FORCE_HOMEBREW_ON_LINUX"] = "1" if bintray_org == "homebrew" && !OS.mac?

      # Don't pass keys/cookies to subprocesses
      ENV.clear_sensitive_environment!

      raise "No bottles found in #{Dir.pwd}!" if Dir["*.bottle*.*"].empty? && !args.dry_run?

      json_files = Dir.glob("*.bottle.json")
      bottles_hash = json_files.reduce({}) do |hash, json_file|
        hash.deep_merge(JSON.parse(IO.read(json_file)))
      end

      bottles_hash.each do |_, bottle_hash|
        root_url = bottle_hash["bottle"]["root_url"]

        next unless root_url.match GitHubReleases::URL_REGEX

        odie "Refusing to upload to GitHub Releases, use `brew pr-upload`."
      end

      if args.dry_run?
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
      tap_name = first_formula_name.rpartition("/").first.chomp.presence
      tap_name ||= CoreTap.instance.name
      tap ||= Tap.fetch(tap_name)

      ENV["GIT_WORK_TREE"] = tap.path
      ENV["GIT_DIR"] = "#{ENV["GIT_WORK_TREE"]}/.git"

      if args.keep_old?
        system "brew", "bottle", "--merge", "--write", "--keep-old", *json_files
      elsif !args.dry_run?
        system "brew", "bottle", "--merge", "--write", *json_files
      else
        puts "brew bottle --merge --write $JSON_FILES"
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
          filename_already_published = if args.dry_run?
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
            package_exists = if args.dry_run?
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
              if args.dry_run?
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
          if args.dry_run?
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

        next unless args.publish?

        publish_url = "https://api.bintray.com/content/#{bintray_org}"
        publish_url += "/#{bintray_repo}/#{bintray_package}/#{version}/publish"

        if args.dry_run?
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
    end
  end
end
