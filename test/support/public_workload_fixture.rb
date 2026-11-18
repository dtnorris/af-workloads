# frozen_string_literal: true

require "af_workloads"
require "open3"
require_relative "staged_selection_source_policy_fixture"

# Creates a mechanical EE catalog, source and explicit store for CLI checks.
module PublicWorkloadFixture
  include StagedSelectionSourcePolicyFixture

  # Allocate content-free input bytes; outputs use unique IDs in this AFW root.
  def prepare_workload_fixture(scorer_root: ENV.fetch("AFW_TEST_SCORER_ROOT"))
    @scratch = Dir.mktmpdir("afw-roots-")
    @workload = "wl06-ee-proof"
    @scorer = File.realpath(scorer_root)
    @store = File.join(@scratch, "data")
    FileUtils.mkdir(@store)
    @public = File.join(@scratch, "public")
    FileUtils.mkdir_p(@public)
    %w[documents.json AdventureFinder_Analysis_Ontology_AFAO_v1.6.1.md AdventureFinder_Analysis_Data_Assessment_Specification_v0.1.md].each do |name|
      FileUtils.cp(File.join(File.realpath(ENV.fetch("AFW_TEST_SPEC_ROOT")), name), @public)
    end
    @catalog = File.join(@scratch, "catalog.xlsx")
    batch = AdventureIngest::Batch.new(root: @code_root, batch: 1, catalog: "catalog.xlsx", ids: ["ADV-0001"], scorer_repo: @scorer)
    headers = ["Adventure ID", "Adventure Title", "Source Book", "Book Publisher", "Page Count", "Start Page", "End Page",
               "Level Start", "Level End", *batch.dimension_contracts.map { |dimension| dimension.fetch("catalog_column") }]
    write_workbook(@catalog, "Adventure Catalog", [headers, ["ADV-0001", "0", "0", "0", 1, 1, 1]])
    File.write(File.join(@scratch, "0.md"), "<!-- Printed Page 1 -->\n0\n")
    File.write(File.join(@scratch, "registry.yml"), YAML.dump("schema_version" => "adventurefinder-source-registry/v0.1",
      "sources" => {"0" => {"file" => "0.md"}}))
    @selection = {"paths" => {"xlsx_root" => @scratch, "specification_root" => @public,
      "source_root" => @scratch, "output_root" => File.join(@store, "output")}, "files" => {"source_registry" => "registry.yml"}}
    @config = File.join(@scratch, "selection.yml")
    File.write(@config, YAML.dump(@selection))
    guard = File.join(@scratch, "transport_guard.rb")
    File.write(guard, <<~GUARD)
      require "net/http"
      module OfflineRootsGuard
        def request(*)
          raise "unexpected HTTP transport during offline roots proof"
        end
      end
      Net::HTTP.prepend(OfflineRootsGuard)
    GUARD
    @environment = AFWorkloads::ScorerEnvironment.compilation.merge("RUBYOPT" => "-r#{guard}")
  end

  # Remove only this test's scratch and unique generated artifacts.
  def remove_workload_fixture
    FileUtils.remove_entry(@scratch)
  end

  # Common public compiler/inspector arguments; no worker placement is selected.
  def arguments
    ["--workload", @workload, "--catalog", @catalog, "--ids", "ADV-0001", "--dimension", "Exploration Emphasis",
     "--scorer-repo", @scorer, "--required-context-length", "131072", "--require-fully-gpu-resident"]
  end

  # Launch a new real CLI process, preserving byte streams and status for checks.
  def invoke(entrypoint, *arguments, environment: {})
    Open3.capture3(@environment.merge(environment), RbConfig.ruby, File.join(@code_root, "bin", entrypoint), "--data-root", @store, *arguments, chdir: @scratch)
  end

end
