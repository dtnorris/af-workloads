# frozen_string_literal: true

require "csv"
require "digest"
require "json"
require "open3"
require "pathname"
require "time"
require "yaml"

module AFWorkloads
  # Validates frozen preparation and current immutable inputs without compiling
  # cases, rendering preflight evidence, or publishing artifacts.
  class FrozenWorkloadValidator
    SHA256 = /\A[0-9a-f]{64}\z/
    INDEX_HEADERS = %w[
      case_id adventure_id dimension profile model_alias ollama_model
      qualified_model_digest qualification_sha256 runtime_sha256 preflight_sha256 case_path
    ].freeze

    def initialize(root:, workload_id:, catalog_path:, ids:, dimensions: [], scorer_repo: nil, worker_name: nil,
                   plan_version: nil, required_context_length: nil, require_fully_gpu_resident: false,
                   required_gpu_id: nil, scorer_config: nil, staged_scoring: nil, batch_factory: nil, git_head_resolver: nil, data_root: nil)
      @code_root = File.expand_path(root)
      @split = !data_root.nil? || Roots.public_distribution?(@code_root)
      @root = @split ? Roots.data(data_root, code: @code_root) : @code_root
      if @split && (scorer_repo.to_s.strip.empty? || scorer_config.to_s.strip.empty?)
        raise Error, "select --scorer-repo and --scorer-config explicitly"
      end
      @workload_id = workload_id.to_s
      @catalog_path = File.expand_path(catalog_path)
      @ids = AdventureIngest::Batch.parse_ids(ids)
      @dimensions = Array(dimensions).map(&:to_s)
      @scorer_repo = File.expand_path(scorer_repo || "../af-cli-scoring-utility", @code_root)
      @scorer_input_selection = ScorerInputSelection.load(scorer_config)
      Roots.owned(@root, File.expand_path(@scorer_input_selection.dig("paths", "output_root"), @scorer_repo)) if @split
      @worker_name = worker_name&.to_s
      @plan_contract_version = resolve_plan_version(plan_version)
      @capabilities = capability_requirements(
        required_context_length, require_fully_gpu_resident, required_gpu_id
      )
      if dynamic_plan? && @capabilities.empty?
        raise Error, "v0.3 needs explicit context length and full GPU residency requirements"
      end
      @staged_scoring = staged_scoring.nil? || staged_scoring.respond_to?(:validate_catalog!) ? staged_scoring :
        StagedScoringInput.new(root: @root, config: staged_scoring)
      @batch_factory = batch_factory || method(:default_batch)
      @git_head_resolver = git_head_resolver || method(:git_head)
      validate_inputs!
      [manifest_path, generated_path].each { |path| Roots.owned(@root, path) } if @split
    end

    def verify!(verify_generated:)
      manifest = load_manifest
      @identity_contract = false
      snapshot = manifest.fetch(:snapshot)
      if snapshot.is_a?(Hash) && snapshot.key?(FrozenInputIdentities::MARKER)
        raise Error, "invalid frozen input identity contract" unless snapshot[FrozenInputIdentities::MARKER] == FrozenInputIdentities::VERSION
        @identity_contract = true
      end
      batch = @batch_factory.call
      interpretation = batch.interpretation(@catalog_path)
      scorer_commit = batch.scorer_check!
      @scorer_commit = scorer_commit
      dimensions = select_dimensions(interpretation)
      operations = operations_for(interpretation, dimensions)
      raise Error, "workload has no runnable cases" if operations.empty?

      models = load_model_config
      validate_snapshot!(manifest.fetch(:snapshot), interpretation, dimensions, operations, scorer_commit)
      expected = expected_cases(operations, dimensions, batch.runtime_payloads, models)
      validate_plan!(manifest.fetch(:plan), expected, models)
      validate_index!(manifest.fetch(:rows), expected)
      validate_staged!(verify_generated:)
      validate_generated!(manifest.fetch(:rows), expected) if verify_generated

      {
        "manifest_files" => manifest_bindings,
        "generated_tree_sha256" => verify_generated ? tree_digest(generated_path) : nil,
        "case_ids" => expected.map { |row| row.fetch("case_id") }
      }
    rescue AdventureIngest::Error => e
      raise Error, e.message
    end

    private

    def load_manifest
      plan_bytes = File.binread(File.join(manifest_path, "execution-plan.json"))
      index_bytes = File.binread(File.join(manifest_path, "case_index.csv"))
      snapshot_bytes = File.binread(File.join(manifest_path, "snapshot.yml"))
      table = CSV.parse(index_bytes, headers: true)
      raise Error, "case index headers differ" unless table.headers == INDEX_HEADERS

      {plan: JSON.parse(plan_bytes), rows: table.map(&:to_h),
       snapshot: YAML.safe_load(snapshot_bytes, aliases: true)}
    rescue Errno::ENOENT, JSON::ParserError, CSV::MalformedCSVError, Psych::Exception => e
      raise Error, "invalid workload manifest: #{e.message}"
    end

    def validate_snapshot!(snapshot, interpretation, dimensions, operations, scorer_commit)
      expected_keys = %w[
        contract_version workload_id generated_at generator_commit scorer_repo scorer_commit catalog_path
        catalog_sha256 adventure_order selected_dimensions case_count execution_plan_sha256
      ]
      expected_keys << "staged_scoring" if @staged_scoring
      expected_keys << FrozenInputIdentities::MARKER if @identity_contract
      raise Error, "snapshot fields differ" unless snapshot.is_a?(Hash) && snapshot.keys.sort == expected_keys.sort
      Time.iso8601(snapshot.fetch("generated_at"))
      expected = {
        "contract_version" => WorkloadCompiler::CONTRACT_VERSION,
        "workload_id" => @workload_id,
        "generator_commit" => Roots.generator(@code_root, @git_head_resolver),
        "scorer_repo" => (@split ? @scorer_repo : relative_to_root(@scorer_repo)),
        "scorer_commit" => scorer_commit,
        "catalog_path" => @catalog_path,
        "catalog_sha256" => Digest::SHA256.file(@catalog_path).hexdigest,
        "adventure_order" => interpretation.fetch("adventure_order"),
        "selected_dimensions" => dimensions.map { |row| row.fetch("name") },
        "case_count" => operations.length,
        "execution_plan_sha256" => Digest::SHA256.file(File.join(manifest_path, "execution-plan.json")).hexdigest
      }
      expected["staged_scoring"] = staged_core if @staged_scoring
      expected.each { |key, value| raise Error, "snapshot #{key} differs" unless snapshot[key] == value }
    rescue ArgumentError, KeyError, TypeError => e
      raise Error, "invalid workload snapshot: #{e.message}"
    end

    def expected_cases(operations, dimensions, runtimes, models)
      operations.map do |adventure, dimension|
        model = qualified_model!(models, dimension.fetch("model_alias"))
        case_id = case_id_for(adventure, dimension)
        runtime = CurrentRuntimePolicy.apply(
          payload: deep_copy(runtimes.fetch(dimension.fetch("runtime_key"))),
          dimension_name: dimension.fetch("name"), model: model.fetch("ollama_model")
        )
        runtime["files"] ||= {}
        runtime["files"]["catalog"] = @catalog_path
        ScorerInputSelection.apply(runtime, @scorer_input_selection)
        runtime[FrozenInputIdentities::MARKER] = FrozenInputIdentities::VERSION if @identity_contract
        if @identity_contract
          Dir.mktmpdir("afw-identity-validation") do |directory|
            path = File.join(directory, "runtime.yml")
            File.write(path, YAML.dump(runtime))
            identities = FrozenInputIdentities.capture(scorer_repo: @scorer_repo, runtime_path: path,
              adventure_id: adventure.fetch("id"), environment: ScorerEnvironment.compilation(environment_for(dimension)))
            identities.merge!("contract_version" => FrozenInputIdentities::VERSION,
              "model_registry" => FrozenInputIdentities.binding(File.join(@code_root, "config/models.yml")))
            FrozenInputIdentities.verify!(identities)
            runtime[FrozenInputIdentities::DIGEST_FIELD] = FrozenInputIdentities.digest(identities)
          end
        end
        {
          "case_id" => case_id, "adventure_id" => adventure.fetch("id"),
          "dimension" => dimension.fetch("name"), "profile" => dimension.fetch("profile"),
          "model_alias" => dimension.fetch("model_alias"), "ollama_model" => model.fetch("ollama_model"),
          "qualified_model_digest" => model.fetch("qualified_manifest_sha256"),
          "qualification_path" => dimension.fetch("qualification_path"),
          "qualification_sha256" => Digest::SHA256.file(File.join(@code_root, dimension.fetch("qualification_path"))).hexdigest,
          "runtime_sha256" => Digest::SHA256.hexdigest(YAML.dump(runtime)),
          "case_path" => "build/workloads/#{@workload_id}/cases/#{case_id}.yml",
          "runtime_path" => "build/workloads/#{@workload_id}/runtime/#{case_id}.yml",
          "preflight_path" => "build/workloads/#{@workload_id}/preflight/#{case_id}.json",
          "output_path" => "output/workloads/#{@workload_id}/results/#{case_id}",
          "environment" => environment_for(dimension)
        }
      end
    end

    def validate_plan!(plan, expected, models)
      raise Error, "plan fields differ" unless plan.is_a?(Hash) && plan.keys.sort == %w[contract_version failure_policy jobs plan_id pools].sort
      raise Error, "plan contract differs" unless plan["contract_version"] == @plan_contract_version
      raise Error, "plan identity differs" unless plan["plan_id"] == @workload_id
      raise Error, "plan failure policy differs" unless plan["failure_policy"] == {"max_consecutive_failures" => 2, "max_total_failures" => 3}

      aliases = expected.map { |row| row.fetch("model_alias") }.uniq
      pools = aliases.map { |name| expected_pool(name, qualified_model!(models, name)) }
      raise Error, "plan pools differ" unless plan["pools"] == pools
      jobs = expected.map do |row|
        {"job_id" => row.fetch("case_id"), "pool_id" => pool_id(row.fetch("model_alias")),
         "group_id" => row.fetch("adventure_id"), "argv" => ["bin/afw-score-job", row.fetch("case_path")],
         "env" => row.fetch("environment")}.tap do |job|
          job["depends_on_job_ids"] = [] if dynamic_plan?
        end
      end
      raise Error, "plan jobs differ" unless plan["jobs"] == jobs
    end

    def validate_index!(rows, expected)
      raise Error, "case index enumeration differs" unless rows.length == expected.length
      rows.zip(expected).each do |row, intended|
        intended.slice(*INDEX_HEADERS).each do |key, value|
          raise Error, "case index #{key} differs" unless row[key].to_s == value.to_s
        end
        raise Error, "case index preflight digest is invalid" unless row["preflight_sha256"].to_s.match?(SHA256)
      end
    end

    def validate_generated!(rows, expected)
      expected_files = {
        "cases" => expected.map { |row| "#{row.fetch('case_id')}.yml" },
        "runtime" => expected.map { |row| "#{row.fetch('case_id')}.yml" },
        "preflight" => expected.map { |row| "#{row.fetch('case_id')}.json" }
      }
      expected_files.each do |directory, names|
        actual = Dir.children(File.join(generated_path, directory)).sort
        raise Error, "generated #{directory} file set differs" unless actual == names.sort
      end
      rows.zip(expected).each do |row, intended|
        case_path = File.join(generated_path, "cases", "#{intended.fetch('case_id')}.yml")
        data = YAML.safe_load_file(case_path, aliases: true)
        raise Error, "generated case must be a mapping" unless data.is_a?(Hash)
        if @identity_contract || data.key?("frozen_input_identities")
          raise Error, "unexpected frozen input identity metadata" unless @identity_contract
          FrozenInputIdentities.verify!(data["frozen_input_identities"])
          FrozenInputIdentities.verify_model!(root: @code_root, data: data, identities: data["frozen_input_identities"])
          actual = FrozenInputIdentities.capture(scorer_repo: @scorer_repo,
            runtime_path: File.join(@root, intended.fetch("runtime_path")), adventure_id: intended.fetch("adventure_id"),
            environment: ScorerEnvironment.compilation(intended.fetch("environment").reject { |_key, value| value.nil? }))
          raise Error, "generated input identity differs" unless actual == data["frozen_input_identities"].slice(*actual.keys)
        end
        common = intended.except("case_path")
        common.each { |key, value| raise Error, "generated case #{key} differs" unless data[key] == value }
        raise Error, "generated case preflight digest differs" unless data["preflight_sha256"] == row["preflight_sha256"]
        raise Error, "generated case contract differs" unless data["contract_version"] == WorkloadCompiler::CONTRACT_VERSION
        raise Error, "generated case workload differs" unless data["workload_id"] == @workload_id
        raise Error, "generated case catalog differs" unless data["catalog_path"] == @catalog_path && data["catalog_sha256"] == Digest::SHA256.file(@catalog_path).hexdigest
        raise Error, "generated case scorer differs" unless data["scorer_repo"] == (@split ? @scorer_repo : relative_to_root(@scorer_repo))
        raise Error, "generated case scorer commit differs" unless data["scorer_commit"] == @scorer_commit
        raise Error, "generated runtime bytes differ" unless Digest::SHA256.file(File.join(@root, data.fetch("runtime_path"))).hexdigest == row.fetch("runtime_sha256")
        raise Error, "generated preflight bytes differ" unless Digest::SHA256.file(File.join(@root, data.fetch("preflight_path"))).hexdigest == row.fetch("preflight_sha256")
      end
    rescue Errno::ENOENT, Psych::Exception, KeyError, TypeError => e
      raise Error, "invalid generated workload: #{e.message}"
    end

    def validate_staged!(verify_generated:)
      return unless @staged_scoring

      if verify_generated
        @staged_scoring.verify_prepared!(workload_id: @workload_id)
      else
        @staged_scoring.verify_manifest_only!(workload_id: @workload_id)
      end
    end

    def staged_core
      @staged_core ||= @staged_scoring.validate_catalog!(
        catalog_path: @catalog_path, workload_id: @workload_id, ids: @ids
      )
    end

    def manifest_bindings
      Dir.children(manifest_path).sort.to_h do |name|
        path = File.join(manifest_path, name)
        [name, StagedScoringInput.file_binding(path)]
      end
    end

    def tree_digest(path)
      entries = Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH).reject { |entry| [".", ".."].include?(File.basename(entry)) }
      signature = entries.sort.map do |entry|
        relative = Pathname.new(entry).relative_path_from(Pathname.new(path)).to_s
        File.directory?(entry) ? [relative, "directory"] : [relative, File.size(entry), Digest::SHA256.file(entry).hexdigest]
      end
      Digest::SHA256.hexdigest(JSON.generate(signature))
    end

    def resolve_plan_version(version)
      if version.nil?
        return @worker_name ? WorkloadCompiler::LEGACY_WLO_CONTRACT_VERSION :
          WorkloadCompiler::DYNAMIC_WLO_CONTRACT_VERSION
      end
      unless %w[0.2 0.3].include?(version) && !@worker_name
        raise Error, "plan version must be 0.2 or 0.3 without a static worker; omit version for legacy v0.1"
      end
      version == "0.3" ? WorkloadCompiler::DYNAMIC_WLO_CONTRACT_VERSION :
        WorkloadCompiler::COMPATIBILITY_WLO_CONTRACT_VERSION
    end

    def capability_requirements(context, gpu_resident, gpu_id)
      return {} if context.nil? && gpu_resident == false && gpu_id.nil?
      if @worker_name || !context.is_a?(Integer) || !context.positive? || gpu_resident != true
        raise Error, "capability requirements need a logical plan, positive context length, and full GPU residency"
      end
      result = {"required_context_length" => context, "require_fully_gpu_resident" => true}
      if gpu_id
        unless gpu_id.is_a?(String) && !gpu_id.strip.empty? && gpu_id.length <= 256
          raise Error, "required GPU identity must be a non-empty string of at most 256 characters"
        end
        result["required_gpu_id"] = gpu_id
      end
      result
    end

    def expected_pool(name, model)
      pool = {"pool_id" => pool_id(name), "requirements" => {"ollama" => {
        "model" => model.fetch("ollama_model"), "expected_digest" => model.fetch("qualified_manifest_sha256")
      }.merge(@capabilities)}}
      return pool unless @worker_name

      {"pool_id" => pool.fetch("pool_id"), "worker_names" => [@worker_name], "required_labels" => ["local"],
       "requirements" => pool.fetch("requirements"), "max_concurrency" => 1}
    end

    # Resolve the same forward contracts as compilation. Returns contracts;
    # raises Error for unsupported requests or candidate capabilities.
    def select_dimensions(snapshot)
      available = snapshot.fetch("dimension_contracts") + [snapshot.fetch("levels_contract")]
      available = available.map { |dimension| CurrentRuntimePolicy.select_dimension(dimension, legacy: !dynamic_plan?) }
      by_name = available.to_h { |row| [row.fetch("name"), row] }
      raise Error, "unknown requested dimensions" unless (@dimensions - by_name.keys).empty?
      raise Error, "requested dimensions must be unique" unless @dimensions.uniq == @dimensions
      selected = @dimensions.empty? ? available : @dimensions.map { |name| by_name.fetch(name) }
      selected.each { |dimension| CurrentRuntimePolicy.validate_capabilities!(dimension, @capabilities) }
      selected
    end

    def operations_for(snapshot, dimensions)
      snapshot.fetch("selected_adventures").flat_map do |adventure|
        dimensions.filter_map do |dimension|
          next if dimension.fetch("name") == "Levels" && !adventure.fetch("needs_levels")
          [adventure, dimension]
        end
      end
    end

    def environment_for(dimension)
      return legacy_environment_for(dimension) unless dynamic_plan?
      overrides = {"AF_LLM_PROVIDER" => "ollama"}
      if ProductionBacklogRuntimeContract.runtime_key_for(dimension.fetch("name"))
        overrides["AF_LLM_MAX_TOKENS"] = WorkloadCompiler::CORE_RUNTIME_MAX_TOKENS.to_s
      end
      overrides[dimension.fetch("env_name")] = dimension.fetch("env_value") if dimension["env_name"]
      ScorerEnvironment.plan(overrides)
    end

    def legacy_environment_for(dimension)
      env = {"AF_LLM_PROVIDER" => "ollama", "AF_LLM_MAX_TOKENS" => nil}
      WorkloadCompiler::PHASE_ENV_NAMES.each { |name| env[name] = nil }
      if ProductionBacklogRuntimeContract.runtime_key_for(dimension.fetch("name"))
        env["AF_LLM_MAX_TOKENS"] = WorkloadCompiler::CORE_RUNTIME_MAX_TOKENS.to_s
      end
      env[dimension.fetch("env_name")] = dimension.fetch("env_value") if dimension["env_name"]
      env
    end

    def load_model_config
      YAML.safe_load_file(File.join(@code_root, "config", "models.yml"), aliases: true).fetch("models")
    rescue Psych::Exception, KeyError => e
      raise Error, "invalid model config: #{e.message}"
    end

    def qualified_model!(models, name)
      model = models.fetch(name)
      CurrentRuntimePolicy.validate_model!(name, model)
      digest = model.fetch("qualified_manifest_sha256").to_s.downcase
      raise Error, "qualified model #{name} lacks exact digest" unless digest.match?(SHA256)
      {"ollama_model" => model.fetch("ollama_model").to_s, "qualified_manifest_sha256" => digest}
    rescue KeyError => e
      raise Error, "qualified model #{name} is incomplete: #{e.message}"
    end

    def validate_inputs!
      raise Error, "invalid workload id" unless @workload_id.match?(WorkloadCompiler::ID_PATTERN)
      if !@worker_name.nil? && (@worker_name.empty? || @worker_name.match?(/[\s,]/))
        raise Error, "worker name must be non-empty and contain no whitespace or commas"
      end
      raise Error, "catalog not found: #{@catalog_path}" unless File.file?(@catalog_path)
      raise Error, "catalog must be an .xlsx file" unless File.extname(@catalog_path).downcase == ".xlsx"
      raise Error, "scorer executable missing: #{@scorer_repo}" unless File.executable?(File.join(@scorer_repo, "bin", "af-score"))
    end

    def default_batch
      AdventureIngest::Batch.new(root: @code_root, batch: 1, catalog: File.basename(@catalog_path),
                                 ids: @ids, scorer_repo: @scorer_repo)
    end

    def git_head(path)
      stdout, status = Open3.capture2("git", "-C", path, "rev-parse", "HEAD")
      raise Error, "cannot resolve git HEAD for #{path}" unless status.success?
      stdout.strip
    end

    def dynamic_plan? = @plan_contract_version == WorkloadCompiler::DYNAMIC_WLO_CONTRACT_VERSION
    def pool_id(name) = @worker_name ? "#{name}-local" : name
    def case_id_for(adventure, dimension) = "#{@workload_id}-adv#{adventure.fetch('id').downcase.delete_prefix('adv-')}-#{dimension.fetch('slug')}"
    def manifest_path = File.join(@root, "workloads", @workload_id)
    def generated_path = File.join(@root, "build", "workloads", @workload_id)

    def relative_to_root(path)
      Pathname.new(path).relative_path_from(Pathname.new(@root)).to_s
    rescue ArgumentError
      path
    end

    def deep_copy(value) = Marshal.load(Marshal.dump(value))
  end
end
