# frozen_string_literal: true

module Homebrew
  module Tests
    class TestFormulae < Test
      attr_accessor :skipped_or_failed_formulae
      attr_reader :artifact_cache

      def initialize(tap:, git:, dry_run:, fail_fast:, verbose:)
        super

        @skipped_or_failed_formulae = []
        @artifact_cache = Pathname("artifact-cache")
      end

      protected

      def cached_event_json
        return unless (event_json = artifact_cache/"event.json").exist?

        event_json
      end

      def github_event_payload
        return if (github_event_path = ENV.fetch("GITHUB_EVENT_PATH", nil)).blank?

        JSON.parse(File.read(github_event_path))
      end

      def previous_github_sha
        return if tap.blank?
        return unless repository.directory?
        return if ENV["GITHUB_ACTIONS"].blank?
        return if (payload = github_event_payload).blank?

        head_repo_owner = payload.dig("pull_request", "head", "repo", "owner", "login")
        head_from_fork = head_repo_owner != ENV.fetch("GITHUB_REPOSITORY_OWNER")
        maintainer_fork = tap.official? && JSON.parse(HOMEBREW_MAINTAINER_JSON.read).include?(head_repo_owner)
        return if head_from_fork && !maintainer_fork

        # If we have a cached event payload, then we failed to get the artifact we wanted
        # from `GITHUB_EVENT_PATH`, so use the cached payload to check for a SHA1.
        event_payload = JSON.parse(cached_event_json.read) if cached_event_json.present?
        event_payload ||= payload

        event_payload.fetch("before", nil)
      end

      GRAPHQL_QUERY = <<~GRAPHQL
        query ($node_id: ID!) {
          node(id: $node_id) {
            ... on Commit {
              checkSuites(last: 100) {
                nodes {
                  status
                  updatedAt
                  workflowRun {
                    databaseId
                    event
                    workflow {
                      name
                    }
                  }
                  checkRuns(last: 100) {
                    nodes {
                      name
                      status
                    }
                  }
                }
              }
            }
          }
        }
      GRAPHQL

      def artifact_metadata(check_suite_nodes, repo, event_name, workflow_name, check_run_name, artifact_name)
        candidate_nodes = check_suite_nodes.select do |node|
          next false if node.fetch("status") != "COMPLETED"

          workflow_run = node.fetch("workflowRun")
          next false if workflow_run.fetch("event") != event_name
          next false if workflow_run.dig("workflow", "name") != workflow_name

          check_run_nodes = node.dig("checkRuns", "nodes")
          next false if check_run_nodes.blank?

          check_run_nodes.any? do |check_run_node|
            check_run_node.fetch("name") == check_run_name && check_run_node.fetch("status") == "COMPLETED"
          end
        end
        return if candidate_nodes.blank?

        run_id = candidate_nodes.max_by { |node| Time.parse(node.fetch("updatedAt")) }
                                .dig("workflowRun", "databaseId")
        return if run_id.blank?

        url = GitHub.url_to("repos", repo, "actions", "runs", run_id, "artifacts")
        response = GitHub::API.open_rest(url)
        return if response.fetch("total_count").zero?

        artifacts = response.fetch("artifacts")
        artifacts.find { |artifact| artifact.fetch("name") == artifact_name }
      end

      def download_artifact_from_previous_run!(artifact_name, dry_run:)
        return if dry_run
        return if GitHub::API.credentials_type == :none
        return if (sha = previous_github_sha).blank?

        repo = ENV.fetch("GITHUB_REPOSITORY")
        pull_number = github_event_payload.dig("pull_request", "number")
        return if pull_number.blank?

        pr_labels = GitHub.pull_request_labels(*repo.split("/"), pull_number)
        return if pr_labels.include?("workflows") # Avoid cache poisoning.

        url = GitHub.url_to("repos", repo, "commits", sha)
        response = GitHub::API.open_rest(url)
        node_id = response.fetch("node_id")

        response = GitHub::API.open_graphql(GRAPHQL_QUERY, variables: { node_id: node_id })
        check_suite_nodes = response.dig("node", "checkSuites", "nodes")
        return if check_suite_nodes.blank?

        wanted_artifact = artifact_metadata(check_suite_nodes, repo, "pull_request",
                                            "CI", "conclusion", artifact_name)
        # If we didn't find the artifact that we wanted, fall back to the `event_payload` artifact.
        wanted_artifact ||= artifact_metadata(check_suite_nodes, repo, "pull_request_target",
                                              "Triage tasks", "upload-metadata", "event_payload")
        return if wanted_artifact.blank?

        wanted_artifact_name = wanted_artifact.fetch("name")
        cached_event_json&.unlink if wanted_artifact_name == "event_payload"

        ohai "Downloading #{wanted_artifact_name} from #{sha}"
        download_url = wanted_artifact.fetch("archive_download_url")
        artifact_id = wanted_artifact.fetch("id")

        require "utils/github/artifacts"

        artifact_cache.mkpath
        artifact_cache.cd do
          GitHub.download_artifact(download_url, artifact_id)
        end

        return if wanted_artifact_name == artifact_name

        # If we made it here, then we downloaded an `event_payload` artifact.
        # We can now use this `event_payload` artifact to attempt to download the artifact we wanted.
        download_artifact_from_previous_run!(artifact_name, dry_run: dry_run)
      rescue GitHub::API::AuthenticationFailedError => e
        opoo e
      rescue LoadError # TODO: Remove when GitHub Actions is on Homebrew 4.0.19+.
        nil
      end

      def no_diff?(formula, git_ref)
        return false unless repository.directory?

        @fetched_refs ||= []
        if @fetched_refs.exclude?(git_ref)
          test git, "-C", repository, "fetch", "origin", git_ref, ignore_failures: true
          @fetched_refs << git_ref if steps.last.passed?
        end

        relative_formula_path = formula.path.relative_path_from(repository)
        system(git, "-C", repository, "diff", "--no-ext-diff", "--quiet", git_ref, "--", relative_formula_path)
      end

      def git_revision_from_local_bottle_json(formula)
        return if (local_bottle_json = bottle_glob(formula, artifact_cache, ".json").first).blank?

        local_bottle_hash = JSON.parse(local_bottle_json.read)
        local_bottle_hash.dig(formula.name, "formula", "tap_git_revision")
      end

      def artifact_cache_valid?(formula, formulae_dependents: false)
        sha = if formulae_dependents
          previous_github_sha
        else
          git_revision_from_local_bottle_json(formula)
        end

        return false if sha.blank?
        return false unless no_diff?(formula, sha)

        formula.recursive_dependencies.all? do |dep|
          no_diff?(dep.to_formula, sha)
        end
      end

      def bottle_glob(formula_name, bottle_dir = Pathname.pwd, ext = ".tar.gz", bottle_tag: Utils::Bottles.tag.to_s)
        bottle_dir.glob("#{formula_name}--*.#{bottle_tag}.bottle*#{ext}")
      end

      def install_formula_from_bottle(formula_name, testing_formulae_dependents:, dry_run:, bottle_dir: Pathname.pwd)
        bottle_filename = bottle_glob(formula_name, bottle_dir).first
        if bottle_filename.blank?
          if testing_formulae_dependents && !dry_run
            raise "Failed to find bottle for '#{formula_name}'."
          elsif !dry_run
            return false
          end

          bottle_filename = "$BOTTLE_FILENAME"
        end

        install_args = []
        install_args += %w[--ignore-dependencies --skip-post-install] if testing_formulae_dependents
        test "brew", "install", *install_args, bottle_filename
        install_step = steps.last
        return install_step.passed? unless testing_formulae_dependents

        test "brew", "unlink", formula_name
        puts

        install_step.passed?
      end

      def bottled?(formula, no_older_versions: false)
        # If a formula has an `:all` bottle, then all its dependencies have
        # to be bottled too for us to use it. We only need to recurse
        # up the dep tree when we encounter an `:all` bottle because
        # a formula is not bottled unless its dependencies are.
        if formula.bottle_specification.tag?(Utils::Bottles.tag(:all))
          formula.deps.all? { |dep| bottled?(dep.to_formula, no_older_versions: no_older_versions) }
        else
          formula.bottle_specification.tag?(Utils::Bottles.tag, no_older_versions: no_older_versions)
        end
      end

      def bottled_or_built?(formula, built_formulae, no_older_versions: false)
        bottled?(formula, no_older_versions: no_older_versions) || built_formulae.include?(formula.full_name)
      end

      def downloads_using_homebrew_curl?(formula)
        [:stable, :head].any? do |spec_name|
          next false unless (spec = formula.send(spec_name))

          spec.using == :homebrew_curl || spec.resources.values.any? { |r| r.using == :homebrew_curl }
        end
      end

      def install_curl_if_needed(formula)
        return unless downloads_using_homebrew_curl?(formula)

        test "brew", "install", "curl",
             env: { "HOMEBREW_DEVELOPER" => nil }
      end

      def install_mercurial_if_needed(deps, reqs)
        return if (deps | reqs).none? { |d| d.name == "mercurial" && d.build? }

        test "brew", "install", "mercurial",
             env:  { "HOMEBREW_DEVELOPER" => nil }
      end

      def install_subversion_if_needed(deps, reqs)
        return if (deps | reqs).none? { |d| d.name == "subversion" && d.build? }

        test "brew", "install", "subversion",
             env:  { "HOMEBREW_DEVELOPER" => nil }
      end

      def skipped(formula_name, reason)
        @skipped_or_failed_formulae << formula_name

        puts Formatter.headline(
          "#{Formatter.warning("SKIPPED")} #{Formatter.identifier(formula_name)}",
          color: :yellow,
        )
        opoo reason
      end

      def failed(formula_name, reason)
        @skipped_or_failed_formulae << formula_name

        puts Formatter.headline(
          "#{Formatter.error("FAILED")} #{Formatter.identifier(formula_name)}",
          color: :red,
        )
        onoe reason
      end

      def unsatisfied_requirements_messages(formula)
        f = Formulary.factory(formula.full_name)
        fi = FormulaInstaller.new(f, build_bottle: true)

        unsatisfied_requirements, = fi.expand_requirements
        return if unsatisfied_requirements.blank?

        unsatisfied_requirements.values.flatten.map(&:message).join("\n").presence
      end

      def cleanup_during!(keep_formulae = [], args:)
        return unless args.cleanup?
        return unless HOMEBREW_CACHE.exist?

        free_gb = Utils.safe_popen_read({ "BLOCKSIZE" => (1000 ** 3).to_s }, "df", HOMEBREW_CACHE.to_s)
                       .lines[1] # HOMEBREW_CACHE
                       .split[3] # free GB
                       .to_i
        return if free_gb > 10

        test_header(:TestFormulae, method: :cleanup_during!)

        FileUtils.chmod_R "u+rw", HOMEBREW_CACHE, force: true
        test "rm", "-rf", HOMEBREW_CACHE.to_s

        if @cleaned_up_during.blank?
          @cleaned_up_during = true
          return
        end

        installed_formulae = Utils.safe_popen_read("brew", "list", "--full-name", "--formulae").split("\n")
        uninstallable_formulae = installed_formulae - keep_formulae

        @installed_formulae_deps ||= Hash.new do |h, formula|
          h[formula] = Utils.safe_popen_read("brew", "deps", "--full-name", formula).split("\n")
        end
        uninstallable_formulae.reject! do |name|
          keep_formulae.any? { |f| @installed_formulae_deps[f].include?(name) }
        end

        return if uninstallable_formulae.blank?

        test "brew", "uninstall", "--force", "--ignore-dependencies", *uninstallable_formulae
      end
    end
  end
end
