# frozen_string_literal: true

require "csv"
require "digest"
require "json"
require "pathname"
require "time"
require "yaml"

module AFWorkloads
  # Coordinates ScoringEvidence across every intended case in one frozen AFW
  # workload. The returned document is an inspection result, not a durable
  # completeness manifest and not editorial acceptance.
  class WorkloadScoringEvidence
    CONTRACT_VERSION = "afw-workload-scoring-evidence-result/v0.1"
    EXECUTION_CONTRACT_VERSION = "wlo-execution-state/v0.1"
    ATTEMPT_STATUSES = %w[complete failed interrupted running].freeze
    RETRYABLE_STATUSES = %w[failed interrupted].freeze

    def initialize(root:, workload_id:, wlo_output:)
      @root = File.expand_path(root)
      @workload_id = workload_id.to_s
      @wlo_output = File.expand_path(wlo_output)
      @bindings = {}
      @missing_paths = []
    end

    def bind
      manifest = load_manifest
      retry_pending = validate_execution!(
        manifest.fetch("execution"), manifest.fetch("plan_sha256"), manifest.fetch("jobs")
      )
      cases = manifest.fetch("rows").zip(manifest.fetch("jobs")).map do |row, job|
        inspect_case(row, job, retry_pending)
      end
      verify_unchanged!

      {
        "contract_version" => CONTRACT_VERSION,
        "semantic_status" => "workload_scoring_evidence_inspection",
        "workload" => workload_identity(manifest),
        "fully_evidenced" => cases.all? { |row| row.fetch("outcome") == "evidenced" },
        "counts" => outcome_counts(cases),
        "reason_counts" => reason_counts(cases),
        "cases" => cases
      }
    rescue KeyError, IndexError => e
      raise Error, "incomplete workload scoring evidence: #{e.message}"
    end

    private

    def load_manifest
      plan_bytes = bind_file(manifest_path("execution-plan.json"), "AFW execution plan")
      plan = parse_json(plan_bytes, "AFW execution plan")
      plan_sha256 = sha256(plan_bytes)
      raise Error, "AFW plan ID mismatch" unless plan["plan_id"] == @workload_id

      wlo_plan_bytes = bind_file(File.join(@wlo_output, "plan.json"), "WLO frozen plan")
      raise Error, "WLO frozen plan differs from the AFW plan" unless wlo_plan_bytes == plan_bytes

      snapshot_bytes = bind_file(manifest_path("snapshot.yml"), "AFW snapshot")
      snapshot = parse_yaml(snapshot_bytes, "AFW snapshot")
      valid_snapshot = snapshot["contract_version"] == ScoringEvidence::CASE_CONTRACT_VERSION &&
                       snapshot["workload_id"] == @workload_id &&
                       snapshot["execution_plan_sha256"] == plan_sha256
      raise Error, "AFW snapshot does not bind the frozen plan" unless valid_snapshot

      index_bytes = bind_file(manifest_path("case_index.csv"), "AFW case index")
      rows = parse_case_index(index_bytes)
      jobs = validate_case_enumeration!(plan, rows)
      execution_path = File.join(@wlo_output, "execution.json")
      execution_bytes = bind_file(execution_path, "WLO execution state")

      {
        "plan" => plan,
        "plan_sha256" => plan_sha256,
        "snapshot_sha256" => sha256(snapshot_bytes),
        "case_index_sha256" => sha256(index_bytes),
        "execution" => parse_json(execution_bytes, "WLO execution state"),
        "execution_sha256" => sha256(execution_bytes),
        "rows" => rows,
        "jobs" => jobs
      }
    end

    def parse_case_index(bytes)
      table = CSV.parse(bytes, headers: true)
      required = %w[case_id adventure_id dimension case_path]
      missing = required - Array(table.headers)
      raise Error, "AFW case index is missing #{missing.join(', ')}" unless missing.empty?

      rows = table.map(&:to_h)
      raise Error, "AFW case index has no cases" if rows.empty?
      raise Error, "AFW case index case IDs are ambiguous" unless rows.map { |row| row["case_id"] }.uniq.length == rows.length

      rows
    rescue CSV::MalformedCSVError => e
      raise Error, "malformed AFW case index: #{e.message}"
    end

    def validate_case_enumeration!(plan, rows)
      jobs = plan["jobs"]
      raise Error, "AFW plan jobs must be an array" unless jobs.is_a?(Array) && !jobs.empty?
      raise Error, "AFW plan job IDs are ambiguous" unless jobs.map { |job| job["job_id"] }.uniq.length == jobs.length
      unless rows.map { |row| row["case_id"] } == jobs.map { |job| job["job_id"] }
        raise Error, "AFW plan jobs do not exactly match the frozen case index"
      end

      rows.zip(jobs).each do |row, job|
        argv = job["argv"]
        valid = argv.is_a?(Array) && argv.length == 2 && argv.first == "bin/afw-score-job" &&
                argv.last == row["case_path"] && job["group_id"] == row["adventure_id"]
        raise Error, "AFW plan job does not match the frozen case index" unless valid
      end
      jobs
    end

    def validate_execution!(execution, plan_sha256, jobs)
      valid = execution["contract_version"] == EXECUTION_CONTRACT_VERSION &&
              execution["plan_id"] == @workload_id && execution["plan_sha256"] == plan_sha256
      raise Error, "WLO execution state does not bind the frozen plan" unless valid

      pending = execution.fetch("retry_pending", {})
      raise Error, "WLO retry-pending state must be an object" unless pending.is_a?(Hash)
      unknown = pending.keys - jobs.map { |job| job.fetch("job_id") }
      raise Error, "WLO retry-pending state references unknown jobs" unless unknown.empty?
      pending.each_value { |attempt| positive_integer!(attempt, "WLO retry-pending attempt") }
      pending
    rescue AttemptInspectionError => e
      raise Error, e.message
    end

    def inspect_case(row, job, retry_pending)
      base = case_identity(row, job)
      path = File.join(@wlo_output, "runs", job.fetch("job_id"), "metadata.json")
      unless File.file?(path)
        @missing_paths << File.expand_path(path)
        return base.merge("outcome" => "pending", "reason" => "wlo_attempt_unstarted")
      end

      attempt = parse_attempt(bind_file(path, "WLO current attempt"), path, job)
      identity = attempt_identity(attempt, path)
      pending_attempt = retry_pending[job.fetch("job_id")]
      if pending_attempt
        unless pending_attempt == attempt.fetch("attempt") && RETRYABLE_STATUSES.include?(attempt.fetch("status"))
          return unsafe(
            base, "attempt_state_malformed", "WLO retry-pending identity does not match the current attempt",
            attempt: identity
          )
        end
        return base.merge(
          "outcome" => "pending", "reason" => "wlo_retry_authorized", "authoritative_attempt" => identity
        )
      end

      case attempt.fetch("status")
      when "complete"
        bind_success(base, identity, job)
      when "failed"
        base.merge("outcome" => "failed", "reason" => "wlo_attempt_failed", "authoritative_attempt" => identity)
      when "interrupted"
        base.merge(
          "outcome" => "interrupted", "reason" => "wlo_attempt_interrupted", "authoritative_attempt" => identity
        )
      when "running"
        base.merge("outcome" => "running", "reason" => "wlo_attempt_running", "authoritative_attempt" => identity)
      end
    rescue AttemptInspectionError => e
      unsafe(base, e.reason, e.message)
    end

    def bind_success(base, identity, job)
      unless identity["exit_status"] == 0 && identity.key?("completed_at")
        return unsafe(
          base, "attempt_state_malformed", "complete WLO attempt is not a terminal success", attempt: identity
        )
      end

      interpreter = ScoringEvidence.new(
        root: @root, workload_id: @workload_id, wlo_output: @wlo_output, job_id: job.fetch("job_id")
      )
      receipt = interpreter.interpret
      existed = File.file?(interpreter.receipt_path)
      path = interpreter.write(receipt)
      base.merge(
        "outcome" => "evidenced",
        "reason" => existed ? "receipt_reused" : "receipt_created",
        "authoritative_attempt" => receipt.fetch("attempt"),
        "receipt" => {
          "path" => relative_root(path),
          "receipt_id" => receipt.fetch("receipt_id")
        }
      )
    rescue Error => e
      unsafe(base, scoring_error_reason(e.message), e.message, attempt: identity)
    end

    def parse_attempt(bytes, path, job)
      attempt = JSON.parse(bytes)
      unless attempt.is_a?(Hash)
        raise AttemptInspectionError.new("attempt_state_malformed", "WLO current attempt must be a JSON object")
      end
      number = positive_integer!(attempt["attempt"], "WLO attempt number")
      status = attempt["status"].to_s
      unless ATTEMPT_STATUSES.include?(status)
        raise AttemptInspectionError.new("attempt_state_malformed", "unsupported WLO attempt status #{status.inspect}")
      end
      valid = attempt["job_id"] == job["job_id"] && attempt["pool_id"] == job["pool_id"] &&
              attempt["argv"] == job["argv"]
      unless valid
        raise AttemptInspectionError.new("attempt_identity_mismatch", "WLO current attempt identity does not match the frozen job")
      end
      validate_attempt_timing!(attempt, status)
      validate_attempt_shape!(attempt, status)
      attempt.merge("attempt" => number, "evidence_path" => relative_wlo(path))
    rescue JSON::ParserError => e
      raise AttemptInspectionError.new("attempt_state_malformed", "malformed WLO current attempt: #{e.message}")
    end

    def validate_attempt_timing!(attempt, status)
      started = Time.iso8601(attempt.fetch("started_at"))
      return if status == "running"

      completed = Time.iso8601(attempt.fetch("completed_at"))
      if completed < started
        raise AttemptInspectionError.new("attempt_state_malformed", "WLO current attempt timing is invalid")
      end
    rescue KeyError, ArgumentError, TypeError
      raise AttemptInspectionError.new("attempt_state_malformed", "WLO current attempt timing is invalid")
    end

    def validate_attempt_shape!(attempt, status)
      valid = case status
              when "complete"
                attempt["exit_status"] == 0
              when "failed"
                attempt["exit_status"].nil? || attempt["exit_status"].is_a?(Integer) && !attempt["exit_status"].zero?
              when "interrupted"
                attempt.key?("completed_at")
              when "running"
                !attempt.key?("completed_at") && !attempt.key?("exit_status")
              end
      return if valid

      raise AttemptInspectionError.new("attempt_state_malformed", "WLO current attempt status fields are inconsistent")
    end

    def attempt_identity(attempt, path)
      {
        "job_id" => attempt.fetch("job_id"),
        "attempt" => attempt.fetch("attempt"),
        "status" => attempt.fetch("status"),
        "exit_status" => attempt["exit_status"],
        "evidence_path" => relative_wlo(path),
        "evidence_sha256" => sha256(@bindings.fetch(File.expand_path(path))),
        "superseded_attempts" => superseded_attempts(attempt.fetch("job_id"), attempt.fetch("attempt"))
      }.tap do |identity|
        %w[started_at completed_at worker worker_execution_identity worker_registry_binding].each do |key|
          identity[key] = attempt[key] if attempt.key?(key)
        end
      end
    end

    def superseded_attempts(job_id, current_attempt)
      pattern = File.join(@wlo_output, "attempts", job_id, "attempt-*", "metadata.json")
      rows = Dir.glob(pattern).sort.map do |path|
        bytes = bind_file(path, "WLO archived attempt")
        metadata = JSON.parse(bytes)
        number = positive_integer!(metadata.fetch("attempt"), "WLO archived attempt number")
        unless metadata["job_id"] == job_id && number <= current_attempt && RETRYABLE_STATUSES.include?(metadata["status"])
          raise AttemptInspectionError.new("attempt_history_malformed", "WLO archived attempt identity is ambiguous")
        end
        {
          "attempt" => number,
          "status" => metadata.fetch("status"),
          "evidence_path" => relative_wlo(path),
          "evidence_sha256" => sha256(bytes)
        }
      end
      unless rows.map { |row| row["attempt"] }.uniq.length == rows.length
        raise AttemptInspectionError.new("attempt_history_malformed", "WLO archived attempt identities are duplicated")
      end
      rows.select { |row| row.fetch("attempt") < current_attempt }
    rescue JSON::ParserError, KeyError => e
      raise AttemptInspectionError.new("attempt_history_malformed", "invalid WLO archived attempt evidence: #{e.message}")
    end

    def case_identity(row, job)
      {
        "case_id" => row.fetch("case_id"),
        "adventure_id" => row.fetch("adventure_id"),
        "dimension" => row.fetch("dimension"),
        "job" => {
          "job_id" => job.fetch("job_id"),
          "pool_id" => job.fetch("pool_id"),
          "argv_sha256" => sha256(canonical_json(job.fetch("argv")))
        }
      }
    end

    def unsafe(base, reason, detail, attempt: nil)
      portable_detail = detail.to_s.gsub(@root, "<AFW_ROOT>").gsub(@wlo_output, "<WLO_OUTPUT>")
      result = base.merge("outcome" => "unsafe", "reason" => reason, "detail" => portable_detail)
      result["authoritative_attempt"] = attempt if attempt
      result
    end

    def scoring_error_reason(message)
      case message
      when /evidence receipt already exists with different bytes/
        "receipt_conflict"
      when /multiple AFSU evidence sets/
        "ambiguous_scoring_evidence"
      when /no complete AFSU evidence set/
        "missing_scoring_evidence"
      when /malformed proposed assessment|malformed raw (?:request|response) evidence/
        "malformed_scoring_evidence"
      when /authoritative evidence changed after selection/
        "evidence_changed_during_binding"
      else
        "invalid_scoring_evidence"
      end
    end

    def workload_identity(manifest)
      execution = manifest.fetch("execution")
      {
        "plan_id" => @workload_id,
        "plan_sha256" => manifest.fetch("plan_sha256"),
        "snapshot_sha256" => manifest.fetch("snapshot_sha256"),
        "case_index_sha256" => manifest.fetch("case_index_sha256"),
        "wlo_execution_contract" => execution.fetch("contract_version"),
        "wlo_execution_status" => execution.fetch("status"),
        "wlo_execution_sha256" => manifest.fetch("execution_sha256")
      }
    end

    def outcome_counts(cases)
      cases.group_by { |row| row.fetch("outcome") }.sort.to_h.transform_values(&:length)
    end

    def reason_counts(cases)
      cases.group_by { |row| row.fetch("reason") }.sort.to_h.transform_values(&:length)
    end

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

    def positive_integer!(value, label)
      number = Integer(value)
      return number if number.positive?

      raise ArgumentError
    rescue ArgumentError, TypeError
      raise AttemptInspectionError.new("attempt_state_malformed", "#{label} is invalid")
    end

    def verify_unchanged!
      changed = @bindings.keys.find { |path| !File.file?(path) || File.binread(path) != @bindings.fetch(path) }
      changed ||= @missing_paths.find { |path| File.exist?(path) }
      raise Error, "authoritative workload evidence changed during inspection: #{changed}" if changed
    end

    def relative_root(path)
      Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(@root)).to_s
    end

    def relative_wlo(path)
      Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(@wlo_output)).to_s
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

    class AttemptInspectionError < StandardError
      attr_reader :reason

      def initialize(reason, message)
        @reason = reason
        super(message)
      end
    end
  end
end
