# frozen_string_literal: true

require "yaml"
require_relative "error"

module AFWorkloads
  # Operator input selection only; qualified scoring policy remains AFW-owned.
  module ScorerInputSelection
    ROOTS = %w[xlsx_root specification_root source_root output_root].freeze

    module_function

    # Read an optional scorer YAML selection. Return a detached mapping or raise
    # Error for missing files, invalid YAML or keys that could alter scoring policy.
    # Relative roots retain AFSU's resolution against the selected scorer repo.
    def load(path)
      return {} if path.nil?

      selection = YAML.safe_load_file(path, aliases: false)
      unless selection.is_a?(Hash) && (selection.keys - %w[paths files]).empty? &&
             selection["paths"].is_a?(Hash) && (selection["paths"].keys - ROOTS).empty? &&
             selection["paths"].keys.sort == ROOTS.sort &&
             selection["paths"].values.all? { |value| value.is_a?(String) && !value.strip.empty? }
        raise Error, "scorer config must explicitly select paths: #{ROOTS.join(', ')}"
      end
      if selection.key?("files")
        files = selection["files"]
        unless files.is_a?(Hash) && files.keys == ["source_registry"] &&
               files["source_registry"].is_a?(String) && !files["source_registry"].strip.empty?
          raise Error, "scorer config files may select only source_registry"
        end
      end
      selection
    rescue Psych::Exception, Errno::ENOENT => e
      raise Error, "invalid scorer input config: #{e.message}"
    end

    # Merge only selected roots/registry into a runtime in place. Return the
    # runtime; qualified policy and the compiler's catalog remain authoritative.
    def apply(payload, selection)
      selection.each do |section, values|
        payload[section] ||= {}
        payload[section].merge!(values)
      end
      payload
    end
  end
end
