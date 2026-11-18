# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/workload_scoring_evidence_fixture"
require "af_workloads"

class WorkloadEvidenceManifestTest < Minitest::Test
  SCALAR_JOB = "batch-adv0001-combat"
  LEVELS_JOB = "batch-adv0002-levels"

  def setup
    @root = Dir.mktmpdir("afw-workload-evidence-manifest-test")
    @fixture = WorkloadScoringEvidenceFixture.new(root: @root, cases: default_cases)
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def test_all_success_freezes_denominator_receipts_and_levels_candidates
    publication = producer.publish
    document = validate(publication.path)

    assert publication.evidence_complete
    assert_equal 2, publication.intended_cases
    assert_equal 2, publication.receipt_count
    assert_equal 3, publication.candidate_count
    assert_equal({ "complete" => 2 }, document.dig("summary", "execution_counts"))
    assert_equal({ "ready" => 2 }, document.dig("summary", "evidence_counts"))
    assert document.dig("summary", "accounting_complete")
    assert document.dig("summary", "evidence_complete")
    assert_equal [1, 2], document.fetch("cases").map { |row| row.dig("receipt", "review_candidate_count") }
  end

  def test_successful_subset_is_accounted_for_but_not_evidence_complete
    @fixture.write_metadata(LEVELS_JOB, "status" => "failed", "exit_status" => 7)

    document = validate(producer.publish.path)

    assert document.dig("summary", "accounting_complete")
    refute document.dig("summary", "evidence_complete")
    assert_equal 2, document.dig("summary", "intended_cases")
    assert_equal 1, document.dig("summary", "receipt_count")
    assert_equal({ "failed" => 1, "ready" => 1 }, combined_status_counts(document))
    failed = manifest_case(document, LEVELS_JOB)
    assert_equal "failed", failed.dig("classification", "outcome")
    assert_equal "wlo_attempt_failed", failed.dig("classification", "reason")
    assert_nil failed.fetch("receipt")
  end

  def test_all_unresolved_never_claims_scoring_completeness
    default_cases.each { |spec| @fixture.remove_metadata(spec.fetch(:job_id)) }

    document = validate(producer.publish.path)

    assert document.dig("summary", "accounting_complete")
    refute document.dig("summary", "evidence_complete")
    assert_equal 0, document.dig("summary", "receipt_count")
    assert_equal({ "pending" => 2 }, document.dig("summary", "execution_counts"))
    assert_equal({ "unresolved" => 2 }, document.dig("summary", "evidence_counts"))
  end

  def test_pending_running_interrupted_and_failed_cases_are_distinct
    replace_fixture([
      case_spec("pending", "ADV-0001", "Combat Emphasis"),
      case_spec("running", "ADV-0002", "Combat Emphasis"),
      case_spec("interrupted", "ADV-0003", "Combat Emphasis"),
      case_spec("failed", "ADV-0004", "Combat Emphasis")
    ])
    @fixture.remove_metadata("pending")
    running = JSON.parse(File.read(@fixture.metadata_path("running")))
    running.delete("exit_status")
    running.delete("completed_at")
    File.write(@fixture.metadata_path("running"), JSON.pretty_generate(running.merge("status" => "running")))
    @fixture.write_metadata("interrupted", "status" => "interrupted", "exit_status" => 130)
    @fixture.write_metadata("failed", "status" => "failed", "exit_status" => 1)

    document = validate(producer.publish.path)

    assert_equal({ "failed" => 1, "interrupted" => 1, "pending" => 1, "running" => 1 },
                 document.dig("summary", "execution_counts"))
    outcomes = document.fetch("cases").map { |row| row.dig("classification", "outcome") }
    assert_equal %w[pending running interrupted failed], outcomes
    assert_equal 0, document.dig("summary", "receipt_count")
  end

  def test_missing_and_ambiguous_scoring_evidence_are_unresolved_without_receipts
    FileUtils.rm_f(@fixture.assessment_path(SCALAR_JOB))
    @fixture.add_evidence_set(LEVELS_JOB, "20261004T120130Z_duplicate")

    document = validate(producer.publish.path)

    reasons = document.fetch("cases").map { |row| row.dig("classification", "reason") }
    assert_equal %w[missing_scoring_evidence ambiguous_scoring_evidence], reasons
    assert document.fetch("cases").all? { |row| row["receipt"].nil? }
    refute document.dig("summary", "evidence_complete")
  end

  def test_authorized_retry_and_superseded_attempt_history_are_preserved
    @fixture.write_archived_attempt(SCALAR_JOB, 1)
    @fixture.write_metadata(SCALAR_JOB, "status" => "failed", "attempt" => 1, "exit_status" => 1)
    @fixture.write_execution("status" => "pending", "retry_pending" => { SCALAR_JOB => 1 })

    pending = validate(producer.publish.path)
    scalar = manifest_case(pending, SCALAR_JOB)

    assert_equal "pending", scalar.dig("classification", "outcome")
    assert_equal "wlo_retry_authorized", scalar.dig("classification", "reason")
    assert_equal 1, scalar.dig("execution", "authoritative_attempt", "attempt")
    assert_empty scalar.dig("execution", "current_attempt", "retained_superseded_attempts")

    replace_fixture(default_cases)
    @fixture.write_archived_attempt(SCALAR_JOB, 1)
    @fixture.write_metadata(SCALAR_JOB, "attempt" => 2)
    completed = validate(producer.publish.path)
    scalar = manifest_case(completed, SCALAR_JOB)
    assert_equal 2, scalar.dig("execution", "authoritative_attempt", "attempt")
    attempts = scalar.dig("execution", "authoritative_attempt", "superseded_attempts").map do |entry|
      entry.fetch("attempt")
    end
    assert_equal [1], attempts
  end

  def test_identical_replay_reuses_exact_manifest_bytes
    first = producer.publish
    bytes = File.binread(first.path)

    second = producer.publish

    assert second.reused
    assert_equal first.path, second.path
    assert_equal first.manifest_id, second.manifest_id
    assert_equal bytes, File.binread(second.path)
  end

  def test_changed_observation_creates_new_revision_and_old_revision_stays_valid
    first = producer.publish
    first_bytes = File.binread(first.path)
    @fixture.write_archived_attempt(SCALAR_JOB, 1)
    @fixture.write_metadata(SCALAR_JOB, "attempt" => 2)

    second = producer.publish

    refute_equal first.path, second.path
    refute second.evidence_complete
    assert_equal first_bytes, File.binread(first.path)
    assert_equal first.manifest_id, validate(first.path).fetch("manifest_id")
    assert_equal "receipt_conflict", manifest_case(validate(second.path), SCALAR_JOB).dig("classification", "reason")
  end

  def test_changes_during_construction_fail_closed_without_a_manifest
    subject = producer
    original = subject.method(:verify_unchanged!)
    execution_path = @fixture.execution_path
    subject.define_singleton_method(:verify_unchanged!) do
      File.open(execution_path, "a") { |file| file.write(" ") }
      original.call
    end

    error = assert_raises(AFWorkloads::Error) { subject.publish }

    assert_includes error.message, "changed during manifest construction"
    assert_empty Dir.glob(File.join(@root, "output", "workloads", "batch", "evidence", "manifests", "*.json"))
  end

  def test_validator_rejects_altered_plan_index_and_case_bytes
    publication = producer.publish
    references = JSON.parse(File.read(publication.path)).dig("workload", "afw")

    %w[execution_plan case_index].each do |name|
      path = File.join(@root, references.fetch(name).fetch("path"))
      File.open(path, "a") { |file| file.write(" ") }
      error = assert_raises(AFWorkloads::Error) { validate(publication.path) }
      assert_includes error.message, "digest mismatch", name
      replace_fixture(default_cases)
      publication = producer.publish
      references = JSON.parse(File.read(publication.path)).dig("workload", "afw")
    end

    case_path = File.join(@root, manifest_case(validate(publication.path), SCALAR_JOB).dig("intent", "case", "path"))
    File.open(case_path, "a") { |file| file.write(" ") }
    error = assert_raises(AFWorkloads::Error) { validate(publication.path) }
    assert_includes error.message, "digest mismatch"
  end

  def test_validator_rejects_missing_duplicate_extra_and_empty_denominators
    publication = producer.publish
    variants = {
      "missing" => ->(document) { document.fetch("cases").pop },
      "duplicate" => ->(document) { document.fetch("cases") << document.fetch("cases").first },
      "extra" => lambda do |document|
        extra = Marshal.load(Marshal.dump(document.fetch("cases").first))
        extra["case_id"] = "unexpected"
        document.fetch("cases") << extra
      end,
      "empty" => lambda do |document|
        document["cases"] = []
        document.dig("workload")["intended_case_count"] = 0
      end
    }

    variants.each do |name, mutation|
      path = tampered_manifest(publication.path, name, &mutation)
      error = assert_raises(AFWorkloads::Error) { validate(path) }
      assert_match(/denominator|case accounting|frozen workload identity/, error.message, name)
    end
  end

  def test_validator_rejects_altered_frozen_intent_and_internal_summary
    publication = producer.publish
    intent = tampered_manifest(publication.path, "intent") do |document|
      document.dig("cases", 0, "intent", "case_index_row")["dimension"] = "Different"
    end
    summary = tampered_manifest(publication.path, "summary") do |document|
      document.dig("summary")["receipt_count"] = 99
    end

    assert_includes assert_raises(AFWorkloads::Error) { validate(intent) }.message, "frozen intent mismatch"
    assert_includes assert_raises(AFWorkloads::Error) { validate(summary) }.message, "summary is internally inconsistent"
  end

  def test_validator_rejects_changed_receipt_bytes_and_receipt_id
    publication = producer.publish
    document = validate(publication.path)
    receipt_path = File.join(@root, manifest_case(document, SCALAR_JOB).dig("receipt", "reference", "path"))
    File.open(receipt_path, "a") { |file| file.write(" ") }
    assert_includes assert_raises(AFWorkloads::Error) { validate(publication.path) }.message, "digest mismatch"

    replace_fixture(default_cases)
    publication = producer.publish
    changed_id = tampered_manifest(publication.path, "receipt-id") do |manifest|
      manifest.dig("cases", 0, "receipt")["receipt_id"] = "0" * 64
    end
    assert_includes assert_raises(AFWorkloads::Error) { validate(changed_id) }.message, "receipt identity mismatch"
  end

  def test_validator_rejects_mismatched_execution_and_attempt_identity
    publication = producer.publish
    execution = tampered_manifest(publication.path, "execution") do |document|
      rewrite_embedded(document.dig("workload", "wlo", "execution")) { |value| value["plan_id"] = "different" }
    end
    attempt = tampered_manifest(publication.path, "attempt") do |document|
      document.dig("cases", 0, "execution", "authoritative_attempt")["attempt"] = 99
    end
    classification = tampered_manifest(publication.path, "classification") do |document|
      value = document.dig("cases", 0, "classification")
      value["outcome"] = "failed"
      value["reason"] = "wlo_attempt_failed"
      value["execution_status"] = "failed"
      value["evidence_status"] = "unresolved"
      document.dig("cases", 0)["receipt"] = nil
    end

    assert_includes assert_raises(AFWorkloads::Error) { validate(execution) }.message, "execution identity mismatch"
    assert_includes assert_raises(AFWorkloads::Error) { validate(attempt) }.message, "attempt identity mismatch"
    assert_includes assert_raises(AFWorkloads::Error) { validate(classification) }.message,
                    "attempt classification mismatch"
  end

  def test_validator_rejects_unknown_contract_and_path_escape
    publication = producer.publish
    contract = tampered_manifest(publication.path, "contract") do |document|
      document["contract_version"] = "afw-workload-evidence-manifest/v99"
    end
    escape = tampered_manifest(publication.path, "escape") do |document|
      document.dig("workload", "wlo", "plan")["path"] = "../plan.json"
    end

    assert_includes assert_raises(AFWorkloads::Error) { validate(contract) }.message, "unsupported"
    assert_includes assert_raises(AFWorkloads::Error) { validate(escape) }.message, "WLO plan identity mismatch"
  end

  private

  def default_cases
    [
      case_spec(SCALAR_JOB, "ADV-0001", "Combat Emphasis"),
      case_spec(LEVELS_JOB, "ADV-0002", "Levels", metrics: ["Level End", "Level Start"])
    ]
  end

  def case_spec(job_id, adventure_id, dimension, metrics: nil)
    { job_id:, adventure_id:, dimension:, metrics: metrics || [dimension] }
  end

  def replace_fixture(cases)
    FileUtils.rm_rf(@root)
    FileUtils.mkdir_p(@root)
    @fixture = WorkloadScoringEvidenceFixture.new(root: @root, cases:)
  end

  def producer
    AFWorkloads::WorkloadEvidenceManifest.new(
      root: @root, workload_id: @fixture.workload_id, wlo_output: @fixture.wlo
    )
  end

  def validate(path)
    AFWorkloads::WorkloadEvidenceManifest.validate!(manifest_path: path, afw_root: @root)
  end

  def manifest_case(document, job_id)
    document.fetch("cases").find { |row| row.fetch("case_id") == job_id }
  end

  def combined_status_counts(document)
    {
      "failed" => document.dig("summary", "execution_counts", "failed"),
      "ready" => document.dig("summary", "evidence_counts", "ready")
    }
  end

  def tampered_manifest(original, label)
    document = JSON.parse(File.read(original))
    yield document
    body = document.reject { |key, _value| key == "manifest_id" }
    document["manifest_id"] = Digest::SHA256.hexdigest(JSON.generate(canonical(body)))
    path = File.join(@root, "#{label}.json")
    File.write(path, JSON.pretty_generate(document) + "\n")
    path
  end

  def rewrite_embedded(embedded)
    value = JSON.parse([embedded.fetch("content")].pack("H*"))
    yield value
    bytes = JSON.pretty_generate(value)
    embedded["content"] = bytes.unpack1("H*")
    embedded.dig("source")["sha256"] = Digest::SHA256.hexdigest(bytes)
  end

  def canonical(value)
    case value
    when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
    when Array then value.map { |entry| canonical(entry) }
    else value
    end
  end
end
