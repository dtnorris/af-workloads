# frozen_string_literal: true

require_relative "test_helper"
require "digest"
require "json"
require "open3"
require "stringio"
require "yaml"
require "af_workloads"
require_relative "support/committed_scorer_fixture"

class AfwScoreJobTest < Minitest::Test
  def self.scorer_template
    @scorer_template ||= CommittedScorerFixture.build(files: {
      "bin/af-score" => <<~'RUBY',
        #!/usr/bin/env ruby
        require "json"
        args = ARGV.dup
        if (index = args.index("--render-preflight"))
          File.write(args.fetch(index + 1), JSON.pretty_generate("stable" => true))
          exit 0
        end
        names = ENV.keys.grep(/\AAF_/) + ["WLO_WORKER_ENDPOINT", "AFW_DW25_ORDINARY_MARKER"]
        File.write(File.expand_path("../scored", __dir__), JSON.generate(ENV.to_h.slice(*names.uniq)))
      RUBY
      "lib/af_scoring/fixture.rb" => "# fixture\n",
      "config/default.yml" => "--- {}\n"
    })
  end

  def setup
    @root = Dir.mktmpdir("afw-score-job-test")
    @scorer = File.join(@root, "scorer")
    template, @head = self.class.scorer_template
    FileUtils.cp_r(template, @scorer)

    File.write(File.join(@root, "catalog.xlsx"), "catalog")
    File.write(File.join(@root, "qualification.yml"), "qualified")
    File.write(File.join(@root, "runtime.yml"), "--- {}\n")
    @preflight = File.join(@root, "preflight.json")
    File.write(@preflight, JSON.pretty_generate("stable" => true))
    @case = File.join(@root, "case.yml")
    File.write(@case, YAML.dump(case_document))
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def test_verify_only_replays_preflight_without_scoring
    assert AFWorkloads::ScorerAdapter.new(root: @root, case_path: @case, out: StringIO.new).run(verify_only: true)
    refute File.exist?(File.join(@scorer, "scored"))
  end

  def test_scoring_runs_after_verification
    with_placement_endpoint do
      assert AFWorkloads::ScorerAdapter.new(root: @root, case_path: @case).run
    end
    assert File.file?(File.join(@scorer, "scored"))
  end

  def test_frozen_case_environment_reaches_scorer_without_stale_controls
    document = case_document
    document["environment"] = AFWorkloads::ScorerEnvironment.plan(
      "AF_LLM_PROVIDER" => "ollama",
      "AF_SOCIAL_INTERACTION_GUARDRAIL_PROFILE" => "phase6-v0.3"
    )
    File.write(@case, YAML.dump(document))
    previous = {
      "AF_SOCIAL_INTERACTION_GUARDRAIL_PROFILE" => ENV["AF_SOCIAL_INTERACTION_GUARDRAIL_PROFILE"],
      "AF_INVESTIGATION_GUARDRAIL_PROFILE" => ENV["AF_INVESTIGATION_GUARDRAIL_PROFILE"],
      "AF_OLLAMA_BASE_URL" => ENV["AF_OLLAMA_BASE_URL"],
      "WLO_WORKER_ENDPOINT" => ENV["WLO_WORKER_ENDPOINT"],
      "AFW_DW25_ORDINARY_MARKER" => ENV["AFW_DW25_ORDINARY_MARKER"]
    }
    ENV["AF_SOCIAL_INTERACTION_GUARDRAIL_PROFILE"] = "stale-social"
    ENV["AF_INVESTIGATION_GUARDRAIL_PROFILE"] = "stale-investigation"
    ENV["AF_OLLAMA_BASE_URL"] = "http://stale-worker.example:11434"
    ENV["WLO_WORKER_ENDPOINT"] = "http://selected-worker.example:11434"
    ENV["AFW_DW25_ORDINARY_MARKER"] = "inherited"

    assert AFWorkloads::ScorerAdapter.new(root: @root, case_path: @case).run
    observed = JSON.parse(File.read(File.join(@scorer, "scored")))
    assert_equal "ollama", observed.fetch("AF_LLM_PROVIDER")
    assert_equal "phase6-v0.3", observed.fetch("AF_SOCIAL_INTERACTION_GUARDRAIL_PROFILE")
    refute observed.key?("AF_INVESTIGATION_GUARDRAIL_PROFILE")
    assert_equal "http://selected-worker.example:11434", observed.fetch("AF_OLLAMA_BASE_URL")
    refute observed.key?("WLO_WORKER_ENDPOINT")
    assert_equal "inherited", observed.fetch("AFW_DW25_ORDINARY_MARKER")
  ensure
    previous&.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  def test_scoring_requires_wlo_placement_input_and_case_cannot_spoof_adapter_variables
    error = assert_raises(AFWorkloads::Error) do
      AFWorkloads::ScorerAdapter.new(root: @root, case_path: @case).run
    end
    assert_includes error.message, "WLO_WORKER_ENDPOINT"

    document = case_document
    document["environment"]["WLO_WORKER_ENDPOINT"] = "http://spoof.invalid:11434"
    File.write(@case, YAML.dump(document))
    error = assert_raises(AFWorkloads::Error) do
      AFWorkloads::ScorerAdapter.new(root: @root, case_path: @case).run(verify_only: true)
    end
    assert_includes error.message, "cannot set runtime adapter"
  end

  def test_changed_scorer_head_fails_closed
    File.write(File.join(@scorer, "new-file"), "new\n")
    system("git", "-C", @scorer, "add", "new-file", exception: true)
    system("git", "-C", @scorer, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
           "commit", "-qm", "next", exception: true)

    error = assert_raises(AFWorkloads::Error) do
      AFWorkloads::ScorerAdapter.new(root: @root, case_path: @case).run(verify_only: true)
    end
    assert_includes error.message, "scorer HEAD changed"
  end

  def test_dirty_protected_scorer_file_fails_closed
    File.open(File.join(@scorer, "config/default.yml"), "a") { |file| file.puts "# changed" }

    error = assert_raises(AFWorkloads::Error) do
      AFWorkloads::ScorerAdapter.new(root: @root, case_path: @case).run(verify_only: true)
    end
    assert_includes error.message, "uncommitted changes"
  end

  def test_staged_case_revalidates_authority_before_preflight_replay
    document = case_document
    document["staged_scoring"] = {"authority_id" => "a" * 64}
    document["staged_scoring_verification"] = {
      "path" => "workloads/fixture/staged-scoring.json", "sha256" => "b" * 64, "bytes" => 1
    }
    File.write(@case, YAML.dump(document))
    observed = nil
    verifier = lambda do |root:, data:|
      observed = [root, data.fetch("case_id")]
      true
    end

    AFWorkloads::StagedScoringInput.stub(:verify_case!, verifier) do
      assert AFWorkloads::ScorerAdapter.new(root: @root, case_path: @case, out: StringIO.new).run(verify_only: true)
    end

    assert_equal [@root, "fixture-case"], observed
  end

  def test_incompatible_staged_replay_stops_before_preflight
    document = case_document
    document["staged_scoring"] = {"authority_id" => "a" * 64}
    document["staged_scoring_verification"] = {
      "path" => "workloads/fixture/staged-scoring.json", "sha256" => "b" * 64, "bytes" => 1
    }
    File.write(@case, YAML.dump(document))
    verifier = ->(**_arguments) { raise AFWorkloads::Error, "staged catalog is not safe for workload preparation" }

    error = AFWorkloads::StagedScoringInput.stub(:verify_case!, verifier) do
      assert_raises(AFWorkloads::Error) do
        AFWorkloads::ScorerAdapter.new(root: @root, case_path: @case, out: StringIO.new).run(verify_only: true)
      end
    end

    assert_includes error.message, "not safe"
    refute File.exist?(File.join(@scorer, "scored"))
  end

  private

  def case_document
    {
      "contract_version" => "afw-workload/v0.1",
      "workload_id" => "fixture",
      "case_id" => "fixture-case",
      "adventure_id" => "ADV-0001",
      "dimension" => "Combat Emphasis",
      "profile" => "production-base",
      "model_alias" => "qwen",
      "ollama_model" => "qwen3.6:35b-a3b",
      "qualified_model_digest" => "a" * 64,
      "catalog_path" => File.join(@root, "catalog.xlsx"),
      "catalog_sha256" => Digest::SHA256.file(File.join(@root, "catalog.xlsx")).hexdigest,
      "qualification_path" => File.join(@root, "qualification.yml"),
      "qualification_sha256" => Digest::SHA256.file(File.join(@root, "qualification.yml")).hexdigest,
      "runtime_path" => File.join(@root, "runtime.yml"),
      "runtime_sha256" => Digest::SHA256.file(File.join(@root, "runtime.yml")).hexdigest,
      "preflight_path" => @preflight,
      "preflight_sha256" => Digest::SHA256.file(@preflight).hexdigest,
      "scorer_repo" => @scorer,
      "scorer_commit" => @head,
      "output_path" => File.join(@root, "results"),
      "environment" => { "AF_LLM_PROVIDER" => "ollama" }
    }
  end

  def with_placement_endpoint(value = "http://selected-worker.example:11434")
    previous = ENV["WLO_WORKER_ENDPOINT"]
    ENV["WLO_WORKER_ENDPOINT"] = value
    yield
  ensure
    previous.nil? ? ENV.delete("WLO_WORKER_ENDPOINT") : ENV["WLO_WORKER_ENDPOINT"] = previous
  end
end
