# frozen_string_literal: true

require_relative "test_helper"
require "af_workloads"

class AfwCatalogSelectionTest < Minitest::Test
  def test_workload_id_is_restricted
    error = assert_raises(AFWorkloads::Error) do
      AFWorkloads::WorkloadCompiler.new(
        root: __dir__,
        workload_id: "Not Valid",
        catalog_path: __FILE__,
        ids: ["ADV-0001"],
        scorer_repo: Dir.pwd,
        plan_version: "0.2"
      )
    end
    assert_includes error.message, "invalid workload id"
  end
end
