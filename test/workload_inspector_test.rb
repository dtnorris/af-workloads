# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "stringio"
require "yaml"
require "af_workloads"

class WorkloadInspectorTest < Minitest::Test
  FakeBatch = Struct.new(:root, :adventure_id) do
    def interpretation(_catalog)
      {
        "adventure_order" => [adventure_id],
        "selected_adventures" => [{"id" => adventure_id, "title" => "Synthetic fixture", "needs_levels" => false}],
        "dimension_contracts" => [{
          "name" => "Combat Emphasis", "slug" => "combat", "profile" => "production-base",
          "model_alias" => "qwen", "ollama_model" => "qwen-fixture",
          "qualification_path" => "qualification/fixture.yml", "runtime_key" => "base"
        }],
        "levels_contract" => {
          "name" => "Levels", "slug" => "levels", "profile" => "levels-v2.1",
          "model_alias" => "qwen", "ollama_model" => "qwen-fixture",
          "qualification_path" => "qualification/fixture.yml", "runtime_key" => "base"
        }
      }
    end

    def scorer_check! = "b" * 40
    def runtime_payloads = {"base" => {"source" => {"allow_full_source_fallback" => false}}}
  end

  def setup
    @root = Dir.mktmpdir("afw-inspector")
    @workload = "inspection-fixture"
    @catalog = File.join(@root, "catalog.xlsx")
    FileUtils.mkdir_p(File.join(@root, "config"))
    FileUtils.mkdir_p(File.join(@root, "qualification"))
    FileUtils.mkdir_p(File.join(@root, "scorer", "bin"))
    File.write(@catalog, "synthetic catalog")
    File.write(File.join(@root, "qualification", "fixture.yml"), "qualified\n")
    File.write(File.join(@root, "config", "models.yml"), YAML.dump("models" => {
      "qwen" => {"ollama_model" => "qwen-fixture", "qualified_manifest_sha256" => "a" * 64}
    }))
    scorer = File.join(@root, "scorer", "bin", "af-score")
    File.write(scorer, "#!/bin/sh\n")
    FileUtils.chmod(0o755, scorer)
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def test_distinguishes_fresh_reuse_and_verified_regeneration_without_mutation
    fresh = inspect_with(validator)
    assert_equal ["fresh-build", "NO_WORKLOAD"], fresh.values_at("action", "reason_code")

    compiler.build
    prepared = lifecycle_bytes
    first = inspect_with(validator)
    second = inspect_with(validator)
    assert_equal ["reuse", "VERIFIED_REUSE"], first.values_at("action", "reason_code")
    assert_equal first, second
    assert_equal prepared, lifecycle_bytes

    FileUtils.rm_rf(generated_path)
    before = lifecycle_bytes
    regenerated = inspect_with(validator)
    assert_equal ["regenerate", "VERIFIED_REGENERATION"], regenerated.values_at("action", "reason_code")
    refute File.exist?(generated_path)
    assert_equal before, lifecycle_bytes

    compiler.build
    assert_equal prepared, lifecycle_bytes
  end

  def test_valid_results_are_reported_without_claiming_completed_scoring
    compiler.build
    case_id = JSON.parse(File.read(File.join(manifest_path, "execution-plan.json"))).dig("jobs", 0, "job_id")
    result = File.join(output_path, "results", case_id, "assessments")
    FileUtils.mkdir_p(result)
    File.write(File.join(result, "proposed.csv"), "synthetic\n")
    before = lifecycle_bytes

    inspection = inspect_with(validator)

    assert_equal "reuse", inspection.fetch("action")
    assert_equal "present", inspection.dig("observed", "results", "state")
    assert_equal false, inspection.dig("observed", "results", "completion_claimed")
    assert_equal [case_id], inspection.dig("observed", "results", "case_ids")
    assert_equal before, lifecycle_bytes
  end

  def test_preserves_legacy_explicit_catalog_static_worker_mode
    compiler(worker: "fixture-worker", plan_version: nil).build

    inspection = inspect_with(validator(worker: "fixture-worker", plan_version: nil))

    assert_equal ["reuse", "VERIFIED_REUSE"], inspection.values_at("action", "reason_code")
  end

  def test_orphan_partial_and_conflicting_publications_refuse
    FileUtils.mkdir_p(generated_path)
    assert_refusal("ORPHANED_ARTIFACTS")
    FileUtils.rm_rf(generated_path)

    FileUtils.mkdir_p(manifest_path)
    File.write(File.join(manifest_path, "snapshot.yml"), "--- {}\n")
    assert_refusal("MANIFEST_INCOMPLETE")
    FileUtils.rm_rf(manifest_path)

    compiler.build
    FileUtils.rm_rf(File.join(generated_path, "runtime"))
    assert_refusal("GENERATED_PARTIAL")
  end

  def test_changed_catalog_generated_bytes_and_immutable_provenance_refuse
    compiler.build
    File.write(@catalog, "changed catalog")
    assert_refusal("VERIFICATION_FAILED", validator)

    File.write(@catalog, "synthetic catalog")
    runtime = Dir[File.join(generated_path, "runtime", "*.yml")].fetch(0)
    File.open(runtime, "a") { |file| file.write("changed\n") }
    assert_refusal("VERIFICATION_FAILED", validator)

    FileUtils.rm_rf(generated_path)
    changed_head = validator(generator_commit: "d" * 40)
    assert_refusal("VERIFICATION_FAILED", changed_head)
  end

  def test_unknown_or_detached_results_refuse_without_cleanup
    compiler.build
    FileUtils.mkdir_p(File.join(output_path, "results", "unknown-case"))
    before = lifecycle_bytes
    assert_refusal("RESULTS_CONFLICT", validator)
    assert_equal before, lifecycle_bytes

    FileUtils.rm_rf(generated_path)
    FileUtils.rm_rf(output_path)
    FileUtils.mkdir_p(File.join(output_path, "results"))
    assert_refusal("RESULTS_WITHOUT_BUILD", validator)
  end

  private

  def compiler(generator_commit: "c" * 40, worker: nil, plan_version: "0.2")
    AFWorkloads::WorkloadCompiler.new(
      root: @root, workload_id: @workload, catalog_path: @catalog, ids: ["ADV-0001"],
      scorer_repo: File.join(@root, "scorer"), worker_name: worker, plan_version:,
      batch_factory: -> { FakeBatch.new(@root, "ADV-0001") },
      preflight_runner: ->(destination:, **_args) { File.write(destination, JSON.generate("preflight" => "fixture")) },
      source_preparer: ->(adventure_id:, destination:, **_args) { File.write(destination, JSON.generate("source" => adventure_id)) },
      git_head_resolver: ->(_path) { generator_commit }, out: StringIO.new
    )
  end

  def validator(generator_commit: "c" * 40, worker: nil, plan_version: "0.2")
    AFWorkloads::FrozenWorkloadValidator.new(
      root: @root, workload_id: @workload, catalog_path: @catalog, ids: ["ADV-0001"],
      scorer_repo: File.join(@root, "scorer"), worker_name: worker, plan_version:,
      batch_factory: -> { FakeBatch.new(@root, "ADV-0001") },
      git_head_resolver: ->(_path) { generator_commit }
    )
  end

  def inspect_with(subject)
    AFWorkloads::WorkloadInspector.new(root: @root, workload_id: @workload, validator: subject).inspect
  end

  def assert_refusal(code, subject = validator)
    result = inspect_with(subject)
    assert_equal "refuse", result.fetch("action")
    assert_equal code, result.fetch("reason_code")
  end

  def lifecycle_bytes
    [manifest_path, generated_path, output_path].each_with_object({}) do |base, files|
      next unless File.exist?(base)
      Find.find(base) { |path| files[path.delete_prefix(@root)] = File.binread(path) if File.file?(path) }
    end
  end

  def manifest_path = File.join(@root, "workloads", @workload)
  def generated_path = File.join(@root, "build", "workloads", @workload)
  def output_path = File.join(@root, "output", "workloads", @workload)
end
