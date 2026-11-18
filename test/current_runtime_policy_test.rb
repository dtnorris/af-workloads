# frozen_string_literal: true

require_relative "test_helper"
require "digest"
require_relative "../lib/af_workloads/current_runtime_policy"

class CurrentRuntimePolicyTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_historical_ee_v05_contract_and_runtime_bytes_are_unchanged
    assert_equal "40c629b5f16d1753895b5cdf313d7ed1717152bb40ee0e2c046e844f40f24640",
                 Digest::SHA256.file(File.join(ROOT, "production_backlog/qualified_exploration_emphasis.yml")).hexdigest
    assert_equal "5bb44d4c2346404ae8756e90cc76e8082ec11fe4c10d0ed7688d0648ce5cf0b6",
                 Digest::SHA256.file(File.join(ROOT, "production_backlog/ee-v0.5-runtime.yml")).hexdigest
  end

  def test_gpt_oss_exploration_emphasis_gets_current_16384_policy_without_mutating_source
    source = { "llm" => { "provider" => "ollama", "model" => "gpt-oss:20b", "max_tokens" => 4096 } }

    resolved = AFWorkloads::CurrentRuntimePolicy.apply(
      payload: source,
      dimension_name: "Exploration Emphasis",
      model: "gpt-oss:20b"
    )

    assert_equal 16_384, resolved.dig("llm", "max_tokens")
    assert_equal 4096, source.dig("llm", "max_tokens")
  end

  def test_unrelated_dimensions_and_models_retain_existing_runtime_values
    source = { "llm" => { "provider" => "ollama", "model" => "gpt-oss:20b", "max_tokens" => 4096 } }

    unrelated_dimension = AFWorkloads::CurrentRuntimePolicy.apply(
      payload: source,
      dimension_name: "GM Preparation Burden",
      model: "gpt-oss:20b"
    )
    unrelated_model = AFWorkloads::CurrentRuntimePolicy.apply(
      payload: source,
      dimension_name: "Exploration Emphasis",
      model: "qwen3.6:35b-a3b"
    )

    assert_equal 4096, unrelated_dimension.dig("llm", "max_tokens")
    assert_equal 4096, unrelated_model.dig("llm", "max_tokens")
  end

  # Forward selection changes only the reviewed EE contract, without mutating
  # historical inputs. No model or profile is implicitly accepted elsewhere.
  def test_candidate_selection_is_scoped_to_the_exact_legacy_ee_profile
    legacy = {"name" => "Exploration Emphasis", "profile" => "ee-clean-reset-v0.5",
              "model_alias" => "gptoss", "ollama_model" => "gpt-oss:20b"}
    selected = AFWorkloads::CurrentRuntimePolicy.select_dimension(legacy)
    assert_equal "gptoss", selected.fetch("model_alias")
    assert_equal "gpt-oss:20b-candidate", selected.fetch("ollama_model")
    assert_equal "gptoss", legacy.fetch("model_alias")
    assert_equal "gptoss-legacy", AFWorkloads::CurrentRuntimePolicy.select_dimension(legacy, legacy: true).fetch("model_alias")
    [{"name" => "Combat Emphasis"}, {"profile" => "other-profile"},
     {"ollama_model" => "other:tag"}].each do |change|
      contract = legacy.merge(change)
      assert_raises(AFWorkloads::Error) { AFWorkloads::CurrentRuntimePolicy.select_dimension(contract) }
    end
    other = legacy.merge("model_alias" => "other-model")
    assert_equal other, AFWorkloads::CurrentRuntimePolicy.select_dimension(other)
  end

  # Runtime evidence must agree with candidate selection while legacy inputs
  # and unrelated dimensions retain their bytes and values.
  def test_candidate_runtime_is_explicit_and_does_not_mutate_source
    source = {"llm" => {"provider" => "ollama", "model" => "gpt-oss:20b",
                        "reasoning_effort" => "low", "max_tokens" => 4096}}
    resolved = AFWorkloads::CurrentRuntimePolicy.apply(
      payload: source, dimension_name: "Exploration Emphasis", model: "gpt-oss:20b-candidate"
    )
    assert_equal({"provider" => "ollama", "model" => "gpt-oss:20b-candidate",
                  "reasoning_effort" => "low", "max_tokens" => 4096, "temperature" => 0}, resolved.fetch("llm"))
    assert_equal "gpt-oss:20b", source.dig("llm", "model")
    refute source.fetch("llm").key?("temperature")
    assert_equal source, AFWorkloads::CurrentRuntimePolicy.apply(
      payload: source, dimension_name: "Combat Emphasis", model: "gpt-oss:20b-candidate"
    )
  end

  # The acquisition locator is informational: exact accepted digest controls
  # candidate selection, and legacy has its own explicit reference.
  def test_registry_keeps_legacy_and_pins_the_accepted_candidate
    models = YAML.safe_load_file(File.join(ROOT, "config/models.yml")).fetch("models")
    assert_equal "gpt-oss:20b", models.dig("gptoss-legacy", "ollama_model")
    assert_equal "17052f91a42e97930aa6e28a6c6c06a983e6a58dbb00434885a0cf5313e376f7",
                 models.dig("gptoss-legacy", "qualified_manifest_sha256")
    refute models.key?("gptoss-ee")
    candidate = models.fetch("gptoss")
    assert_equal "dhiltgen/gpt-oss:20b-llamacpp", candidate.fetch("pull_model")
    assert_nil AFWorkloads::CurrentRuntimePolicy.validate_model!("gptoss", candidate)
    %w[ollama_model qualified_manifest_sha256].each do |field|
      assert_raises(AFWorkloads::Error) do
        AFWorkloads::CurrentRuntimePolicy.validate_model!("gptoss", candidate.merge(field => "changed"))
      end
    end
  end

  # Check exact and v0.4 minimum context forms, full residency, and the
  # negative boundary without imposing the EE envelope on other models.
  def test_candidate_capability_envelope_is_explicit_and_scoped
    dimension = {"model_alias" => "gptoss"}
    %w[required_context_length minimum_context_length].each do |field|
      assert_nil AFWorkloads::CurrentRuntimePolicy.validate_capabilities!(
        dimension, {field => 131072, "require_fully_gpu_resident" => true}
      )
      assert_raises(AFWorkloads::Error) do
        AFWorkloads::CurrentRuntimePolicy.validate_capabilities!(
          dimension, {field => 32768, "require_fully_gpu_resident" => true}
        )
      end
    end
    assert_raises(AFWorkloads::Error) do
      AFWorkloads::CurrentRuntimePolicy.validate_capabilities!(
        dimension, {"required_context_length" => 131072, "require_fully_gpu_resident" => false}
      )
    end
    assert_nil AFWorkloads::CurrentRuntimePolicy.validate_capabilities!({"model_alias" => "qwen"}, {})
  end

  # Historical gptoss records resolve through an explicit pinned legacy entry;
  # a missing or altered entry cannot fall back to the accepted default.
  def test_historical_lookup_preserves_the_old_identity_and_fails_closed
    models = YAML.safe_load_file(File.join(ROOT, "config/models.yml")).fetch("models")
    legacy = models.fetch("gptoss-legacy")
    assert_equal legacy, AFWorkloads::CurrentRuntimePolicy.historical_model(models, "gptoss")
    assert_equal legacy, AFWorkloads::CurrentRuntimePolicy.historical_model(models, "gptoss-legacy")
    assert_equal models.fetch("qwen"), AFWorkloads::CurrentRuntimePolicy.historical_model(models, "qwen")
    assert_equal "gpt-oss:20b-candidate", models.dig("gptoss", "ollama_model")
    assert_raises(KeyError) do
      AFWorkloads::CurrentRuntimePolicy.historical_model(models.except("gptoss-legacy"), "gptoss")
    end
    changed = models.merge("gptoss-legacy" => legacy.merge("qualified_manifest_sha256" => "0" * 64))
    assert_raises(KeyError) { AFWorkloads::CurrentRuntimePolicy.historical_model(changed, "gptoss") }
  end
end
