# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/workload_scoring_evidence_fixture"
require "af_workloads"

class WorkloadScoringEvidenceTest < Minitest::Test
  SCALAR_JOB = "batch-adv0001-combat"
  LEVELS_JOB = "batch-adv0002-levels"

  def setup
    @root = Dir.mktmpdir("afw-workload-scoring-evidence-test")
    @fixture = WorkloadScoringEvidenceFixture.new(root: @root, cases: default_cases)
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def test_all_success_scalar_and_levels_cases_bind_exact_receipts
    result = binder.bind

    assert result.fetch("fully_evidenced")
    assert_equal({ "evidenced" => 2 }, result.fetch("counts"))
    assert_equal %w[receipt_created receipt_created], result.fetch("cases").map { |row| row.fetch("reason") }
    assert_equal ["Combat Emphasis", "Levels"], result.fetch("cases").map { |row| row.fetch("dimension") }
    assert_path_exists @fixture.receipt_path(SCALAR_JOB)
    assert_path_exists @fixture.receipt_path(LEVELS_JOB)
    levels = JSON.parse(File.read(@fixture.receipt_path(LEVELS_JOB)))
    assert_equal "Levels", levels.dig("scoring_intent", "dimension")
    assert_equal "provenance_validated_proposed_scoring_evidence", levels.fetch("semantic_status")
  end

  def test_identical_replay_reuses_byte_identical_receipts
    first = binder.bind
    before = default_cases.to_h { |spec| [spec.fetch(:job_id), File.binread(@fixture.receipt_path(spec.fetch(:job_id)))] }

    second = binder.bind

    assert first.fetch("fully_evidenced")
    assert second.fetch("fully_evidenced")
    assert_equal %w[receipt_reused receipt_reused], second.fetch("cases").map { |row| row.fetch("reason") }
    before.each { |job_id, bytes| assert_equal bytes, File.binread(@fixture.receipt_path(job_id)) }
  end

  def test_mixed_success_and_failure_is_explicitly_partial
    @fixture.write_metadata(LEVELS_JOB, "status" => "failed", "exit_status" => 7)

    result = binder.bind

    refute result.fetch("fully_evidenced")
    assert_equal({ "evidenced" => 1, "failed" => 1 }, result.fetch("counts"))
    assert_equal "receipt_created", case_result(result, SCALAR_JOB).fetch("reason")
    failed = case_result(result, LEVELS_JOB)
    assert_equal "wlo_attempt_failed", failed.fetch("reason")
    assert_equal 1, failed.dig("authoritative_attempt", "attempt")
    refute_path_exists @fixture.receipt_path(LEVELS_JOB)
  end

  def test_interrupted_running_and_unstarted_cases_are_distinct
    fixture = replace_fixture([
      case_spec("interrupted", "ADV-0001", "Combat Emphasis"),
      case_spec("running", "ADV-0002", "Combat Emphasis"),
      case_spec("unstarted", "ADV-0003", "Combat Emphasis")
    ])
    fixture.write_metadata("interrupted", "status" => "interrupted", "exit_status" => 130)
    running = JSON.parse(File.read(fixture.metadata_path("running")))
    running["status"] = "running"
    running.delete("exit_status")
    running.delete("completed_at")
    File.write(fixture.metadata_path("running"), JSON.pretty_generate(running))
    fixture.remove_metadata("unstarted")

    result = binder.bind

    refute result.fetch("fully_evidenced")
    assert_equal({ "interrupted" => 1, "pending" => 1, "running" => 1 }, result.fetch("counts"))
    assert_equal "wlo_attempt_interrupted", case_result(result, "interrupted").fetch("reason")
    assert_equal "wlo_attempt_running", case_result(result, "running").fetch("reason")
    assert_equal "wlo_attempt_unstarted", case_result(result, "unstarted").fetch("reason")
    result.fetch("cases").each { |row| refute_path_exists @fixture.receipt_path(row.fetch("case_id")) }
  end

  def test_authorized_retry_is_pending_and_retains_current_attempt_identity
    @fixture.write_archived_attempt(SCALAR_JOB, 1)
    @fixture.write_metadata(SCALAR_JOB, "status" => "failed", "attempt" => 1, "exit_status" => 1)
    @fixture.write_execution("status" => "pending", "retry_pending" => { SCALAR_JOB => 1 })

    result = binder.bind
    row = case_result(result, SCALAR_JOB)

    assert_equal "pending", row.fetch("outcome")
    assert_equal "wlo_retry_authorized", row.fetch("reason")
    assert_equal 1, row.dig("authoritative_attempt", "attempt")
    refute_path_exists @fixture.receipt_path(SCALAR_JOB)
  end

  def test_successful_retry_binds_current_attempt_and_superseded_history
    @fixture.write_archived_attempt(SCALAR_JOB, 1)
    @fixture.write_metadata(SCALAR_JOB, "attempt" => 2)

    result = binder.bind
    row = case_result(result, SCALAR_JOB)

    assert_equal "evidenced", row.fetch("outcome")
    assert_equal 2, row.dig("authoritative_attempt", "attempt")
    assert_equal [1], row.dig("authoritative_attempt", "superseded_attempts").map { |attempt| attempt.fetch("attempt") }
    assert_equal "failed", row.dig("authoritative_attempt", "superseded_attempts", 0, "status")
  end

  def test_existing_receipt_for_prior_attempt_is_never_rebound
    first = binder.bind
    assert first.fetch("fully_evidenced")
    bytes = File.binread(@fixture.receipt_path(SCALAR_JOB))
    @fixture.write_archived_attempt(SCALAR_JOB, 1)
    @fixture.write_metadata(SCALAR_JOB, "attempt" => 2)

    second = binder.bind
    row = case_result(second, SCALAR_JOB)

    refute second.fetch("fully_evidenced")
    assert_equal "unsafe", row.fetch("outcome")
    assert_equal "receipt_conflict", row.fetch("reason")
    assert_equal bytes, File.binread(@fixture.receipt_path(SCALAR_JOB))
  end

  def test_missing_scoring_artifact_is_unsafe_and_has_no_receipt
    FileUtils.rm_f(@fixture.assessment_path(SCALAR_JOB))

    result = binder.bind
    row = case_result(result, SCALAR_JOB)

    assert_equal "unsafe", row.fetch("outcome")
    assert_equal "missing_scoring_evidence", row.fetch("reason")
    refute_path_exists @fixture.receipt_path(SCALAR_JOB)
  end

  def test_duplicate_evidence_sets_are_unsafe_and_have_no_receipt
    @fixture.add_evidence_set(SCALAR_JOB, "20261004T120130Z_duplicate")

    result = binder.bind
    row = case_result(result, SCALAR_JOB)

    assert_equal "unsafe", row.fetch("outcome")
    assert_equal "ambiguous_scoring_evidence", row.fetch("reason")
    refute_path_exists @fixture.receipt_path(SCALAR_JOB)
  end

  def test_malformed_attempt_state_is_distinct_and_has_no_receipt
    File.write(@fixture.metadata_path(SCALAR_JOB), "not json")

    result = binder.bind
    row = case_result(result, SCALAR_JOB)

    assert_equal "unsafe", row.fetch("outcome")
    assert_equal "attempt_state_malformed", row.fetch("reason")
    refute_path_exists @fixture.receipt_path(SCALAR_JOB)
  end

  def test_malformed_assessment_is_distinct_and_has_no_receipt
    File.write(@fixture.assessment_path(SCALAR_JOB), "run_id,status\nfixture,PROPOSED\n")

    result = binder.bind
    row = case_result(result, SCALAR_JOB)

    assert_equal "unsafe", row.fetch("outcome")
    assert_equal "malformed_scoring_evidence", row.fetch("reason")
    assert_equal 1, row.dig("authoritative_attempt", "attempt")
    refute_path_exists @fixture.receipt_path(SCALAR_JOB)
  end

  def test_incomplete_levels_metrics_are_unsafe
    @fixture.rewrite_metrics(LEVELS_JOB, ["Level Start"])

    result = binder.bind

    assert_equal "invalid_scoring_evidence", case_result(result, LEVELS_JOB).fetch("reason")
    refute_path_exists @fixture.receipt_path(LEVELS_JOB)
  end

  def test_scalar_extra_metric_is_unsafe
    @fixture.rewrite_metrics(SCALAR_JOB, ["Combat Emphasis", "Level Start"])

    result = binder.bind

    assert_equal "invalid_scoring_evidence", case_result(result, SCALAR_JOB).fetch("reason")
    refute_path_exists @fixture.receipt_path(SCALAR_JOB)
  end

  def test_changed_qualification_provenance_is_unsafe
    data = YAML.safe_load_file(@fixture.case_path(SCALAR_JOB))
    data["qualified_model_digest"] = "c" * 64
    File.write(@fixture.case_path(SCALAR_JOB), YAML.dump(data))

    result = binder.bind

    assert_equal "invalid_scoring_evidence", case_result(result, SCALAR_JOB).fetch("reason")
    refute_path_exists @fixture.receipt_path(SCALAR_JOB)
  end

  def test_profile_model_runtime_and_scorer_provenance_remain_required
    mutations = {
      "profile" => ->(data) { data["profile"] = "different" },
      "model" => ->(data) { data["ollama_model"] = "different-model" },
      "runtime" => lambda do |data|
        File.open(File.join(@root, data.fetch("runtime_path")), "a") { |file| file.write("changed\n") }
      end,
      "scorer" => ->(data) { data["scorer_commit"] = "c" * 40 }
    }

    mutations.each do |label, mutation|
      replace_fixture(default_cases)
      data = YAML.safe_load_file(@fixture.case_path(SCALAR_JOB))
      mutation.call(data)
      File.write(@fixture.case_path(SCALAR_JOB), YAML.dump(data)) unless label == "runtime"

      row = case_result(binder.bind, SCALAR_JOB)
      assert_equal "invalid_scoring_evidence", row.fetch("reason"), label
      refute_path_exists @fixture.receipt_path(SCALAR_JOB), label
    end
  end

  def test_prompt_schema_and_source_provenance_remain_required
    %w[prompt_sha256 schema_sha256].each do |field|
      replace_fixture(default_cases)
      request_path = @fixture.request_path(SCALAR_JOB)
      request = JSON.parse(File.read(request_path))
      request[field] = "f" * 64
      File.write(request_path, JSON.pretty_generate(request))

      row = case_result(binder.bind, SCALAR_JOB)
      assert_equal "invalid_scoring_evidence", row.fetch("reason"), field
      refute_path_exists @fixture.receipt_path(SCALAR_JOB), field
    end

    replace_fixture(default_cases)
    assessment = CSV.read(@fixture.assessment_path(SCALAR_JOB), headers: true)
    assessment[0]["source_file"] = "/different/source.md"
    CSV.open(@fixture.assessment_path(SCALAR_JOB), "w") do |csv|
      csv << assessment.headers
      assessment.each { |row| csv << row.fields }
    end
    row = case_result(binder.bind, SCALAR_JOB)
    assert_equal "invalid_scoring_evidence", row.fetch("reason"), "source"
    refute_path_exists @fixture.receipt_path(SCALAR_JOB), "source"
  end

  def test_changed_bound_artifact_bytes_are_rejected_before_receipt_write
    original = AFWorkloads::ScoringEvidence.method(:new)
    factory = lambda do |**arguments|
      subject = original.call(**arguments)
      response = @fixture.response_path(arguments.fetch(:job_id))
      subject.define_singleton_method(:write) do |receipt = nil|
        File.open(response, "a") { |file| file.write(" ") }
        super(receipt)
      end
      subject
    end

    result = AFWorkloads::ScoringEvidence.stub(:new, factory) { binder.bind }

    assert_equal "evidence_changed_during_binding", case_result(result, SCALAR_JOB).fetch("reason")
    refute_path_exists @fixture.receipt_path(SCALAR_JOB)
    refute result.fetch("fully_evidenced")
  end

  def test_mismatched_wlo_plan_aborts_before_any_receipt
    wlo_plan = File.join(@fixture.wlo, "plan.json")
    File.open(wlo_plan, "a") { |file| file.write(" ") }

    error = assert_raises(AFWorkloads::Error) { binder.bind }

    assert_includes error.message, "WLO frozen plan differs"
    default_cases.each { |spec| refute_path_exists @fixture.receipt_path(spec.fetch(:job_id)) }
  end

  def test_ambiguous_case_and_job_identity_aborts_before_any_receipt
    path = File.join(@root, "workloads", @fixture.workload_id, "case_index.csv")
    rows = CSV.read(path, headers: true)
    CSV.open(path, "a") { |csv| csv << rows.first.fields }

    error = assert_raises(AFWorkloads::Error) { binder.bind }

    assert_includes error.message, "case IDs are ambiguous"
    default_cases.each { |spec| refute_path_exists @fixture.receipt_path(spec.fetch(:job_id)) }
  end

  private

  def default_cases
    [
      case_spec(SCALAR_JOB, "ADV-0001", "Combat Emphasis"),
      case_spec(LEVELS_JOB, "ADV-0002", "Levels", metrics: ["Level End", "Level Start"])
    ]
  end

  def case_spec(job_id, adventure_id, dimension, metrics: nil)
    { job_id: job_id, adventure_id: adventure_id, dimension: dimension, metrics: metrics || [dimension] }
  end

  def replace_fixture(cases)
    FileUtils.rm_rf(@root)
    FileUtils.mkdir_p(@root)
    @fixture = WorkloadScoringEvidenceFixture.new(root: @root, cases: cases)
  end

  def binder
    AFWorkloads::WorkloadScoringEvidence.new(
      root: @root, workload_id: @fixture.workload_id, wlo_output: @fixture.wlo
    )
  end

  def case_result(result, job_id)
    result.fetch("cases").find { |row| row.fetch("case_id") == job_id }
  end
end
