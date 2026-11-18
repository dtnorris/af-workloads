# frozen_string_literal: true

require_relative "test_helper"
require "af_workloads"

class StagedSelectionTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  class SyntheticSelection < AFWorkloads::StagedSelection
    attr_accessor :sheets, :preflight_failure

    private

    def read_sheets(_catalog) = sheets

    def source_preflight!(_batch, _catalog, _id, _authority)
      raise AFWorkloads::Error, "synthetic missing source evidence" if preflight_failure
      {"contract_version" => "afsu-prepared-source/v0.1", "synthetic" => true}
    end

    def batch_for(catalog, ids)
      super.tap { |batch| batch.define_singleton_method(:scorer_check!) { "a" * 40 } }
    end
  end

  def setup
    @root = Dir.mktmpdir("afw-selection")
    files = AdventureIngest::Batch::QUALIFICATION_PATHS.values + AdventureIngest::Batch::RUNTIME_SOURCE_PATHS.values + ["config/models.yml"]
    files.each do |path|
      FileUtils.mkdir_p(File.dirname(File.join(@root, path)))
      FileUtils.cp(File.join(ROOT, path), File.join(@root, path))
    end
    @catalog = File.join(@root, "staged.xlsx")
    File.write(@catalog, "synthetic non-narrative catalog")
    @selector = SyntheticSelection.new(root: @root, scorer_repo: @root)
    batch = AdventureIngest::Batch.new(root: @root, batch: 1, catalog: "staged.xlsx", ids: ["ADV-0003"])
    @headers = ["Adventure ID", "Adventure Title", "Source Book", "Book Publisher", "Page Count", "Start Page", "End Page", "Level Start", "Level End", *batch.dimension_contracts.map { |d| d.fetch("catalog_column") }, *AdventureIngest::Batch::DEFERRED_COLUMNS]
    @rows = [@headers, row("ADV-0001"), row("ADV-0003"), row("ADV-0004", count: 100)]
    @selector.sheets = {"Adventure Catalog" => @rows, "AMC >100pg" => [@headers]}
    @authority = {"authority_id" => "", "operation" => {"operation_id" => "fixture-operation"},
                  "intent" => {"workload_id" => "synthetic-selection", "source" => {"source_id" => "Source", "publisher" => "Publisher"}},
                  "base_amc" => {"filename" => "base.xlsx", "sha256" => "b" * 64, "bytes" => 10},
                  "staged_amc" => {"filename" => "staged.xlsx", **AFWorkloads::StagedScoringInput.file_binding(@catalog)},
                  "allocation" => [record("ADV-0003", 3), record("ADV-0004", 4, count: 100)]}
    rehash
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_mixed_allocation_defers_exactly_100_pages_and_replays_durably
    before = Dir[File.join(@root, "**", "*")].select { |p| File.file?(p) }.to_h { |p| [p, File.binread(p)] }
    selection, path = @selector.select!(authority: @authority, catalog_path: @catalog)
    assert_equal "SELECTED", selection.fetch("status")
    assert_equal ["ADV-0003"], selection.fetch("selected_ids")
    assert_equal %w[selected-qualified legitimately-deferred], selection.fetch("dispositions").map { |d| d.fetch("disposition") }
    assert_equal "OUTSIDE_QUALIFIED_PAGE_ENVELOPE", selection.dig("dispositions", 1, "reason", "code")
    assert selection.dig("dispositions", 0, "evidence", "needs_levels")
    assert_equal [selection, path], @selector.select!(authority: @authority, catalog_path: @catalog)
    assert_equal selection, @selector.verify!(authority: @authority, catalog_path: @catalog, selection_path: path)
    before.each { |p, bytes| assert_equal bytes, File.binread(p) }
    refute Dir.exist?(File.join(@root, "build"))
  end

  def test_single_multiple_and_all_deferred_are_distinct
    @authority["allocation"].pop
    rehash
    assert_equal ["ADV-0003"], evaluate.fetch("selected_ids")
    @authority["allocation"] << record("ADV-0004", 4)
    @rows[3] = row("ADV-0004")
    rehash
    assert_equal %w[ADV-0003 ADV-0004], evaluate.fetch("selected_ids")
    @authority["allocation"] = [record("ADV-0004", 4, count: 101)]
    @rows[3] = row("ADV-0004", count: 101)
    rehash
    @authority["allocation"][0].merge!("sheet" => "AMC >100pg", "row" => 2)
    @selector.sheets["AMC >100pg"] = [@headers, row("ADV-0004", count: 101)]
    rehash
    selection, path = @selector.select!(authority: @authority, catalog_path: @catalog)
    assert_equal "ALL_DEFERRED", selection.fetch("status")
    assert_empty selection.fetch("selected_ids")
    assert_equal 1, selection.fetch("dispositions").size
    assert File.file?(path)
    refute File.exist?(File.join(@root, "workloads", "synthetic-selection", "execution-plan.json"))
  end

  def test_invalid_large_records_are_refused_before_deferral
    original = @rows[3].dup
    {"asymmetric Levels" => {7 => 1}, "fractional Levels" => {7 => 1.5, 8 => 2},
     "out of range Levels" => {7 => 0, 8 => 21}, "reversed Levels" => {7 => 5, 8 => 1},
     "populated scores" => {9 => 2}, "bad pages" => {4 => 100.5},
     "contradictory pages" => {6 => 2}, "missing source" => {2 => nil},
     "conflicting publisher" => {3 => "Other"}, "missing ID" => {0 => "ADV-0005"}}.each do |label, changes|
      @rows[3] = original.dup
      changes.each { |i, v| @rows[3][i] = v }
      selection = evaluate
      assert_equal "REFUSED", selection["status"], label
      assert_equal "refused", selection.dig("dispositions", 1, "disposition"), label
      refute_empty selection.dig("dispositions", 1, "reason", "detail"), label
    end
    @rows[3] = original
    @rows << original
    assert_equal "REFUSED", evaluate["status"]
  end

  def test_populated_levels_preserved_blank_levels_selected_and_source_failure_refused
    @rows[2][7] = 1
    @rows[2][8] = 5
    @authority["allocation"][0]["levels"] = {"start" => 1, "end" => 5}
    rehash
    refute evaluate.dig("dispositions", 0, "evidence", "needs_levels")
    @selector.preflight_failure = true
    selection, path = @selector.select!(authority: @authority, catalog_path: @catalog)
    assert_equal "REFUSED", selection["status"]
    assert_equal "refused", selection.dig("dispositions", 0, "disposition")
    assert_raises(AFWorkloads::Error) { @selector.verify!(authority: @authority, catalog_path: @catalog, selection_path: path) }
    refute Dir.exist?(File.join(@root, "build"))
  end

  def test_rehashed_tampering_and_changed_qualification_or_bytes_refused
    selection, path = @selector.select!(authority: @authority, catalog_path: @catalog)
    bad = Marshal.load(Marshal.dump(selection))
    bad["dispositions"].pop
    bad["selection_id"] = AFWorkloads::StagedScoringInput.digest(bad.except("selection_id"))
    File.write(path, JSON.generate(bad))
    assert_raises(AFWorkloads::Error) { @selector.verify!(authority: @authority, catalog_path: @catalog, selection_path: path) }
    assert_raises(AFWorkloads::Error) { @selector.select!(authority: @authority, catalog_path: @catalog) }
    File.write(path, JSON.pretty_generate(AFWorkloads::StagedScoringInput.canonical(selection)) + "\n")
    File.open(File.join(@root, "config/models.yml"), "a") { |f| f.write("\n# altered qualification input\n") }
    assert_raises(AFWorkloads::Error) { @selector.verify!(authority: @authority, catalog_path: @catalog, selection_path: path) }
    File.write(@catalog, "changed")
    assert_raises(AFWorkloads::Error) { evaluate }
  end

  # Staged selection must use the same scoped model as forward compilation,
  # while retaining the historical qualifications as immutable source evidence.
  def test_ee_candidate_selection_and_changed_artifact_refusal
    original = AdventureIngest::Batch.new(root: @root, batch: 1, catalog: "staged.xlsx", ids: ["ADV-0003"]).dimension_contracts
    selected = evaluate.fetch("dimensions")
    original.zip(selected).each do |historical, current|
      if historical.fetch("name") == "Exploration Emphasis"
        assert_equal "gptoss", current.fetch("model_alias")
        assert_equal "gpt-oss:20b-candidate", current.fetch("ollama_model")
        assert_equal historical.except("model_alias", "ollama_model"), current.except("model_alias", "ollama_model")
      else
        assert_equal historical, current
      end
    end
    path = File.join(@root, "config/models.yml")
    models = YAML.safe_load_file(path)
    models.fetch("models").fetch("gptoss")["qualified_manifest_sha256"] = "0" * 64
    File.write(path, YAML.dump(models))
    error = assert_raises(AFWorkloads::Error) { evaluate }
    assert_match(/gptoss model\/digest changed/, error.message)
  end

  # Bind explicit configuration bytes, reload on the same owner instance, and
  # preserve exact recovery without changing historical unset selection shape.
  def test_explicit_configuration_is_bound_and_revalidated
    config = File.join(@root, "selection.yml")
    mapping = {"paths" => AFWorkloads::ScorerInputSelection::ROOTS.to_h { |key| [key, @root] }}
    bytes = YAML.dump(mapping)
    File.write(config, bytes)
    configured = SyntheticSelection.new(root: @root, scorer_repo: @root, scorer_config: config)
    configured.sheets = @selector.sheets
    selection, path = configured.select!(authority: @authority, catalog_path: @catalog)
    assert_equal Digest::SHA256.hexdigest(bytes), selection.dig("scorer_config", "sha256")
    refute evaluate.key?("scorer_config")
    File.unlink(config)
    assert_raises(AFWorkloads::Error) { configured.verify!(authority: @authority, catalog_path: @catalog, selection_path: path) }
    File.write(config, bytes + "\n# changed configuration bytes\n")
    assert_raises(AFWorkloads::Error) { configured.select!(authority: @authority, catalog_path: @catalog) }
    File.write(config, bytes)
    assert_equal selection, configured.verify!(authority: @authority, catalog_path: @catalog, selection_path: path)
    mapping["llm"] = {"model" => "forbidden"}
    File.write(config, YAML.dump(mapping))
    assert_raises(AFWorkloads::Error) { configured.evaluate(authority: @authority, catalog_path: @catalog) }
  end

  private

  def row(id, count: 2) = [id, "Unit #{id}", "Source", "Publisher", count, 1, count, nil, nil]

  def record(id, row_number, count: 2)
    {"adventure_id" => id, "canonical_title" => "Unit #{id}", "printed_pages" => {"start" => 1, "end" => count}, "sheet" => "Adventure Catalog", "row" => row_number}
  end

  def rehash
    @authority["authority_id"] = AFWorkloads::StagedScoringInput.digest(@authority.except("authority_id"))
  end

  def evaluate = @selector.evaluate(authority: @authority, catalog_path: @catalog)
end
