# frozen_string_literal: true

require_relative "test_helper"
require "digest"
require "json"
require "af_workloads"
require_relative "support/afw_wlo_v0_3_contract"

class AfwWloV03ContractTest < Minitest::Test
  include AfwWloV03Contract
  FIXTURE_ROOT = File.expand_path("fixtures/afw-wlo-v0.3", __dir__)
  CHECKSUM_MANIFEST_SHA256 = "04a958bd00135c866679eda12e39c6590fcba3382726525a932e6b2bece75b14"
  LEGACY_V02_FIXTURE = File.expand_path("fixtures/afw-wlo-v0.2.json", __dir__)
  LEGACY_V02_SHA256 = "03cd53956ef828dd61d46a4433eba948d0cba6017a25e97e360d3cc5a61952f5"

  def test_canonical_fixture_bytes_match_frozen_hashes
    manifest = File.join(FIXTURE_ROOT, "SHA256SUMS")
    assert_equal CHECKSUM_MANIFEST_SHA256, Digest::SHA256.file(manifest).hexdigest

    checksum_rows.each do |relative_path, expected|
      assert_equal expected, Digest::SHA256.file(File.join(FIXTURE_ROOT, relative_path)).hexdigest, relative_path
    end
  end

  def test_valid_grouped_ungrouped_and_dependency_fixtures_match_v03_semantics
    grouped = validated_fixture("valid/grouped-no-dependencies.json")
    chain = validated_fixture("valid/dependency-chain.json")
    ungrouped = validated_fixture("valid/ungrouped.json")

    assert_equal [[], [], []], grouped.fetch("jobs").map { |job| job.fetch("depends_on_job_ids", []) }
    assert_equal(
      [[0, 0, "group-a-1"], [1, 0, "group-b-1"], [0, 1, "group-a-2"]],
      priority_keys(grouped)
    )
    assert_equal [[], ["step-1"], ["step-2"]],
                 chain.fetch("jobs").map { |job| job.fetch("depends_on_job_ids", []) }
    assert_equal [[0, 0, "zeta"], [0, 1, "alpha"]], priority_keys(ungrouped)
  end

  def test_invalid_fixtures_are_rejected_by_the_afw_contract_seam
    Dir.glob(File.join(FIXTURE_ROOT, "invalid", "*.json")).sort.each do |path|
      assert_raises(ArgumentError, File.basename(path)) { validate_contract!(JSON.parse(File.read(path))) }
    end
  end

  def test_malformed_environment_representations_fail_closed
    canonical = JSON.parse(File.read(File.join(FIXTURE_ROOT, "valid/grouped-no-dependencies.json")))
    [{ "BAD-NAME" => "value" }, { "VALID_NAME" => 1 }, [], nil].each do |environment|
      document = Marshal.load(Marshal.dump(canonical))
      document.fetch("jobs").first["env"] = environment
      assert_raises(ArgumentError) { validate_contract!(document) }
    end
  end

  def test_v02_fixture_bytes_remain_legacy_while_compiler_default_is_v03
    assert_equal LEGACY_V02_SHA256, Digest::SHA256.file(LEGACY_V02_FIXTURE).hexdigest
    assert_equal "wlo-execution-plan/v0.3", AFWorkloads::WorkloadCompiler::WLO_CONTRACT_VERSION
    assert_equal "wlo-execution-plan/v0.2",
                 AFWorkloads::WorkloadCompiler::COMPATIBILITY_WLO_CONTRACT_VERSION
  end

  private

  def validated_fixture(relative_path)
    document = JSON.parse(File.read(File.join(FIXTURE_ROOT, relative_path)))
    validate_contract!(document)
    document
  end

  def checksum_rows
    File.readlines(File.join(FIXTURE_ROOT, "SHA256SUMS"), chomp: true).to_h do |line|
      checksum, relative_path = line.split(/\s+/, 2)
      [relative_path, checksum]
    end
  end
end
