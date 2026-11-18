# frozen_string_literal: true

require_relative "error"

module AFWorkloads
  # Exact forward-production model/runtime amendments. Historical qualification
  # and runtime sources remain immutable inputs; see docs/MDL-01_EE_ADOPTION.md.
  module CurrentRuntimePolicy
    GPT_OSS_MODEL = "gpt-oss:20b"
    EXPLORATION_EMPHASIS = "Exploration Emphasis"
    GPT_OSS_EE_MAX_TOKENS = 16_384
    GPT_OSS_EE_CANDIDATE = "gpt-oss:20b-candidate"
    GPT_OSS_EE_CANDIDATE_ALIAS = "gptoss"
    GPT_OSS_EE_CANDIDATE_DIGEST = "f38aa0c53da5f8c49d08c43a99df24ff53167fe68e24664a7777288e7656fdfe"
    GPT_OSS_LEGACY_ALIAS = "gptoss-legacy"
    GPT_OSS_LEGACY_DIGEST = "17052f91a42e97930aa6e28a6c6c06a983e6a58dbb00434885a0cf5313e376f7"

    module_function

    # Amend the frozen EE source contract for forward or compatibility plans.
    # Returns a new mapping; other aliases are unchanged. Unsupported gptoss
    # qualification raises Error; missing identity fields raise KeyError.
    def select_dimension(dimension, legacy: false)
      return dimension unless dimension.fetch("model_alias") == "gptoss"
      unless dimension.fetch("name") == EXPLORATION_EMPHASIS &&
             dimension.fetch("profile") == "ee-clean-reset-v0.5" && dimension.fetch("ollama_model") == GPT_OSS_MODEL
        raise Error, "MDL-01 gptoss qualification is limited to EE clean-reset v0.5"
      end

      return dimension.merge("model_alias" => GPT_OSS_LEGACY_ALIAS) if legacy
      dimension.merge("model_alias" => GPT_OSS_EE_CANDIDATE_ALIAS, "ollama_model" => GPT_OSS_EE_CANDIDATE)
    end

    # Validate the separately accepted EE artifact. Other aliases are unchanged.
    # Returns nil; raises Error for a changed candidate identity and KeyError
    # for missing model fields. A pull locator never substitutes for the digest.
    def validate_model!(model_alias, model)
      expected = case model_alias
                 when GPT_OSS_EE_CANDIDATE_ALIAS then [GPT_OSS_EE_CANDIDATE, GPT_OSS_EE_CANDIDATE_DIGEST]
                 when GPT_OSS_LEGACY_ALIAS then [GPT_OSS_MODEL, GPT_OSS_LEGACY_DIGEST]
                 else return
                 end
      return if model.values_at("ollama_model", "qualified_manifest_sha256") == expected

      raise Error, "MDL-01 #{model_alias} model/digest changed"
    end

    # Frozen production records retain the historical logical name gptoss.
    # Resolve their artifact through the explicit legacy entry without changing
    # records or job IDs. Returns a model mapping; raises KeyError for missing
    # or changed legacy identity. Never call this for new forward selection.
    def historical_model(models, model_alias)
      lookup = model_alias == "gptoss" ? GPT_OSS_LEGACY_ALIAS : model_alias
      model = models.fetch(lookup)
      validate_model!(lookup, model) if lookup == GPT_OSS_LEGACY_ALIAS
      model
    rescue Error => e
      raise KeyError, e.message
    end

    # Require the reviewed context and GPU residency for dynamic candidate EE.
    # Returns nil for other contracts or matching capabilities; raises Error
    # when the accepted candidate would be scheduled outside its tested profile.
    def validate_capabilities!(dimension, capabilities)
      return unless dimension.fetch("model_alias") == GPT_OSS_EE_CANDIDATE_ALIAS
      context = capabilities["required_context_length"] || capabilities["minimum_context_length"]
      return if context == 131_072 && capabilities["require_fully_gpu_resident"] == true

      raise Error, "MDL-01 EE candidate requires context 131072 and full GPU residency"
    end

    # Copy a source runtime and apply the selected forward EE model's policy.
    # Candidate EE retains the reviewed low/4096/temperature-zero profile;
    # explicit legacy selection retains its existing 16384 policy. Invalid EE
    # llm mappings raise Error; missing mappings raise KeyError.
    def apply(payload:, dimension_name:, model:)
      resolved = Marshal.load(Marshal.dump(payload))
      return resolved unless dimension_name.to_s == EXPLORATION_EMPHASIS &&
        [GPT_OSS_MODEL, GPT_OSS_EE_CANDIDATE].include?(model.to_s)

      llm = resolved.fetch("llm")
      raise Error, "GPT-OSS EE runtime llm policy must be a mapping" unless llm.is_a?(Hash)

      if model.to_s == GPT_OSS_EE_CANDIDATE
        llm.merge!("provider" => "ollama", "model" => GPT_OSS_EE_CANDIDATE,
                   "reasoning_effort" => "low", "max_tokens" => 4096, "temperature" => 0)
      else
        llm["max_tokens"] = GPT_OSS_EE_MAX_TOKENS
      end
      resolved
    end
  end
end
