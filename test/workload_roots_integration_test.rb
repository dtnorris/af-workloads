# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "af_workloads"
require_relative "support/public_workload_fixture"

# Exercise the supported compiler and replay CLIs with real owner validators.
# Only mechanical inputs and an HTTP refusal guard are introduced by this test.
class WorkloadRootsIntegrationTest < Minitest::Test
  include PublicWorkloadFixture

  ROOT = File.expand_path("..", __dir__)
  PUBLIC_REVISION = "394a44c2c2052ce2eeb6d28cd7647ad8a50acfcf"

  # Select the real public distribution and allocate the isolated data root.
  def setup
    @code_root = ROOT
    prepare_workload_fixture
  end

  # Remove only the mechanical fixture.
  def teardown
    remove_workload_fixture
  end

  # Compile with ambient decoys, check exact bindings and run two fresh replays.
  # Missing/changed public bytes, source and registry refuse; restoration replays.
  # Admission must refuse before the scoring command or any HTTP request.
  def test_public_compile_frozen_bindings_uncached_replay_and_refusals
    contaminated = AFWorkloads::ScorerEnvironment::CONTROL_NAMES.to_h { |name| [name, "/missing/ambient-control"] }
    assert_success invoke("afw-build-workload", *arguments, "--scorer-config", @config, environment: contaminated)
    plan = JSON.parse(File.binread(File.join(@store, "workloads", @workload, "execution-plan.json")))
    assert_equal "wlo-execution-plan/v0.3", plan.fetch("contract_version")
    assert_equal [["bin/afw-score-job", "build/workloads/#{@workload}/cases/#{@workload}-adv0001-ee.yml"]], plan.fetch("jobs").map { |job| job.fetch("argv") }
    case_path = Dir[File.join(@store, "build/workloads", @workload, "cases/*.yml")].fetch(0)
    data = YAML.safe_load_file(case_path)
    assert_equal "ee-clean-reset-v0.5", data.fetch("profile")
    runtime = YAML.safe_load_file(File.join(@store, data.fetch("runtime_path")))
    assert_equal @selection.fetch("paths"), runtime.fetch("paths")
    assert_equal "registry.yml", runtime.dig("files", "source_registry")
    assert_equal @catalog, runtime.dig("files", "catalog")
    assert_equal AFWorkloads::FrozenInputIdentities::VERSION, runtime.fetch(AFWorkloads::FrozenInputIdentities::MARKER)
    identities = data.fetch("frozen_input_identities")
    assert_equal File.join(@scratch, "0.md"), identities.dig("source_file", "path")
    assert_equal File.join(@scratch, "registry.yml"), identities.dig("source_registry", "path")
    assert_equal File.join(@public, "AdventureFinder_Analysis_Ontology_AFAO_v1.6.1.md"), identities.dig("ontology", "path")
    assert_nil AFWorkloads::FrozenInputIdentities.verify!(identities)
    preflight = JSON.parse(File.binread(File.join(@store, data.fetch("preflight_path"))))
    assert_equal PUBLIC_REVISION, preflight.dig("run_metadata", "method", "revision")
    assert_equal AFWorkloads::FrozenInputIdentities.digest(identities), runtime.fetch(AFWorkloads::FrozenInputIdentities::DIGEST_FIELD)
    assert_inspection "reuse"
    first_replay = invoke("afw-score-job", "--verify-only", case_path, environment: contaminated)
    second_replay = invoke("afw-score-job", "--verify-only", case_path, environment: contaminated)
    assert_success first_replay
    assert_success second_replay
    assert_equal first_replay.first(2), second_replay.first(2)

    paths = Dir.glob("{workloads,build/workloads}/#{@workload}/**/*", base: @store)
    digests = paths.filter_map do |relative|
      path = File.join(@store, relative)
      [relative, Digest::SHA256.file(path).hexdigest] if File.file?(path)
    end.to_h
    FileUtils.rm_r(File.join(@store, "build/workloads", @workload))
    assert_success invoke("afw-build-workload", *arguments, "--scorer-config", @config)
    digests.each { |relative, digest| assert_equal digest, Digest::SHA256.file(File.join(@store, relative)).hexdigest }

    relative_case = case_path.delete_prefix("#{@store}/")
    decoy = File.join(@scratch, "decoy")
    FileUtils.cp_r(@store, decoy)
    environment = {"AFW_ROOT" => @store, "AF_AFW_ROOT" => @store, "AFW_DATA_ROOT" => @store}
    [[], ["--data-root", decoy], ["--data-root", File.join(@scratch, "missing")]].each do |root_options|
      _stdout, stderr, status = Open3.capture3(@environment.merge(environment), RbConfig.ruby,
        File.join(ROOT, "bin/afw-score-job"), *root_options, "--verify-only", relative_case, chdir: @store)
      refute status.success?, "wrong or implicit data root accepted"
      assert_match(/data root|--data-root/, stderr)
    end
    assert_success invoke("afw-score-job", "--verify-only", relative_case)
    files = %w[documents.json AdventureFinder_Analysis_Ontology_AFAO_v1.6.1.md AdventureFinder_Analysis_Data_Assessment_Specification_v0.1.md].map { |name| File.join(@public, name) }
    files.concat([@catalog, File.join(@scratch, "0.md"), File.join(@scratch, "registry.yml"),
      File.join(@store, data.fetch("runtime_path")), File.join(@store, data.fetch("preflight_path"))])
    files.each do |path|
      bytes = File.binread(path)
      File.unlink(path)
      refute invoke("afw-score-job", "--verify-only", case_path).last.success?, "missing input accepted: #{path}"
      File.binwrite(path, bytes + "\n")
      refute invoke("afw-score-job", "--verify-only", case_path).last.success?, "changed input accepted: #{path}"
      File.binwrite(path, bytes)
      assert_success invoke("afw-score-job", "--verify-only", case_path)
    end
    changed = Marshal.load(Marshal.dump(@selection))
    changed.fetch("paths")["xlsx_root"] = @public
    File.write(@config, YAML.dump(changed))
    assert_inspection "refuse"
    File.write(@config, YAML.dump(@selection))
    assert_inspection "reuse"
    # Replay uses the frozen runtime, not a mutable original selection file.
    File.unlink(@config)
    assert_success invoke("afw-score-job", "--verify-only", case_path)
    _stdout, stderr, status = invoke("afw-score-job", case_path, environment: {"WLO_WORKER_ENDPOINT" => "http://127.0.0.1:1"})
    refute status.success?
    assert_match(/public method execution requires separate qualification/, stderr)
  end

  # Shell roots cannot supply missing explicit configuration; invalid selections
  # and missing public files also refuse before any workload is published.
  def test_missing_or_invalid_selection_refuses_compilation
    ambient = {"AF_XLSX_ROOT" => @scratch, "AF_SPEC_ROOT" => @public, "AF_SOURCE_ROOT" => @scratch,
      "AF_SOURCE_REGISTRY" => File.join(@scratch, "registry.yml"), "AF_OUTPUT_DIR" => File.join(@store, "output")}
    _stdout, stderr, status = invoke("afw-build-workload", *arguments, environment: ambient)
    refute status.success?
    assert_match(/select --scorer-repo and --scorer-config explicitly/, stderr)
    invalid = [nil, [], {}, @selection.merge("llm" => {"provider" => "openai"}),
      @selection.merge("paths" => @selection.fetch("paths").reject { |key, _value| key == "source_root" }),
      @selection.merge("paths" => @selection.fetch("paths").merge("source_root" => "")),
      @selection.merge("files" => {"catalog" => "another.xlsx"})]
    invalid.each do |selection|
      File.write(@config, YAML.dump(selection))
      refute invoke("afw-build-workload", *arguments, "--scorer-config", @config).last.success?
    end
    File.write(@config, "paths: [\n")
    refute invoke("afw-build-workload", *arguments, "--scorer-config", @config).last.success?
    File.unlink(@config)
    refute invoke("afw-build-workload", *arguments, "--scorer-config", @config).last.success?
    File.write(@config, YAML.dump(@selection))
    inventory = File.join(@public, "documents.json")
    inventory_bytes = File.binread(inventory)
    File.unlink(inventory)
    refute invoke("afw-build-workload", *arguments, "--scorer-config", @config).last.success?
    refute_path_exists File.join(@store, "workloads", @workload)
    File.binwrite(inventory, inventory_bytes + "\n")
    refute invoke("afw-build-workload", *arguments, "--scorer-config", @config).last.success?
    File.binwrite(inventory, inventory_bytes)
    assert_success invoke("afw-build-workload", *arguments, "--scorer-config", @config)
  end

  private

  # Report actual child failure details, keeping successful output quiet.
  def assert_success(result)
    stdout, stderr, status = result
    assert status.success?, "#{stdout}\n#{stderr}"
  end

  # Inspection reports eligibility in JSON even when the CLI itself succeeds.
  def assert_inspection(action)
    result = invoke("afw-inspect-workload", *arguments, "--scorer-config", @config)
    assert_success result
    report = JSON.parse(result.first)
    assert_equal action, report.fetch("action"), report.inspect
  end
end
