# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "time"
require "tmpdir"
require "yaml"
require_relative "../adventure_ingest"
require_relative "../production_backlog_runtime_contract"
require_relative "current_runtime_policy"
require_relative "scorer_environment"
require_relative "frozen_input_identities"
require_relative "scorer_input_selection"
require_relative "roots"

module AFWorkloads
  class WorkloadCompiler
    CONTRACT_VERSION = "afw-workload/v0.1"
    WLO_CONTRACT_VERSION = "wlo-execution-plan/v0.3"
    COMPATIBILITY_WLO_CONTRACT_VERSION = "wlo-execution-plan/v0.2"
    DYNAMIC_WLO_CONTRACT_VERSION = WLO_CONTRACT_VERSION
    MINIMUM_CONTEXT_WLO_CONTRACT_VERSION = "wlo-execution-plan/v0.4"
    LEGACY_WLO_CONTRACT_VERSION = "wlo-execution-plan/v0.1"
    ID_PATTERN = /\A[a-z0-9][a-z0-9_-]{0,63}\z/
    CORE_RUNTIME_MAX_TOKENS = 8192
    PHASE_ENV_NAMES = %w[
      AF_SOCIAL_INTERACTION_GUARDRAIL_PROFILE
      AF_INVESTIGATION_GUARDRAIL_PROFILE
    ].freeze

    attr_reader :root, :workload_id, :catalog_path, :ids, :dimensions, :scorer_repo, :worker_name,
                :plan_contract_version

    def initialize(root:, workload_id:, catalog_path:, ids:, dimensions: [], scorer_repo: nil, worker_name: nil,
                   plan_version: nil, required_context_length: nil, require_fully_gpu_resident: false,
                   required_gpu_id: nil, minimum_context_length: nil, scorer_config: nil,
                   staged_scoring: nil, batch_factory: nil, preflight_runner: nil, source_preparer: nil,
                   git_head_resolver: nil, out: $stdout, data_root: nil)
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
      if !minimum_context_length.nil? &&
         (plan_contract_version != MINIMUM_CONTEXT_WLO_CONTRACT_VERSION || !required_context_length.nil?)
        raise Error, "minimum context requires explicit plan version 0.4 without an exact context requirement"
      end
      @ollama_capabilities = capability_requirements(
        required_context_length, require_fully_gpu_resident, required_gpu_id, minimum_context_length
      )
      if dynamic_plan? && @ollama_capabilities.empty?
        raise Error, "#{plan_contract_version.delete_prefix('wlo-execution-plan/')} needs explicit context length and full GPU residency requirements"
      end
      @batch_factory = batch_factory || method(:default_batch)
      @preflight_runner = preflight_runner || method(:run_preflight)
      @source_preparer = source_preparer || method(:run_source_preparation)
      @git_head_resolver = git_head_resolver || method(:git_head)
      @staged_scoring = if staged_scoring.nil? || staged_scoring.respond_to?(:validate_catalog!)
                          staged_scoring
                        else
                          StagedScoringInput.new(root: @root, config: staged_scoring)
                        end
      @out = out
      validate_inputs!
    end

    def build
      if @split
        [workload_dir, generated_workload_dir, results_workload_dir].each { |path| Roots.owned(root, path) }
      end
      staged_context = @staged_scoring&.validate_catalog!(
        catalog_path:, workload_id:, ids:
      )
      destination = workload_dir
      generated_destination = generated_workload_dir
      results_destination = results_workload_dir
      if File.exist?(destination) && !File.directory?(destination)
        raise Error, "workload manifest path is not a directory: #{destination}"
      end
      existing = [generated_destination, results_destination].select { |path| File.exist?(path) }
      unless existing.empty?
        raise Error, "generated workload artifacts already exist: #{existing.join(', ')}"
      end
      reuse_manifest = File.directory?(destination)
      # Existing manifests keep their original guarantees and bytes. New
      # forward manifests opt into the strict runtime identity envelope.
      @identity_contract = dynamic_plan? && (!reuse_manifest ||
        YAML.safe_load_file(File.join(destination, "snapshot.yml"), aliases: true).key?(FrozenInputIdentities::MARKER))
      if reuse_manifest && @identity_contract
        marker = YAML.safe_load_file(File.join(destination, "snapshot.yml"), aliases: true)[FrozenInputIdentities::MARKER]
        raise Error, "invalid frozen input identity contract" unless marker == FrozenInputIdentities::VERSION
      end
      @source_identities = {}

      announce_start
      batch = @batch_factory.call
      snapshot = batch.interpretation(catalog_path)
      scorer_commit = batch.scorer_check!
      selected_dimensions = select_dimensions(snapshot)
      model_config = load_model_config
      runtime_payloads = batch.runtime_payloads
      operations = operations_for(snapshot, selected_dimensions)
      raise Error, "workload has no runnable cases" if operations.empty?
      announce_plan(snapshot, operations)

      Dir.mktmpdir("afw-workload-build", @split ? root : nil) do |tmp|
        manifest_staging = File.join(tmp, "manifest", workload_id)
        generated_staging = File.join(tmp, "generated", workload_id)
        prepare_directories(manifest_staging: manifest_staging, generated_staging: generated_staging)
        prepared_sources = prepare_shared_sources(
          cache_root: File.join(tmp, "prepared-source"),
          runtime_payloads: runtime_payloads,
          selected_dimensions: selected_dimensions,
          operations: operations
        )
        rows = []
        jobs = []
        case_counts = operations.each_with_object(Hash.new(0)) do |(adventure, _dimension), counts|
          counts[adventure.fetch("id")] += 1
        end
        completed_by_adventure = Hash.new(0)
        current_adventure_id = nil

        operations.each_with_index do |(adventure, dimension), index|
          adventure_id = adventure.fetch("id")
          if adventure_id != current_adventure_id
            @out.puts
            @out.puts "#{adventure_label(adventure)} (#{case_counts.fetch(adventure_id)} cases)"
            current_adventure_id = adventure_id
          end

          @out.print "  [#{index + 1}/#{operations.length}] #{dimension.fetch('name')} ... "
          @out.flush
          begin
            case_data = build_case(
              generated_staging: generated_staging,
              adventure: adventure,
              dimension: dimension,
              runtime_payloads: runtime_payloads,
              scorer_commit: scorer_commit,
              model_config: model_config,
              prepared_source_path: prepared_sources.fetch(adventure_id), staged_context:
            )
          rescue Interrupt
            @out.puts "INTERRUPTED"
            raise
          rescue StandardError
            @out.puts "FAIL"
            raise
          end
          @out.puts "PASS"

          rows << case_index_row(case_data)
          jobs << wlo_job(case_data)
          completed_by_adventure[adventure_id] += 1
          if completed_by_adventure.fetch(adventure_id) == case_counts.fetch(adventure_id)
            @out.puts "  COMPLETE #{adventure_id}: #{completed_by_adventure.fetch(adventure_id)}/#{case_counts.fetch(adventure_id)} cases"
          end
        end

        @out.puts
        @out.puts "Writing WLO execution plan..."
        @out.flush
        plan = build_plan(jobs, operations, model_config)
        plan_bytes = JSON.pretty_generate(plan) + "\n"
        File.write(File.join(manifest_staging, "execution-plan.json"), plan_bytes)
        write_case_index(File.join(manifest_staging, "case_index.csv"), rows)
        write_snapshot(
          File.join(manifest_staging, "snapshot.yml"),
          snapshot: snapshot,
          scorer_commit: scorer_commit,
          selected_dimensions: selected_dimensions,
          case_count: jobs.length,
          plan_sha256: Digest::SHA256.hexdigest(plan_bytes), staged_context:,
          generated_at: reuse_manifest ? existing_generated_at(destination) : nil
        )
        finalize_staged_scoring!(manifest_staging, generated_staging, staged_context) if staged_context

        if reuse_manifest
          verify_existing_manifest!(destination, manifest_staging)
          materialize_generated_workload!(generated_staging, generated_destination)
        else
          materialize_workload!(
            manifest_staging: manifest_staging,
            generated_staging: generated_staging,
            manifest_destination: destination,
            generated_destination: generated_destination
          )
        end
      end

      announce_complete(destination, operations.length)
      destination
    rescue AdventureIngest::Error, Errno::ENOENT, Errno::EACCES => e
      raise Error, e.message
    end

    private

    # Resolve explicit producer selection to its wire version, preserving the
    # historical default. Returns a version string or raises Error on conflict.
    def resolve_plan_version(version)
      return worker_name ? LEGACY_WLO_CONTRACT_VERSION : WLO_CONTRACT_VERSION if version.nil?
      unless %w[0.2 0.3 0.4].include?(version) && !worker_name
        raise Error, "plan version must be 0.2, 0.3 or 0.4 without a static worker; omit version for legacy v0.1"
      end
      return MINIMUM_CONTEXT_WLO_CONTRACT_VERSION if version == "0.4"

      version == "0.3" ? DYNAMIC_WLO_CONTRACT_VERSION : COMPATIBILITY_WLO_CONTRACT_VERSION
    end

    # Return whether the selected wire version uses dynamic placement; no errors.
    def dynamic_plan?
      [DYNAMIC_WLO_CONTRACT_VERSION, MINIMUM_CONTEXT_WLO_CONTRACT_VERSION].include?(plan_contract_version)
    end

    # Build scheduling requirements from explicit exact/minimum context and GPU
    # inputs. Returns a capability hash; raises Error for malformed combinations.
    # This does not modify scorer runtime configuration or qualification evidence.
    def capability_requirements(context, gpu_resident, gpu_id, minimum_context)
      context_field = minimum_context.nil? ? "required_context_length" : "minimum_context_length"
      context = minimum_context unless minimum_context.nil?
      return {} if context.nil? && gpu_resident == false && gpu_id.nil?
      if worker_name || !context.is_a?(Integer) || !context.positive? || gpu_resident != true
        raise Error, "capability requirements need a logical plan, positive context length, and full GPU residency"
      end
      requirements = { context_field => context, "require_fully_gpu_resident" => true }
      unless gpu_id.nil?
        unless gpu_id.is_a?(String) && !gpu_id.strip.empty? && gpu_id.length <= 256
          raise Error, "required GPU identity must be a non-empty string of at most 256 characters"
        end
        requirements["required_gpu_id"] = gpu_id
      end
      requirements
    end

    def announce_start
      @out.puts "AFW workload build"
      @out.puts "  Workload: #{workload_id}"
      @out.puts "  Catalog: #{catalog_path}"
      @out.puts "  Requested adventures: #{ids.length}"
      if dynamic_plan?
        @out.puts "  WLO plan: #{plan_contract_version}"
        @out.puts "  Execution placement: selected later by WLO dynamic worker registry"
      else
        @out.puts(worker_name ? "  Legacy worker: #{worker_name}" : "  Execution placement: selected later by WLO profile")
      end
      @out.puts "  Model inference during build: none"
      @out.puts "  Paid API cost during build: $0"
      @out.puts
      @out.puts "Resolving production scoring intent..."
      @out.flush
    end

    def announce_plan(snapshot, operations)
      @out.puts "Resolved workload"
      @out.puts "  Adventures: #{snapshot.fetch('selected_adventures').length}"
      @out.puts "  Cases / AFSU preflights: #{operations.length}"
      @out.puts "  Final workload is materialized only after every preflight passes."
      @out.puts
      @out.puts "Rendering zero-inference AFSU preflights..."
      @out.flush
    end

    def announce_complete(destination, case_count)
      @out.puts
      @out.puts "AFW workload build complete"
      @out.puts "  Preflights: #{case_count}/#{case_count} PASS"
      @out.puts "  Manifest: #{destination}"
      @out.puts "  Generated build: #{generated_workload_dir}"
      @out.puts "  Results: #{results_workload_dir}"
      @out.puts "  WLO plan: #{File.join(destination, 'execution-plan.json')}"
      @out.puts "  Model inference: 0"
      @out.puts "  Paid API cost: $0"
      @out.flush
    end

    def adventure_label(adventure)
      id = adventure.fetch("id")
      title = adventure["title"].to_s.strip
      title.empty? ? id : "#{id} — #{title}"
    end

    def validate_inputs!
      raise Error, "invalid workload id #{workload_id.inspect}" unless workload_id.match?(ID_PATTERN)
      raise Error, "catalog not found: #{catalog_path}" unless File.file?(catalog_path)
      raise Error, "catalog must be an .xlsx file" unless File.extname(catalog_path).downcase == ".xlsx"
      raise Error, "scorer executable missing: #{scorer_repo}" unless File.executable?(File.join(scorer_repo, "bin", "af-score"))
      raise Error, "worker name must be non-empty" if worker_name&.empty?
    end

    def workload_dir
      File.join(root, "workloads", workload_id)
    end

    def generated_workload_dir
      File.join(root, "build", "workloads", workload_id)
    end

    def results_workload_dir
      File.join(root, "output", "workloads", workload_id, "results")
    end

    def default_batch
      AdventureIngest::Batch.new(
        root: @code_root,
        batch: 1,
        catalog: File.basename(catalog_path),
        ids: ids,
        scorer_repo: scorer_repo
      )
    end

    # Resolve requested forward dimensions without changing historical source
    # contracts. Returns contracts; raises Error for unknown/duplicate requests
    # or candidate EE capabilities outside its accepted profile.
    def select_dimensions(snapshot)
      available = snapshot.fetch("dimension_contracts") + [snapshot.fetch("levels_contract")]
      available = available.map { |dimension| CurrentRuntimePolicy.select_dimension(dimension, legacy: !dynamic_plan?) }
      by_name = available.to_h { |row| [row.fetch("name"), row] }
      unknown = dimensions - by_name.keys
      raise Error, "unknown requested dimension(s): #{unknown.join(', ')}" unless unknown.empty?
      raise Error, "requested dimensions must be unique" unless dimensions.uniq == dimensions

      selected = dimensions.empty? ? available : dimensions.map { |name| by_name.fetch(name) }
      selected.each { |dimension| CurrentRuntimePolicy.validate_capabilities!(dimension, @ollama_capabilities) }
      selected
    end

    def operations_for(snapshot, selected_dimensions)
      snapshot.fetch("selected_adventures").flat_map do |adventure|
        selected_dimensions.filter_map do |dimension|
          next if dimension.fetch("name") == "Levels" && !adventure.fetch("needs_levels")
          [adventure, dimension]
        end
      end
    end

    def prepare_shared_sources(cache_root:, runtime_payloads:, selected_dimensions:, operations:)
      FileUtils.mkdir_p(cache_root)
      runtime_path = File.join(cache_root, "source-runtime.yml")
      File.write(
        runtime_path,
        YAML.dump(shared_source_runtime_payload(runtime_payloads, selected_dimensions))
      )

      adventures = operations.map(&:first).uniq { |adventure| adventure.fetch("id") }
      @out.puts
      @out.puts "Preparing shared canonical source cache..."
      @out.flush

      adventures.each_with_index.to_h do |adventure, index|
        adventure_id = adventure.fetch("id")
        destination = File.join(cache_root, "#{adventure_id.downcase}.json")
        @out.print "  [#{index + 1}/#{adventures.length}] #{adventure_id} ... "
        @out.flush
        begin
          source_arguments = {
            adventure_id: adventure_id,
            runtime_path: runtime_path,
            destination: destination
          }
          source_arguments[:environment] = ScorerEnvironment.compilation(
            "AF_LLM_PROVIDER" => "ollama"
          ) if dynamic_plan?
          if @identity_contract
            @source_identities[adventure_id] = FrozenInputIdentities.capture(
              scorer_repo: scorer_repo, runtime_path: runtime_path, adventure_id: adventure_id,
              environment: source_arguments.fetch(:environment)).merge(
                "contract_version" => FrozenInputIdentities::VERSION, "model_registry" => @model_registry_binding)
            FrozenInputIdentities.verify!(@source_identities.fetch(adventure_id))
          end
          @source_preparer.call(**source_arguments)
          raise Error, "AFSU source preparation did not write #{destination}" unless File.file?(destination)
          if @identity_contract
            FrozenInputIdentities.verify_prepared!(destination, @source_identities.fetch(adventure_id))
            FrozenInputIdentities.verify!(@source_identities.fetch(adventure_id))
          end
        rescue Interrupt
          @out.puts "INTERRUPTED"
          raise
        rescue StandardError
          @out.puts "FAIL"
          raise
        end
        @out.puts "PASS"
        [adventure_id, destination]
      end
    end

    def shared_source_runtime_payload(runtime_payloads, selected_dimensions)
      runtime_keys = selected_dimensions.map { |dimension| dimension.fetch("runtime_key") }.uniq
      policies = runtime_keys.map do |runtime_key|
        payload = deep_copy(runtime_payloads.fetch(runtime_key))
        {
          "files" => { "catalog" => catalog_path },
          "source" => deep_copy(payload.fetch("source", {}))
        }
      end
      signatures = policies.map { |payload| YAML.dump(payload) }.uniq
      if signatures.length != 1
        raise Error,
              "selected dimensions do not share one source-resolution policy; compile-time source caching is unsafe"
      end
      ScorerInputSelection.apply(policies.first, @scorer_input_selection)
    end

    def prepare_directories(manifest_staging:, generated_staging:)
      FileUtils.mkdir_p(manifest_staging)
      %w[cases runtime preflight].each { |name| FileUtils.mkdir_p(File.join(generated_staging, name)) }
    end

    def verify_existing_manifest!(destination, candidate)
      filenames = %w[execution-plan.json case_index.csv]
      filenames << "staged-scoring.json" if File.file?(File.join(candidate, "staged-scoring.json"))
      filenames << "snapshot.yml"
      actual_entries = Dir.children(destination).sort
      unless actual_entries == filenames.sort
        raise Error, "existing workload manifest entries differ from deterministic replay"
      end
      filenames.delete("snapshot.yml")
      filenames.each do |filename|
        existing_path = File.join(destination, filename)
        candidate_path = File.join(candidate, filename)
        raise Error, "existing workload manifest is incomplete: #{existing_path}" unless File.file?(existing_path)
        next if File.binread(existing_path) == File.binread(candidate_path)

        raise Error, "existing workload manifest differs from regenerated #{filename}"
      end

      existing_snapshot_path = File.join(destination, "snapshot.yml")
      candidate_snapshot_path = File.join(candidate, "snapshot.yml")
      raise Error, "existing workload manifest is incomplete: #{existing_snapshot_path}" unless File.file?(existing_snapshot_path)
      existing_snapshot = YAML.safe_load_file(existing_snapshot_path, aliases: true) || {}
      candidate_snapshot = YAML.safe_load_file(candidate_snapshot_path, aliases: true) || {}
      existing_snapshot.delete("generated_at")
      candidate_snapshot.delete("generated_at")
      return if existing_snapshot == candidate_snapshot

      raise Error, "existing workload manifest differs from regenerated snapshot.yml"
    end

    def materialize_generated_workload!(generated_staging, generated_destination)
      FileUtils.mkdir_p(File.dirname(generated_destination))
      FileUtils.mv(generated_staging, generated_destination)
    end

    def materialize_workload!(manifest_staging:, generated_staging:, manifest_destination:, generated_destination:)
      FileUtils.mkdir_p(File.dirname(manifest_destination))
      materialize_generated_workload!(generated_staging, generated_destination)
      begin
        FileUtils.mv(manifest_staging, manifest_destination)
      rescue StandardError
        FileUtils.rm_rf(generated_destination)
        raise
      end
    end

    def build_case(generated_staging:, adventure:, dimension:, runtime_payloads:, scorer_commit:, model_config:,
                   prepared_source_path:, staged_context:)
      model_alias = dimension.fetch("model_alias")
      model = qualified_model!(model_config, model_alias)
      case_id = case_id_for(adventure, dimension)
      runtime_payload = CurrentRuntimePolicy.apply(
        payload: runtime_payloads.fetch(dimension.fetch("runtime_key")),
        dimension_name: dimension.fetch("name"),
        model: model.fetch("ollama_model")
      )
      runtime_payload["files"] ||= {}
      runtime_payload["files"]["catalog"] = catalog_path
      ScorerInputSelection.apply(runtime_payload, @scorer_input_selection)
      runtime_relative = File.join("build", "workloads", workload_id, "runtime", "#{case_id}.yml")
      runtime_staging = File.join(generated_staging, "runtime", "#{case_id}.yml")
      runtime_payload[FrozenInputIdentities::MARKER] = FrozenInputIdentities::VERSION if @identity_contract
      File.write(runtime_staging, YAML.dump(runtime_payload))

      environment = environment_for(dimension)
      preflight_environment = dynamic_plan? ? compilation_environment(environment) : environment
      result_relative = File.join("output", "workloads", workload_id, "results", case_id)
      preflight_relative = File.join("build", "workloads", workload_id, "preflight", "#{case_id}.json")
      preflight_staging = File.join(generated_staging, "preflight", "#{case_id}.json")
      if @identity_contract
        FrozenInputIdentities.verify!(@source_identities.fetch(adventure.fetch("id")))
        identities = FrozenInputIdentities.capture(scorer_repo: scorer_repo, runtime_path: runtime_staging,
          adventure_id: adventure.fetch("id"), environment: preflight_environment)
        unless identities.slice(*FrozenInputIdentities::SOURCE_INPUTS) ==
               @source_identities.fetch(adventure.fetch("id")).slice(*FrozenInputIdentities::SOURCE_INPUTS)
          raise Error, "source identity changed between capture and preparation"
        end
        identities.merge!("contract_version" => FrozenInputIdentities::VERSION, "model_registry" => @model_registry_binding)
        FrozenInputIdentities.verify!(identities)
        runtime_payload[FrozenInputIdentities::DIGEST_FIELD] = FrozenInputIdentities.digest(identities)
        File.write(runtime_staging, YAML.dump(runtime_payload))
      end
      @preflight_runner.call(
        adventure_id: adventure.fetch("id"),
        dimension: dimension.fetch("name"),
        model: model.fetch("ollama_model"),
        runtime_path: runtime_staging,
        output_path: File.join(root, result_relative),
        environment: preflight_environment,
        destination: preflight_staging,
        prepared_source_path: prepared_source_path
      )

      if @identity_contract
        FrozenInputIdentities.verify!(identities)
        actual = FrozenInputIdentities.capture(scorer_repo: scorer_repo, runtime_path: runtime_staging,
          adventure_id: adventure.fetch("id"), environment: preflight_environment)
        raise Error, "operative input identity changed during preflight" unless actual == identities.slice(*actual.keys)
      end
      qualification_path = File.join(@code_root, dimension.fetch("qualification_path"))
      case_relative = File.join("build", "workloads", workload_id, "cases", "#{case_id}.yml")
      case_data = {
        "contract_version" => CONTRACT_VERSION,
        "workload_id" => workload_id,
        "case_id" => case_id,
        "adventure_id" => adventure.fetch("id"),
        "dimension" => dimension.fetch("name"),
        "profile" => dimension.fetch("profile"),
        "model_alias" => model_alias,
        "ollama_model" => model.fetch("ollama_model"),
        "qualified_model_digest" => model.fetch("qualified_manifest_sha256"),
        "catalog_path" => catalog_path,
        "catalog_sha256" => Digest::SHA256.file(catalog_path).hexdigest,
        "qualification_path" => dimension.fetch("qualification_path"),
        "qualification_sha256" => Digest::SHA256.file(qualification_path).hexdigest,
        "runtime_path" => runtime_relative,
        "runtime_sha256" => Digest::SHA256.file(runtime_staging).hexdigest,
        "preflight_path" => preflight_relative,
        "preflight_sha256" => Digest::SHA256.file(preflight_staging).hexdigest,
        "scorer_repo" => @split ? scorer_repo : relative_to_root(scorer_repo),
        "scorer_commit" => scorer_commit,
        "output_path" => result_relative,
        "environment" => environment
      }
      case_data["frozen_input_identities"] = identities if @identity_contract
      FrozenInputIdentities.verify_model!(root: @code_root, data: case_data, identities: identities) if @identity_contract
      case_data["staged_scoring"] = deep_copy(staged_context) if staged_context
      File.write(File.join(generated_staging, "cases", "#{case_id}.yml"), YAML.dump(case_data))
      case_data.merge("case_path" => case_relative)
    end

    def build_plan(jobs, operations, model_config)
      aliases = operations.map { |_adventure, dimension| dimension.fetch("model_alias") }.uniq
      pools = aliases.map do |model_alias|
        model = qualified_model!(model_config, model_alias)
        {
          "pool_id" => pool_id(model_alias),
          "requirements" => {
            "ollama" => {
              "model" => model.fetch("ollama_model"),
              "expected_digest" => model.fetch("qualified_manifest_sha256")
            }.merge(@ollama_capabilities)
          }
        }.tap do |pool|
          if worker_name
            pool["worker_names"] = [worker_name]
            pool["required_labels"] = ["local"]
            pool["max_concurrency"] = 1
            # Retain byte-for-byte key order for rebuilding historical v0.1 manifests.
            pool.replace(pool.slice("pool_id", "worker_names", "required_labels", "requirements", "max_concurrency"))
          end
        end
      end
      {
        "contract_version" => plan_contract_version,
        "plan_id" => workload_id,
        "failure_policy" => {
          "max_consecutive_failures" => 2,
          "max_total_failures" => 3
        },
        "pools" => pools,
        "jobs" => jobs
      }
    end

    def wlo_job(case_data)
      {
        "job_id" => case_data.fetch("case_id"),
        "pool_id" => pool_id(case_data.fetch("model_alias")),
        "group_id" => case_data.fetch("adventure_id"),
        "argv" => ["bin/afw-score-job", case_data.fetch("case_path")],
        "env" => case_data.fetch("environment")
      }.tap do |job|
        # Adventure grouping sets priority/reporting only in v0.3. Forward cases
        # are independent; historical backlog sequencing belongs to its handoff.
        job["depends_on_job_ids"] = [] if dynamic_plan?
      end
    end

    def environment_for(dimension)
      return legacy_environment_for(dimension) unless dynamic_plan?

      overrides = { "AF_LLM_PROVIDER" => "ollama" }
      if ProductionBacklogRuntimeContract.runtime_key_for(dimension.fetch("name"))
        overrides["AF_LLM_MAX_TOKENS"] = CORE_RUNTIME_MAX_TOKENS.to_s
      end
      overrides[dimension.fetch("env_name")] = dimension.fetch("env_value") if dimension["env_name"]
      ScorerEnvironment.plan(overrides)
    end

    def legacy_environment_for(dimension)
      env = {
        "AF_LLM_PROVIDER" => "ollama",
        "AF_LLM_MAX_TOKENS" => nil
      }
      PHASE_ENV_NAMES.each { |name| env[name] = nil }
      if ProductionBacklogRuntimeContract.runtime_key_for(dimension.fetch("name"))
        env["AF_LLM_MAX_TOKENS"] = CORE_RUNTIME_MAX_TOKENS.to_s
      end
      env[dimension.fetch("env_name")] = dimension.fetch("env_value") if dimension["env_name"]
      env
    end

    def compilation_environment(environment)
      ScorerEnvironment.compilation(environment)
    end

    def case_id_for(adventure, dimension)
      suffix = adventure.fetch("id").downcase.delete_prefix("adv-")
      "#{workload_id}-adv#{suffix}-#{dimension.fetch('slug')}"
    end

    def pool_id(model_alias)
      worker_name ? "#{model_alias}-local" : model_alias
    end

    def case_index_row(case_data)
      [
        case_data.fetch("case_id"),
        case_data.fetch("adventure_id"),
        case_data.fetch("dimension"),
        case_data.fetch("profile"),
        case_data.fetch("model_alias"),
        case_data.fetch("ollama_model"),
        case_data.fetch("qualified_model_digest"),
        case_data.fetch("qualification_sha256"),
        case_data.fetch("runtime_sha256"),
        case_data.fetch("preflight_sha256"),
        case_data.fetch("case_path")
      ]
    end

    def write_case_index(path, rows)
      CSV.open(path, "w") do |csv|
        csv << %w[
          case_id adventure_id dimension profile model_alias ollama_model
          qualified_model_digest qualification_sha256 runtime_sha256 preflight_sha256 case_path
        ]
        rows.each { |row| csv << row }
      end
    end

    def write_snapshot(path, snapshot:, scorer_commit:, selected_dimensions:, case_count:, plan_sha256:, staged_context:,
                       generated_at: nil)
      document = {
        "contract_version" => CONTRACT_VERSION,
        "workload_id" => workload_id,
        "generated_at" => generated_at || Time.now.iso8601,
        "generator_commit" => Roots.generator(@code_root, @git_head_resolver),
        "scorer_repo" => @split ? scorer_repo : relative_to_root(scorer_repo),
        "scorer_commit" => scorer_commit,
        "catalog_path" => catalog_path,
        "catalog_sha256" => Digest::SHA256.file(catalog_path).hexdigest,
        "adventure_order" => snapshot.fetch("adventure_order"),
        "selected_dimensions" => selected_dimensions.map { |row| row.fetch("name") },
        "case_count" => case_count,
        "execution_plan_sha256" => plan_sha256
      }
      document[FrozenInputIdentities::MARKER] = FrozenInputIdentities::VERSION if @identity_contract
      document["staged_scoring"] = deep_copy(staged_context) if staged_context
      File.write(path, YAML.dump(document))
    end

    def existing_generated_at(destination)
      path = File.join(destination, "snapshot.yml")
      snapshot = YAML.safe_load_file(path, aliases: true)
      value = snapshot.fetch("generated_at")
      raise Error, "existing workload snapshot generated_at is invalid" unless value.is_a?(String) && !value.empty?

      value
    rescue Errno::ENOENT, Psych::Exception, KeyError, TypeError => e
      raise Error, "existing workload snapshot is invalid: #{e.message}"
    end

    def finalize_staged_scoring!(manifest_staging, generated_staging, staged_context)
      paths = {
        "plan" => File.join(manifest_staging, "execution-plan.json"),
        "snapshot" => File.join(manifest_staging, "snapshot.yml"),
        "index" => File.join(manifest_staging, "case_index.csv")
      }
      paths["generated"] = generated_staging if staged_context["schema_version"] == "af-staged-scoring-workload-binding/v0.2"
      document = @staged_scoring.finalize!(core: staged_context, paths:, catalog_path:)
      verification_path = File.join(manifest_staging, "staged-scoring.json")
      File.write(verification_path, JSON.pretty_generate(StagedScoringInput.canonical(document)) + "\n")
      reference = StagedScoringInput.file_binding(verification_path).merge(
        "path" => File.join("workloads", workload_id, "staged-scoring.json")
      )
      Dir[File.join(generated_staging, "cases", "*.yml")].each do |case_path|
        data = YAML.safe_load_file(case_path, aliases: true) || {}
        data["staged_scoring_verification"] = reference
        File.write(case_path, YAML.dump(data))
      end
      # The validator is intentionally called again after all staged workload
      # bytes exist and immediately before publication/reuse comparison.
      @staged_scoring.finalize!(core: staged_context, paths:, catalog_path:)
    end

    def run_source_preparation(adventure_id:, runtime_path:, destination:, environment: nil)
      command = [
        File.join(scorer_repo, "bin", "af-score"),
        "--config", runtime_path,
        "--prepare-source", destination,
        adventure_id
      ]
      stdout, stderr, status = if environment
                                 Open3.capture3(environment, *command, chdir: scorer_repo)
                               else
                                 Open3.capture3(*command, chdir: scorer_repo)
                               end
      return if status.success? && File.file?(destination)

      detail = [stdout, stderr].reject(&:empty?).join("\n").strip
      raise Error, "AFSU source preparation failed for #{adventure_id}: #{detail}"
    end

    def run_preflight(adventure_id:, dimension:, model:, runtime_path:, output_path:, environment:, destination:, prepared_source_path:)
      command = [
        File.join(scorer_repo, "bin", "af-score"),
        "--config", runtime_path,
        "--model", model,
        "--dimension", dimension,
        "--output", output_path,
        "--preflight",
        "--render-preflight", destination,
        "--prepared-source", prepared_source_path,
        adventure_id
      ]
      stdout, stderr, status = Open3.capture3(environment, *command, chdir: scorer_repo)
      return if status.success? && File.file?(destination)

      detail = [stdout, stderr].reject(&:empty?).join("\n").strip
      raise Error, "AFSU preflight failed for #{adventure_id} / #{dimension}: #{detail}"
    end

    def load_model_config
      path = File.join(@code_root, "config", "models.yml")
      bytes = File.binread(path)
      @model_registry_binding = FrozenInputIdentities.binding(path, bytes)
      data = YAML.safe_load(bytes, aliases: true) || {}
      models = data.fetch("models")
      raise Error, "config/models.yml models must be a mapping" unless models.is_a?(Hash)
      models.transform_keys(&:to_s)
    rescue KeyError, Psych::Exception => e
      raise Error, "invalid model config: #{e.message}"
    end

    def qualified_model!(models, alias_name)
      model = models.fetch(alias_name).transform_keys(&:to_s)
      CurrentRuntimePolicy.validate_model!(alias_name, model)
      name = model.fetch("ollama_model").to_s
      digest = model.fetch("qualified_manifest_sha256").to_s.downcase
      raise Error, "qualified model #{alias_name} lacks exact digest" unless digest.match?(/\A[0-9a-f]{64}\z/)
      { "ollama_model" => name, "qualified_manifest_sha256" => digest }
    rescue KeyError => e
      raise Error, "qualified model #{alias_name.inspect} is incomplete: #{e.message}"
    end

    def git_head(repo)
      stdout, stderr, status = Open3.capture3("git", "-C", repo, "rev-parse", "HEAD")
      raise Error, "cannot read Git HEAD for #{repo}: #{stderr.strip}" unless status.success?
      stdout.strip
    end

    def relative_to_root(path)
      Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(root)).to_s
    rescue ArgumentError
      File.expand_path(path)
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end
  end
end
