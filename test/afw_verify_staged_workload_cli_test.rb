# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"

class AfwVerifyStagedWorkloadCliTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def setup
    @dir = Dir.mktmpdir("afw-verify-staged-cli")
    @preload = File.join(@dir, "fixture.rb")
    File.write(@preload, <<~RUBY)
      require #{File.join(ROOT, "lib/af_workloads").dump}
      class << AFWorkloads::StagedScoringInput
        def verify_workload!(root:, workload_id:)
          raise AFWorkloads::Error, "wrong root" unless root == #{File.realpath(@dir).dump}
          raise AFWorkloads::Error, "fixture failure" if workload_id == "bad"
          {"binding" => {"authority_id" => "a" * 64, "operation_id" => "fixture-operation"}}
        end
      end
    RUBY
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_reports_verified_identity_without_execution
    output, error, status = run_cli("fixture")
    assert status.success?, error
    assert_includes output, "VERIFIED fixture"
    assert_includes output, "Authority: #{"a" * 64}"
    assert_includes output, "No inference or catalog adoption"
  end

  def test_failure_is_nonzero
    _output, error, status = run_cli("bad")
    refute status.success?
    assert_includes error, "fixture failure"
  end

  private

  def run_cli(workload)
    Open3.capture3(
      RbConfig.ruby, "-r", @preload, File.join(ROOT, "bin/afw-verify-staged-workload"),
      "--data-root", @dir, "--workload", workload, chdir: ROOT
    )
  end
end
