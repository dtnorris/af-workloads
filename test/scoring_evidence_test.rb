# frozen_string_literal: true

require_relative "test_helper"
require "csv"
require "digest"
require "json"
require "time"
require "yaml"
require "af_workloads"

class ScoringEvidenceTest < Minitest::Test
  HEAD = "b" * 40
  JOB_ID = "batch-adv0001-combat"
  WORKLOAD_ID = "batch"
  ADVENTURE_ID = "ADV-0001"
  DIMENSION = "Combat Emphasis"
  MODEL = "qwen-test"
  STARTED_AT = "2026-10-04T12:00:00Z"
  RECORDED_AT = "2026-10-04T12:01:00Z"
  COMPLETED_AT = "2026-10-04T12:02:00Z"
  ASSESSMENT_HEADERS = %w[
    run_id status review_disposition adventure_id adventure_title source_book book_publisher
    start_page end_page afao_version assessment_spec_version provider model source_file source_scope
    group metric_kind metric assessment_state value range_low range_high confidence path_sensitive
    path_variation_affects_anchor rationale adjacent_lower_reason adjacent_higher_reason evidence
    metric_review_flags package_review_flags
  ].freeze

  def setup
    @root = Dir.mktmpdir("afw-scoring-evidence-test")
    @wlo = File.join(@root, "wlo-output")
    @run_id = "20261004T120100Z_deadbeef"
    build_fixture
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def test_valid_current_attempt_and_artifacts_produce_proposed_evidence_receipt
    receipt = interpreter.interpret

    assert_equal "afw-scoring-evidence-receipt/v0.1", receipt.fetch("contract_version")
    assert_equal "provenance_validated_proposed_scoring_evidence", receipt.fetch("semantic_status")
    assert_equal 2, receipt.dig("attempt", "attempt")
    assert_equal JOB_ID, receipt.dig("attempt", "job_id")
    assert_equal @run_id, receipt.dig("artifacts", "run_id")
    assert_match(/\A[0-9a-f]{64}\z/, receipt.fetch("receipt_id"))
    refute_match(/accepted|approved|published|canonical|amc-applied/i, JSON.generate(receipt))
  end

  def test_valid_levels_assessment_requires_exactly_one_start_and_end_row
    configure_assessment(dimension: "Levels", metrics: ["Level End", "Level Start"])

    receipt = interpreter.interpret

    assert_equal "Levels", receipt.dig("scoring_intent", "dimension")
    assert_equal @run_id, receipt.dig("artifacts", "run_id")
  end

  def test_levels_assessment_without_level_start_is_rejected
    configure_assessment(dimension: "Levels", metrics: ["Level End"])

    assert_rejected(/provenance/)
  end

  def test_levels_assessment_without_level_end_is_rejected
    configure_assessment(dimension: "Levels", metrics: ["Level Start"])

    assert_rejected(/provenance/)
  end

  def test_levels_assessment_with_duplicate_level_start_is_rejected
    configure_assessment(dimension: "Levels", metrics: ["Level Start", "Level Start", "Level End"])

    assert_rejected(/provenance/)
  end

  def test_levels_assessment_with_duplicate_level_end_is_rejected
    configure_assessment(dimension: "Levels", metrics: ["Level Start", "Level End", "Level End"])

    assert_rejected(/provenance/)
  end

  def test_levels_assessment_with_unexpected_third_metric_is_rejected
    configure_assessment(
      dimension: "Levels",
      metrics: ["Level Start", "Level End", "Combat Emphasis"]
    )

    assert_rejected(/provenance/)
  end

  def test_scalar_assessment_rejects_an_extra_metric
    configure_assessment(dimension: DIMENSION, metrics: [DIMENSION, "Level Start"])

    assert_rejected(/provenance/)
  end

  def test_command_success_without_proposed_assessment_is_rejected
    FileUtils.mv(@assessment_path, "#{@assessment_path}.missing")
    assert_rejected(/no complete AFSU evidence set/)
  end

  def test_command_success_without_request_evidence_is_rejected
    FileUtils.mv(@request_path, "#{@request_path}.missing")
    assert_rejected(/no complete AFSU evidence set/)
  end

  def test_command_success_without_response_evidence_is_rejected
    FileUtils.mv(@response_path, "#{@response_path}.missing")
    assert_rejected(/no complete AFSU evidence set/)
  end

  def test_malformed_proposed_assessment_is_rejected
    File.write(@assessment_path, "run_id,status\n#{@run_id},PROPOSED\n")
    assert_rejected(/malformed proposed assessment/)
  end

  def test_wrong_plan_identity_is_rejected
    snapshot = YAML.safe_load_file(@snapshot_path)
    snapshot["execution_plan_sha256"] = "0" * 64
    File.write(@snapshot_path, YAML.dump(snapshot))
    assert_rejected(/snapshot does not bind/)
  end

  def test_job_absent_from_plan_is_rejected
    assert_raises(AFWorkloads::Error) do
      AFWorkloads::ScoringEvidence.new(
        root: @root, workload_id: WORKLOAD_ID, wlo_output: @wlo, job_id: "missing-job"
      ).interpret
    end
  end

  def test_scoring_evidence_for_different_wlo_job_is_rejected
    metadata = JSON.parse(File.read(@metadata_path))
    metadata["job_id"] = "different-job"
    File.write(@metadata_path, JSON.pretty_generate(metadata))
    assert_rejected(/not an authoritative terminal success/)
  end

  def test_superseded_attempt_evidence_cannot_be_selected_and_attempt_two_is_bound
    write_archived_attempt(1, status: "failed")
    request = JSON.parse(File.read(@request_path))
    request["recorded_at"] = "2026-10-04T11:01:00Z"
    File.write(@request_path, JSON.pretty_generate(request))

    assert_rejected(/no complete AFSU evidence set/)

    request["recorded_at"] = RECORDED_AT
    File.write(@request_path, JSON.pretty_generate(request))
    receipt = interpreter.interpret
    assert_equal 2, receipt.dig("attempt", "attempt")
    assert_equal [1], receipt.dig("attempt", "superseded_attempts").map { |row| row.fetch("attempt") }
    assert_equal "failed", receipt.dig("attempt", "superseded_attempts", 0, "status")
  end

  def test_current_attempt_change_after_selection_is_rejected_before_write
    subject = interpreter
    receipt = subject.interpret
    metadata = JSON.parse(File.read(@metadata_path))
    metadata["attempt"] = 3
    File.write(@metadata_path, JSON.pretty_generate(metadata))

    error = assert_raises(AFWorkloads::Error) { subject.write(receipt) }
    assert_includes error.message, "changed after selection"
    refute_path_exists subject.receipt_path
  end

  def test_adventure_identity_mismatch_is_rejected
    rows = CSV.read(@assessment_path, headers: true)
    rows[0]["adventure_id"] = "ADV-9999"
    write_csv(@assessment_path, rows.headers, rows.map(&:fields))
    assert_rejected(/no complete AFSU evidence set|provenance/)
  end

  def test_scorer_config_and_source_provenance_mismatches_are_rejected
    original_case = File.binread(@case_path)
    original_assessment = File.binread(@assessment_path)

    data = YAML.safe_load(original_case)
    data["scorer_commit"] = "c" * 40
    File.write(@case_path, YAML.dump(data))
    assert_rejected(/scorer_commit/)

    File.binwrite(@case_path, original_case)
    rows = CSV.parse(original_assessment, headers: true)
    rows[0]["model"] = "wrong-model"
    write_csv(@assessment_path, rows.headers, rows.map(&:fields))
    assert_rejected(/provenance/)

    File.binwrite(@assessment_path, original_assessment)
    rows = CSV.parse(original_assessment, headers: true)
    rows[0]["source_file"] = "/wrong/source.md"
    write_csv(@assessment_path, rows.headers, rows.map(&:fields))
    assert_rejected(/provenance/)
  end

  def test_modified_evidence_bytes_after_discovery_are_detected
    subject = interpreter
    receipt = subject.interpret
    File.open(@response_path, "a") { |file| file.write(" ") }

    error = assert_raises(AFWorkloads::Error) { subject.write(receipt) }
    assert_includes error.message, "changed after selection"
  end

  def test_failed_wlo_attempt_with_present_outputs_is_not_valid_evidence
    metadata = JSON.parse(File.read(@metadata_path))
    metadata["status"] = "failed"
    metadata["exit_status"] = 1
    File.write(@metadata_path, JSON.pretty_generate(metadata))
    assert_rejected(/not an authoritative terminal success/)
  end

  def test_identical_interpretation_and_write_are_deterministic_and_idempotent
    first = interpreter
    receipt_one = first.interpret
    receipt_two = interpreter.interpret
    assert_equal receipt_one, receipt_two

    path = first.write(receipt_one)
    bytes = File.binread(path)
    assert_equal path, interpreter.write
    assert_equal bytes, File.binread(path)
  end

  def test_malformed_response_is_rejected
    File.write(@response_path, "not json")
    assert_rejected(/malformed raw response/)
  end

  private

  def interpreter
    AFWorkloads::ScoringEvidence.new(
      root: @root, workload_id: WORKLOAD_ID, wlo_output: @wlo, job_id: JOB_ID
    )
  end

  def assert_rejected(pattern)
    error = assert_raises(AFWorkloads::Error) { interpreter.interpret }
    assert_match pattern, error.message
  end

  def configure_assessment(dimension:, metrics:)
    preflight = JSON.parse(File.read(@preflight_path))
    preflight.fetch("run_metadata")["selected_dimension"] = dimension
    File.write(@preflight_path, JSON.pretty_generate(preflight))

    case_data = YAML.safe_load_file(@case_path)
    case_data["dimension"] = dimension
    case_data["preflight_sha256"] = digest(@preflight_path)
    File.write(@case_path, YAML.dump(case_data))

    index = CSV.read(@case_index_path, headers: true)
    index[0]["dimension"] = dimension
    index[0]["preflight_sha256"] = digest(@preflight_path)
    write_csv(@case_index_path, index.headers, index.map(&:fields))

    assessment = CSV.read(@assessment_path, headers: true)
    template = assessment[0].to_h
    rows = metrics.map { |metric| assessment.headers.map { |header| template.merge("metric" => metric)[header] } }
    write_csv(@assessment_path, assessment.headers, rows)
  end

  def build_fixture
    %w[workloads/batch build/workloads/batch/cases build/workloads/batch/runtime
       build/workloads/batch/preflight input output/workloads/batch/results/batch-adv0001-combat/assessments
       wlo-output/runs/batch-adv0001-combat].each do |path|
      FileUtils.mkdir_p(File.join(@root, path))
    end
    @plan_path = File.join(@root, "workloads/batch/execution-plan.json")
    @snapshot_path = File.join(@root, "workloads/batch/snapshot.yml")
    @case_index_path = File.join(@root, "workloads/batch/case_index.csv")
    @case_path = File.join(@root, "build/workloads/batch/cases/#{JOB_ID}.yml")
    @preflight_path = File.join(@root, "build/workloads/batch/preflight/#{JOB_ID}.json")
    @runtime_path = File.join(@root, "build/workloads/batch/runtime/#{JOB_ID}.yml")
    @catalog_path = File.join(@root, "input/catalog.xlsx")
    @qualification_path = File.join(@root, "input/qualification.yml")
    @metadata_path = File.join(@wlo, "runs", JOB_ID, "metadata.json")
    @source_file = File.join(@root, "input/source.md")
    @output = File.join(@root, "output/workloads/batch/results", JOB_ID)

    File.write(@catalog_path, "catalog\n")
    File.write(@qualification_path, "qualification\n")
    File.write(@runtime_path, "--- {}\n")
    File.write(@source_file, "source\n")

    preflight = {
      "adventure_id" => ADVENTURE_ID,
      "run_metadata" => {
        "run_id" => "preflight", "adventure_id" => ADVENTURE_ID,
        "selected_dimension" => DIMENSION, "provider" => "ollama", "model" => MODEL,
        "source_file" => @source_file, "source_scope" => "bounded",
        "afao_version" => "1.6.1", "assessment_spec_version" => "0.1"
      },
      "targets" => [{
        "artifact_name" => "dimension_combat_emphasis",
        "prompt_sha256" => "1" * 64, "schema_sha256" => "2" * 64
      }]
    }
    File.write(@preflight_path, JSON.pretty_generate(preflight))

    case_data = {
      "contract_version" => "afw-workload/v0.1", "workload_id" => WORKLOAD_ID,
      "case_id" => JOB_ID, "adventure_id" => ADVENTURE_ID, "dimension" => DIMENSION,
      "profile" => "production", "model_alias" => "qwen", "ollama_model" => MODEL,
      "qualified_model_digest" => "a" * 64,
      "catalog_path" => relative(@catalog_path), "catalog_sha256" => digest(@catalog_path),
      "qualification_path" => relative(@qualification_path), "qualification_sha256" => digest(@qualification_path),
      "runtime_path" => relative(@runtime_path), "runtime_sha256" => digest(@runtime_path),
      "preflight_path" => relative(@preflight_path), "preflight_sha256" => digest(@preflight_path),
      "scorer_repo" => "../af-cli-scoring-utility", "scorer_commit" => HEAD,
      "output_path" => relative(@output), "environment" => { "AF_LLM_PROVIDER" => "ollama" }
    }
    File.write(@case_path, YAML.dump(case_data))

    plan = {
      "contract_version" => "wlo-execution-plan/v0.3", "plan_id" => WORKLOAD_ID,
      "failure_policy" => { "max_consecutive_failures" => 2, "max_total_failures" => 3 },
      "pools" => [{ "pool_id" => "qwen", "requirements" => { "ollama" => { "model" => MODEL } } }],
      "jobs" => [{ "job_id" => JOB_ID, "pool_id" => "qwen", "group_id" => ADVENTURE_ID,
                    "argv" => ["bin/afw-score-job", relative(@case_path)], "env" => case_data.fetch("environment"),
                    "depends_on_job_ids" => [] }]
    }
    plan_bytes = JSON.pretty_generate(plan) + "\n"
    File.write(@plan_path, plan_bytes)
    FileUtils.mkdir_p(@wlo)
    File.write(File.join(@wlo, "plan.json"), plan_bytes)
    File.write(@snapshot_path, YAML.dump(
      "contract_version" => "afw-workload/v0.1", "workload_id" => WORKLOAD_ID,
      "scorer_commit" => HEAD, "execution_plan_sha256" => Digest::SHA256.hexdigest(plan_bytes)
    ))
    write_csv(@case_index_path,
              %w[case_id adventure_id dimension profile model_alias ollama_model qualified_model_digest
                 qualification_sha256 runtime_sha256 preflight_sha256 case_path],
              [[JOB_ID, ADVENTURE_ID, DIMENSION, "production", "qwen", MODEL, "a" * 64,
                digest(@qualification_path), digest(@runtime_path), digest(@preflight_path), relative(@case_path)]])

    File.write(@metadata_path, JSON.pretty_generate(
      "job_id" => JOB_ID, "pool_id" => "qwen", "worker" => "worker-1", "status" => "complete",
      "attempt" => 2, "started_at" => STARTED_AT, "completed_at" => COMPLETED_AT,
      "elapsed_seconds" => 120.0, "exit_status" => 0,
      "argv" => ["bin/afw-score-job", relative(@case_path)], "environment_keys" => ["AF_LLM_PROVIDER"],
      "worker_execution_identity" => "worker-exec-1", "worker_registry_binding" => { "revision" => 1 }
    ))
    build_scoring_artifacts
  end

  def build_scoring_artifacts
    @assessment_path = File.join(@output, "assessments", "#{ADVENTURE_ID}_#{@run_id}.csv")
    values = {
      "run_id" => @run_id, "status" => "PROPOSED", "review_disposition" => "REVIEW_REQUIRED",
      "adventure_id" => ADVENTURE_ID, "adventure_title" => "Fixture", "source_book" => "Book",
      "book_publisher" => "Publisher", "start_page" => "1", "end_page" => "2",
      "afao_version" => "1.6.1", "assessment_spec_version" => "0.1", "provider" => "ollama",
      "model" => MODEL, "source_file" => @source_file, "source_scope" => "bounded",
      "group" => "combat", "metric_kind" => "integer", "metric" => DIMENSION,
      "assessment_state" => "scored", "value" => "3", "confidence" => "0.9", "evidence" => "[]"
    }
    write_csv(@assessment_path, ASSESSMENT_HEADERS, [ASSESSMENT_HEADERS.map { |name| values[name] }])

    raw_dir = File.join(@output, "raw", ADVENTURE_ID, @run_id)
    FileUtils.mkdir_p(raw_dir)
    @request_path = File.join(raw_dir, "dimension_combat_emphasis_request.json")
    @response_path = File.join(raw_dir, "dimension_combat_emphasis.json")
    provider_request = {
      "provider" => "ollama", "transport" => { "kind" => "http_post" },
      "payload" => { "model" => MODEL, "messages" => [] }
    }
    request = {
      "record_type" => "provider_request", "recorded_at" => RECORDED_AT,
      "recorded_before_inference" => true, "prompt_sha256" => "1" * 64, "schema_sha256" => "2" * 64,
      "request_sha256" => Digest::SHA256.hexdigest(JSON.generate(provider_request)), "request" => provider_request
    }
    File.write(@request_path, JSON.pretty_generate(request))
    File.write(@response_path, JSON.pretty_generate("choices" => [{ "message" => { "content" => "{}" } }]))
  end

  def write_archived_attempt(number, status:)
    path = File.join(@wlo, "attempts", JOB_ID, "attempt-#{number}", "metadata.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(
      "job_id" => JOB_ID, "attempt" => number, "status" => status, "exit_status" => 1
    ))
  end

  def write_csv(path, headers, rows)
    CSV.open(path, "w") do |csv|
      csv << headers
      rows.each { |row| csv << row }
    end
  end

  def digest(path)
    Digest::SHA256.file(path).hexdigest
  end

  def relative(path)
    Pathname.new(path).relative_path_from(Pathname.new(@root)).to_s
  end
end
