# frozen_string_literal: true

# Test-only wire validator shared by frozen DW-18 fixtures and compiler output.
# Authority: workload-orchestrator/contracts/wlo-execution-plan/v0.3.
# This producer-side checker and its copied corpus are non-authoritative.
module AfwWloV03Contract
  TOP_KEYS = %w[contract_version failure_policy jobs plan_id pools].freeze
  JOB_REQUIRED_KEYS = %w[argv job_id pool_id].freeze
  JOB_OPTIONAL_KEYS = %w[depends_on_job_ids env group_id].freeze
  ID_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/

  private

  def validate_contract!(document)
    contract_keys!(document, TOP_KEYS)
    raise ArgumentError unless document.fetch("contract_version") == "wlo-execution-plan/v0.3"
    contract_id!(document.fetch("plan_id"))
    policy = document.fetch("failure_policy")
    contract_keys!(policy, %w[max_consecutive_failures max_total_failures], %w[non_operational_exit_statuses])
    %w[max_consecutive_failures max_total_failures].each { |key| contract_positive_integer!(policy.fetch(key)) }
    exits = policy.fetch("non_operational_exit_statuses", [])
    raise ArgumentError unless exits.is_a?(Array) && exits.uniq == exits &&
                               exits.all? { |value| value.is_a?(Integer) && (1..255).cover?(value) }

    pools = document.fetch("pools")
    raise ArgumentError unless pools.is_a?(Array) && !pools.empty?
    pool_ids = pools.map do |pool|
      contract_keys!(pool, %w[pool_id], %w[required_labels requirements])
      contract_id!(pool.fetch("pool_id"))
      labels = pool.fetch("required_labels", [])
      raise ArgumentError unless labels.is_a?(Array) && labels.uniq == labels &&
                                 labels.all? { |label| label.is_a?(String) && !label.strip.empty? }
      requirements = pool.fetch("requirements", {})
      contract_keys!(requirements, [], %w[ollama])
      if requirements.key?("ollama")
        ollama = requirements.fetch("ollama")
        contract_keys!(ollama, %w[model expected_digest],
                       %w[required_context_length require_fully_gpu_resident required_gpu_id])
        raise ArgumentError unless ollama.fetch("model").is_a?(String) && !ollama.fetch("model").strip.empty?
        raise ArgumentError unless ollama.fetch("expected_digest").is_a?(String) &&
                                   ollama.fetch("expected_digest").match?(/\A[0-9a-fA-F]{64}\z/)
        contract_positive_integer!(ollama.fetch("required_context_length")) if ollama.key?("required_context_length")
        raise ArgumentError if ollama.key?("require_fully_gpu_resident") && ollama.fetch("require_fully_gpu_resident") != true
        if ollama.key?("required_gpu_id")
          gpu = ollama.fetch("required_gpu_id")
          raise ArgumentError unless gpu.is_a?(String) && !gpu.strip.empty? && gpu.length <= 256
        end
      end
      pool.fetch("pool_id")
    end
    raise ArgumentError unless pool_ids.uniq == pool_ids

    jobs = document.fetch("jobs")
    raise ArgumentError unless jobs.is_a?(Array) && !jobs.empty?
    raise ArgumentError unless jobs.all? { |job| job.is_a?(Hash) }
    ids = jobs.map { |job| job.fetch("job_id") }
    raise ArgumentError unless ids.uniq == ids
    raise ArgumentError unless jobs.map { |job| job.key?("group_id") }.uniq.length == 1
    seen = []
    jobs.each do |job|
      contract_keys!(job, JOB_REQUIRED_KEYS, JOB_OPTIONAL_KEYS)
      contract_id!(job.fetch("job_id"))
      raise ArgumentError unless pool_ids.include?(job.fetch("pool_id"))
      contract_id!(job.fetch("group_id")) if job.key?("group_id")
      argv = job.fetch("argv")
      raise ArgumentError unless argv.is_a?(Array) && !argv.empty? &&
                                 argv.all? { |arg| arg.is_a?(String) && !arg.empty? }
      env = job.fetch("env", {})
      raise ArgumentError unless env.is_a?(Hash) && env.all? do |key, value|
        key.is_a?(String) && key.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/) && (value.nil? || value.is_a?(String))
      end
      dependencies = job.fetch("depends_on_job_ids", [])
      raise ArgumentError unless dependencies.is_a?(Array) && dependencies.uniq == dependencies &&
                                 (dependencies - seen).empty?
      seen << job.fetch("job_id")
    end
    true
  rescue KeyError, TypeError, NoMethodError
    raise ArgumentError, "invalid v0.3 wire shape"
  end

  def contract_keys!(object, required, optional = [])
    raise ArgumentError unless object.is_a?(Hash) && (required - object.keys).empty? &&
                               (object.keys - required - optional).empty?
  end

  def contract_id!(value)
    raise ArgumentError unless value.is_a?(String) && value.match?(ID_PATTERN)
  end

  def contract_positive_integer!(value)
    raise ArgumentError unless value.is_a?(Integer) && value.positive?
  end

  def priority_keys(document)
    jobs = document.fetch("jobs")
    return jobs.map.with_index { |job, index| [0, index, job.fetch("job_id")] } unless jobs.first.key?("group_id")

    ranks = {}
    positions = Hash.new(0)
    jobs.map do |job|
      group = job.fetch("group_id")
      ranks[group] ||= ranks.length
      key = [ranks.fetch(group), positions[group], job.fetch("job_id")]
      positions[group] += 1
      key
    end
  end
end
