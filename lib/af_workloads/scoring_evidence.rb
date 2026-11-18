# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "pathname"
require "time"
require "yaml"

module AFWorkloads
  # Interprets, but never mutates, WLO's retained attempt evidence and AFSU's
  # proposed scoring artifacts. A receipt is evidence provenance, not editorial
  # acceptance.
  class ScoringEvidence
    CONTRACT_VERSION = "afw-scoring-evidence-receipt/v0.1"
    CASE_CONTRACT_VERSION = WorkloadCompiler::CONTRACT_VERSION
    HEX_SHA256 = /\A[0-9a-f]{64}\z/
    LEVELS_METRICS = ["Level Start", "Level End"].freeze

    attr_reader :receipt_path

    def initialize(root:, workload_id:, wlo_output:, job_id:)
      @root = File.expand_path(root)
      @workload_id = workload_id.to_s
      @wlo_output = File.expand_path(wlo_output)
      @job_id = job_id.to_s
      @bindings = nil
      @candidate = nil
      @receipt_path = File.join(@root, "output", "workloads", @workload_id, "evidence", "#{@job_id}.json")
    end
    def interpret
      @bindings = {}
      plan_bytes = bind_file(manifest_path("execution-plan.json"), "AFW execution plan")
      plan = parse_json(plan_bytes, "AFW execution plan")
      plan_sha256 = sha256(plan_bytes)
      validate_plan!(plan, plan_sha256)

      snapshot = parse_yaml(bind_file(manifest_path("snapshot.yml"), "AFW snapshot"), "AFW snapshot")
      validate_snapshot!(snapshot, plan_sha256)
      index_row = case_index_row(bind_file(manifest_path("case_index.csv"), "AFW case index"))
      job = exact_job(plan)
      validate_index_job!(index_row, job)

      case_path = safe_root_path(job.fetch("argv").fetch(1), "case")
      case_data = parse_yaml(bind_file(case_path, "AFW scoring case"), "AFW scoring case")
      validate_case!(case_data, index_row, job, snapshot)
      frozen_inputs = validate_frozen_inputs!(case_data)
      preflight = parse_json(@bindings.fetch(resolve(case_data.fetch("preflight_path"))), "AFSU preflight")
      validate_preflight!(preflight, case_data)

      wlo_plan_bytes = bind_file(File.join(@wlo_output, "plan.json"), "WLO frozen plan")
      raise Error, "WLO frozen plan differs from the AFW plan" unless wlo_plan_bytes == plan_bytes

      attempt_path = File.join(@wlo_output, "runs", @job_id, "metadata.json")
      attempt = parse_json(bind_file(attempt_path, "WLO current attempt"), "WLO current attempt")
      validate_attempt!(attempt, job)
      history = archived_attempts(attempt.fetch("attempt"))
      artifacts = scoring_artifacts(case_data, preflight, attempt)

      body = {
        "contract_version" => CONTRACT_VERSION,
        "semantic_status" => "provenance_validated_proposed_scoring_evidence",
        "workload" => {
          "plan_id" => @workload_id,
          "plan_sha256" => plan_sha256,
          "snapshot_sha256" => sha256(@bindings.fetch(manifest_path("snapshot.yml"))),
          "case_index_sha256" => sha256(@bindings.fetch(manifest_path("case_index.csv"))),
          "job_id" => @job_id,
          "pool_id" => job.fetch("pool_id"),
          "pool_requirements_sha256" => sha256(canonical_json(exact_pool(plan, job).fetch("requirements")))
        },
        "scoring_intent" => {
          "case_id" => case_data.fetch("case_id"),
          "adventure_id" => case_data.fetch("adventure_id"),
          "dimension" => case_data.fetch("dimension"),
          "profile" => case_data.fetch("profile"),
          "model_alias" => case_data.fetch("model_alias"),
          "ollama_model" => case_data.fetch("ollama_model"),
          "case_sha256" => sha256(@bindings.fetch(case_path))
        },
        "attempt" => attempt_receipt(attempt, attempt_path, history),
        "scorer_provenance" => {
          "scorer_commit" => case_data.fetch("scorer_commit"),
          "qualified_model_digest" => case_data.fetch("qualified_model_digest"),
          "catalog_sha256" => case_data.fetch("catalog_sha256"),
          "qualification_sha256" => case_data.fetch("qualification_sha256"),
          "runtime_sha256" => case_data.fetch("runtime_sha256"),
          "preflight_sha256" => case_data.fetch("preflight_sha256"),
          "prompt_sha256" => artifacts.fetch("prompt_sha256"),
          "schema_sha256" => artifacts.fetch("schema_sha256"),
          "source_scope" => artifacts.fetch("source_scope"),
          "afao_version" => artifacts.fetch("afao_version"),
          "assessment_spec_version" => artifacts.fetch("assessment_spec_version"),
          "frozen_inputs" => frozen_inputs
        },
        "artifacts" => artifacts.fetch("receipt_artifacts")
      }
      @candidate = body.merge("receipt_id" => sha256(canonical_json(body)))
    rescue KeyError, IndexError => e
      raise Error, "incomplete scoring evidence: #{e.message}"
    end

    def write(receipt = nil)
      receipt ||= interpret
      unless @candidate && receipt == @candidate
        raise Error, "receipt was not produced by the current evidence selection"
      end
      verify_unchanged!
      bytes = JSON.pretty_generate(receipt) + "\n"
      if File.exist?(receipt_path)
        return receipt_path if File.binread(receipt_path) == bytes

        raise Error, "evidence receipt already exists with different bytes: #{receipt_path}"
      end
      FileUtils.mkdir_p(File.dirname(receipt_path))
      temporary = "#{receipt_path}.tmp.#{Process.pid}"
      File.binwrite(temporary, bytes)
      File.rename(temporary, receipt_path)
      receipt_path
    ensure
      File.delete(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
    end

    private

    def manifest_path(name)
      File.join(@root, "workloads", @workload_id, name)
    end

    def bind_file(path, label)
      expanded = File.expand_path(path)
      raise Error, "missing #{label}: #{expanded}" unless File.file?(expanded)

      bytes = File.binread(expanded)
      @bindings[expanded] = bytes
      bytes
    end

    def parse_json(bytes, label)
      value = JSON.parse(bytes)
      raise Error, "#{label} must be a JSON object" unless value.is_a?(Hash)

      value
    rescue JSON::ParserError => e
      raise Error, "malformed #{label}: #{e.message}"
    end

    def parse_yaml(bytes, label)
      value = YAML.safe_load(bytes, aliases: true)
      raise Error, "#{label} must be a mapping" unless value.is_a?(Hash)

      value
    rescue Psych::Exception => e
      raise Error, "malformed #{label}: #{e.message}"
    end

    def validate_plan!(plan, digest)
      raise Error, "AFW plan ID mismatch" unless plan["plan_id"] == @workload_id
      raise Error, "invalid AFW plan SHA-256" unless digest.match?(HEX_SHA256)
      jobs = plan["jobs"]
      raise Error, "AFW plan jobs must be an array" unless jobs.is_a?(Array)
      raise Error, "AFW plan job IDs are ambiguous" unless jobs.map { |row| row["job_id"] }.uniq.length == jobs.length
    end

    def validate_snapshot!(snapshot, plan_sha256)
      valid = snapshot["contract_version"] == CASE_CONTRACT_VERSION &&
              snapshot["workload_id"] == @workload_id &&
              snapshot["execution_plan_sha256"] == plan_sha256
      raise Error, "AFW snapshot does not bind the frozen plan" unless valid
    end

    def case_index_row(bytes)
      table = CSV.parse(bytes, headers: true)
      rows = table.select { |row| row["case_id"] == @job_id }
      raise Error, "job #{@job_id.inspect} is not unique in the AFW case index" unless rows.length == 1

      rows.first.to_h
    rescue CSV::MalformedCSVError => e
      raise Error, "malformed AFW case index: #{e.message}"
    end

    def exact_job(plan)
      jobs = plan.fetch("jobs").select { |row| row["job_id"] == @job_id }
      raise Error, "job #{@job_id.inspect} does not exist in the frozen AFW plan" unless jobs.length == 1

      jobs.first
    end

    def exact_pool(plan, job)
      pools = plan.fetch("pools").select { |row| row["pool_id"] == job.fetch("pool_id") }
      raise Error, "AFW plan pool identity is ambiguous" unless pools.length == 1

      pools.first
    end

    def validate_index_job!(row, job)
      argv = job["argv"]
      valid = argv.is_a?(Array) && argv.length == 2 && argv.first == "bin/afw-score-job" &&
              row["case_id"] == @job_id && row["case_path"] == argv.last &&
              row["adventure_id"] == job["group_id"]
      raise Error, "AFW plan job does not match the frozen case index" unless valid
    end

    def validate_case!(data, row, job, snapshot)
      expected = {
        "contract_version" => CASE_CONTRACT_VERSION,
        "workload_id" => @workload_id,
        "case_id" => @job_id,
        "adventure_id" => row.fetch("adventure_id"),
        "dimension" => row.fetch("dimension"),
        "profile" => row.fetch("profile"),
        "model_alias" => row.fetch("model_alias"),
        "ollama_model" => row.fetch("ollama_model"),
        "qualified_model_digest" => row.fetch("qualified_model_digest"),
        "qualification_sha256" => row.fetch("qualification_sha256"),
        "runtime_sha256" => row.fetch("runtime_sha256"),
        "preflight_sha256" => row.fetch("preflight_sha256"),
        "scorer_commit" => snapshot.fetch("scorer_commit")
      }
      mismatch = expected.find { |key, value| data[key] != value }
      raise Error, "AFW scoring case provenance mismatch for #{mismatch.first}" if mismatch
      raise Error, "AFW case adventure does not match plan grouping" unless data["adventure_id"] == job["group_id"]
      raise Error, "invalid scorer commit" unless data["scorer_commit"].to_s.match?(/\A[0-9a-f]{40}\z/)
    end

    def validate_frozen_inputs!(data)
      %w[catalog qualification runtime preflight].to_h do |label|
        path = resolve(data.fetch("#{label}_path"))
        bytes = bind_file(path, label)
        actual = sha256(bytes)
        raise Error, "#{label} provenance mismatch" unless actual == data.fetch("#{label}_sha256")

        [label, { "path" => relative_root(path), "sha256" => actual }]
      end
    end

    def validate_preflight!(preflight, data)
      metadata = preflight["run_metadata"]
      targets = preflight["targets"]
      valid = metadata.is_a?(Hash) && targets.is_a?(Array) && targets.length == 1 &&
              preflight["adventure_id"] == data["adventure_id"] &&
              metadata["adventure_id"] == data["adventure_id"] &&
              metadata["selected_dimension"] == data["dimension"] &&
              metadata["model"] == data["ollama_model"]
      raise Error, "AFSU preflight provenance does not match the AFW scoring intent" unless valid
    end

    def validate_attempt!(attempt, job)
      number = Integer(attempt.fetch("attempt"))
      valid = number.positive? && attempt["job_id"] == @job_id && attempt["pool_id"] == job["pool_id"] &&
              attempt["argv"] == job["argv"] && attempt["status"] == "complete" && attempt["exit_status"] == 0
      raise Error, "WLO current attempt is not an authoritative terminal success" unless valid
      started = Time.iso8601(attempt.fetch("started_at"))
      completed = Time.iso8601(attempt.fetch("completed_at"))
      raise Error, "WLO attempt timing is invalid" if completed < started
    rescue ArgumentError, TypeError
      raise Error, "WLO current attempt identity or timing is invalid"
    end

    def archived_attempts(current_attempt)
      pattern = File.join(@wlo_output, "attempts", @job_id, "attempt-*", "metadata.json")
      Dir.glob(pattern).sort.map do |path|
        metadata = parse_json(bind_file(path, "WLO archived attempt"), "WLO archived attempt")
        number = Integer(metadata.fetch("attempt"))
        unless metadata["job_id"] == @job_id && number.positive? && number < current_attempt
          raise Error, "WLO archived attempt identity is ambiguous"
        end
        {
          "attempt" => number,
          "status" => metadata.fetch("status"),
          "evidence_path" => Pathname.new(path).relative_path_from(Pathname.new(@wlo_output)).to_s,
          "evidence_sha256" => sha256(@bindings.fetch(File.expand_path(path)))
        }
      end.tap do |rows|
        raise Error, "WLO archived attempt identities are duplicated" unless rows.map { |row| row["attempt"] }.uniq.length == rows.length
      end
    rescue ArgumentError, TypeError, KeyError => e
      raise Error, "invalid WLO archived attempt evidence: #{e.message}"
    end

    def scoring_artifacts(data, preflight, attempt)
      output = safe_root_path(data.fetch("output_path"), "scoring output")
      assessment_paths = Dir.glob(File.join(output, "assessments", "#{data.fetch('adventure_id')}_*.csv")).sort
      candidates = assessment_paths.filter_map do |path|
        run_id = File.basename(path, ".csv").delete_prefix("#{data.fetch('adventure_id')}_")
        target = preflight.fetch("targets").first
        artifact_name = target.fetch("artifact_name")
        raw_dir = File.join(output, "raw", data.fetch("adventure_id"), run_id)
        request_path = File.join(raw_dir, "#{artifact_name}_request.json")
        response_path = File.join(raw_dir, "#{artifact_name}.json")
        next unless File.file?(request_path) && File.file?(response_path)

        request = parse_json(File.binread(request_path), "raw request evidence")
        recorded_at = Time.iso8601(request.fetch("recorded_at"))
        started = Time.iso8601(attempt.fetch("started_at"))
        completed = Time.iso8601(attempt.fetch("completed_at"))
        next unless recorded_at >= started && recorded_at <= completed

        rows = parse_assessment(bind_file(path, "proposed assessment"))
        request = parse_json(bind_file(request_path, "raw request evidence"), "raw request evidence")
        response_bytes = bind_file(response_path, "raw response evidence")
        JSON.parse(response_bytes)
        validate_assessment!(rows, data, preflight)
        validate_request!(request, data, target)
        {
          "rows" => rows,
          "run_id" => run_id,
          "target" => target,
          "request" => request,
          "assessment_path" => path,
          "request_path" => request_path,
          "response_path" => response_path
        }
      rescue JSON::ParserError => e
        raise Error, "malformed raw response evidence: #{e.message}"
      rescue ArgumentError
        raise Error, "raw request evidence has invalid recorded_at"
      end
      raise Error, "no complete AFSU evidence set belongs to the authoritative WLO attempt" if candidates.empty?
      raise Error, "multiple AFSU evidence sets belong to the authoritative WLO attempt" unless candidates.length == 1

      selected = candidates.first
      metadata = preflight.fetch("run_metadata")
      target = selected.fetch("target")
      {
        "prompt_sha256" => target.fetch("prompt_sha256"),
        "schema_sha256" => target.fetch("schema_sha256"),
        "source_scope" => metadata.fetch("source_scope"),
        "afao_version" => metadata.fetch("afao_version"),
        "assessment_spec_version" => metadata.fetch("assessment_spec_version"),
        "receipt_artifacts" => {
          "run_id" => selected.fetch("run_id"),
          "proposed_assessment" => artifact_receipt(selected.fetch("assessment_path")),
          "raw_request" => artifact_receipt(selected.fetch("request_path")),
          "raw_response" => artifact_receipt(selected.fetch("response_path"))
        }
      }
    end

    def parse_assessment(bytes)
      table = CSV.parse(bytes, headers: true)
      required = %w[run_id status adventure_id afao_version assessment_spec_version provider model source_file metric]
      missing = required - Array(table.headers)
      raise Error, "malformed proposed assessment: missing #{missing.join(', ')}" unless missing.empty?
      rows = table.map(&:to_h)
      raise Error, "malformed proposed assessment: no rows" if rows.empty?

      rows
    rescue CSV::MalformedCSVError => e
      raise Error, "malformed proposed assessment: #{e.message}"
    end

    def validate_assessment!(rows, data, preflight)
      metadata = preflight.fetch("run_metadata")
      run_ids = rows.map { |row| row["run_id"] }.uniq
      metrics = rows.map { |row| row["metric"] }
      expected_metrics = data["dimension"] == "Levels" ? LEVELS_METRICS : [data["dimension"]]
      valid = run_ids.length == 1 && metrics.sort == expected_metrics.sort && rows.all? do |row|
        row["status"] == "PROPOSED" && row["adventure_id"] == data["adventure_id"] &&
          row["provider"] == metadata["provider"] && row["model"] == data["ollama_model"] &&
          row["source_file"] == metadata["source_file"] &&
          row["afao_version"] == metadata["afao_version"] &&
          row["assessment_spec_version"] == metadata["assessment_spec_version"]
      end
      raise Error, "proposed assessment provenance does not match the AFW scoring intent" unless valid
    end

    def validate_request!(request, data, target)
      provider_request = request["request"]
      serialized = JSON.generate(provider_request)
      valid = request["record_type"] == "provider_request" && request["recorded_before_inference"] == true &&
              request["prompt_sha256"] == target["prompt_sha256"] &&
              request["schema_sha256"] == target["schema_sha256"] &&
              request["request_sha256"] == sha256(serialized) && provider_request.is_a?(Hash) &&
              provider_request["provider"] == expected_provider(data) &&
              provider_request.dig("payload", "model") == data["ollama_model"]
      raise Error, "raw request provenance does not match the AFW scoring intent" unless valid
    end

    def expected_provider(data)
      data.fetch("environment", {}).fetch("AF_LLM_PROVIDER")
    rescue NoMethodError, KeyError
      raise Error, "AFW scoring case has no provider provenance"
    end

    def attempt_receipt(attempt, path, history)
      result = {
        "job_id" => @job_id,
        "attempt" => attempt.fetch("attempt"),
        "status" => attempt.fetch("status"),
        "exit_status" => attempt.fetch("exit_status"),
        "started_at" => attempt.fetch("started_at"),
        "completed_at" => attempt.fetch("completed_at"),
        "argv_sha256" => sha256(canonical_json(attempt.fetch("argv"))),
        "evidence_path" => Pathname.new(path).relative_path_from(Pathname.new(@wlo_output)).to_s,
        "evidence_sha256" => sha256(@bindings.fetch(File.expand_path(path))),
        "superseded_attempts" => history
      }
      %w[worker worker_execution_identity worker_registry_binding].each do |key|
        result[key] = attempt[key] if attempt.key?(key)
      end
      result
    end

    def artifact_receipt(path)
      { "path" => relative_root(path), "sha256" => sha256(@bindings.fetch(File.expand_path(path))) }
    end

    def safe_root_path(path, label)
      expanded = resolve(path)
      unless expanded == @root || expanded.start_with?("#{@root}/")
        raise Error, "#{label} escapes AFW root"
      end
      expanded
    end

    def resolve(path)
      pathname = Pathname.new(path.to_s)
      pathname.absolute? ? pathname.to_s : File.expand_path(pathname.to_s, @root)
    end

    def relative_root(path)
      Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(@root)).to_s
    end

    def verify_unchanged!
      changed = @bindings.keys.find { |path| !File.file?(path) || File.binread(path) != @bindings.fetch(path) }
      raise Error, "authoritative evidence changed after selection: #{changed}" if changed
    end

    def canonical_json(value)
      JSON.generate(canonical(value))
    end

    def canonical(value)
      case value
      when Hash
        value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
      when Array
        value.map { |entry| canonical(entry) }
      else
        value
      end
    end

    def sha256(bytes)
      Digest::SHA256.hexdigest(bytes)
    end
  end
end
