#:  * `ci-upload` [options]  <url|formula>:
#:    Tests the full lifecycle of a formula or Homebrew/brew change.
#:
#:    If `--dry-run` is passed, print what would be done rather than doing
#:    it.
#:
#:    If `--bintray-org=<bintray-org>` is passed, upload to the given Bintray
#:    organisation.
#:
#:    If `--tap=<tap>` is passed, use the `git` repository of the given
#:    tap.
#:
#:    If `--git-name=<git-name>` is passed, set the Git
#:    author/committer names to the given name.
#:
#:    If `--git-email=<git-email>` is passed, set the Git
#:    author/committer email to the given email.


module Homebrew
  module_function

  def ci_upload
      $stdout.sync = true
      $stderr.sync = true

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
        ENV["HOMEBREW_FORCE_HOMEBREW_ON_LINUX"] = "1"
      end

      # Don't pass keys/cookies to subprocesses
      ENV.clear_sensitive_environment!

      ARGV << "--verbose"

      copy_bottles_from_jenkins if !ENV["JENKINS_HOME"].nil?

      raise "No bottles found in #{Dir.pwd}!" if Dir["*.bottle*.*"].empty? && !ARGV.include?("--dry-run")

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
        safe_system "brew", "pull", "--clean", pull_pr
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

        bottle_hash["bottle"]["tags"].each do |tag, _tag_hash|
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

    # Get tap from Jenkins UPSTREAM_GIT_URL, GIT_URL or
    # Circle CI's CIRCLE_REPOSITORY_URL.
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

  def copy_bottles_from_jenkins
    jenkins = ENV["JENKINS_HOME"]
    job = ENV["UPSTREAM_JOB_NAME"]
    id = ENV["UPSTREAM_BUILD_ID"]
    if (!job || !id) && !ARGV.include?("--dry-run")
      raise "Missing Jenkins variables!"
    end

    jenkins_dir  = "#{jenkins}/jobs/#{job}/configurations/axis-version/*/"
    jenkins_dir += "builds/#{id}/archive/*.bottle*.*"
    bottles = Dir[jenkins_dir]

    raise "No bottles found in #{jenkins_dir}!" if bottles.empty? && !ARGV.include?("--dry-run")

    FileUtils.cp bottles, Dir.pwd, verbose: true
  end
end

Homebrew.ci_upload
