# frozen_string_literal: true

require "digest"
require "open3"
require "yaml"


module AdventureIngest
  class Error < StandardError; end

  class Batch
    DEFERRED_COLUMNS = [
      "Rules / System-Master Demand",
      "Tactical Complexity",
      "Lethality / Failure Severity",
      "Puzzle / Problem-Solving Emphasis",
      "Consequential Player Agency",
      "Fantastic Weirdness",
      "GM Improvisation Demand"
    ].freeze

    QUALIFICATION_PATHS = {
      "core" => "production_backlog/qualified_dimensions.yml",
      "nos" => "production_backlog/qualified_number_of_sessions.yml",
      "ee" => "production_backlog/qualified_exploration_emphasis.yml",
      "gmbs" => "production_backlog/qualified_gm_beginner_suitability.yml",
      "gmpb" => "production_backlog/qualified_gm_preparation_burden.yml",
      "seriousness" => "production_backlog/qualified_seriousness.yml"
    }.freeze

    RUNTIME_SOURCE_PATHS = {
      "ee" => "production_backlog/ee-v0.5-runtime.yml",
      "gmpb" => "production_backlog/gmpb-v0.6-runtime.yml",
      "seriousness" => "production_backlog/seriousness-reset-runtime.yml"
    }.freeze


    attr_reader :root, :scorer_repo, :queue, :catalog_filename, :catalog_sha256, :clamp_ids, :clamp_gaps

    def abort_with(message)
      raise Error, message
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def canonical_header(value)
      header = value.to_s.strip
      header == "ADV - ID" ? "Adventure ID" : header
    end

    def integer_or_nil(value)
      return nil if blank?(value)
      Integer(Float(value))
    rescue ArgumentError, TypeError
      nil
    end

    def git_head(repo)
      out, _err, status = Open3.capture3("git", "-C", repo, "rev-parse", "HEAD")
      abort_with("cannot read Git HEAD: #{repo}") unless status.success?
      out.strip
    end

    def load_yaml(path)
      YAML.safe_load_file(path, aliases: true) || {}
    end

    def sha256(path)
      Digest::SHA256.file(path).hexdigest
    end

    def deep_merge(base, other)
      merged = Marshal.load(Marshal.dump(base))
      other.each do |key, value|
        if merged[key].is_a?(Hash) && value.is_a?(Hash)
          merged[key] = deep_merge(merged[key], value)
        else
          merged[key] = value
        end
      end
      merged
    end

    def qualification_path(key)
      File.join(root, QUALIFICATION_PATHS.fetch(key))
    end

    def load_qualifications
      QUALIFICATION_PATHS.each_value do |relative|
        path = File.join(root, relative)
        abort_with("missing qualification contract #{path}") unless File.file?(path)
      end
      RUNTIME_SOURCE_PATHS.each_value do |relative|
        path = File.join(root, relative)
        abort_with("missing qualified runtime config #{path}") unless File.file?(path)
      end

      core = load_yaml(qualification_path("core"))
      abort_with("qualified core model alias changed") unless core.fetch("model_alias") == "qwen"
      abort_with("qualified core Ollama model changed") unless core.fetch("ollama_model") == "qwen3.6:35b-a3b"
      core_by_name = core.fetch("dimensions").to_h { |d| [d.fetch("name"), d] }

      nos = load_yaml(qualification_path("nos"))
      ee = load_yaml(qualification_path("ee"))
      gmbs = load_yaml(qualification_path("gmbs"))
      gmpb = load_yaml(qualification_path("gmpb"))
      seriousness = load_yaml(qualification_path("seriousness"))

      expected_individual = {
        nos => ["nos_local_qualified_v1", "# of Sessions", "qwen27", "qwen3.6:27b", "nos-clean-blind-v1"],
        ee => ["ee_local_qualified_v1", "Exploration Emphasis", "gptoss", "gpt-oss:20b", "ee-clean-reset-v0.5"],
        gmbs => ["gmbs_local_qualified_v1", "GM Beginner Suitability", "qwen", "qwen3.6:35b-a3b", "gmbs-clean-blind-v0.3"],
        gmpb => ["gmpb_local_qualified_v1", "GM Preparation Burden", "gemma", "gemma4:26b", "gmpb-v0.6-dependency-fan-out"],
        seriousness => ["seriousness_local_qualified_v1", "Seriousness", "qwen", "qwen3.6:35b-a3b", "seriousness-reset-only"]
      }
      expected_individual.each do |contract, expected|
        actual = [contract["contract_type"], contract["dimension"], contract["model_alias"], contract["ollama_model"], contract["profile"]]
        abort_with("qualified contract changed: expected #{expected.inspect}, got #{actual.inspect}") unless actual == expected
        abort_with("qualified contract no longer uses one replicate") unless Integer(contract.fetch("replicates")) == 1
        abort_with("qualified contract permits favorable reruns or external API cost") unless contract.fetch("no_favorable_rerun") == true && contract.fetch("external_api_cost_usd") == 0.0
        abort_with("qualified temperature changed") if contract.key?("temperature") && contract.fetch("temperature") != 0
      end

      core_expected = {
        "Levels" => ["levels", "levels-v2.1"],
        "Combat Emphasis" => ["combat", "production-base"],
        "Social Interaction Emphasis" => ["social", "phase6-v0.3"],
        "Investigation Emphasis" => ["investigation", "phase6-v0.4"],
        "Structural Openness" => ["structural-openness", "production-base"],
        "Darkness / Horror Intensity" => ["darkness", "production-base"],
        "Player Beginner Suitability" => ["player-beginner", "production-base"]
      }
      core_expected.each do |name, (slug, profile)|
        d = core_by_name.fetch(name)
        abort_with("qualified #{name} slug/profile changed") unless d.fetch("slug") == slug && d.fetch("profile") == profile
      end

      [core, core_by_name, nos, ee, gmbs, gmpb, seriousness]
    end

    def dimension_contracts
      core, core_by_name, nos, ee, gmbs, gmpb, seriousness = load_qualifications
      core_sha = sha256(qualification_path("core"))

      build_core = lambda do |name|
        d = core_by_name.fetch(name)
        {
          "name" => name,
          "slug" => d.fetch("slug"),
          "catalog_column" => name,
          "model_alias" => core.fetch("model_alias"),
          "ollama_model" => core.fetch("ollama_model"),
          "profile" => d.fetch("profile"),
          "qualification_path" => QUALIFICATION_PATHS.fetch("core"),
          "qualification_sha256" => core_sha,
          "runtime_key" => "base",
          "env_name" => d["env_name"],
          "env_value" => d["env_value"],
          "qualified_scorer_baseline" => %w[Social\ Interaction\ Emphasis Investigation\ Emphasis].include?(name) ? core.fetch("social_investigation_qualified_scorer_baseline") : nil
        }
      end

      individual = lambda do |key, contract, runtime_key, catalog_column = nil|
        {
          "name" => contract.fetch("dimension"),
          "slug" => contract.fetch("slug"),
          "catalog_column" => catalog_column || contract.fetch("catalog_column"),
          "model_alias" => contract.fetch("model_alias"),
          "ollama_model" => contract.fetch("ollama_model"),
          "profile" => contract.fetch("profile"),
          "qualification_path" => QUALIFICATION_PATHS.fetch(key),
          "qualification_sha256" => sha256(qualification_path(key)),
          "runtime_key" => runtime_key,
          "qualified_scorer_baseline" => contract["qualified_scorer_baseline"]
        }
      end

      [
        individual.call("nos", nos, "base", "Number of Sessions"),
        individual.call("ee", ee, "ee"),
        individual.call("gmpb", gmpb, "gmpb"),
        build_core.call("Combat Emphasis"),
        build_core.call("Social Interaction Emphasis"),
        build_core.call("Investigation Emphasis"),
        build_core.call("Structural Openness"),
        build_core.call("Darkness / Horror Intensity"),
        build_core.call("Player Beginner Suitability"),
        individual.call("gmbs", gmbs, "base"),
        individual.call("seriousness", seriousness, "seriousness")
      ]
    end

    def levels_contract
      core, core_by_name, *_rest = load_qualifications
      d = core_by_name.fetch("Levels")
      columns = d.fetch("catalog_columns")
      abort_with("qualified Levels catalog columns changed") unless columns == ["Level Start", "Level End"]

      {
        "name" => "Levels",
        "slug" => d.fetch("slug"),
        "catalog_columns" => columns,
        "model_alias" => core.fetch("model_alias"),
        "ollama_model" => core.fetch("ollama_model"),
        "profile" => d.fetch("profile"),
        "qualification_path" => QUALIFICATION_PATHS.fetch("core"),
        "qualification_sha256" => sha256(qualification_path("core")),
        "runtime_key" => "base"
      }
    end

    def runtime_payloads
      payloads = { "base" => {} }
      RUNTIME_SOURCE_PATHS.each do |key, relative|
        payloads[key] = load_yaml(File.join(root, relative))
        qualification = load_yaml(qualification_path(key))
        expected = { "llm" => {
          "provider" => "ollama", "model" => qualification.fetch("ollama_model"),
          "reasoning_effort" => qualification.fetch("reasoning_effort"),
          "max_tokens" => qualification.fetch("max_tokens")
        } }
        abort_with("qualified runtime content changed: #{relative}") unless payloads[key] == expected
      end
      payloads.transform_values do |payload|
        deep_merge(
          payload,
          {
            "files" => { "catalog" => catalog_filename },
            "source" => {
              "allow_inward_boundary_clamp_adventure_ids" => clamp_ids,
              "inward_boundary_clamp_max_gap_by_adventure" => clamp_gaps
            }
          }
        )
      end
    end

    def self.parse_ids(spec)
      tokens = Array(spec).flat_map { |value| value.split(',', -1) }
      ids = tokens.flat_map do |token|
        if (match = /\AADV-(\d{4})\.\.ADV-(\d{4})\z/.match(token))
          first, last = match.captures.map(&:to_i)
          raise Error, "descending ID range: #{token}" if first > last
          (first..last).map { |n| format('ADV-%04d', n) }
        elsif /\AADV-\d{4}\z/.match?(token)
          [token]
        else
          raise Error, "invalid Adventure ID/range: #{token.inspect}"
        end
      end
      raise Error, 'target IDs must be nonempty and unique' if ids.empty? || ids.uniq != ids
      ids
    end

    def initialize(root:, batch:, catalog:, ids:, scorer_repo: nil, clamp_ids: [], clamp_gaps: {})
      @root = File.expand_path(root)
      number = batch.to_s.sub(/\Aproduction-backlog-/, '')
      abort_with('batch must be a positive integer (e.g. 020)') unless /\A\d+\z/.match?(number) && number.to_i.positive?
      @queue = format('production-backlog-%03d', number.to_i)
      abort_with('catalog must be an XLSX basename') unless File.basename(catalog) == catalog && catalog.end_with?('.xlsx')
      @catalog_filename = catalog
      @ids = self.class.parse_ids(ids)
      @scorer_repo = scorer_repo && File.expand_path(scorer_repo, @root)
      @clamp_ids = clamp_ids
      @clamp_gaps = clamp_gaps
      abort_with('clamp allowlist must contain unique target IDs only') unless clamp_ids.is_a?(Array) && clamp_ids.uniq == clamp_ids && (clamp_ids - @ids).empty?
      abort_with('max-gap overrides require allowlisted IDs and positive integer gaps') unless clamp_gaps.is_a?(Hash) && (clamp_gaps.keys - clamp_ids).empty? && clamp_gaps.values.all? { |v| v.is_a?(Integer) && v.positive? }
    end

    def read_rows(path)
      require File.join(scorer_repo, 'lib/af_scoring/errors')
      require File.join(scorer_repo, 'lib/af_scoring/xlsx_reader')
      AFScoring::XlsxReader.new(path).rows(sheet_name: 'Adventure Catalog')
    end

    # Kept separate from IO so target/Levels interpretation can be tested directly.
    def select_targets(rows)
      abort_with('AMC Adventure Catalog sheet is empty') if rows.empty?
      headers = rows.first.map { |v| canonical_header(v) }
      score_columns = dimension_contracts.map { |d| d.fetch('catalog_column') }
      required = ['Adventure ID', 'Adventure Title', 'Source Book', 'Book Publisher',
                  'Page Count', 'Start Page', 'End Page', 'Level Start', 'Level End', *score_columns]
      abort_with("missing catalog headers: #{(required - headers).join(', ')}") unless (required - headers).empty?
      abort_with('duplicate catalog headers') unless headers.reject(&:empty?).uniq == headers.reject(&:empty?)
      deferred_columns_present = DEFERRED_COLUMNS.select { |column| headers.include?(column) }
      seen = []
      targets = []
      rows.drop(1).each do |row|
        values = headers.zip(row).to_h
        id = values['Adventure ID'].to_s.strip
        next if id.empty?
        seen << id
        next unless @ids.include?(id)
        start_page = integer_or_nil(values['Start Page'])
        end_page = integer_or_nil(values['End Page'])
        page_count = integer_or_nil(values['Page Count'])
        page_count ||= end_page - start_page + 1 if start_page && end_page && end_page >= start_page
        abort_with("#{id} missing/invalid page count or outside proven <100 page envelope") unless page_count&.positive? && page_count < 100
        left, right = ['Level Start', 'Level End'].map { |column| blank?(values[column]) }
        abort_with("#{id} has asymmetric Levels state") unless left == right
        (score_columns + deferred_columns_present).each do |column|
          abort_with("#{id} #{column} must remain blank") unless blank?(values[column])
        end
        targets << {
          'id' => id, 'title' => values['Adventure Title'].to_s,
          'source_book' => values['Source Book'].to_s, 'publisher' => values['Book Publisher'].to_s,
          'page_count' => page_count, 'start_page' => start_page, 'end_page' => end_page,
          'level_start' => integer_or_nil(values['Level Start']), 'level_end' => integer_or_nil(values['Level End']),
          'needs_levels' => left
        }
        unless left
          abort_with("#{id} invalid populated Levels pair") if targets.last.values_at('level_start', 'level_end').any?(&:nil?)
        end
      end
      abort_with('duplicate catalog Adventure IDs') unless seen.uniq == seen
      missing = @ids - targets.map { |t| t.fetch('id') }
      abort_with("missing target IDs: #{missing.join(', ')}") unless missing.empty?
      targets
    end

    def interpretation(catalog_path)
      abort_with("catalog missing or wrong basename: #{catalog_path}") unless File.file?(catalog_path) && File.basename(catalog_path) == catalog_filename
      @catalog_sha256 = sha256(catalog_path)
      targets = select_targets(read_rows(catalog_path))
      level_ids = targets.select { |t| t.fetch('needs_levels') }.map { |t| t.fetch('id') }
      dimensions = dimension_contracts
      {
        'version' => 1, 'contract_type' => 'adventure_ingest_v1', 'queue' => queue,
        'catalog_filename' => catalog_filename, 'catalog_path' => catalog_path, 'catalog_sha256' => catalog_sha256,
        'expected_adventure_count' => targets.length,
        'expected_ordinary_calls' => targets.length * dimensions.length,
        'expected_levels_calls' => level_ids.length,
        'expected_calls' => targets.length * dimensions.length + level_ids.length,
        'adventures_per_pack' => 5, 'adventure_order' => targets.map { |t| t.fetch('id') },
        'source_boundary_clamp_adventure_ids' => clamp_ids, 'source_boundary_clamp_max_gaps' => clamp_gaps,
        'dimension_order' => dimensions.map { |d| d.fetch('name') }, 'dimension_contracts' => dimensions,
        'conditional_dimension_order' => ['Levels'], 'levels_contract' => levels_contract,
        'levels_inference_adventure_ids' => level_ids,
        'preserved_levels_adventure_ids' => targets.reject { |t| t.fetch('needs_levels') }.map { |t| t.fetch('id') },
        'deferred_columns' => DEFERRED_COLUMNS, 'selected_adventures' => targets,
        'qualification_files' => QUALIFICATION_PATHS.values.to_h { |path| [path, sha256(File.join(root, path))] }
      }
    end

    def scorer_check!
      abort_with('scorer executable missing') unless File.executable?(File.join(scorer_repo, 'bin/af-score'))
      commit = git_head(scorer_repo)
      [[], ['--cached']].each do |args|
        _out, _err, status = Open3.capture3('git', '-C', scorer_repo, 'diff', *args, '--quiet', '--',
                                          'lib/af_scoring', 'config/default.yml', 'config/source_mappings.yml')
        abort_with('scorer protected paths have uncommitted changes') unless status.success?
      end
      commit
    end

  end
end
