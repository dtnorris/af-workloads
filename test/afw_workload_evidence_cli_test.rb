# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/workload_scoring_evidence_fixture"
require "json"
require "open3"
require "rbconfig"

class AfwWorkloadEvidenceCliTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("afw-workload-evidence-cli-test")
    @job_id = "batch-adv0001-combat"
    @fixture = WorkloadScoringEvidenceFixture.new(
      root: @root,
      cases: [{
        job_id: @job_id, adventure_id: "ADV-0001", dimension: "Combat Emphasis", metrics: ["Combat Emphasis"]
      }]
    )
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def test_publish_and_validate_expose_the_versioned_manifest
    stdout, stderr, status = cli("publish", @fixture.workload_id, @fixture.wlo)
    published = JSON.parse(stdout)

    assert status.success?, stderr
    assert published.fetch("evidence_complete")
    assert_equal 1, published.fetch("intended_cases")
    assert_equal 1, published.fetch("receipt_count")
    assert_equal 1, published.fetch("review_candidate_count")
    manifest = File.join(@root, published.fetch("manifest_path"))
    assert_path_exists manifest

    stdout, stderr, status = cli("validate", published.fetch("manifest_path"))
    validated = JSON.parse(stdout)
    assert status.success?, stderr
    assert_equal published.fetch("manifest_id"), validated.fetch("manifest_id")
    assert validated.fetch("evidence_complete")
  end

  def test_partial_publication_succeeds_but_does_not_claim_evidence_complete
    @fixture.write_metadata(@job_id, "status" => "failed", "exit_status" => 1)

    stdout, stderr, status = cli("publish", @fixture.workload_id, @fixture.wlo)
    published = JSON.parse(stdout)

    assert status.success?, stderr
    refute published.fetch("evidence_complete")
    assert_equal 1, published.fetch("intended_cases")
    assert_equal 0, published.fetch("receipt_count")
    assert_equal 0, published.fetch("review_candidate_count")
  end

  def test_invalid_manifest_fails_closed
    path = File.join(@root, "invalid.json")
    File.write(path, "{}\n")

    _stdout, stderr, status = cli("validate", path)

    refute status.success?
    assert_includes stderr, "ERROR:"
  end

  private

  def cli(*arguments)
    executable = File.expand_path("../bin/afw-workload-evidence", __dir__)
    Open3.capture3({ "AFW_ROOT" => @root }, RbConfig.ruby, executable, "--data-root", @root, *arguments)
  end
end
