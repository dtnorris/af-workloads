# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "rbconfig"
require "af_workloads"

class AfwScorerEnvironmentTest < Minitest::Test
  ORDINARY_MARKER = "AFW_DW25_ORDINARY_MARKER"

  def test_plan_environment_is_complete_and_keeps_runtime_binding_out_of_afw
    environment = AFWorkloads::ScorerEnvironment.plan(
      "AF_LLM_PROVIDER" => "ollama",
      "AF_SOCIAL_INTERACTION_GUARDRAIL_PROFILE" => "phase6-v0.3"
    )

    assert_equal AFWorkloads::ScorerEnvironment::CONTROL_NAMES, environment.keys
    assert_equal "ollama", environment.fetch("AF_LLM_PROVIDER")
    assert_equal "phase6-v0.3", environment.fetch("AF_SOCIAL_INTERACTION_GUARDRAIL_PROFILE")
    assert_nil environment.fetch("AF_INVESTIGATION_GUARDRAIL_PROFILE")
    refute environment.key?("AF_OLLAMA_BASE_URL")

    compile_environment = AFWorkloads::ScorerEnvironment.compilation(environment)
    assert_nil compile_environment.fetch("AF_OLLAMA_BASE_URL")
    assert_nil compile_environment.fetch("WLO_WORKER_ENDPOINT")
  end

  def test_effective_process_environment_has_absence_values_isolation_and_endpoint_precedence
    stale = AFWorkloads::ScorerEnvironment::CONTROL_NAMES.to_h { |name| [name, "stale-#{name}"] }
    stale["AF_OLLAMA_BASE_URL"] = "http://wrong.example:11434"
    stale[ORDINARY_MARKER] = "inherited"

    social = AFWorkloads::ScorerEnvironment.plan(
      "AF_LLM_PROVIDER" => "ollama",
      "AF_SOCIAL_INTERACTION_GUARDRAIL_PROFILE" => "phase6-v0.3"
    ).merge("AF_OLLAMA_BASE_URL" => "http://127.0.0.1:11434")
    investigation = AFWorkloads::ScorerEnvironment.plan(
      "AF_LLM_PROVIDER" => "ollama",
      "AF_INVESTIGATION_GUARDRAIL_PROFILE" => "phase6-v0.4"
    ).merge("AF_OLLAMA_BASE_URL" => "http://remote.example:11434")

    with_environment(stale) do
      social_seen = observed_environment(social)
      investigation_seen = observed_environment(investigation)

      assert_equal "inherited", social_seen.fetch(ORDINARY_MARKER)
      assert_equal "ollama", social_seen.fetch("AF_LLM_PROVIDER")
      assert_equal "phase6-v0.3", social_seen.fetch("AF_SOCIAL_INTERACTION_GUARDRAIL_PROFILE")
      refute social_seen.key?("AF_INVESTIGATION_GUARDRAIL_PROFILE")
      assert_equal "http://127.0.0.1:11434", social_seen.fetch("AF_OLLAMA_BASE_URL")

      assert_equal "ollama", investigation_seen.fetch("AF_LLM_PROVIDER")
      assert_equal "phase6-v0.4", investigation_seen.fetch("AF_INVESTIGATION_GUARDRAIL_PROFILE")
      refute investigation_seen.key?("AF_SOCIAL_INTERACTION_GUARDRAIL_PROFILE")
      assert_equal "http://remote.example:11434", investigation_seen.fetch("AF_OLLAMA_BASE_URL")

      assert_equal social_seen.reject { |name, _value| name == "AF_OLLAMA_BASE_URL" || name.include?("GUARDRAIL") },
                   investigation_seen.reject { |name, _value| name == "AF_OLLAMA_BASE_URL" || name.include?("GUARDRAIL") }
    end
  end

  def test_malformed_or_non_owned_overrides_fail_closed
    [
      ["AF_OLLAMA_BASE_URL", "http://wrong.example"],
      ["WLO_WORKER_ENDPOINT", "http://wrong.example"],
      ["AF_UNKNOWN_SCORER_KNOB", "value"],
      ["AF_LLM_PROVIDER", 1],
      [:AF_LLM_PROVIDER, "ollama"]
    ].each do |name, value|
      assert_raises(AFWorkloads::Error) { AFWorkloads::ScorerEnvironment.plan(name => value) }
    end
    assert_raises(AFWorkloads::Error) { AFWorkloads::ScorerEnvironment.plan([]) }
  end

  private

  def observed_environment(overlay)
    names = AFWorkloads::ScorerEnvironment::CONTROL_NAMES +
            AFWorkloads::ScorerEnvironment::RUNTIME_OWNED_NAMES + [ORDINARY_MARKER]
    script = "require 'json'; puts JSON.generate(ENV.to_h.slice(*#{names.inspect}))"
    stdout, stderr, status = Open3.capture3(overlay, RbConfig.ruby, "-e", script)
    assert status.success?, stderr
    JSON.parse(stdout)
  end

  def with_environment(values)
    previous = values.to_h { |name, _value| [name, ENV[name]] }
    values.each { |name, value| ENV[name] = value }
    yield
  ensure
    previous&.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end
end
