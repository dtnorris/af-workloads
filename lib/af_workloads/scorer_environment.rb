# frozen_string_literal: true

require_relative "error"

module AFWorkloads
  module ScorerEnvironment
    # Every environment variable read by the scorer that can select scoring
    # inputs or behavior. Keep this list in lockstep with AFSU's Config::ENV_MAP
    # and experiment PROFILE_ENV constants. Placement/runtime adapter variables
    # are deliberately excluded from workload-controlled overrides.
    CONTROL_NAMES = %w[
      AF_CATALOG_ROLE
      AF_CATALOG_WORKBOOK
      AF_INVESTIGATION_GUARDRAIL_PROFILE
      AF_LETHALITY_GUARDRAIL_PROFILE
      AF_LLM_MAX_TOKENS
      AF_LLM_PROVIDER
      AF_NOS_TWO_STAGE_PROFILE
      AF_OPENAI_MODEL
      AF_OPENAI_REASONING_EFFORT
      AF_OUTPUT_DIR
      AF_PROJECT_STATE
      AF_PUZZLE_GUARDRAIL_PROFILE
      AF_SERIOUSNESS_GUARDRAIL_PROFILE
      AF_SOCIAL_INTERACTION_GUARDRAIL_PROFILE
      AF_SOURCE_REGISTRY
      AF_SOURCE_ROOT
      AF_SPEC_ROOT
      AF_XLSX_ROOT
    ].freeze
    RUNTIME_OWNED_NAMES = %w[AF_OLLAMA_BASE_URL WLO_WORKER_ENDPOINT].freeze

    module_function

    def plan(overrides = {})
      validate_overrides!(overrides)
      CONTROL_NAMES.to_h { |name| [name, nil] }.merge(overrides)
    end

    def compilation(overrides = {})
      plan(overrides).merge(RUNTIME_OWNED_NAMES.to_h { |name| [name, nil] })
    end

    def validate_overrides!(overrides)
      raise Error, "scorer environment overrides must be a mapping" unless overrides.is_a?(Hash)

      invalid_names = overrides.keys.reject { |name| name.is_a?(String) }
      unless invalid_names.empty?
        raise Error, "scorer environment variable names must be strings: #{invalid_names.map(&:inspect).join(', ')}"
      end
      unknown = overrides.keys - CONTROL_NAMES
      unless unknown.empty?
        raise Error, "unrecognized or runtime-owned scorer environment variable(s): #{unknown.sort.join(', ')}"
      end
      invalid = overrides.filter_map do |name, value|
        name unless name.is_a?(String) && (value.nil? || value.is_a?(String))
      end
      return if invalid.empty?

      raise Error, "scorer environment values must be strings or null: #{invalid.map(&:to_s).sort.join(', ')}"
    end
    private_class_method :validate_overrides!
  end
end
