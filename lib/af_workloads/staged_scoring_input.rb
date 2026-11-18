# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "pathname"
require "tempfile"
require "yaml"

module AFWorkloads
  # Consumer of af-data-pipeline's public staged-scoring authority contract.
  # It owns no ingest lifecycle, authority issuance, or catalog-role mutation.
  class StagedScoringInput
    DOCUMENT_VERSION = "afw-staged-scoring-input/v0.1"
    PROJECTION_VERSION = "af-staged-scoring-authority-projection/v0.1"
    AUTHORITY_VERSION = "af-staged-scoring-authority/v0.1"
    WORKLOAD_VERSION = "af-staged-scoring-workload-binding/v0.1"
    SHA256_RE = /\A[0-9a-f]{64}\z/
    REQUIRED_CONFIG = %i[pipeline_root inputs_path store_root project_state_path operation_id].freeze
    OPTIONAL_CONFIG = %i[mode command_runner selection_path scorer_repo scorer_config].freeze

    attr_reader :root

    def self.file_binding(path)
      {"sha256" => Digest::SHA256.file(path).hexdigest, "bytes" => File.size(path)}
    end

    def self.canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
      when Array then value.map { |entry| canonical(entry) }
      else value
      end
    end

    def self.digest(value)
      Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
    end

    def self.verify_workload!(root:, workload_id:, expected_reference: nil, command_runner: nil)
      manifest = File.join(File.expand_path(root), "workloads", workload_id.to_s)
      document_path = File.join(manifest, "staged-scoring.json")
      if expected_reference
        expected = expected_reference.fetch("path")
        actual = Pathname.new(document_path).relative_path_from(Pathname.new(File.expand_path(root))).to_s
        raise Error, "staged verification path changed" unless expected == actual
        raise Error, "staged verification document changed" unless file_binding(document_path) == expected_reference.slice("sha256", "bytes")
      end
      document = JSON.parse(File.binread(document_path))
      exact_keys!(document, %w[schema_version validator binding])
      raise Error, "unsupported staged verification document" unless document["schema_version"] == DOCUMENT_VERSION
      validator = document.fetch("validator")
      validator_keys = %w[pipeline_root inputs_path inputs_sha256 inputs_bytes store_root project_state_path operation_id mode]
      selected = document.dig("binding", "schema_version") == "af-staged-scoring-workload-binding/v0.2"
      validator_keys += %w[selection_path scorer_repo selection_sha256] if selected
      validator_keys << "scorer_config" if selected && validator.key?("scorer_config")
      exact_keys!(validator, validator_keys)
      config = {
        pipeline_root: resolve(root, validator.fetch("pipeline_root")),
        inputs_path: resolve(root, validator.fetch("inputs_path")),
        store_root: resolve(root, validator.fetch("store_root")),
        project_state_path: resolve(root, validator.fetch("project_state_path")),
        operation_id: validator.fetch("operation_id"), mode: validator.fetch("mode"), command_runner:
      }
      if selected
        config[:selection_path] = resolve(root, validator.fetch("selection_path"))
        config[:scorer_repo] = resolve(root, validator.fetch("scorer_repo"))
        config[:scorer_config] = resolve(root, validator.fetch("scorer_config")) if validator.key?("scorer_config")
        raise Error, "selection document changed" unless file_binding(config[:selection_path])["sha256"] == validator["selection_sha256"]
      end
      service = new(root:, config:)
      expected_inputs = {"sha256" => validator.fetch("inputs_sha256"), "bytes" => validator.fetch("inputs_bytes")}
      raise Error, "staged authority locator input changed" unless file_binding(service.inputs_path) == expected_inputs
      paths = {
        "plan" => File.join(manifest, "execution-plan.json"),
        "snapshot" => File.join(manifest, "snapshot.yml"),
        "index" => File.join(manifest, "case_index.csv")
      }
      paths["generated"] = File.join(File.expand_path(root), "build", "workloads", workload_id) if selected
      service.verify_frozen!(document.fetch("binding"), paths)
      document
    rescue Errno::ENOENT, JSON::ParserError, KeyError, TypeError => e
      raise Error, "invalid staged workload verification: #{e.message}"
    end

    def self.verify_case!(root:, data:, command_runner: nil)
      staged = data.fetch("staged_scoring")
      reference = data.fetch("staged_scoring_verification")
      document = verify_workload!(
        root:, workload_id: data.fetch("workload_id"), expected_reference: reference, command_runner:
      )
      core = document.fetch("binding").except("artifacts")
      raise Error, "case staged authority binding changed" unless staged == core
      catalog = File.expand_path(data.fetch("catalog_path"), root)
      expected_catalog = staged.fetch("staged_amc")
      unless File.basename(catalog) == expected_catalog.fetch("filename") &&
             file_binding(catalog) == expected_catalog.slice("sha256", "bytes")
        raise Error, "case staged catalog differs from authority"
      end
      true
    rescue KeyError, TypeError => e
      raise Error, "invalid staged case binding: #{e.message}"
    end

    def self.exact_keys!(value, keys)
      raise Error, "expected exactly #{keys.join(', ')}" unless value.is_a?(Hash) && value.keys.sort == keys.sort
    end

    def self.resolve(root, value)
      path = Pathname.new(value.to_s)
      path.absolute? ? path.to_s : File.expand_path(path.to_s, root)
    end

    def initialize(root:, config:)
      raise Error, "staged scoring configuration must be a mapping" unless config.is_a?(Hash)
      keys = config.keys
      missing = REQUIRED_CONFIG - keys
      unknown = keys - REQUIRED_CONFIG - OPTIONAL_CONFIG
      raise Error, "missing staged scoring option(s): #{missing.join(', ')}" unless missing.empty?
      raise Error, "unknown staged scoring option(s): #{unknown.join(', ')}" unless unknown.empty?

      @root = File.expand_path(root)
      @pipeline_root = File.expand_path(config.fetch(:pipeline_root))
      @inputs_path = File.expand_path(config.fetch(:inputs_path))
      @store_root = File.expand_path(config.fetch(:store_root))
      @project_state_path = File.expand_path(config.fetch(:project_state_path))
      @operation_id = config.fetch(:operation_id).to_s
      @mode = (config[:mode] || "production").to_s
      @command_runner = config[:command_runner] || method(:run_command)
      @selection_path = config[:selection_path]
      @scorer_repo = config[:scorer_repo]
      @scorer_config = config[:scorer_config] && File.expand_path(config[:scorer_config])
      raise Error, "staged authority mode must be production or synthetic" unless %w[production synthetic].include?(@mode)
      raise Error, "staged authority operation id is required" if @operation_id.empty?
      executable = File.join(@pipeline_root, "bin", "af-staged-scoring-authority")
      raise Error, "pipeline staged-authority validator missing: #{executable}" unless File.executable?(executable)
      raise Error, "staged authority locator input missing: #{@inputs_path}" unless File.file?(@inputs_path)
      raise Error, "current project state missing: #{@project_state_path}" unless File.file?(@project_state_path)
    end

    attr_reader :inputs_path

    # Public allocation projection; callers cannot substitute their own ID list.
    def authority!(catalog_path:)
      projection = call_validator
      if projection["status"] == "NO_SUCCESSOR_NEEDED"
        self.class.exact_keys!(projection, %w[schema_version status authority observation preparation_allowed execution_authorized catalog_adoption_authorized])
        raise Error, "invalid zero-allocation projection" unless projection["schema_version"] == PROJECTION_VERSION && projection["authority"].nil? && projection["preparation_allowed"] == false &&
          projection["execution_authorized"] == false && projection["catalog_adoption_authorized"] == false
        return nil
      end
      authority = projection.fetch("authority")
      ids = @selection_path ? selection.fetch("selected_ids") : authority.fetch("allocation").map { |r| r.fetch("adventure_id") }
      validate_projection(projection, catalog_path:, workload_id: authority.dig("intent", "workload_id"), ids:, frozen: false)
      authority
    end

    def verify_prepared!(workload_id:)
      self.class.verify_workload!(root:, workload_id:, command_runner: @command_runner)
    end

    # Verifies the immutable manifest and current producer authority without
    # requiring a generated build. This is the restart-safe prerequisite for
    # authorizing the compiler's existing deterministic regeneration path.
    def verify_manifest_only!(workload_id:)
      manifest = File.join(root, "workloads", workload_id.to_s)
      document_path = File.join(manifest, "staged-scoring.json")
      document = JSON.parse(File.binread(document_path))
      self.class.exact_keys!(document, %w[schema_version validator binding])
      raise Error, "unsupported staged verification document" unless document["schema_version"] == DOCUMENT_VERSION
      raise Error, "staged validator configuration changed" unless document.fetch("validator") == validator_document

      binding = document.fetch("binding")
      artifacts = binding.fetch("artifacts")
      self.class.exact_keys!(artifacts, %w[index plan snapshot])
      paths = {
        "plan" => File.join(manifest, "execution-plan.json"),
        "snapshot" => File.join(manifest, "snapshot.yml"),
        "index" => File.join(manifest, "case_index.csv")
      }
      paths.each do |name, path|
        raise Error, "frozen staged #{name} changed" unless self.class.file_binding(path) == artifacts.fetch(name)
      end
      snapshot = YAML.safe_load_file(paths.fetch("snapshot"), aliases: true)
      core = validate_catalog!(
        catalog_path: snapshot.fetch("catalog_path"), workload_id:, ids: binding.fetch("intended_ids")
      )
      raise Error, "frozen staged authority changed" unless core == binding.except("artifacts")
      document
    rescue Errno::ENOENT, JSON::ParserError, Psych::Exception, KeyError, TypeError => e
      raise Error, "invalid staged workload verification: #{e.message}"
    end

    # Retain explicit owner selectors for all subsequent pipeline revalidation.
    # Paths are recorded in the validator document; selection binds config bytes.
    def use_selection!(path:, scorer_repo:, scorer_config: nil)
      @selection_path = File.expand_path(path)
      @scorer_repo = File.expand_path(scorer_repo)
      @scorer_config = scorer_config && File.expand_path(scorer_config)
      self
    end

    def validate_catalog!(catalog_path:, workload_id:, ids:)
      projection = validate_projection(call_validator, catalog_path:, workload_id:, ids:, frozen: false)
      authority = projection.fetch("authority")
      core = {
        "schema_version" => @selection_path ? StagedSelection::WORKLOAD_VERSION : WORKLOAD_VERSION,
        "authority_id" => authority.fetch("authority_id"),
        "operation_id" => @operation_id,
        "workload_id" => workload_id,
        "staged_amc" => authority.fetch("staged_amc"),
        "intended_ids" => ids
      }
      core["selection_id"] = selection.fetch("selection_id") if @selection_path
      core
    end

    def finalize!(core:, paths:, catalog_path:)
      binding = core.merge("artifacts" => paths.except("generated").transform_values { |path| self.class.file_binding(path) })
      projection = validate_projection(
        call_validator(frozen_workload: binding, workload_paths: paths),
        catalog_path:, workload_id: core.fetch("workload_id"), ids: core.fetch("intended_ids"), frozen: true
      )
      raise Error, "staged authority changed during workload compilation" unless
        projection.dig("authority", "authority_id") == core.fetch("authority_id")
      document = {
        "schema_version" => DOCUMENT_VERSION,
        "validator" => validator_document,
        "binding" => binding
      }
      document
    end

    def verify_frozen!(binding, paths)
      core = binding.except("artifacts")
      projection = validate_projection(
        call_validator(frozen_workload: binding, workload_paths: paths),
        catalog_path: resolve_catalog(paths.fetch("snapshot")),
        workload_id: core.fetch("workload_id"), ids: core.fetch("intended_ids"), frozen: true
      )
      raise Error, "frozen staged authority changed" unless projection.dig("authority", "authority_id") == core.fetch("authority_id")
      true
    end

    private

    def call_validator(frozen_workload: nil, workload_paths: nil)
      command = [File.join(@pipeline_root, "bin", "af-staged-scoring-authority"), "validate",
                 "--inputs", @inputs_path, "--store", @store_root, "--project-state", @project_state_path]
      command << "--synthetic" if @mode == "synthetic"
      if @selection_path
        command += ["--selection", @selection_path, "--selection-afw-root", File.expand_path("../..", __dir__),
                    "--selection-project-root", root, "--selection-scorer-root", @scorer_repo]
      end
      command += ["--selection-scorer-config", @scorer_config] if @selection_path && @scorer_config
      if frozen_workload || workload_paths
        raise Error, "complete frozen workload evidence required" unless frozen_workload && workload_paths
        Tempfile.create(["afw-staged-binding", ".json"]) do |binding_file|
          Tempfile.create(["afw-staged-paths", ".json"]) do |paths_file|
            binding_file.write(JSON.generate(frozen_workload)); binding_file.flush
            paths_file.write(JSON.generate(workload_paths)); paths_file.flush
            command += ["--workload-binding", binding_file.path, "--workload-paths", paths_file.path]
            return parse_result(@command_runner.call(command))
          end
        end
      end
      parse_result(@command_runner.call(command))
    end

    def parse_result(result)
      stdout, stderr, status = result
      success = status.respond_to?(:success?) ? status.success? : status == true
      raise Error, "pipeline staged-authority validation failed: #{[stderr, stdout].reject(&:empty?).join(' ').strip}" unless success
      JSON.parse(stdout)
    rescue JSON::ParserError => e
      raise Error, "pipeline staged-authority validator returned invalid JSON: #{e.message}"
    end

    def validate_projection(projection, catalog_path:, workload_id:, ids:, frozen:)
      self.class.exact_keys!(projection, %w[schema_version authority concurrency workload_frozen preparation_allowed execution_authorized catalog_adoption_authorized])
      raise Error, "unsupported staged authority projection" unless projection["schema_version"] == PROJECTION_VERSION
      raise Error, "staged catalog is not safe for workload preparation" unless
        projection["preparation_allowed"] == true && projection.dig("concurrency", "decision") == "SAFE_REUSE"
      raise Error, "staged authority grants execution or adoption" unless
        projection["execution_authorized"] == false && projection["catalog_adoption_authorized"] == false
      raise Error, "staged workload freeze state mismatch" unless projection["workload_frozen"] == frozen
      authority = projection.fetch("authority")
      required = %w[schema_version issuer mode operation intent permissions base_amc staged_amc approval_id allocation protected_ids evidence authority_id]
      self.class.exact_keys!(authority, required)
      raise Error, "unsupported staged scoring authority" unless
        authority["schema_version"] == AUTHORITY_VERSION && authority["issuer"] == "af-data-pipeline" && authority["mode"] == @mode
      expected_id = self.class.digest(authority.except("authority_id"))
      raise Error, "staged authority digest mismatch" unless authority["authority_id"] == expected_id
      raise Error, "staged authority operation mismatch" unless authority.dig("operation", "operation_id") == @operation_id
      raise Error, "staged authority workload mismatch" unless authority.dig("intent", "workload_id") == workload_id
      raise Error, "staged authority permissions changed" unless authority["permissions"] == %w[scoring_input workload_preparation]
      allocated = authority.fetch("allocation").map { |row| row.fetch("adventure_id") }
      intended = @selection_path ? selection.fetch("selected_ids") : allocated
      raise Error, "staged authority intended IDs differ" unless intended == ids && allocated.uniq == allocated
      if @selection_path
        raise Error, "selection allocation/authority differs" unless selection["allocation"] == authority["allocation"] &&
          selection["authority_id"] == authority["authority_id"] && selection["status"] == "SELECTED"
      end
      staged = authority.fetch("staged_amc")
      validate_file_identity!(staged, "staged catalog")
      validate_file_identity!(authority.fetch("base_amc"), "base catalog")
      catalog = File.expand_path(catalog_path)
      unless File.basename(catalog) == staged.fetch("filename") && self.class.file_binding(catalog) == staged.slice("sha256", "bytes")
        raise Error, "explicit catalog differs from authorized staged successor"
      end
      projection
    rescue KeyError, TypeError => e
      raise Error, "malformed staged authority projection: #{e.message}"
    end

    def validate_file_identity!(value, label)
      self.class.exact_keys!(value, %w[filename sha256 bytes])
      unless value["filename"].is_a?(String) && !value["filename"].empty? &&
             SHA256_RE.match?(value["sha256"].to_s) && value["bytes"].is_a?(Integer) && value["bytes"].positive?
        raise Error, "invalid #{label} identity"
      end
    end

    def selection
      JSON.parse(File.binread(@selection_path))
    end

    def resolve_catalog(snapshot_path)
      snapshot = YAML.safe_load_file(snapshot_path, aliases: true) || {}
      snapshot.fetch("catalog_path")
    rescue Psych::Exception, KeyError => e
      raise Error, "invalid staged workload snapshot: #{e.message}"
    end

    def portable(path)
      Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
    rescue ArgumentError
      path
    end

    def validator_document
      document = {
        "pipeline_root" => portable(@pipeline_root),
        "inputs_path" => portable(@inputs_path),
        **self.class.file_binding(@inputs_path).transform_keys { |key| "inputs_#{key}" },
        "store_root" => portable(@store_root),
        "project_state_path" => portable(@project_state_path),
        "operation_id" => @operation_id,
        "mode" => @mode
      }
      if @selection_path
        document.merge!("selection_path" => portable(@selection_path), "scorer_repo" => portable(@scorer_repo),
                        "selection_sha256" => self.class.file_binding(@selection_path).fetch("sha256"))
        document["scorer_config"] = portable(@scorer_config) if @scorer_config
      end
      document
    end

    def run_command(command)
      capture = -> { Open3.capture3(
        {"AF_CATALOG_WORKBOOK" => nil, "AF_CATALOG_ROLE" => nil, "AF_PROJECT_STATE" => nil}, *command
      ) }
      defined?(Bundler) ? Bundler.with_unbundled_env(&capture) : capture.call
    end
  end
end
