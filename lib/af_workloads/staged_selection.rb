# frozen_string_literal: true

require "csv"
require "tempfile"
require "rbconfig"
require_relative "workload_compiler"
require_relative "staged_scoring_input"

module AFWorkloads
  # AFW owns qualification. The caller supplies an authority already independently
  # validated by pipeline; this document alone never grants allocation authority.
  class StagedSelection
    VERSION = "afw-staged-selection/v0.1"
    WORKLOAD_VERSION = "af-staged-scoring-workload-binding/v0.2"
    SHEETS = ["Adventure Catalog", "AMC >100pg"].freeze
    # The pinned owner identifies its produced version. Its v0.2 replay validator
    # re-resolves all source/content/policy/target fields without provider execution.
    VERIFY_PREPARED_SOURCE = <<~'RUBY'
      require "af_scoring"
      require "json"
      require "digest"
      scorer, runtime, path, id, expected = ARGV
      bytes = File.binread(path)
      raise "prepared source changed during validation" unless Digest::SHA256.hexdigest(bytes) == expected
      data = JSON.parse(bytes)
      version = AFScoring::Runner::PREPARED_SOURCE_CONTRACT_VERSION
      raise "prepared source version differs from pinned producer" unless data.fetch("contract_version") == version
      if version == "afsu-prepared-source/v0.2"
        config = AFScoring::Config.new(project_root: scorer, config_path: runtime,
          overrides: {"scoring" => {"dimension" => "Combat Emphasis"}})
        AFScoring::Runner.new(config: config, logger: ->(_message) {}).preflight(id, prepared_source: data)
      end
    RUBY

    # Select an optional roots-only YAML file; evaluate reloads and binds its bytes.
    # Invalid or missing explicit configuration raises Error through the owner API.
    def initialize(root:, scorer_repo:, scorer_config: nil, data_root: nil)
      @code_root = File.expand_path(root)
      if data_root || Roots.public_distribution?(@code_root)
        @data_root = Roots.data(data_root, code: @code_root)
      end
      @root = @data_root || @code_root
      @scorer = File.expand_path(scorer_repo)
      @scorer_config = scorer_config && File.expand_path(scorer_config)
    end

    def evaluate(authority:, catalog_path:)
      raise Error, "select --scorer-config explicitly" if @data_root && @scorer_config.nil?

      selection = ScorerInputSelection.load(@scorer_config)
      Roots.owned(@root, File.expand_path(selection.dig("paths", "output_root"), @scorer)) if @data_root
      config_binding = @scorer_config && StagedScoringInput.file_binding(@scorer_config).merge("path" => @scorer_config)
      ids = authority.fetch("allocation").map { |r| r.fetch("adventure_id") }
      raise Error, "allocation must be complete, nonempty and unique" if ids.empty? || ids.uniq != ids
      raise Error, "authority digest changed" unless authority.fetch("authority_id") == StagedScoringInput.digest(authority.except("authority_id"))
      raise Error, "staged bytes changed" unless File.basename(catalog_path) == authority.dig("staged_amc", "filename") &&
        StagedScoringInput.file_binding(catalog_path) == authority.fetch("staged_amc").except("filename")
      batch = batch_for(catalog_path, ids)
      dimensions = batch.dimension_contracts.map { |dimension| CurrentRuntimePolicy.select_dimension(dimension) }
      levels = batch.levels_contract
      runtimes = runtime_payloads(batch)
      scorer_commit = batch.scorer_check!
      models = YAML.safe_load_file(File.join(@code_root, "config/models.yml"), aliases: false).fetch("models")
      (dimensions + [levels]).each do |d|
        m = models.fetch(d.fetch("model_alias"))
        CurrentRuntimePolicy.validate_model!(d.fetch("model_alias"), m)
        raise Error, "qualified model identity changed" unless m.fetch("ollama_model") == d.fetch("ollama_model") &&
          m.fetch("qualified_manifest_sha256").match?(/\A[0-9a-f]{64}\z/)
      end
      sheets = read_sheets(catalog_path)
      dispositions = authority.fetch("allocation").map do |record|
        classify(batch, sheets, record, authority, dimensions, catalog_path)
      end
      selected = dispositions.select { |d| d["disposition"] == "selected-qualified" }.map { |d| d.fetch("adventure_id") }
      status = if dispositions.any? { |d| d["disposition"] == "refused" }
                 "REFUSED"
               elsif selected.empty?
                 "ALL_DEFERRED"
               else
                 "SELECTED"
               end
      inputs = (AdventureIngest::Batch::QUALIFICATION_PATHS.values + AdventureIngest::Batch::RUNTIME_SOURCE_PATHS.values + ["config/models.yml"])
        .to_h { |path| [path, StagedScoringInput.file_binding(File.join(@code_root, path))] }
      document = {
        "schema_version" => VERSION, "producer" => "af-workloads", "status" => status,
        "authority_id" => authority.fetch("authority_id"), "operation" => authority.fetch("operation"),
        "workload_id" => authority.dig("intent", "workload_id"),
        "allocation" => authority.fetch("allocation"), "base_amc" => authority.fetch("base_amc"),
        "staged_amc" => authority.fetch("staged_amc"), "selected_ids" => selected,
        "dispositions" => dispositions, "qualification_inputs" => inputs,
        "selection_contract" => %w[staged_selection.rb workload_compiler.rb current_runtime_policy.rb scorer_environment.rb ../adventure_ingest.rb].to_h { |name| [name, StagedScoringInput.file_binding(File.expand_path(name, __dir__))] },
        "dimensions" => dimensions, "levels" => levels, "runtime_policy_sha256" => StagedScoringInput.digest(runtimes),
        "scorer_commit" => scorer_commit, "execution_authorized" => false
      }
      if @scorer_config
        raise Error, "scorer configuration changed during selection" unless
          ScorerInputSelection.load(@scorer_config) == selection && StagedScoringInput.file_binding(@scorer_config) == config_binding.except("path")
        document["selection_contract"]["scorer_input_selection.rb"] = StagedScoringInput.file_binding(File.join(__dir__, "scorer_input_selection.rb"))
        document["scorer_config"] = config_binding
      end
      document["selection_id"] = StagedScoringInput.digest(document)
      document
    rescue AdventureIngest::Error, KeyError, TypeError, Psych::Exception => e
      raise Error, "invalid selection evidence: #{e.message}"
    end

    # Durable ledger is separate from the compiler's immutable workload. Replays
    # compare exact bytes under one workload lock; a refused ledger is retained.
    def select!(authority:, catalog_path:)
      document = evaluate(authority:, catalog_path:)
      id = document.fetch("workload_id")
      raise Error, "invalid workload identity" unless WorkloadCompiler::ID_PATTERN.match?(id.to_s)
      directory = File.join(@root, "workloads", ".selections", id)
      Roots.owned(@root, directory) if @data_root
      FileUtils.mkdir_p(directory)
      path = File.join(directory, "selection.json")
      publication = File.join(directory, "publication.json")
      completion_bytes = JSON.generate("selection_id" => document.fetch("selection_id")) + "\n"
      bytes = JSON.pretty_generate(StagedScoringInput.canonical(document)) + "\n"
      File.open(File.join(directory, "selection.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        raise Error, "selection inputs raced" unless evaluate(authority:, catalog_path:) == document
        if File.exist?(path)
          raise Error, "immutable selection conflict" unless File.binread(path) == bytes
          raise Error, "partial selection publication" unless File.file?(publication) && File.binread(publication) == completion_bytes
        else
          Tempfile.create(".selection-", directory) do |tmp|
            tmp.write(bytes); tmp.flush; tmp.fsync
            File.link(tmp.path, path)
          end
          raise Error, "selection inputs raced" unless evaluate(authority:, catalog_path:) == document
          Tempfile.create(".selection-publication-", directory) do |tmp|
            tmp.write(completion_bytes); tmp.flush; tmp.fsync
            File.link(tmp.path, publication)
          end
        end
        raise Error, "selection inputs raced" unless evaluate(authority:, catalog_path:) == document
      end
      [document, path]
    end

    # No caller ID selector exists here. Pipeline proves the full allocation.
    # Compiler options are deliberately bounded to the existing capability seam.
    def prepare!(staged_scoring:, catalog_path:, required_context_length:, require_fully_gpu_resident:, out: $stdout)
      authority = staged_scoring.authority!(catalog_path:)
      return {"status" => "NO_SUCCESSOR_NEEDED", "selection" => nil, "workload" => nil} unless authority
      document, path = select!(authority:, catalog_path:)
      rechecked = staged_scoring.authority!(catalog_path:)
      raise Error, "authority changed across selection publication" unless rechecked && rechecked["authority_id"] == document.fetch("authority_id")
      return {"status" => document.fetch("status"), "selection" => document, "workload" => nil} unless document["status"] == "SELECTED"
      staged_scoring.use_selection!(path:, scorer_repo: @scorer, **scorer_config_options)
      manifest = File.join(@root, "workloads", document.fetch("workload_id"))
      if File.directory?(manifest)
        staged_scoring.verify_prepared!(workload_id: document.fetch("workload_id"))
        return {"status" => "PREPARED", "selection" => document, "workload" => manifest}
      end
      workload = WorkloadCompiler.new(
        root: @code_root, data_root: @data_root, scorer_repo: @scorer, **scorer_config_options, workload_id: document.fetch("workload_id"),
        catalog_path:, ids: document.fetch("selected_ids"), staged_scoring:,
        required_context_length:, require_fully_gpu_resident:, out:
      ).build
      freeze_binding!(document, workload)
      staged_scoring.verify_prepared!(workload_id: document.fetch("workload_id"))
      {"status" => "PREPARED", "selection" => document, "workload" => workload}
    rescue Error => e
      raise unless document && path
      refused = document.fetch("dispositions").map do |d|
        d["disposition"] == "selected-qualified" ? d.merge("disposition" => "refused", "reason" => {"code" => "COMPILATION_REFUSED", "detail" => e.message}) : d
      end
      report = {"schema_version" => "afw-staged-preparation-refusal/v0.1", "status" => "REFUSED", "selection_id" => document.fetch("selection_id"),
                "dispositions" => refused, "reason" => {"code" => "PREPARATION_REFUSED", "detail" => e.message}, "workload" => nil, "execution_authorized" => false}
      bytes = JSON.pretty_generate(StagedScoringInput.canonical(report)) + "\n"
      refusal_path = File.join(File.dirname(path), "refusal-#{StagedScoringInput.digest(report)}.json")
      File.write(refusal_path, bytes, mode: "wx") unless File.exist?(refusal_path)
      report
    end

    def verify!(authority:, catalog_path:, selection_path:, workload_paths: nil, binding: nil)
      selection_path = Roots.owned(@root, selection_path) if @data_root
      selection_bytes = File.binread(selection_path)
      actual = JSON.parse(selection_bytes)
      expected = evaluate(authority:, catalog_path:)
      raise Error, "selection differs from owning evidence" unless actual == expected && selection_bytes == JSON.pretty_generate(StagedScoringInput.canonical(expected)) + "\n"
      publication = File.join(File.dirname(selection_path), "publication.json")
      raise Error, "partial selection publication" unless File.binread(publication) == JSON.generate("selection_id" => actual.fetch("selection_id")) + "\n"
      raise Error, "refused selection cannot authorize preparation" if expected["status"] == "REFUSED"
      verify_frozen!(expected, workload_paths, binding) if workload_paths || binding
      expected
    end

    private

    def freeze_binding!(selection, manifest)
      document = JSON.parse(File.binread(File.join(manifest, "staged-scoring.json")))
      binding = document.fetch("binding")
      raise Error, "selection changed at workload publication" unless binding["selection_id"] == selection.fetch("selection_id")
      directory = File.join(@root, "workloads", ".selections", selection.fetch("workload_id"))
      bytes = JSON.pretty_generate(StagedScoringInput.canonical(binding)) + "\n"
      File.open(File.join(directory, "selection.lock"), File::RDWR) do |lock|
        lock.flock(File::LOCK_EX)
        path = File.join(directory, "frozen-workload.json")
        if File.exist?(path)
          raise Error, "immutable frozen selection conflict" unless File.binread(path) == bytes
        else
          Tempfile.create(".frozen-selection-", directory) do |tmp|
            tmp.write(bytes); tmp.flush; tmp.fsync
            File.link(tmp.path, path)
          end
        end
      end
    end

    def read_sheets(catalog_path)
      require File.join(@scorer, "lib/af_scoring/errors")
      require File.join(@scorer, "lib/af_scoring/xlsx_reader")
      reader = AFScoring::XlsxReader.new(catalog_path)
      SHEETS.to_h { |name| [name, reader.rows(sheet_name: name)] }
    end

    # Prepare through the real producer and validate exact v0.2 bytes with its
    # replay API; retain v0.1 authority/policy checks under a genuine v0.1 producer.
    # Returns content-free evidence; malformed, changed or unbound inputs raise Error.
    def source_preflight!(batch, catalog_path, id, authority)
      Tempfile.create(["afw-selection-source", ".yml"]) do |tmp|
        Tempfile.create(["afw-selection-prepared-source", ".json"]) do |prepared|
          payload = runtime_payloads(batch).fetch("base")
          payload["files"]["catalog"] = File.expand_path(catalog_path)
          tmp.write(YAML.dump(payload)); tmp.flush
          _stdout, stderr, status = Open3.capture3(ScorerEnvironment.compilation("AF_LLM_PROVIDER" => "ollama"),
            File.join(@scorer, "bin/af-score"), "--config", tmp.path, "--prepare-source", prepared.path, id, chdir: @scorer)
          detail = stderr.strip.gsub(tmp.path, "<selection-runtime>").gsub(prepared.path, "<prepared-source>").gsub(@scorer, "<scorer-root>").gsub(@root, "<afw-root>").gsub(File.expand_path(catalog_path), "<staged-catalog>")
          raise Error, "source preflight refused: #{detail}" unless status.success?
          prepared_bytes = File.binread(prepared.path)
          prepared_sha256 = Digest::SHA256.hexdigest(prepared_bytes)
          data = JSON.parse(prepared_bytes)
          version = data.fetch("contract_version")
          raise Error, "unsupported source evidence" unless %w[afsu-prepared-source/v0.1 afsu-prepared-source/v0.2].include?(version) && data.dig("adventure", "id") == id
          files = %w[catalog source_registry source_file].to_h do |key|
            ref = data.fetch(key)
            actual = StagedScoringInput.file_binding(ref.fetch("path"))
            raise Error, "changed source artifact" unless ref.fetch("sha256") == actual.fetch("sha256")
            [key, actual]
          end
          raise Error, "source/catalog evidence conflicts" unless File.expand_path(data.dig("catalog", "path")) == File.expand_path(catalog_path) &&
            files["catalog"] == authority.fetch("staged_amc").except("filename") && files["source_registry"] == authority.dig("evidence", "source_registry") &&
            authority.fetch("evidence").any? { |name, ref| name.start_with?("source:") && ref == files["source_file"] }
          policy = data.fetch("source_policy")
          raise Error, "source policy widened" unless policy.is_a?(Hash)
          policy = policy.except("source_root", "source_registry_path")
          # With clamping disabled, legacy nil and the scorer's default 1 are
          # equivalent. Keep the exact policy bytes bound in the ledger digest.
          gap = policy["max_inward_boundary_clamp_gap"]
          raise Error, "source policy widened" unless policy.keys.sort == %w[allow_full_source_fallback allow_inward_boundary_clamp max_inward_boundary_clamp_gap] &&
            policy["allow_full_source_fallback"] == false && policy["allow_inward_boundary_clamp"] == false &&
            (gap.nil? || (gap.is_a?(Integer) && gap == 1))
          _stdout, stderr, status = Open3.capture3(ScorerEnvironment.compilation("AF_LLM_PROVIDER" => "ollama"),
            RbConfig.ruby, "-I#{File.join(@scorer, 'lib')}", "-e", VERIFY_PREPARED_SOURCE,
            @scorer, tmp.path, prepared.path, id, prepared_sha256, chdir: @scorer)
          detail = stderr.strip.gsub(tmp.path, "<selection-runtime>").gsub(prepared.path, "<prepared-source>").gsub(@scorer, "<scorer-root>").gsub(@root, "<afw-root>")
          raise Error, "prepared source replay refused: #{detail}" unless status.success?
          raise Error, "prepared source changed during validation" unless Digest::SHA256.file(prepared.path).hexdigest == prepared_sha256
          # Source text is temporary and never retained in the disposition ledger.
          evidence = files.merge("contract_version" => version, "source_policy_sha256" => StagedScoringInput.digest(policy))
          if version == "afsu-prepared-source/v0.2"
            evidence.merge!("prepared_source_sha256" => prepared_sha256,
              "target_eligibility_sha256" => StagedScoringInput.digest(data.fetch("target_eligibility")))
          end
          evidence
        end
      end
    rescue JSON::ParserError, KeyError, TypeError, SystemCallError => e
      raise Error, "missing/malformed source evidence: #{e.message}"
    end

    # Pass only an explicitly selected config; omitted selection preserves retained calls.
    def scorer_config_options
      @scorer_config ? {scorer_config: @scorer_config} : {}
    end

    # Apply the existing roots-only interface to each detached qualified runtime.
    # Reload on every use so missing or changed configuration cannot reuse a ledger.
    def runtime_payloads(batch)
      raise Error, "select --scorer-config explicitly" if @data_root && @scorer_config.nil?

      selection = ScorerInputSelection.load(@scorer_config)
      Roots.owned(@root, File.expand_path(selection.dig("paths", "output_root"), @scorer)) if @data_root
      batch.runtime_payloads.transform_values { |payload| ScorerInputSelection.apply(payload, selection) }
    end

    def batch_for(catalog, ids)
      AdventureIngest::Batch.new(root: @code_root, batch: 1, catalog: File.basename(catalog), ids:, scorer_repo: @scorer)
    end

    def strict_integer(value)
      number = Float(value)
      number.to_i if number.finite? && number == number.to_i
    rescue TypeError, ArgumentError
      nil
    end

    def classify(batch, sheets, record, authority, dimensions, catalog_path)
      id = record.fetch("adventure_id")
      evidence = {"allocation_sha256" => StagedScoringInput.digest(record)}
      result = {"adventure_id" => id, "disposition" => "refused", "reason" => {"code" => "INVALID_RECORD"}, "evidence" => evidence}
      rows = sheets.fetch(record.fetch("sheet"))
      headers = rows.fetch(0).map { |v| batch.canonical_header(v) }
      required = ["Adventure ID", "Adventure Title", "Source Book", "Book Publisher", "Page Count", "Start Page", "End Page", "Level Start", "Level End", *dimensions.map { |d| d.fetch("catalog_column") }]
      raise Error, "missing/duplicate catalog headers" unless (required - headers).empty? && headers.reject(&:empty?).uniq == headers.reject(&:empty?)
      matches = rows.drop(1).select { |r| r[headers.index("Adventure ID")].to_s.strip == id }
      raise Error, "missing/duplicate allocated ID" unless matches.length == 1
      row = matches.fetch(0)
      values = headers.zip(row).to_h
      evidence["catalog_row_sha256"] = StagedScoringInput.digest(values)
      raise Error, "catalog row placement conflicts" unless rows[record.fetch("row") - 1] == row
      expected = {"Adventure Title" => record.fetch("canonical_title"), "Source Book" => authority.dig("intent", "source", "source_id"), "Book Publisher" => authority.dig("intent", "source", "publisher")}
      raise Error, "source/title evidence conflicts" unless expected.all? { |k,v| !batch.blank?(v) && values[k] == v }
      start, finish, count = values.values_at("Start Page", "End Page", "Page Count").map { |v| strict_integer(v) }
      raise Error, "malformed/contradictory page evidence" unless start && finish && count && start.positive? && finish >= start && count == finish - start + 1 &&
        record.fetch("printed_pages") == {"start" => start, "end" => finish}
      left, right = values.values_at("Level Start", "Level End")
      blank = [left, right].map { |v| batch.blank?(v) }
      raise Error, "asymmetric Levels" unless blank[0] == blank[1]
      pair = blank[0] ? nil : [strict_integer(left), strict_integer(right)]
      raise Error, "invalid populated Levels" if pair && !(pair.all? { |v| v && v.between?(1, 20) } && pair[0] <= pair[1])
      raise Error, "Levels evidence conflicts" unless record["levels"] == (pair && {"start" => pair[0], "end" => pair[1]})
      score_columns = dimensions.map { |d| d.fetch("catalog_column") } + AdventureIngest::Batch::DEFERRED_COLUMNS
      raise Error, "unexpected populated scores" unless score_columns.all? { |c| batch.blank?(values[c]) }
      evidence.merge!("needs_levels" => blank[0], "page_count" => count, "source_id" => expected.fetch("Source Book"))
      if count >= 100
        result.merge!("disposition" => "legitimately-deferred", "reason" => {"code" => "OUTSIDE_QUALIFIED_PAGE_ENVELOPE", "limit_exclusive" => 100})
      else
        raise Error, "unsupported catalog sheet" unless record["sheet"] == "Adventure Catalog"
        # Existing qualification/conditional-Levels selector remains authoritative.
        batch_for(File.join(@root, authority.dig("staged_amc", "filename")), [id]).select_targets([headers, row])
        evidence["source_preflight"] = source_preflight!(batch, catalog_path, id, authority)
        result.merge!("disposition" => "selected-qualified", "reason" => {"code" => "AFW_QUALIFIED_DEFAULT"})
      end
      result
    rescue Error, AdventureIngest::Error, KeyError, IndexError => e
      result["reason"] = {"code" => "INVALID_OR_UNSUPPORTED_RECORD", "detail" => e.message}
      result
    end

    def verify_frozen!(selection, paths, binding)
      raise Error, "complete frozen selection evidence required" unless paths && binding && selection["status"] == "SELECTED"
      core = binding.except("artifacts")
      expected = {
        "schema_version" => WORKLOAD_VERSION, "authority_id" => selection.fetch("authority_id"),
        "operation_id" => selection.dig("operation", "operation_id"), "workload_id" => selection.fetch("workload_id"),
        "staged_amc" => selection.fetch("staged_amc"), "intended_ids" => selection.fetch("selected_ids"),
        "selection_id" => selection.fetch("selection_id")
      }
      raise Error, "frozen selection binding differs" unless core == expected
      published = File.join(@root, "workloads", selection.fetch("workload_id"), "staged-scoring.json")
      if File.exist?(published)
        previous = JSON.parse(File.binread(published)).fetch("binding")
        anchor = File.join(@root, "workloads", ".selections", selection.fetch("workload_id"), "frozen-workload.json")
        anchored = JSON.parse(File.binread(anchor))
        raise Error, "immutable frozen workload conflict" unless previous == binding && anchored == binding
      end
      artifacts = paths.except("generated").transform_values { |p| StagedScoringInput.file_binding(p) }
      raise Error, "workload artifact changed" unless artifacts == binding.fetch("artifacts")
      snapshot = YAML.safe_load_file(paths.fetch("snapshot"), aliases: false)
      identity_contract = snapshot.key?(FrozenInputIdentities::MARKER)
      raise Error, "invalid frozen input identity contract" if identity_contract &&
        snapshot[FrozenInputIdentities::MARKER] != FrozenInputIdentities::VERSION
      plan = JSON.parse(File.binread(paths.fetch("plan")))
      rows = CSV.read(paths.fetch("index"), headers: true).map(&:to_h)
      dimensions = selection.fetch("dimensions")
      expected_pairs = selection.fetch("dispositions").flat_map do |d|
        next [] unless d["disposition"] == "selected-qualified"
        ds = dimensions + (d.dig("evidence", "needs_levels") ? [selection.fetch("levels")] : [])
        ds.map { |dimension| [d.fetch("adventure_id"), dimension] }
      end
      raise Error, "workload coverage differs" unless rows.map { |r| r.values_at("adventure_id", "dimension") } == expected_pairs.map { |id,d| [id,d.fetch("name")] }
      raise Error, "frozen workload identity changed" unless snapshot["staged_scoring"] == core && snapshot["adventure_order"] == selection["selected_ids"] &&
        snapshot["execution_plan_sha256"] == artifacts.dig("plan", "sha256") && snapshot["case_count"] == rows.length &&
        plan["plan_id"] == selection["workload_id"] && plan["jobs"].map { |j| j["job_id"] } == rows.map { |r| r["case_id"] } &&
        plan["contract_version"] == WorkloadCompiler::WLO_CONTRACT_VERSION && plan["failure_policy"] == {"max_consecutive_failures" => 2, "max_total_failures" => 3} &&
        plan["jobs"].all? { |j| j["depends_on_job_ids"] == [] }
      generated = paths.fetch("generated")
      raise Error, "expanded case set differs" unless Dir[File.join(generated, "cases", "*.yml")].map { |p| File.basename(p, ".yml") }.sort == rows.map { |r| r.fetch("case_id") }.sort
      models = YAML.safe_load_file(File.join(@code_root, "config/models.yml"), aliases: false).fetch("models")
      runtimes = runtime_payloads(batch_for(snapshot.fetch("catalog_path"), selection.fetch("selected_ids")))
      rows.zip(expected_pairs, plan.fetch("jobs")).each do |row, (id, dimension), job|
        verification_path = File.join(File.dirname(paths.fetch("snapshot")), "staged-scoring.json")
        verification = File.file?(verification_path) ? StagedScoringInput.file_binding(verification_path).merge("path" => "workloads/#{selection.fetch('workload_id')}/staged-scoring.json") : nil
        verify_case!(selection, generated, row, id, dimension, job, plan, verification, models, runtimes, identity_contract)
      end
    end

    # Reconstruct the qualified runtime, recapture strict input identities when
    # the frozen snapshot declares them, and replay real preflight. Any drift raises Error.
    def verify_case!(selection, generated, row, id, dimension, job, plan, verification, models, runtimes, identity_contract)
      case_id = row.fetch("case_id")
      expected_case_id = "#{selection.fetch('workload_id')}-adv#{id.downcase.delete_prefix('adv-')}-#{dimension.fetch('slug')}"
      raise Error, "case identity differs" unless case_id == expected_case_id
      data = YAML.safe_load_file(File.join(generated, "cases", "#{case_id}.yml"), aliases: false)
      row.except("case_path").each do |key, value|
        raise Error, "case/index #{key} differs" unless data[key].to_s == value
      end
      model = models.fetch(dimension.fetch("model_alias"))
      raise Error, "model selection differs" unless data["model_alias"] == dimension["model_alias"] && data["ollama_model"] == model["ollama_model"] && data["qualified_model_digest"] == model["qualified_manifest_sha256"]
      raise Error, "qualification/profile differs" unless data["profile"] == dimension.fetch("profile") && data["qualification_sha256"] == selection.dig("qualification_inputs", dimension.fetch("qualification_path"), "sha256") &&
        data["scorer_commit"] == selection["scorer_commit"] && data["catalog_sha256"] == selection.dig("staged_amc", "sha256")
      pool = plan.fetch("pools").find { |p| p["pool_id"] == dimension.fetch("model_alias") }
      capabilities = pool && pool.dig("requirements", "ollama")
      CurrentRuntimePolicy.validate_model!(dimension.fetch("model_alias"), model)
      CurrentRuntimePolicy.validate_capabilities!(dimension, capabilities || {})
      raise Error, "model/capability differs" unless capabilities && capabilities["model"] == data["ollama_model"] && capabilities["expected_digest"] == data["qualified_model_digest"] &&
        capabilities["required_context_length"].is_a?(Integer) && capabilities["required_context_length"].positive? && capabilities["require_fully_gpu_resident"] == true
      prefix = "build/workloads/#{selection.fetch('workload_id')}"
      raise Error, "case plan/input differs" unless row["case_path"] == "#{prefix}/cases/#{case_id}.yml" && job["argv"] == ["bin/afw-score-job", row["case_path"]] && job["group_id"] == id && job["pool_id"] == dimension["model_alias"] && job["env"] == data["environment"]
      runtime = runtimes.fetch(dimension.fetch("runtime_key"))
      runtime = CurrentRuntimePolicy.apply(payload: runtime, dimension_name: dimension.fetch("name"), model: model.fetch("ollama_model"))
      runtime["files"]["catalog"] = data.fetch("catalog_path")
      actual_runtime = YAML.safe_load_file(File.join(generated, "runtime", "#{case_id}.yml"), aliases: false)
      overrides = {"AF_LLM_PROVIDER" => "ollama"}
      overrides["AF_LLM_MAX_TOKENS"] = WorkloadCompiler::CORE_RUNTIME_MAX_TOKENS.to_s if ProductionBacklogRuntimeContract.runtime_key_for(dimension.fetch("name"))
      overrides[dimension.fetch("env_name")] = dimension.fetch("env_value") if dimension["env_name"]
      if identity_contract
        runtime[FrozenInputIdentities::MARKER] = FrozenInputIdentities::VERSION
        Tempfile.create(["afw-selection-identities", ".yml"]) do |tmp|
          tmp.write(YAML.dump(runtime)); tmp.flush
          identities = FrozenInputIdentities.capture(scorer_repo: @scorer, runtime_path: tmp.path,
            adventure_id: id, environment: ScorerEnvironment.compilation(overrides))
          identities.merge!("contract_version" => FrozenInputIdentities::VERSION,
            "model_registry" => FrozenInputIdentities.binding(File.join(@code_root, "config/models.yml")))
          FrozenInputIdentities.verify!(identities)
          FrozenInputIdentities.verify_model!(root: @code_root, data:, identities:)
          raise Error, "case frozen input identities differ" unless data["frozen_input_identities"] == identities
          runtime[FrozenInputIdentities::DIGEST_FIELD] = FrozenInputIdentities.digest(identities)
        end
      end
      raise Error, "qualified runtime differs" unless actual_runtime == runtime
      raise Error, "environment differs" unless data["environment"] == ScorerEnvironment.plan(overrides)
      {"runtime" => "yml", "preflight" => "json"}.each do |kind, ext|
        relative = "#{prefix}/#{kind}/#{case_id}.#{ext}"
        raise Error, "#{kind} path differs" unless data["#{kind}_path"] == relative
        raise Error, "#{kind} bytes differ" unless Digest::SHA256.file(File.join(generated, kind, "#{case_id}.#{ext}")).hexdigest == row.fetch("#{kind}_sha256")
      end
      raise Error, "case verification reference differs" unless data["staged_scoring_verification"] == verification
      raise Error, "case provenance differs" unless data["output_path"] == "output/workloads/#{selection.fetch('workload_id')}/results/#{case_id}" &&
        File.expand_path(data.fetch("scorer_repo"), @root) == @scorer && data["qualification_path"] == dimension["qualification_path"] &&
        File.basename(data.fetch("catalog_path")) == selection.dig("staged_amc", "filename") && StagedScoringInput.file_binding(data.fetch("catalog_path")) == selection.fetch("staged_amc").except("filename")
      raise Error, "case authority differs" unless data["staged_scoring"] == {
        "schema_version" => WORKLOAD_VERSION, "authority_id" => selection["authority_id"], "operation_id" => selection.dig("operation", "operation_id"),
        "workload_id" => selection["workload_id"], "staged_amc" => selection["staged_amc"], "intended_ids" => selection["selected_ids"], "selection_id" => selection["selection_id"]
      }
      # Reuse AFSU's public zero-inference replay, as the existing scorer adapter
      # does. A forged preflight JSON/hash never substitutes for source evidence.
      Tempfile.create(["afw-selection-preflight", ".json"]) do |tmp|
        _stdout, stderr, status = Open3.capture3(ScorerEnvironment.compilation(overrides), File.join(@scorer, "bin/af-score"),
          "--config", File.join(generated, "runtime", "#{case_id}.yml"), "--model", data.fetch("ollama_model"),
          "--dimension", dimension.fetch("name"), "--output", File.join(@root, data.fetch("output_path")),
          "--preflight", "--render-preflight", tmp.path, id, chdir: @scorer)
        raise Error, "preflight evidence differs: #{stderr.strip}" unless status.success? && Digest::SHA256.file(tmp.path).hexdigest == row.fetch("preflight_sha256")
      end
    end
  end
end
