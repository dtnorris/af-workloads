# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "tmpdir"
require "yaml"

module AFWorkloads
  class ScorerAdapter
    CONTRACT_VERSION = WorkloadCompiler::CONTRACT_VERSION
    PLACEMENT_ENDPOINT_ENV = "WLO_WORKER_ENDPOINT"
    SCORER_ENDPOINT_ENV = "AF_OLLAMA_BASE_URL"

    def initialize(root:, case_path:, out: $stdout, err: $stderr, command_runner: nil, data_root: nil)
      @code_root = File.expand_path(root)
      @split = !data_root.nil? || Roots.public_distribution?(@code_root)
      @root = @split ? Roots.data(data_root, code: @code_root) : @code_root
      @case_path = data_path(case_path)
      @out = out
      @err = err
      @command_runner = command_runner || method(:system_run)
    end

    def run(verify_only: false)
      data = load_case
      verify_frozen_inputs!(data)
      verify_selected_store!(data) if @split
      scorer_environment = environment(data, require_placement: !verify_only)
      identities = verify_input_identities!(data, scorer_environment)
      verify_manifest!(data) if @split
      verify_preflight!(data, scorer_environment)
      verify_input_identities!(data, scorer_environment) if identities
      if verify_only
        @out.puts "VERIFIED #{data.fetch('case_id')} (no inference)"
        return true
      end

      # Existing production qualifications do not authorize the public Git/method
      # identity. Preparation/replay remain available; execution needs a separately
      # reviewed qualification policy, never an implicit transfer of old approvals.
      preflight = JSON.parse(File.binread(data_path(data.fetch("preflight_path"))))
      if preflight.dig("run_metadata", "method")
        raise Error, "public method execution requires separate qualification; retained qualifications do not authorize this identity"
      end

      status = @command_runner.call(
        scorer_environment,
        score_command(data),
        scorer_repo(data)
      )
      raise Error, "AFSU scoring failed for #{data.fetch('case_id')}" unless status

      true
    end

    private

    def load_case
      data = YAML.safe_load_file(@case_path, aliases: true) || {}
      raise Error, "case must be a mapping" unless data.is_a?(Hash)
      unless data["contract_version"] == CONTRACT_VERSION
        raise Error, "case contract must be #{CONTRACT_VERSION.inspect}"
      end
      if @split
        workload_id = data.fetch("workload_id")
        case_id = data.fetch("case_id")
        unless WorkloadCompiler::ID_PATTERN.match?(workload_id.to_s) && case_id.to_s.match?(/\A[a-z0-9_-]+\z/) &&
               @case_path == data_path("build/workloads/#{workload_id}/cases/#{case_id}.yml")
          raise Error, "case is outside its generated workload in the selected data root"
        end
        paths = {
          "runtime_path" => "build/workloads/#{workload_id}/runtime/#{case_id}.yml",
          "preflight_path" => "build/workloads/#{workload_id}/preflight/#{case_id}.json",
          "output_path" => "output/workloads/#{workload_id}/results/#{case_id}"
        }
        paths.each do |field, expected|
          raise Error, "case #{field} differs from its generated workload" unless data[field] == expected

          data_path(expected)
        end
      end
      data
    rescue KeyError, Psych::Exception, Errno::ENOENT => e
      raise Error, "invalid case YAML: #{e.message}"
    end

    def verify_frozen_inputs!(data)
      verify_sha!(resolve(data.fetch("catalog_path")), data.fetch("catalog_sha256"), "catalog")
      StagedScoringInput.verify_case!(root: @root, data:) if data.key?("staged_scoring")
      verify_sha!(File.expand_path(data.fetch("qualification_path"), @code_root), data.fetch("qualification_sha256"), "qualification")
      verify_sha!(data_path(data.fetch("runtime_path")), data.fetch("runtime_sha256"), "runtime")
      verify_sha!(data_path(data.fetch("preflight_path")), data.fetch("preflight_sha256"), "preflight")
      verify_scorer!(data)
    end

    # The hash-bound scorer output root must belong to the selected store even
    # when someone copies the generated tree to another directory.
    def verify_selected_store!(data)
      runtime = YAML.safe_load_file(data_path(data.fetch("runtime_path")), aliases: true)
      output_root = runtime.dig("paths", "output_root")
      raise Error, "runtime does not bind the selected data root" if output_root.to_s.empty?

      data_path(File.expand_path(output_root, scorer_repo(data)))
    rescue Psych::Exception, NoMethodError, TypeError => error
      raise Error, "invalid runtime data root: #{error.message}"
    end

    # Verify the split case against its published index, plan and snapshot.
    # An incomplete or inconsistent published workload raises Error.
    def verify_manifest!(data)
      workload = data.fetch("workload_id")
      prefix = "workloads/#{workload}"
      snapshot = YAML.safe_load_file(data_path("#{prefix}/snapshot.yml"))
      plan_bytes = File.binread(data_path("#{prefix}/execution-plan.json"))
      plan = JSON.parse(plan_bytes)
      rows = CSV.read(data_path("#{prefix}/case_index.csv"), headers: true)
      row = rows.find { |record| record["case_id"] == data.fetch("case_id") }
      job = plan.fetch("jobs").find { |entry| entry["job_id"] == data.fetch("case_id") }
      relative_case = @case_path.delete_prefix("#{@root}/")

      unless snapshot.values_at("workload_id", "execution_plan_sha256", "case_count") ==
             [workload, Digest::SHA256.hexdigest(plan_bytes), rows.size] &&
             plan["plan_id"] == workload && plan.fetch("jobs").size == rows.size &&
             %w[catalog_path catalog_sha256 scorer_repo scorer_commit].all? { |key| snapshot[key] == data[key] } &&
             row && row["case_path"] == relative_case && row.to_h.except("case_path").all? { |key, value| data[key] == value } &&
             job && job["argv"] == ["bin/afw-score-job", relative_case] && job["env"] == data["environment"]
        raise Error, "case differs from its published workload"
      end
      if Roots.public_distribution?(@code_root) && snapshot["generator_commit"] != Roots.generator(@code_root, nil)
        raise Error, "generator identity differs from the published workload"
      end
    rescue SystemCallError, JSON::ParserError, CSV::MalformedCSVError, Psych::Exception, KeyError, TypeError, NoMethodError => error
      raise Error, "invalid published workload: #{error.message}"
    end

    # The hash-bound runtime marker makes identity metadata mandatory for new
    # cases even when its case field is removed or malformed. Old cases retain
    # their original checks; presence never silently falls back to legacy mode.
    def verify_input_identities!(data, scorer_environment)
      runtime = YAML.safe_load_file(data_path(data.fetch("runtime_path")), aliases: true)
      raise Error, "invalid frozen runtime identity envelope" unless runtime.is_a?(Hash)
      marker = FrozenInputIdentities::MARKER
      return nil unless runtime.key?(marker) || runtime.key?(FrozenInputIdentities::DIGEST_FIELD) || data.key?("frozen_input_identities")
      raise Error, "invalid frozen input identity contract" unless runtime[marker] == FrozenInputIdentities::VERSION
      identities = data["frozen_input_identities"]
      FrozenInputIdentities.verify!(identities)
      unless runtime[FrozenInputIdentities::DIGEST_FIELD] == FrozenInputIdentities.digest(identities)
        raise Error, "case input identity metadata differs from frozen runtime binding"
      end
      FrozenInputIdentities.verify_model!(root: @code_root, data: data, identities: identities)
      actual = FrozenInputIdentities.capture(scorer_repo: scorer_repo(data),
        runtime_path: data_path(data.fetch("runtime_path")), adventure_id: data.fetch("adventure_id"),
        environment: scorer_environment)
      raise Error, "operative input identity paths or bytes changed" unless actual == identities.slice(*actual.keys)
      identities
    rescue Psych::Exception => e
      raise Error, "invalid frozen runtime identity: #{e.message}"
    end

    def verify_scorer!(data)
      repo = scorer_repo(data)
      stdout, stderr, status = Open3.capture3("git", "-C", repo, "rev-parse", "HEAD")
      raise Error, "cannot read scorer HEAD: #{stderr.strip}" unless status.success?
      expected = data.fetch("scorer_commit")
      raise Error, "scorer HEAD changed: expected #{expected}, got #{stdout.strip}" unless stdout.strip == expected

      [[], ["--cached"]].each do |extra|
        _out, _err, clean = Open3.capture3(
          "git", "-C", repo, "diff", *extra, "--quiet", "--", "lib/af_scoring", "config/default.yml"
        )
        raise Error, "scorer protected paths have uncommitted changes" unless clean.success?
      end
    end

    def verify_preflight!(data, scorer_environment)
      Dir.mktmpdir("afw-score-preflight") do |dir|
        candidate = File.join(dir, "preflight.json")
        command = preflight_command(data, candidate)
        stdout, stderr, status = Open3.capture3(scorer_environment, *command, chdir: scorer_repo(data))
        unless status.success? && File.file?(candidate)
          detail = [stdout, stderr].reject(&:empty?).join("\n").strip
          raise Error, "AFSU preflight replay failed: #{detail}"
        end
        actual = Digest::SHA256.file(candidate).hexdigest
        expected = data.fetch("preflight_sha256")
        raise Error, "AFSU preflight changed: expected #{expected}, got #{actual}" unless actual == expected
      end
    end

    def preflight_command(data, destination)
      common_command(data) + ["--preflight", "--render-preflight", destination, data.fetch("adventure_id")]
    end

    def score_command(data)
      common_command(data) + [data.fetch("adventure_id")]
    end

    def common_command(data)
      [
        File.join(scorer_repo(data), "bin", "af-score"),
        "--config", data_path(data.fetch("runtime_path")),
        "--model", data.fetch("ollama_model"),
        "--dimension", data.fetch("dimension"),
        "--output", data_path(data.fetch("output_path"))
      ]
    end

    def environment(data, require_placement:)
      environment = data.fetch("environment", {})
      unless environment.is_a?(Hash)
        raise Error, "case environment must be a mapping"
      end
      reserved = [PLACEMENT_ENDPOINT_ENV, SCORER_ENDPOINT_ENV].select { |name| environment.key?(name) }
      unless reserved.empty?
        raise Error, "case environment cannot set runtime adapter variable(s): #{reserved.sort.join(', ')}"
      end

      endpoint = ENV.fetch(PLACEMENT_ENDPOINT_ENV, "").strip
      if require_placement && endpoint.empty?
        raise Error, "missing WLO attempt placement endpoint in #{PLACEMENT_ENDPOINT_ENV}"
      end

      environment.transform_values { |value| value.nil? ? nil : value.to_s }.merge(
        PLACEMENT_ENDPOINT_ENV => nil,
        SCORER_ENDPOINT_ENV => endpoint.empty? ? nil : endpoint
      )
    end

    def scorer_repo(data)
      path = data.fetch("scorer_repo")
      raise Error, "case requires an explicit scorer repository" if @split && !Pathname.new(path).absolute?

      resolve(path)
    end

    # Resolve generated state; in split mode reject paths outside the store.
    def data_path(path)
      @split ? Roots.owned(@root, path) : resolve(path)
    end

    def resolve(path)
      pathname = Pathname.new(path.to_s)
      pathname.absolute? ? pathname.to_s : File.expand_path(pathname.to_s, @root)
    end

    def verify_sha!(path, expected, label)
      raise Error, "missing #{label}: #{path}" unless File.file?(path)
      actual = Digest::SHA256.file(path).hexdigest
      raise Error, "#{label} changed: expected #{expected}, got #{actual}" unless actual == expected.to_s.downcase
    end

    def system_run(environment, command, chdir)
      system(environment, *command, chdir: chdir)
    end
  end
end
