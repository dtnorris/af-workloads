# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "rbconfig"
require "yaml"

module AFWorkloads
  # Content-free bindings for new frozen runtimes. AFSU owns all input path
  # resolution; AFW records and checks its result around preparation and replay.
  module FrozenInputIdentities
    VERSION = "afw-frozen-input-identities/v0.1"
    MARKER = "afw_frozen_input_contract"
    DIGEST_FIELD = "afw_frozen_input_identities_sha256"
    INPUTS = %w[source_file source_registry ontology assessment_spec model_registry].freeze
    SOURCE_INPUTS = %w[source_file source_registry].freeze
    SHA256 = /\A[0-9a-f]{64}\z/
    # Runs in a separate process so Config sees exactly the scorer environment
    # without changing the parent ENV or duplicating scorer path semantics.
    RESOLVE = <<~'RUBY'
      require "af_scoring"
      require "json"
      config = AFScoring::Config.new(project_root: ARGV[0], config_path: ARGV[1])
      bind = ->(path) { {"path" => File.expand_path(path), "sha256" => Digest::SHA256.file(path).hexdigest} }
      registry = bind.call(config.source_registry_path)
      catalog = bind.call(config.catalog_path)
      adventure = AFScoring::Catalog.new(config.catalog_path).fetch(ARGV[2])
      resolution = AFScoring::SourceResolver.new(source_root: config.dig("paths", "source_root"),
        registry_path: config.source_registry_path).resolve(adventure)
      raise "source registry changed during identity resolution" unless registry == bind.call(config.source_registry_path)
      raise "catalog changed during identity resolution" unless catalog == bind.call(config.catalog_path)
      puts JSON.generate("source_file" => bind.call(resolution.path), "source_registry" => registry,
        "ontology" => bind.call(config.afao_path), "assessment_spec" => bind.call(config.assessment_spec_path))
    RUBY

    module_function

    # Resolve operative inputs through actual AFSU Config/Catalog/SourceResolver.
    # Returns path/hash mappings; raises Error on owner or malformed output errors.
    def capture(scorer_repo:, runtime_path:, adventure_id:, environment:)
      stdout, stderr, status = Open3.capture3(environment, RbConfig.ruby,
        "-I#{File.join(scorer_repo, 'lib')}", "-e", RESOLVE, scorer_repo, runtime_path, adventure_id,
        chdir: scorer_repo)
      raise Error, "frozen input identity resolution failed: #{stderr.strip}" unless status.success?
      JSON.parse(stdout)
    rescue JSON::ParserError => e
      raise Error, "invalid frozen input identity resolution: #{e.message}"
    end

    # Bind exact supplied bytes, allowing the model parser to consume those same
    # bytes. Returns a path/hash mapping without retaining file contents.
    def binding(path, bytes = File.binread(path))
      {"path" => File.expand_path(path), "sha256" => Digest::SHA256.hexdigest(bytes)}
    end

    # Bind metadata itself through the already frozen runtime hash. Returns a
    # canonical SHA-256 independent of mapping insertion order; verify! must
    # validate the schema first. No file contents enter this metadata digest.
    def digest(identities)
      canonical = identities.sort.to_h.transform_values do |value|
        value.is_a?(Hash) ? value.sort.to_h : value
      end
      Digest::SHA256.hexdigest(JSON.generate(canonical))
    end

    # Validate mandatory schema and current whole-file bytes. Returns nil or
    # raises Error, including missing fields, wrong types and missing files.
    def verify!(identities)
      unless identities.is_a?(Hash) && identities.keys.all? { |key| key.is_a?(String) } &&
             identities.keys.sort == ["contract_version", *INPUTS].sort &&
             identities["contract_version"] == VERSION
        raise Error, "invalid frozen input identity metadata"
      end
      INPUTS.each do |name|
        entry = identities[name]
        unless entry.is_a?(Hash) && entry.keys.all? { |key| key.is_a?(String) } && entry.keys.sort == %w[path sha256] &&
               entry["path"].is_a?(String) && entry["path"].start_with?("/") &&
               entry["sha256"].is_a?(String) && entry["sha256"].match?(SHA256)
          raise Error, "invalid frozen input identity #{name}"
        end
        unless File.file?(entry["path"]) && binding(entry["path"]) == entry
          raise Error, "frozen input identity #{name} changed"
        end
      end
      nil
    end

    # Compare prepared source bindings from the real owner with pre-preparation
    # bindings. Returns nil; raises Error for mixed or malformed preparation.
    def verify_prepared!(path, expected)
      prepared = JSON.parse(File.binread(path))
      unless prepared.is_a?(Hash) && SOURCE_INPUTS.all? { |name| prepared[name] == expected.fetch(name) }
        raise Error, "prepared source identity differs from captured inputs"
      end
      nil
    rescue JSON::ParserError, KeyError => e
      raise Error, "invalid prepared source identity: #{e.message}"
    end

    # Validate the selected current registry entry separately from immutable file
    # identity and runtime/method qualification. Returns nil or raises Error.
    def verify_model!(root:, data:, identities:)
      path = File.join(root, "config/models.yml")
      raise Error, "model registry identity path differs" unless identities.fetch("model_registry")["path"] == path
      model = YAML.safe_load_file(path, aliases: true).fetch("models").fetch(data.fetch("model_alias"))
      CurrentRuntimePolicy.validate_model!(data.fetch("model_alias"), model)
      unless model.fetch("ollama_model") == data.fetch("ollama_model") &&
             model.fetch("qualified_manifest_sha256") == data.fetch("qualified_model_digest")
        raise Error, "selected model identity differs from registry"
      end
      nil
    rescue KeyError, NoMethodError, Psych::Exception => e
      raise Error, "invalid model registry identity: #{e.message}"
    end
  end
end
