# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/workload_scoring_evidence_fixture"
require "json"
require "open3"
require "rbconfig"

class AfwBindScoringEvidenceCliTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("afw-bind-scoring-evidence-cli-test")
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

  def test_two_argument_operation_binds_the_complete_workload
    stdout, stderr, status = cli(@fixture.workload_id, @fixture.wlo)
    result = JSON.parse(stdout)

    assert status.success?, stderr
    assert result.fetch("fully_evidenced")
    assert_equal({ "evidenced" => 1 }, result.fetch("counts"))
    assert_path_exists @fixture.receipt_path(@job_id)
  end

  def test_partial_workload_is_reported_as_json_with_nonzero_status
    @fixture.write_metadata(@job_id, "status" => "failed", "exit_status" => 1)

    stdout, stderr, status = cli(@fixture.workload_id, @fixture.wlo)
    result = JSON.parse(stdout)

    refute status.success?
    assert_empty stderr
    refute result.fetch("fully_evidenced")
    assert_equal "wlo_attempt_failed", result.dig("cases", 0, "reason")
    refute_path_exists @fixture.receipt_path(@job_id)
  end

  def test_three_argument_per_job_operation_remains_available
    stdout, stderr, status = cli(@fixture.workload_id, @fixture.wlo, @job_id)

    assert status.success?, stderr
    assert_match(/Evidence receipt:/, stdout)
    assert_path_exists @fixture.receipt_path(@job_id)
  end

  private

  def cli(*arguments)
    executable = File.expand_path("../bin/afw-bind-scoring-evidence", __dir__)
    Open3.capture3({ "AFW_ROOT" => @root }, RbConfig.ruby, executable, "--data-root", @root, *arguments)
  end
end
