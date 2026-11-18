# frozen_string_literal: true

require_relative "test_helper"
require "af_workloads"
require_relative "support/staged_selection_source_policy_fixture"

# Exercises the actual source-preparation CLI and AFW handoff with bound files.
class StagedSelectionSourcePolicyTest < Minitest::Test
  include StagedSelectionSourcePolicyFixture

  # Build only mechanical source/reference/catalog inputs beside real scorer code.
  def setup
    @workspace = Dir.mktmpdir("afw-source-policy")
    @scorer = File.realpath(ENV.fetch("AFW_TEST_SCORER_ROOT"))
    raise "actual scorer missing" unless File.executable?(File.join(@scorer, "bin/af-score"))
    # Scorer roots are selected explicitly through its supported environment.
    @source_root = File.join(@workspace, "source")
    FileUtils.mkdir_p(@source_root)
    @source = File.join(@source_root, "0.md")
    File.write(@source, "<!-- Printed Page 1 -->\n0\n")
    @registry = File.join(@source_root, "source_registry.yml")
    File.write(@registry, YAML.dump("schema_version" => "adventurefinder-source-registry/v0.1", "sources" => {"0" => {"file" => "0.md", "page_marker_offset" => "+0"}}))
    @catalog = File.join(@workspace, "fixture.xlsx")
    write_workbook(@catalog, "Adventure Catalog", [["Adventure ID", "Adventure Title", "Source Book", "Book Publisher", "Page Count", "Start Page", "End Page", "Level Start", "Level End"], ["ADV-0001", "0", "0", "0", 1, 1, 1, "", ""]])
    @reference = File.join(@workspace, "reference.xlsx")
    write_workbook(@reference, "AFAO 1.0 ADV References", [["Adventure ID"], ["ADV-0001"]])
    @batch = AdventureIngest::Batch.new(root: File.expand_path("..", __dir__), batch: 1, catalog: "fixture.xlsx", ids: ["ADV-0001"], scorer_repo: @scorer)
    @payload = @batch.runtime_payloads.fetch("base")
    @payload["files"].merge!("catalog" => @catalog, "regression_workbook" => @reference)
    @payload["source"] ||= {}
    @payload["paths"] ||= {}
    @payload["paths"].merge!("xlsx_root" => @workspace, "source_root" => @source_root, "output_root" => File.join(@workspace, "output"),
      "specification_root" => File.realpath(ENV.fetch("AFW_TEST_SPEC_ROOT")))
    @payload["files"]["source_registry"] = @registry
    @batch.define_singleton_method(:runtime_payloads) { {"base" => @payload_for_test} }
    @batch.instance_variable_set(:@payload_for_test, @payload)
    binding = AFWorkloads::StagedScoringInput.method(:file_binding)
    @authority = {"staged_amc" => binding.call(@catalog).merge("filename" => "fixture.xlsx"), "evidence" => {"source_registry" => binding.call(@registry), "source:0" => binding.call(@source)}}
    @selector = AFWorkloads::StagedSelection.new(root: @workspace, scorer_repo: @scorer)
  end

  # Remove disposable fixtures, including changed-source controls.
  def teardown
    FileUtils.remove_entry(@workspace)
  end

  # The current producer default is accepted without weakening bound source bytes.
  def test_real_producer_default_and_changed_source
    evidence = preflight
    assert_equal "afsu-prepared-source/v0.2", evidence.fetch("contract_version")
    assert_match(/\A[0-9a-f]{64}\z/, evidence.fetch("prepared_source_sha256"))
    assert_match(/\A[0-9a-f]{64}\z/, evidence.fetch("target_eligibility_sha256"))
    File.open(@source, "a") { |file| file.write("1\n") }
    assert_equal "source/catalog evidence conflicts", assert_raises(AFWorkloads::Error) { preflight }.message
  end

  # Actual producer configuration must not widen clamping or fallback.
  def test_real_producer_widened_and_malformed_policies_refuse
    [{"allow_inward_boundary_clamp_adventure_ids" => ["ADV-0001"]},
     {"inward_boundary_clamp_max_gap_by_adventure" => {"ADV-0001" => 2}},
     {"inward_boundary_clamp_max_gap_by_adventure" => {"ADV-0001" => "bad"}},
     {"allow_full_source_fallback" => true}].each do |changes|
      original = @payload["source"].dup
      @payload["source"].merge!(changes)
      assert_raises(AFWorkloads::Error) { preflight }
      @payload["source"].replace(original)
    end
  end

  # Tamper only real producer output. The real owner replay validator must refuse
  # missing/context/content bindings and a version downgrade, then accept restoration.
  def test_v2_missing_and_tampered_bindings_refuse
    capture = Open3.method(:capture3)
    mutation = nil
    interceptor = lambda do |*arguments, **options|
      result = capture.call(*arguments, **options)
      index = arguments.index("--prepare-source")
      if result.last.success? && index && mutation
        path = arguments[index + 1]
        data = JSON.parse(File.binread(path))
        mutation.call(data)
        File.write(path, JSON.generate(data))
      end
      result
    end
    mutations = [
      ->(data) { data.delete("target_eligibility") },
      ->(data) { data.fetch("target_eligibility").delete("context") },
      ->(data) { data.fetch("target_eligibility")["calibration"] = "historical" },
      ->(data) { data.fetch("target_eligibility").fetch("context")["page_marker_offset"] = 9 },
      ->(data) { data.fetch("extraction")["text"] = "9" },
      ->(data) { data.delete("levels_context") },
      ->(data) { data.fetch("adventure")["title"] = "9" },
      ->(data) { data.fetch("source_policy")["max_inward_boundary_clamp_gap"] = nil },
      ->(data) { data["contract_version"] = "afsu-prepared-source/v0.1"; data.delete("target_eligibility") }
    ]
    Open3.stub(:capture3, interceptor) do
      mutations.each do |change|
        mutation = change
        error = assert_raises(AFWorkloads::Error) { preflight }
        assert_match(/prepared source replay refused/, error.message)
      end
      mutation = nil
      assert_equal "afsu-prepared-source/v0.2", preflight.fetch("contract_version")
    end
  end

  private

  # Invoke the actual owner method; no source validator or process is replaced.
  def preflight
    @selector.send(:source_preflight!, @batch, @catalog, "ADV-0001", @authority)
  end
end
