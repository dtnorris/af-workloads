# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "rbconfig"
require "stringio"
require "yaml"
require "af_workloads"

class AfwInspectWorkloadCliTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  FixtureBatch = Struct.new(:adventure_id) do
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
    @dir = Dir.mktmpdir("afw-inspect-cli")
    @capture = File.join(@dir, "capture.json")
    @preload = File.join(@dir, "inspection-fixture.rb")
    File.write(@preload, <<~RUBY)
      require #{File.join(ROOT, "lib/af_workloads").dump}
      require "json"
      class << AFWorkloads::FrozenWorkloadValidator
        def new(**options)
          File.write(ENV.fetch("AFW_INSPECT_CAPTURE"), JSON.generate(options))
          Object.new
        end
      end
      class << AFWorkloads::WorkloadInspector
        def new(**_options)
          result = JSON.parse(ENV.fetch("AFW_INSPECT_RESULT"))
          Object.new.tap { |value| value.define_singleton_method(:inspect) { result } }
        end
      end
    RUBY
    prepare_real_fixture
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_prints_every_supported_action_as_versioned_json
    %w[fresh-build reuse regenerate refuse].each do |action|
      expected = {"contract_version" => "afw-workload-inspection/v0.1", "workload_id" => "cli-fixture",
                  "action" => action, "reason_code" => "FIXTURE", "observed" => {}}
      output, error, status = run_cli(expected)
      assert status.success?, error
      assert_equal expected, JSON.parse(output)
    end
  end

  def test_forwards_portable_roots_and_staged_selection
    expected = {"contract_version" => "afw-workload-inspection/v0.1", "workload_id" => "cli-fixture",
                "action" => "fresh-build", "reason_code" => "NO_WORKLOAD", "observed" => {}}
    _output, error, status = run_cli(
      expected, "--staged-authority-inputs", "/input/authority.json", "--staged-authority-store", "/store",
      "--staged-project-state", "/front/PROJECT_STATE.yml", "--staged-operation", "operation-id",
      "--staged-selection", "/selection.json", "--staged-pipeline-root", "/components/pipeline"
    )
    assert status.success?, error
    options = JSON.parse(File.read(@capture))
    assert_equal ROOT, options.fetch("root")
    assert_equal File.realpath(@dir), options.fetch("data_root")
    assert_equal "/explicit/scorer", options.fetch("scorer_repo")
    assert_equal "/components/pipeline", options.dig("staged_scoring", "pipeline_root")
    assert_equal "/selection.json", options.dig("staged_scoring", "selection_path")
  end

  def test_fresh_process_cli_inspects_fresh_reuse_regeneration_and_interrupted_publication
    fresh = run_real_cli
    assert_equal ["fresh-build", "NO_WORKLOAD"], fresh.values_at("action", "reason_code")

    real_compiler.build
    reuse = run_real_cli
    assert_equal ["reuse", "VERIFIED_REUSE"], reuse.values_at("action", "reason_code")

    FileUtils.rm_rf(File.join(@data_root, "build", "workloads", "cli-fixture"))
    regenerate = run_real_cli
    assert_equal ["regenerate", "VERIFIED_REGENERATION"], regenerate.values_at("action", "reason_code")

    FileUtils.mkdir_p(File.join(@data_root, "build", "workloads", "cli-fixture", "cases"))
    refused = run_real_cli
    assert_equal ["refuse", "GENERATED_PARTIAL"], refused.values_at("action", "reason_code")
  end

  private

  def run_cli(result, *extra)
    environment = {
      "AFW_INSPECT_CAPTURE" => @capture, "AFW_INSPECT_RESULT" => JSON.generate(result),
      "AF_PROJECT_ROOT" => File.join(@dir, "components"), "AF_ADVENTURE_FINDER_ROOT" => File.join(@dir, "front")
    }
    Open3.capture3(
      environment, RbConfig.ruby, "-r", @preload, File.join(ROOT, "bin", "afw-inspect-workload"),
      "--data-root", @dir, "--scorer-repo", "/explicit/scorer", "--workload", "cli-fixture", "--catalog", "catalog.xlsx", "--ids", "ADV-0001", *extra, chdir: ROOT
    )
  end

  def prepare_real_fixture
    @real_root = File.join(@dir, "real-afw")
    @data_root = File.join(@dir, "real-data")
    FileUtils.mkdir_p(@data_root)
    @config = File.join(@dir, "scorer.yml")
    File.write(@config, YAML.dump("paths" => {"xlsx_root" => @dir, "source_root" => @dir,
      "specification_root" => @dir, "output_root" => File.join(@data_root, "output")}))
    FileUtils.mkdir_p(File.join(@real_root, "config"))
    FileUtils.mkdir_p(File.join(@real_root, "qualification"))
    FileUtils.mkdir_p(File.join(@real_root, "scorer", "bin"))
    File.write(File.join(@real_root, "catalog.xlsx"), "synthetic catalog")
    File.write(File.join(@real_root, "qualification", "fixture.yml"), "qualified\n")
    File.write(File.join(@real_root, "config", "models.yml"), YAML.dump("models" => {
      "qwen" => {"ollama_model" => "qwen-fixture", "qualified_manifest_sha256" => "a" * 64}
    }))
    executable = File.join(@real_root, "scorer", "bin", "af-score")
    File.write(executable, "#!/bin/sh\n")
    FileUtils.chmod(0o755, executable)
    @real_preload = File.join(@dir, "real-inspection-fixture.rb")
    File.write(@real_preload, <<~RUBY)
      require #{File.join(ROOT, "lib/af_workloads").dump}
      AFWorkloads::Roots.send(:remove_const, :CODE)
      AFWorkloads::Roots.const_set(:CODE, #{@real_root.dump})
      class CliInspectionFixtureBatch
        def interpretation(_catalog)
          {"adventure_order" => ["ADV-0001"],
           "selected_adventures" => [{"id" => "ADV-0001", "title" => "Synthetic fixture", "needs_levels" => false}],
           "dimension_contracts" => [{"name" => "Combat Emphasis", "slug" => "combat",
             "profile" => "production-base", "model_alias" => "qwen", "ollama_model" => "qwen-fixture",
             "qualification_path" => "qualification/fixture.yml", "runtime_key" => "base"}],
           "levels_contract" => {"name" => "Levels", "slug" => "levels", "profile" => "levels-v2.1",
             "model_alias" => "qwen", "ollama_model" => "qwen-fixture",
             "qualification_path" => "qualification/fixture.yml", "runtime_key" => "base"}}
        end
        def scorer_check! = "b" * 40
        def runtime_payloads = {"base" => {"source" => {"allow_full_source_fallback" => false}}}
      end
      class << AdventureIngest::Batch
        def new(**_options) = CliInspectionFixtureBatch.new
      end
      class AFWorkloads::FrozenWorkloadValidator
        private
        def git_head(_path) = "c" * 40
      end
    RUBY
  end

  def real_compiler
    AFWorkloads::WorkloadCompiler.new(
      root: @real_root, data_root: @data_root, scorer_config: @config, workload_id: "cli-fixture", catalog_path: File.join(@real_root, "catalog.xlsx"),
      ids: ["ADV-0001"], scorer_repo: File.join(@real_root, "scorer"), plan_version: "0.2",
      batch_factory: -> { FixtureBatch.new("ADV-0001") },
      preflight_runner: ->(destination:, **_args) { File.write(destination, JSON.generate("preflight" => "fixture")) },
      source_preparer: ->(adventure_id:, destination:, **_args) { File.write(destination, JSON.generate("source" => adventure_id)) },
      git_head_resolver: ->(_path) { "c" * 40 }, out: StringIO.new
    )
  end

  def run_real_cli
    output, error, status = Open3.capture3(
      RbConfig.ruby, "-r", @real_preload, File.join(ROOT, "bin", "afw-inspect-workload"),
      "--data-root", @data_root, "--scorer-config", @config, "--workload", "cli-fixture", "--catalog", File.join(@real_root, "catalog.xlsx"),
      "--ids", "ADV-0001", "--scorer-repo", File.join(@real_root, "scorer"), "--wlo-plan-version", "0.2",
      chdir: ROOT
    )
    assert status.success?, error
    JSON.parse(output)
  end
end
