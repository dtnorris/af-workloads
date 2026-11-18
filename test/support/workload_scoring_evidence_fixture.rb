# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "pathname"
require "yaml"

class WorkloadScoringEvidenceFixture
  HEAD = "b" * 40
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

  attr_reader :root, :wlo, :workload_id, :cases

  def initialize(root:, cases:)
    @root = root
    @workload_id = "batch"
    @wlo = File.join(root, "wlo-output")
    @cases = cases
    build
  end

  def metadata_path(job_id)
    File.join(wlo, "runs", job_id, "metadata.json")
  end

  def assessment_path(job_id, run_id: run_id(job_id))
    data = case_data(job_id)
    File.join(root, data.fetch("output_path"), "assessments", "#{data.fetch('adventure_id')}_#{run_id}.csv")
  end

  def request_path(job_id, run_id: run_id(job_id))
    data = case_data(job_id)
    artifact = preflight(job_id).fetch("targets").first.fetch("artifact_name")
    File.join(root, data.fetch("output_path"), "raw", data.fetch("adventure_id"), run_id, "#{artifact}_request.json")
  end

  def response_path(job_id, run_id: run_id(job_id))
    request_path(job_id, run_id: run_id).delete_suffix("_request.json") + ".json"
  end

  def case_path(job_id)
    File.join(root, "build", "workloads", workload_id, "cases", "#{job_id}.yml")
  end

  def preflight_path(job_id)
    File.join(root, "build", "workloads", workload_id, "preflight", "#{job_id}.json")
  end

  def execution_path
    File.join(wlo, "execution.json")
  end

  def plan_path
    File.join(root, "workloads", workload_id, "execution-plan.json")
  end

  def receipt_path(job_id)
    File.join(root, "output", "workloads", workload_id, "evidence", "#{job_id}.json")
  end

  def write_metadata(job_id, attributes)
    current = File.file?(metadata_path(job_id)) ? JSON.parse(File.read(metadata_path(job_id))) : {}
    FileUtils.mkdir_p(File.dirname(metadata_path(job_id)))
    File.write(metadata_path(job_id), JSON.pretty_generate(current.merge(attributes)))
  end

  def remove_metadata(job_id)
    FileUtils.rm_f(metadata_path(job_id))
  end

  def write_execution(attributes)
    current = JSON.parse(File.read(execution_path))
    File.write(execution_path, JSON.pretty_generate(current.merge(attributes)))
  end

  def write_archived_attempt(job_id, number, status: "failed")
    path = File.join(wlo, "attempts", job_id, "attempt-#{number}", "metadata.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate("job_id" => job_id, "attempt" => number, "status" => status))
  end

  def add_evidence_set(job_id, alternate_run_id)
    data = case_data(job_id)
    metrics = cases.find { |row| row.fetch(:job_id) == job_id }.fetch(:metrics)
    write_scoring_artifacts(data, metrics, alternate_run_id)
  end

  def rewrite_metrics(job_id, metrics)
    rows = CSV.read(assessment_path(job_id), headers: true)
    template = rows.first.to_h
    write_csv(
      assessment_path(job_id), rows.headers,
      metrics.map { |metric| rows.headers.map { |header| template.merge("metric" => metric)[header] } }
    )
  end

  private

  def build
    FileUtils.mkdir_p(File.join(root, "workloads", workload_id))
    FileUtils.mkdir_p(wlo)
    source = File.join(root, "input", "source.md")
    catalog = File.join(root, "input", "catalog.xlsx")
    qualification = File.join(root, "input", "qualification.yml")
    FileUtils.mkdir_p(File.dirname(source))
    File.write(source, "fixture source\n")
    File.write(catalog, "fixture catalog\n")
    File.write(qualification, "fixture qualification\n")

    rows = []
    jobs = []
    cases.each do |spec|
      row, job = build_case(spec, source, catalog, qualification)
      rows << row
      jobs << job
    end
    plan = {
      "contract_version" => "wlo-execution-plan/v0.3", "plan_id" => workload_id,
      "failure_policy" => { "max_consecutive_failures" => 2, "max_total_failures" => 3 },
      "pools" => [{ "pool_id" => "qwen", "requirements" => { "ollama" => { "model" => MODEL } } }],
      "jobs" => jobs
    }
    plan_bytes = JSON.pretty_generate(plan) + "\n"
    File.write(plan_path, plan_bytes)
    File.write(File.join(wlo, "plan.json"), plan_bytes)
    File.write(File.join(root, "workloads", workload_id, "snapshot.yml"), YAML.dump(
      "contract_version" => "afw-workload/v0.1", "workload_id" => workload_id,
      "scorer_commit" => HEAD, "execution_plan_sha256" => Digest::SHA256.hexdigest(plan_bytes)
    ))
    write_csv(
      File.join(root, "workloads", workload_id, "case_index.csv"),
      %w[case_id adventure_id dimension profile model_alias ollama_model qualified_model_digest
         qualification_sha256 runtime_sha256 preflight_sha256 case_path],
      rows
    )
    File.write(execution_path, JSON.pretty_generate(
      "contract_version" => "wlo-execution-state/v0.1", "plan_id" => workload_id,
      "plan_sha256" => Digest::SHA256.hexdigest(plan_bytes), "status" => "completed"
    ))
  end

  def build_case(spec, source, catalog, qualification)
    job_id = spec.fetch(:job_id)
    adventure_id = spec.fetch(:adventure_id)
    dimension = spec.fetch(:dimension)
    runtime = File.join(root, "build", "workloads", workload_id, "runtime", "#{job_id}.yml")
    preflight_path = self.preflight_path(job_id)
    output = File.join(root, "output", "workloads", workload_id, "results", job_id)
    [runtime, preflight_path, output, metadata_path(job_id), case_path(job_id)].each do |path|
      FileUtils.mkdir_p(File.dirname(path))
    end
    File.write(runtime, "--- {}\n")
    artifact = "dimension_#{dimension.downcase.gsub(/[^a-z]+/, '_').sub(/_\z/, '')}"
    preflight = {
      "adventure_id" => adventure_id,
      "run_metadata" => {
        "run_id" => "preflight", "adventure_id" => adventure_id, "selected_dimension" => dimension,
        "provider" => "ollama", "model" => MODEL, "source_file" => source, "source_scope" => "bounded",
        "afao_version" => "1.6.1", "assessment_spec_version" => "0.1"
      },
      "targets" => [{ "artifact_name" => artifact, "prompt_sha256" => "1" * 64, "schema_sha256" => "2" * 64 }]
    }
    File.write(preflight_path, JSON.pretty_generate(preflight))
    data = {
      "contract_version" => "afw-workload/v0.1", "workload_id" => workload_id,
      "case_id" => job_id, "adventure_id" => adventure_id, "dimension" => dimension,
      "profile" => "production", "model_alias" => "qwen", "ollama_model" => MODEL,
      "qualified_model_digest" => "a" * 64,
      "catalog_path" => relative(catalog), "catalog_sha256" => digest(catalog),
      "qualification_path" => relative(qualification), "qualification_sha256" => digest(qualification),
      "runtime_path" => relative(runtime), "runtime_sha256" => digest(runtime),
      "preflight_path" => relative(preflight_path), "preflight_sha256" => digest(preflight_path),
      "scorer_repo" => "../af-cli-scoring-utility", "scorer_commit" => HEAD,
      "output_path" => relative(output), "environment" => { "AF_LLM_PROVIDER" => "ollama" }
    }
    File.write(case_path(job_id), YAML.dump(data))
    write_metadata(job_id, successful_metadata(job_id, data))
    write_scoring_artifacts(data, spec.fetch(:metrics), run_id(job_id))
    row = [
      job_id, adventure_id, dimension, "production", "qwen", MODEL, "a" * 64,
      digest(qualification), digest(runtime), digest(preflight_path), relative(case_path(job_id))
    ]
    job = {
      "job_id" => job_id, "pool_id" => "qwen", "group_id" => adventure_id,
      "argv" => ["bin/afw-score-job", relative(case_path(job_id))],
      "env" => data.fetch("environment"), "depends_on_job_ids" => []
    }
    [row, job]
  end

  def successful_metadata(job_id, data)
    {
      "job_id" => job_id, "pool_id" => "qwen", "worker" => "worker-1", "status" => "complete",
      "attempt" => 1, "started_at" => STARTED_AT, "completed_at" => COMPLETED_AT,
      "elapsed_seconds" => 120.0, "exit_status" => 0,
      "argv" => ["bin/afw-score-job", relative(case_path(job_id))], "environment_keys" => ["AF_LLM_PROVIDER"],
      "worker_execution_identity" => "worker-exec-#{job_id}", "worker_registry_binding" => { "revision" => 1 }
    }
  end

  def write_scoring_artifacts(data, metrics, selected_run_id)
    assessment = File.join(
      root, data.fetch("output_path"), "assessments", "#{data.fetch('adventure_id')}_#{selected_run_id}.csv"
    )
    values = {
      "run_id" => selected_run_id, "status" => "PROPOSED", "review_disposition" => "REVIEW_REQUIRED",
      "adventure_id" => data.fetch("adventure_id"), "adventure_title" => "Fixture",
      "source_book" => "Fixture", "book_publisher" => "Fixture", "start_page" => "1", "end_page" => "2",
      "afao_version" => "1.6.1", "assessment_spec_version" => "0.1", "provider" => "ollama",
      "model" => MODEL, "source_file" => preflight(data.fetch("case_id")).dig("run_metadata", "source_file"),
      "source_scope" => "bounded", "group" => "fixture", "metric_kind" => "integer",
      "assessment_state" => "scored", "value" => "3", "confidence" => "0.9", "evidence" => "[]"
    }
    write_csv(
      assessment, ASSESSMENT_HEADERS,
      metrics.map { |metric| ASSESSMENT_HEADERS.map { |name| values.merge("metric" => metric)[name] } }
    )
    artifact = preflight(data.fetch("case_id")).fetch("targets").first.fetch("artifact_name")
    raw_dir = File.join(root, data.fetch("output_path"), "raw", data.fetch("adventure_id"), selected_run_id)
    FileUtils.mkdir_p(raw_dir)
    provider_request = {
      "provider" => "ollama", "transport" => { "kind" => "http_post" },
      "payload" => { "model" => MODEL, "messages" => [] }
    }
    request = {
      "record_type" => "provider_request", "recorded_at" => RECORDED_AT,
      "recorded_before_inference" => true, "prompt_sha256" => "1" * 64, "schema_sha256" => "2" * 64,
      "request_sha256" => Digest::SHA256.hexdigest(JSON.generate(provider_request)), "request" => provider_request
    }
    File.write(File.join(raw_dir, "#{artifact}_request.json"), JSON.pretty_generate(request))
    File.write(
      File.join(raw_dir, "#{artifact}.json"),
      JSON.pretty_generate("choices" => [{ "message" => { "content" => "{}" } }])
    )
  end

  def case_data(job_id)
    YAML.safe_load_file(case_path(job_id))
  end

  def preflight(job_id)
    JSON.parse(File.read(preflight_path(job_id)))
  end

  def run_id(job_id)
    "20261004T120100Z_#{Digest::SHA256.hexdigest(job_id)[0, 8]}"
  end

  def write_csv(path, headers, rows)
    FileUtils.mkdir_p(File.dirname(path))
    CSV.open(path, "w") do |csv|
      csv << headers
      rows.each { |row| csv << row }
    end
  end

  def digest(path)
    Digest::SHA256.file(path).hexdigest
  end

  def relative(path)
    Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
  end
end
