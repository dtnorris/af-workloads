# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "rbconfig"

class AfwBuildWorkloadCliTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def setup
    @dir = Dir.mktmpdir("afw-build-cli-test")
    @capture = File.join(@dir, "options.json")
    @preload = File.join(@dir, "compiler-fixture.rb")
    File.write(@preload, <<~RUBY)
      require #{File.join(ROOT, "lib/af_workloads").dump}
      require "json"
      class << AFWorkloads::WorkloadCompiler
        def new(**options)
          File.write(ENV.fetch("AFW_CLI_CAPTURE"), JSON.generate(options))
          Object.new.tap { |compiler| compiler.define_singleton_method(:build) { "fixture-workload" } }
        end
      end
    RUBY
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_dynamic_cli_forwards_capabilities_and_does_not_request_static_profile
    output, error, status = run_cli("--wlo-plan-version", "0.3", "--required-context-length", "131072",
                                    "--require-fully-gpu-resident", "--required-gpu-id", "NVIDIA A40")
    assert status.success?, error
    options = JSON.parse(File.read(@capture))
    assert_equal File.realpath(@dir), options.fetch("data_root")
    assert_equal "0.3", options.fetch("plan_version")
    assert_equal 131_072, options.fetch("required_context_length")
    assert_equal true, options.fetch("require_fully_gpu_resident")
    assert_equal "NVIDIA A40", options.fetch("required_gpu_id")
    assert_nil options.fetch("worker_name")
    assert_includes output, "one execution with WLO's dynamic worker registry"
    refute_includes output, "--execution-profile"
    refute_includes output, "--workers-config"
  end

  def test_default_cli_uses_dynamic_handoff_without_static_guidance
    output, error, status = run_cli
    assert status.success?, error
    assert_nil JSON.parse(File.read(@capture)).fetch("plan_version")
    assert_includes output, "one execution with WLO's dynamic worker registry"
    refute_includes output, "--execution-profile"
    refute_includes output, "--workers-config"
  end

  def test_explicit_v02_cli_retains_legacy_profile_guidance
    output, error, status = run_cli("--wlo-plan-version", "0.2")
    assert status.success?, error
    assert_equal "0.2", JSON.parse(File.read(@capture)).fetch("plan_version")
    assert_includes output, "--execution-profile"
    assert_includes output, "--workers-config"
  end

  def test_cli_rejects_unsupported_version_before_compiler_call
    _output, error, status = run_cli("--wlo-plan-version", "0.5")
    refute status.success?
    assert_includes error, "invalid argument: --wlo-plan-version 0.5"
    refute_path_exists @capture
  end

  # The public CLI forwards explicit minimum opt-in; returns captured options
  # without compiling or invoking a scorer. Unexpected CLI failure fails the test.
  def test_cli_forwards_v04_minimum_without_an_exact_context
    output, error, status = run_cli("--wlo-plan-version", "0.4", "--minimum-context-length", "131072",
                                    "--require-fully-gpu-resident")
    assert status.success?, error
    options = JSON.parse(File.read(@capture))
    assert_equal "0.4", options.fetch("plan_version")
    assert_equal 131_072, options.fetch("minimum_context_length")
    assert_nil options.fetch("required_context_length")
    refute_includes output, "--execution-profile"
  end

  def test_cli_forwards_complete_explicit_staged_authority_configuration
    output, error, status = run_cli(
      "--staged-authority-inputs", "/evidence/inputs.json",
      "--staged-authority-store", "/evidence/authority",
      "--staged-project-state", "/catalog/PROJECT_STATE.yml",
      "--staged-operation", "11111111-1111-4111-8111-111111111111",
      "--staged-pipeline-root", "/components/af-data-pipeline"
    )

    assert status.success?, error
    staged = JSON.parse(File.read(@capture)).fetch("staged_scoring")
    assert_equal "/components/af-data-pipeline", staged.fetch("pipeline_root")
    assert_equal "/evidence/inputs.json", staged.fetch("inputs_path")
    assert_equal "/evidence/authority", staged.fetch("store_root")
    assert_equal "/catalog/PROJECT_STATE.yml", staged.fetch("project_state_path")
    assert_equal "11111111-1111-4111-8111-111111111111", staged.fetch("operation_id")
    assert_equal "production", staged.fetch("mode")
    assert_includes output, "PREPARED"
  end

  def test_cli_refuses_partial_staged_mode
    _output, error, status = run_cli("--staged-authority-inputs", "/evidence/inputs.json")

    refute status.success?
    assert_includes error, "staged mode also requires"
    refute_path_exists @capture
  end

  private

  def run_cli(*args)
    Open3.capture3({ "AFW_CLI_CAPTURE" => @capture }, RbConfig.ruby, "-r", @preload,
                  File.join(ROOT, "bin/afw-build-workload"), "--data-root", @dir, "--workload", "cli-fixture",
                  "--catalog", "catalog.xlsx", "--ids", "ADV-0943", *args, chdir: ROOT)
  end
end
