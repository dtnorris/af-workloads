# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "pathname"
require "yaml"

module AFWorkloads
  # Publishes one immutable, content-addressed snapshot of the authoritative
  # evidence observation for every intended case in a frozen workload.
  class WorkloadEvidenceManifest
    CONTRACT_VERSION = "afw-workload-evidence-manifest/v0.1"
    SEMANTIC_STATUS = "authoritative_workload_evidence_snapshot"
    RECEIPT_CONTRACT = ScoringEvidence::CONTRACT_VERSION
    RECEIPT_STATUS = "provenance_validated_proposed_scoring_evidence"
    OUTCOMES = %w[evidenced failed interrupted pending running unsafe].freeze
    EXECUTION_STATUSES = %w[complete failed interrupted pending running unresolved].freeze
    EVIDENCE_STATUSES = %w[ready unresolved].freeze
    INDEX_IDENTITY_FIELDS = %w[
      case_id adventure_id dimension profile model_alias ollama_model qualified_model_digest
      qualification_sha256 runtime_sha256 preflight_sha256 case_path
    ].freeze
    HEX_SHA256 = /\A[0-9a-f]{64}\z/

    Publication = Struct.new(
      :path, :manifest_id, :reused, :evidence_complete, :intended_cases,
      :receipt_count, :candidate_count, keyword_init: true
    )

    def self.validate!(manifest_path:, afw_root:)
      Validator.new(afw_root:).validate!(manifest_path)
    end

    def initialize(root:, workload_id:, wlo_output:)
      @root = File.expand_path(root)
      @workload_id = workload_id.to_s
      @wlo_output = File.expand_path(wlo_output)
      @bindings = {}
      @missing_paths = []
    end

    def publish
      observation = WorkloadScoringEvidence.new(
        root: @root, workload_id: @workload_id, wlo_output: @wlo_output
      ).bind
      document = build_document(observation)
      Validator.new(afw_root: @root).validate_document!(document)
      verify_unchanged!
      bytes = JSON.pretty_generate(document) + "\n"
      path = publication_path(document.fetch("manifest_id"))
      reused = write_or_reuse!(path, bytes)
      Validator.new(afw_root: @root).validate!(path)
      summary = document.fetch("summary")
      Publication.new(
        path:, manifest_id: document.fetch("manifest_id"), reused:,
        evidence_complete: summary.fetch("evidence_complete"),
        intended_cases: summary.fetch("intended_cases"),
        receipt_count: summary.fetch("receipt_count"),
        candidate_count: summary.fetch("review_candidate_count")
      )
    end

    private

    def build_document(observation)
      frozen = frozen_workload(observation)
      cases = observation.fetch("cases").map do |result|
        row = frozen.fetch("rows_by_id").fetch(result.fetch("case_id"))
        job = frozen.fetch("jobs_by_id").fetch(result.fetch("case_id"))
        manifest_case(result, row, job, frozen.fetch("snapshot"))
      end
      body = {
        "contract_version" => CONTRACT_VERSION,
        "semantic_status" => SEMANTIC_STATUS,
        "workload" => workload_section(observation, frozen, cases.length),
        "summary" => summary(cases),
        "cases" => cases
      }
      body.merge("manifest_id" => sha256(canonical_json(body)))
    end

    def frozen_workload(observation)
      plan_ref, plan_bytes = afw_reference(manifest_path("execution-plan.json"), "AFW execution plan")
      snapshot_ref, snapshot_bytes = afw_reference(manifest_path("snapshot.yml"), "AFW snapshot")
      index_ref, index_bytes = afw_reference(manifest_path("case_index.csv"), "AFW case index")
      plan = parse_json(plan_bytes, "AFW execution plan")
      snapshot = parse_yaml(snapshot_bytes, "AFW snapshot")
      rows = CSV.parse(index_bytes, headers: true).map(&:to_h)
      jobs = plan.fetch("jobs")
      expected = observation.fetch("workload")
      unless plan_ref["sha256"] == expected.fetch("plan_sha256") &&
             snapshot_ref["sha256"] == expected.fetch("snapshot_sha256") &&
             index_ref["sha256"] == expected.fetch("case_index_sha256")
        raise Error, "workload observation does not match the frozen AFW manifests"
      end

      wlo_plan = source_reference(File.join(@wlo_output, "plan.json"), "WLO frozen plan")
      wlo_plan_path = File.join(@wlo_output, wlo_plan.fetch("path"))
      raise Error, "WLO frozen plan differs from the AFW plan" unless @bindings.fetch(wlo_plan_path) == plan_bytes
      execution = embedded_wlo(File.join(@wlo_output, "execution.json"), "WLO execution state")
      unless execution.dig("source", "sha256") == expected.fetch("wlo_execution_sha256")
        raise Error, "workload observation does not match the WLO execution state"
      end

      {
        "plan" => plan,
        "snapshot" => snapshot,
        "rows_by_id" => rows.to_h { |row| [row.fetch("case_id"), row] },
        "jobs_by_id" => jobs.to_h { |job| [job.fetch("job_id"), job] },
        "afw" => {
          "execution_plan" => plan_ref,
          "snapshot" => snapshot_ref,
          "case_index" => index_ref
        },
        "wlo" => {
          "plan" => wlo_plan.merge("root" => "wlo"),
          "execution" => execution
        }
      }
    rescue CSV::MalformedCSVError => e
      raise Error, "malformed AFW case index: #{e.message}"
    end

    def manifest_case(result, row, job, snapshot)
      validate_frozen_case!(row, job, snapshot)
      case_ref, = afw_reference(resolve_afw(row.fetch("case_path")), "AFW scoring case")
      current_attempt = current_attempt_snapshot(job.fetch("job_id"), result)
      receipt = receipt_snapshot(result)
      outcome = result.fetch("outcome")
      evidence_status = outcome == "evidenced" ? "ready" : "unresolved"
      reason = outcome == "evidenced" ? "receipt_valid" : result.fetch("reason")
      {
        "case_id" => row.fetch("case_id"),
        "adventure_id" => row.fetch("adventure_id"),
        "dimension" => row.fetch("dimension"),
        "intent" => {
          "case_index_row" => row,
          "case" => case_ref
        },
        "job" => job_identity(job),
        "classification" => {
          "outcome" => outcome,
          "reason" => reason,
          "execution_status" => execution_status(result),
          "evidence_status" => evidence_status
        },
        "execution" => {
          "current_attempt" => current_attempt,
          "authoritative_attempt" => result["authoritative_attempt"]
        },
        "receipt" => receipt
      }
    end

    def validate_frozen_case!(row, job, snapshot)
      missing = INDEX_IDENTITY_FIELDS - row.keys
      raise Error, "AFW case index row is missing #{missing.join(', ')}" unless missing.empty?
      argv = job["argv"]
      valid = job["job_id"] == row["case_id"] && job["group_id"] == row["adventure_id"] &&
              argv.is_a?(Array) && argv.length == 2 && argv.first == "bin/afw-score-job" &&
              argv.last == row["case_path"] && snapshot["workload_id"] == @workload_id
      raise Error, "frozen case, index and plan identity do not agree" unless valid
    end

    def current_attempt_snapshot(job_id, result)
      path = File.join(@wlo_output, "runs", job_id, "metadata.json")
      unless File.file?(path)
        @missing_paths << File.expand_path(path)
        raise Error, "authoritative attempt evidence is missing" if result["authoritative_attempt"]

        return nil
      end
      embedded = embedded_wlo(path, "WLO current attempt")
      identity = result["authoritative_attempt"]
      if identity && (identity["evidence_path"] != embedded.dig("source", "path") ||
                      identity["evidence_sha256"] != embedded.dig("source", "sha256"))
        raise Error, "workload observation does not match the current WLO attempt"
      end
      retained = Array(identity && identity["superseded_attempts"]).map do |attempt|
        archive = File.join(@wlo_output, attempt.fetch("evidence_path"))
        snapshot = embedded_wlo(archive, "WLO superseded attempt")
        unless snapshot.dig("source", "sha256") == attempt.fetch("evidence_sha256")
          raise Error, "workload observation does not match a superseded WLO attempt"
        end
        snapshot
      end
      embedded.merge("retained_superseded_attempts" => retained)
    end

    def receipt_snapshot(result)
      return nil unless result.fetch("outcome") == "evidenced"

      observed = result.fetch("receipt")
      path = resolve_afw(observed.fetch("path"))
      reference, bytes = afw_reference(path, "AFW scoring evidence receipt")
      receipt = parse_json(bytes, "AFW scoring evidence receipt")
      unless receipt["receipt_id"] == observed.fetch("receipt_id")
        raise Error, "workload observation does not match the AFW receipt"
      end
      dimension = receipt.dig("scoring_intent", "dimension")
      {
        "reference" => reference,
        "receipt_id" => receipt.fetch("receipt_id"),
        "contract_version" => receipt.fetch("contract_version"),
        "semantic_status" => receipt.fetch("semantic_status"),
        "review_candidate_count" => dimension == "Levels" ? 2 : 1
      }
    end

    def workload_section(observation, frozen, intended_cases)
      identity = observation.fetch("workload")
      {
        "plan_id" => @workload_id,
        "intended_case_count" => intended_cases,
        "afw" => frozen.fetch("afw"),
        "wlo" => frozen.fetch("wlo").merge(
          "execution_contract" => identity.fetch("wlo_execution_contract"),
          "execution_status" => identity.fetch("wlo_execution_status")
        )
      }
    end

    def job_identity(job)
      {
        "job_id" => job.fetch("job_id"),
        "pool_id" => job.fetch("pool_id"),
        "group_id" => job.fetch("group_id"),
        "argv_sha256" => sha256(canonical_json(job.fetch("argv"))),
        "plan_job_sha256" => sha256(canonical_json(job))
      }
    end

    def execution_status(result)
      outcome = result.fetch("outcome")
      return "complete" if outcome == "evidenced"
      return outcome if %w[failed interrupted pending running].include?(outcome)

      status = result.dig("authoritative_attempt", "status")
      %w[complete failed interrupted running].include?(status) ? status : "unresolved"
    end

    def summary(cases)
      execution_counts = tally(cases) { |row| row.dig("classification", "execution_status") }
      evidence_counts = tally(cases) { |row| row.dig("classification", "evidence_status") }
      receipts = cases.filter_map { |row| row["receipt"] }
      intended = cases.length
      ready = evidence_counts.fetch("ready", 0)
      {
        "intended_cases" => intended,
        "classified_cases" => cases.length,
        "accounting_complete" => intended.positive? && cases.length == intended,
        "execution_counts" => execution_counts,
        "evidence_counts" => evidence_counts,
        "receipt_count" => receipts.length,
        "review_candidate_count" => receipts.sum { |receipt| receipt.fetch("review_candidate_count") },
        "evidence_complete" => intended.positive? && ready == intended
      }
    end

    def tally(rows, &)
      rows.map(&).tally.sort.to_h
    end

    def afw_reference(path, label)
      expanded = safe_path(@root, path, label)
      bytes = bind_file(expanded, label)
      [{ "root" => "afw", "path" => relative(@root, expanded), "sha256" => sha256(bytes) }, bytes]
    end

    def source_reference(path, label)
      expanded = safe_path(@wlo_output, path, label)
      bytes = bind_file(expanded, label)
      { "path" => relative(@wlo_output, expanded), "sha256" => sha256(bytes) }
    end

    def embedded_wlo(path, label)
      expanded = safe_path(@wlo_output, path, label)
      bytes = bind_file(expanded, label)
      {
        "source" => {
          "root" => "wlo", "path" => relative(@wlo_output, expanded), "sha256" => sha256(bytes)
        },
        "encoding" => "hex",
        "content" => bytes.unpack1("H*")
      }
    end

    def bind_file(path, label)
      expanded = File.expand_path(path)
      raise Error, "missing #{label}: #{expanded}" unless File.file?(expanded)

      bytes = File.binread(expanded)
      @bindings[expanded] = bytes
      bytes
    end

    def safe_path(root, path, label)
      expanded = File.expand_path(path, root)
      prefix = "#{File.expand_path(root)}#{File::SEPARATOR}"
      raise Error, "#{label} escapes its component root" unless expanded.start_with?(prefix)

      expanded
    end

    def resolve_afw(path)
      File.expand_path(path, @root)
    end

    def manifest_path(name)
      File.join(@root, "workloads", @workload_id, name)
    end

    def publication_path(manifest_id)
      File.join(@root, "output", "workloads", @workload_id, "evidence", "manifests", "#{manifest_id}.json")
    end

    def write_or_reuse!(path, bytes)
      if File.exist?(path)
        return true if File.file?(path) && File.binread(path) == bytes

        raise Error, "workload evidence manifest path conflicts with immutable revision: #{path}"
      end
      FileUtils.mkdir_p(File.dirname(path))
      temporary = "#{path}.tmp.#{Process.pid}"
      File.binwrite(temporary, bytes)
      File.rename(temporary, path)
      false
    ensure
      File.delete(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
    end

    def verify_unchanged!
      changed = @bindings.keys.find do |path|
        !File.file?(path) || File.binread(path) != @bindings.fetch(path)
      end
      changed ||= @missing_paths.find { |path| File.exist?(path) }
      raise Error, "authoritative evidence changed during manifest construction: #{changed}" if changed
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

    def relative(root, path)
      Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(File.expand_path(root))).to_s
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

    # Reference validator for downstream consumers. Volatile WLO bytes are
    # validated from the embedded snapshot; immutable AFW references are
    # re-read from their public component-root-relative paths.
    class Validator
      def initialize(afw_root:)
        @afw_root = File.expand_path(afw_root)
      end

      def validate!(manifest_path)
        path = safe_afw_path(manifest_path, "workload evidence manifest")
        document = parse_json(File.binread(path), "workload evidence manifest")
        validate_document!(document)
      rescue Errno::ENOENT => e
        raise Error, "missing workload evidence manifest: #{e.message}"
      end

      def validate_document!(document)
        validate_identity!(document)
        workload = document.fetch("workload")
        plan_bytes = read_afw_reference(workload.dig("afw", "execution_plan"), "AFW execution plan")
        snapshot_bytes = read_afw_reference(workload.dig("afw", "snapshot"), "AFW snapshot")
        index_bytes = read_afw_reference(workload.dig("afw", "case_index"), "AFW case index")
        plan = parse_json(plan_bytes, "AFW execution plan")
        snapshot = parse_yaml(snapshot_bytes, "AFW snapshot")
        rows = parse_index(index_bytes)
        jobs = plan.fetch("jobs")
        cases = document.fetch("cases")
        execution = validate_workload!(workload, plan, snapshot, rows, jobs, cases, plan_bytes)
        rows.zip(jobs, cases).each do |row, job, manifest_case|
          validate_case!(workload, snapshot, execution, row, job, manifest_case)
        end
        validate_summary!(document.fetch("summary"), cases)
        document
      rescue KeyError, IndexError => e
        raise Error, "incomplete workload evidence manifest: #{e.message}"
      end

      private

      def validate_identity!(document)
        unless document["contract_version"] == CONTRACT_VERSION
          raise Error, "unsupported workload evidence manifest contract #{document['contract_version'].inspect}"
        end
        unless document["semantic_status"] == SEMANTIC_STATUS
          raise Error, "invalid workload evidence manifest semantic status"
        end
        supplied = document["manifest_id"].to_s
        body = document.reject { |key, _value| key == "manifest_id" }
        expected = sha256(canonical_json(body))
        raise Error, "workload evidence manifest identity mismatch" unless supplied.match?(HEX_SHA256) && supplied == expected
      end

      def validate_workload!(workload, plan, snapshot, rows, jobs, cases, plan_bytes)
        plan_id = workload.fetch("plan_id")
        count = workload.fetch("intended_case_count")
        valid = plan["plan_id"] == plan_id && snapshot["contract_version"] == WorkloadCompiler::CONTRACT_VERSION &&
                snapshot["workload_id"] == plan_id &&
                snapshot["execution_plan_sha256"] == sha256(plan_bytes) && count.is_a?(Integer) && count.positive?
        raise Error, "workload evidence manifest has invalid frozen workload identity" unless valid
        unless rows.length == count && jobs.length == count && cases.length == count
          raise Error, "workload evidence manifest denominator does not match frozen intent"
        end
        row_ids = rows.map { |row| row["case_id"] }
        job_ids = jobs.map { |job| job["job_id"] }
        case_ids = cases.map { |entry| entry["case_id"] }
        unless row_ids.uniq.length == count && job_ids.uniq.length == count && case_ids.uniq.length == count &&
               row_ids == job_ids && row_ids == case_ids
          raise Error, "workload evidence manifest case accounting is missing, duplicated or unexpected"
        end
        wlo_plan = workload.dig("wlo", "plan")
        unless source_reference?(wlo_plan, "plan.json") && wlo_plan["sha256"] == sha256(plan_bytes)
          raise Error, "workload evidence manifest WLO plan identity mismatch"
        end
        execution_bytes = embedded_bytes(workload.dig("wlo", "execution"), "WLO execution state", "execution.json")
        execution = parse_json(execution_bytes, "WLO execution state")
        valid_execution = execution["contract_version"] == workload.dig("wlo", "execution_contract") &&
                          execution["plan_id"] == plan_id && execution["plan_sha256"] == sha256(plan_bytes) &&
                          execution["status"] == workload.dig("wlo", "execution_status")
        raise Error, "workload evidence manifest WLO execution identity mismatch" unless valid_execution
        retry_pending = execution.fetch("retry_pending", {})
        retry_valid = retry_pending.is_a?(Hash) && (retry_pending.keys - job_ids).empty? &&
                      retry_pending.values.all? { |attempt| attempt.is_a?(Integer) && attempt.positive? }
        raise Error, "workload evidence manifest WLO retry state is invalid" unless retry_valid

        execution
      end

      def validate_case!(workload, snapshot, execution, row, job, manifest_case)
        unless manifest_case["adventure_id"] == row["adventure_id"] &&
               manifest_case["dimension"] == row["dimension"] &&
               manifest_case.dig("intent", "case_index_row") == row
          raise Error, "workload evidence manifest frozen intent mismatch"
        end
        validate_job!(manifest_case.fetch("job"), job)
        validate_case_reference!(workload, snapshot, manifest_case, row)
        validate_classification!(manifest_case)
        validate_attempt!(manifest_case, job, execution)
        validate_receipt!(workload, snapshot, manifest_case, row)
      end

      def validate_job!(identity, job)
        valid = identity["job_id"] == job["job_id"] && identity["pool_id"] == job["pool_id"] &&
                identity["group_id"] == job["group_id"] &&
                identity["argv_sha256"] == sha256(canonical_json(job.fetch("argv"))) &&
                identity["plan_job_sha256"] == sha256(canonical_json(job))
        raise Error, "workload evidence manifest job identity mismatch" unless valid
      end

      def validate_case_reference!(workload, snapshot, manifest_case, row)
        reference = manifest_case.dig("intent", "case")
        raise Error, "workload evidence manifest case path mismatch" unless reference["path"] == row["case_path"]
        data = parse_yaml(read_afw_reference(reference, "AFW scoring case"), "AFW scoring case")
        expected = {
          "workload_id" => workload.fetch("plan_id"), "case_id" => row.fetch("case_id"),
          "adventure_id" => row.fetch("adventure_id"), "dimension" => row.fetch("dimension"),
          "profile" => row.fetch("profile"), "model_alias" => row.fetch("model_alias"),
          "ollama_model" => row.fetch("ollama_model"),
          "qualified_model_digest" => row.fetch("qualified_model_digest"),
          "qualification_sha256" => row.fetch("qualification_sha256"),
          "runtime_sha256" => row.fetch("runtime_sha256"), "preflight_sha256" => row.fetch("preflight_sha256")
        }
        expected["contract_version"] = WorkloadCompiler::CONTRACT_VERSION
        expected["scorer_commit"] = snapshot.fetch("scorer_commit")
        mismatch = expected.find { |key, value| data[key] != value }
        raise Error, "workload evidence manifest case intent mismatch for #{mismatch.first}" if mismatch
      end

      def validate_classification!(manifest_case)
        classification = manifest_case.fetch("classification")
        outcome = classification.fetch("outcome")
        execution = classification.fetch("execution_status")
        evidence = classification.fetch("evidence_status")
        unless OUTCOMES.include?(outcome) && EXECUTION_STATUSES.include?(execution) &&
               EVIDENCE_STATUSES.include?(evidence) && !classification.fetch("reason").to_s.empty?
          raise Error, "workload evidence manifest has invalid case classification"
        end
        ready = outcome == "evidenced" && execution == "complete" && evidence == "ready" &&
                classification["reason"] == "receipt_valid"
        unresolved = outcome != "evidenced" && evidence == "unresolved"
        raise Error, "workload evidence manifest execution/evidence classification is inconsistent" unless ready || unresolved
      end

      def validate_attempt!(manifest_case, job, wlo_execution)
        case_execution = manifest_case.fetch("execution")
        snapshot = case_execution["current_attempt"]
        identity = case_execution["authoritative_attempt"]
        if snapshot.nil?
          unless identity.nil? && manifest_case.dig("classification", "outcome") == "pending" &&
                 manifest_case.dig("classification", "reason") == "wlo_attempt_unstarted"
            raise Error, "workload evidence manifest is missing its attempt observation"
          end
          return
        end
        expected_path = File.join("runs", job.fetch("job_id"), "metadata.json")
        bytes = embedded_bytes(snapshot, "WLO current attempt", expected_path)
        return validate_unparsed_attempt!(manifest_case, identity) if identity.nil?

        metadata = parse_json(bytes, "WLO current attempt")
        source = snapshot.fetch("source")
        valid = source["path"] == identity["evidence_path"] && source["sha256"] == identity["evidence_sha256"] &&
                metadata["job_id"] == job["job_id"] && metadata["attempt"] == identity["attempt"] &&
                metadata["status"] == identity["status"] && metadata["exit_status"] == identity["exit_status"]
        raise Error, "workload evidence manifest attempt identity mismatch" unless valid
        validate_retained_attempts!(snapshot, identity, job)
        validate_attempt_classification!(manifest_case, metadata, wlo_execution)
      end

      def validate_attempt_classification!(manifest_case, metadata, execution)
        classification = manifest_case.fetch("classification")
        job_id = manifest_case.fetch("case_id")
        retry_attempt = execution.fetch("retry_pending", {})[job_id]
        expected = if retry_attempt
                     if retry_attempt == metadata["attempt"] && %w[failed interrupted].include?(metadata["status"])
                       ["pending", "wlo_retry_authorized", "pending"]
                     end
                   else
                     case metadata["status"]
                     when "complete"
                       [classification["outcome"], classification["reason"], "complete"] if
                         %w[evidenced unsafe].include?(classification["outcome"])
                     when "failed" then ["failed", "wlo_attempt_failed", "failed"]
                     when "interrupted" then ["interrupted", "wlo_attempt_interrupted", "interrupted"]
                     when "running" then ["running", "wlo_attempt_running", "running"]
                     end
                   end
        actual = classification.values_at("outcome", "reason", "execution_status")
        raise Error, "workload evidence manifest attempt classification mismatch" unless expected == actual
      end

      def validate_unparsed_attempt!(manifest_case, identity)
        return if identity.nil? && manifest_case.dig("classification", "outcome") == "unsafe" &&
                  manifest_case.dig("classification", "reason").to_s.include?("attempt")

        raise Error, "workload evidence manifest has unaccounted attempt bytes"
      end

      def validate_retained_attempts!(snapshot, identity, job)
        expected = Array(identity["superseded_attempts"])
        retained = snapshot.fetch("retained_superseded_attempts")
        raise Error, "workload evidence manifest superseded-attempt count mismatch" unless retained.length == expected.length
        expected.zip(retained).each do |attempt, embedded|
          bytes = embedded_bytes(embedded, "WLO superseded attempt")
          metadata = parse_json(bytes, "WLO superseded attempt")
          source = embedded.fetch("source")
          valid = source["path"] == attempt["evidence_path"] && source["sha256"] == attempt["evidence_sha256"] &&
                  metadata["job_id"] == job["job_id"] && metadata["attempt"] == attempt["attempt"] &&
                  metadata["status"] == attempt["status"]
          raise Error, "workload evidence manifest superseded-attempt identity mismatch" unless valid
        end
      end

      def validate_receipt!(workload, snapshot, manifest_case, row)
        classification = manifest_case.fetch("classification")
        receipt_ref = manifest_case["receipt"]
        if classification.fetch("evidence_status") == "unresolved"
          raise Error, "unresolved workload case cannot carry a receipt" unless receipt_ref.nil?

          return
        end
        raise Error, "evidenced workload case is missing a receipt" unless receipt_ref.is_a?(Hash)
        bytes = read_afw_reference(receipt_ref.fetch("reference"), "AFW scoring evidence receipt")
        receipt = parse_json(bytes, "AFW scoring evidence receipt")
        supplied = receipt.fetch("receipt_id")
        body = receipt.reject { |key, _value| key == "receipt_id" }
        expected_id = sha256(canonical_json(body))
        attempt = manifest_case.dig("execution", "authoritative_attempt")
        receipt_attempt = receipt.fetch("attempt")
        receipt_workload = receipt.fetch("workload")
        receipt_intent = receipt.fetch("scoring_intent")
        provenance = receipt.fetch("scorer_provenance")
        valid = receipt_ref["contract_version"] == RECEIPT_CONTRACT &&
                receipt_ref["semantic_status"] == RECEIPT_STATUS && receipt_ref["receipt_id"] == supplied &&
                supplied == expected_id && receipt["contract_version"] == RECEIPT_CONTRACT &&
                receipt["semantic_status"] == RECEIPT_STATUS &&
                valid_receipt_workload?(receipt_workload, workload, manifest_case) &&
                valid_receipt_intent?(receipt_intent, manifest_case, row) &&
                valid_receipt_attempt?(receipt_attempt, attempt, manifest_case) &&
                valid_receipt_provenance?(provenance, snapshot, row)
        raise Error, "workload evidence manifest receipt identity mismatch" unless valid
        expected_candidates = manifest_case["dimension"] == "Levels" ? 2 : 1
        unless receipt_ref["review_candidate_count"] == expected_candidates
          raise Error, "workload evidence manifest receipt candidate count mismatch"
        end
      end

      def valid_receipt_workload?(receipt, workload, manifest_case)
        receipt["plan_id"] == workload["plan_id"] && receipt["job_id"] == manifest_case["case_id"] &&
          receipt["pool_id"] == manifest_case.dig("job", "pool_id") &&
          receipt["plan_sha256"] == workload.dig("afw", "execution_plan", "sha256") &&
          receipt["snapshot_sha256"] == workload.dig("afw", "snapshot", "sha256") &&
          receipt["case_index_sha256"] == workload.dig("afw", "case_index", "sha256")
      end

      def valid_receipt_intent?(receipt, manifest_case, row)
        receipt["case_id"] == manifest_case["case_id"] &&
          receipt["adventure_id"] == manifest_case["adventure_id"] &&
          receipt["dimension"] == manifest_case["dimension"] && receipt["profile"] == row["profile"] &&
          receipt["model_alias"] == row["model_alias"] && receipt["ollama_model"] == row["ollama_model"] &&
          receipt["case_sha256"] == manifest_case.dig("intent", "case", "sha256")
      end

      def valid_receipt_attempt?(receipt, attempt, manifest_case)
        receipt["job_id"] == manifest_case["case_id"] && receipt["attempt"] == attempt["attempt"] &&
          receipt["status"] == "complete" && receipt["exit_status"] == 0 &&
          receipt["evidence_path"] == attempt["evidence_path"] &&
          receipt["evidence_sha256"] == attempt["evidence_sha256"] &&
          Array(receipt["superseded_attempts"]) == Array(attempt["superseded_attempts"])
      end

      def valid_receipt_provenance?(receipt, snapshot, row)
        receipt["scorer_commit"] == snapshot["scorer_commit"] &&
          receipt["qualified_model_digest"] == row["qualified_model_digest"] &&
          receipt["qualification_sha256"] == row["qualification_sha256"] &&
          receipt["runtime_sha256"] == row["runtime_sha256"] &&
          receipt["preflight_sha256"] == row["preflight_sha256"]
      end

      def validate_summary!(summary, cases)
        intended = cases.length
        evidence_counts = tally(cases) { |row| row.dig("classification", "evidence_status") }
        execution_counts = tally(cases) { |row| row.dig("classification", "execution_status") }
        receipts = cases.filter_map { |row| row["receipt"] }
        expected = {
          "intended_cases" => intended,
          "classified_cases" => intended,
          "accounting_complete" => intended.positive?,
          "execution_counts" => execution_counts,
          "evidence_counts" => evidence_counts,
          "receipt_count" => receipts.length,
          "review_candidate_count" => receipts.sum { |receipt| receipt.fetch("review_candidate_count") },
          "evidence_complete" => intended.positive? && evidence_counts.fetch("ready", 0) == intended
        }
        raise Error, "workload evidence manifest summary is internally inconsistent" unless summary == expected
      end

      def read_afw_reference(reference, label)
        unless reference.is_a?(Hash) && reference["root"] == "afw" && reference["sha256"].to_s.match?(HEX_SHA256)
          raise Error, "#{label} reference is invalid"
        end
        path = safe_afw_path(reference.fetch("path"), label)
        bytes = File.binread(path)
        raise Error, "#{label} digest mismatch" unless sha256(bytes) == reference["sha256"]

        bytes
      rescue Errno::ENOENT => e
        raise Error, "missing #{label}: #{e.message}"
      end

      def embedded_bytes(snapshot, label, expected_path = nil)
        unless snapshot.is_a?(Hash) && snapshot["encoding"] == "hex" &&
               source_reference?(snapshot["source"], expected_path)
          raise Error, "#{label} embedded snapshot is invalid"
        end
        content = snapshot.fetch("content")
        raise Error, "#{label} embedded snapshot is malformed" unless content.match?(/\A(?:[0-9a-f]{2})*\z/)

        bytes = [content].pack("H*")
        raise Error, "#{label} embedded digest mismatch" unless sha256(bytes) == snapshot.dig("source", "sha256")

        bytes
      end

      def source_reference?(reference, expected_path = nil)
        path = reference.is_a?(Hash) ? reference["path"].to_s : ""
        clean = !path.empty? && !Pathname.new(path).absolute? && Pathname.new(path).cleanpath.to_s == path &&
                !path.split(File::SEPARATOR).include?("..")
        reference.is_a?(Hash) && reference["root"] == "wlo" && clean &&
          reference["sha256"].to_s.match?(HEX_SHA256) &&
          (!expected_path || reference["path"] == expected_path)
      end

      def parse_index(bytes)
        table = CSV.parse(bytes, headers: true)
        missing = INDEX_IDENTITY_FIELDS - Array(table.headers)
        raise Error, "AFW case index is missing #{missing.join(', ')}" unless missing.empty?

        table.map(&:to_h)
      rescue CSV::MalformedCSVError => e
        raise Error, "malformed AFW case index: #{e.message}"
      end

      def safe_afw_path(path, label)
        expanded = File.expand_path(path, @afw_root)
        prefix = "#{@afw_root}#{File::SEPARATOR}"
        raise Error, "#{label} escapes AFW root" unless expanded.start_with?(prefix)

        expanded
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

      def tally(rows, &)
        rows.map(&).tally.sort.to_h
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
end
