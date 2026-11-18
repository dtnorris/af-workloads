# frozen_string_literal: true

require "digest"
require "find"
require "json"
require "pathname"

module AFWorkloads
  # Read-only lifecycle inspection for one immutable AFW workload identity.
  class WorkloadInspector
    CONTRACT_VERSION = "afw-workload-inspection/v0.1"
    MANIFEST_FILES = %w[case_index.csv execution-plan.json snapshot.yml].freeze
    OPTIONAL_MANIFEST_FILES = %w[staged-scoring.json].freeze
    GENERATED_DIRECTORIES = %w[cases preflight runtime].freeze
    OUTPUT_DIRECTORIES = %w[evidence results].freeze

    def initialize(root:, workload_id:, validator:)
      @root = File.expand_path(root)
      @workload_id = workload_id.to_s
      @validator = validator
    end

    def inspect
      before = lifecycle_snapshot
      result = inspect_once
      after = lifecycle_snapshot
      return refusal("INSPECTION_RACE", "workload artifacts changed during inspection", observed) unless before == after

      result
    rescue Error => e
      after = lifecycle_snapshot
      reason = defined?(before) && before != after ? "INSPECTION_RACE" : "VERIFICATION_FAILED"
      refusal(reason, e.message, observed)
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError, Psych::Exception => e
      refusal("VERIFICATION_FAILED", e.message, observed)
    end

    private

    def inspect_once
      manifest = artifact_state(manifest_path)
      generated = artifact_state(generated_path)
      output = artifact_state(output_path)
      current = observed(manifest:, generated:, output:)

      if manifest.fetch("state") == "absent"
        unless generated.fetch("state") == "absent" && output.fetch("state") == "absent"
          return refusal("ORPHANED_ARTIFACTS", "build or output exists without a workload manifest", current)
        end
        return decision("fresh-build", "NO_WORKLOAD", current)
      end

      invalid = validate_manifest_state(manifest)
      return refusal(invalid.fetch(:code), invalid.fetch(:detail), current) if invalid

      invalid = validate_generated_state(generated)
      return refusal(invalid.fetch(:code), invalid.fetch(:detail), current) if invalid

      replay = @validator.verify!(verify_generated: generated.fetch("state") == "directory")
      results = inspect_results(replay.fetch("case_ids"), output)
      current = observed(manifest:, generated:, output:, replay:, results: results.fetch(:evidence))
      return refusal("RESULTS_CONFLICT", results.fetch(:detail), current) unless results.fetch(:valid)

      if generated.fetch("state") == "absent"
        if results.fetch(:evidence).fetch("state") != "absent"
          return refusal("RESULTS_WITHOUT_BUILD", "scoring output exists while the generated build is absent", current)
        end
        decision("regenerate", "VERIFIED_REGENERATION", current)
      else
        decision("reuse", "VERIFIED_REUSE", current)
      end
    end

    def validate_manifest_state(state)
      return {code: "MANIFEST_NOT_DIRECTORY", detail: "workload manifest is not a directory"} unless state["state"] == "directory"

      entries = state.fetch("entries")
      missing = MANIFEST_FILES - entries
      return {code: "MANIFEST_INCOMPLETE", detail: "missing manifest files: #{missing.join(', ')}"} unless missing.empty?

      unknown = entries - MANIFEST_FILES - OPTIONAL_MANIFEST_FILES
      return {code: "MANIFEST_CONFLICT", detail: "unexpected manifest entries: #{unknown.join(', ')}"} unless unknown.empty?

      bad = entries.find do |name|
        path = File.join(manifest_path, name)
        File.symlink?(path) || !File.file?(path)
      end
      return unless bad

      {code: "MANIFEST_CONFLICT", detail: "manifest entry is not a regular file: #{bad}"}
    end

    def validate_generated_state(state)
      return if state["state"] == "absent"
      return {code: "GENERATED_CONFLICT", detail: "generated workload is not a directory"} unless state["state"] == "directory"

      entries = state.fetch("entries")
      missing = GENERATED_DIRECTORIES - entries
      return {code: "GENERATED_PARTIAL", detail: "missing generated directories: #{missing.join(', ')}"} unless missing.empty?

      unknown = entries - GENERATED_DIRECTORIES
      return {code: "GENERATED_CONFLICT", detail: "unexpected generated entries: #{unknown.join(', ')}"} unless unknown.empty?

      bad = first_unsafe_entry(generated_path)
      return unless bad

      {code: "GENERATED_CONFLICT", detail: "generated workload contains unsupported entry: #{relative(bad)}"}
    end

    def inspect_results(case_ids, output)
      absent = {"state" => "absent", "completion_claimed" => false}
      return {valid: true, evidence: absent} if output["state"] == "absent"
      return {valid: false, detail: "workload output is not a directory", evidence: output.merge("completion_claimed" => false)} unless output["state"] == "directory"

      unknown = output.fetch("entries") - OUTPUT_DIRECTORIES
      unless unknown.empty?
        return {valid: false, detail: "unexpected workload output entries: #{unknown.join(', ')}",
                evidence: output.merge("completion_claimed" => false)}
      end
      results = File.join(output_path, "results")
      unless File.exist?(results)
        return {valid: false, detail: "evidence exists without a results tree",
                evidence: output.merge("completion_claimed" => false)} if File.exist?(File.join(output_path, "evidence"))
        return {valid: true, evidence: absent}
      end
      unless File.directory?(results) && !File.symlink?(results)
        return {valid: false, detail: "results path is not a directory", evidence: {"state" => "conflict", "completion_claimed" => false}}
      end

      result_ids = Dir.children(results).sort
      unknown_ids = result_ids - case_ids
      bad = result_ids.find { |id| !File.directory?(File.join(results, id)) || File.symlink?(File.join(results, id)) }
      bad ||= first_unsafe_entry(results)
      evidence = tree_evidence(results).merge(
        "state" => "present", "case_ids" => result_ids, "completion_claimed" => false
      )
      return {valid: false, detail: "results reference unknown case IDs: #{unknown_ids.join(', ')}", evidence:} unless unknown_ids.empty?
      return {valid: false, detail: "results contain unsupported entry: #{relative(bad)}", evidence:} if bad

      {valid: true, evidence:}
    end

    def first_unsafe_entry(path)
      Find.find(path) do |entry|
        next if entry == path
        return entry if File.symlink?(entry) || !(File.file?(entry) || File.directory?(entry))
      end
      nil
    end

    def artifact_state(path)
      return {"state" => "absent", "path" => relative(path)} unless File.exist?(path) || File.symlink?(path)
      return {"state" => "symlink", "path" => relative(path)} if File.symlink?(path)
      return {"state" => "file", "path" => relative(path)} if File.file?(path)
      return {"state" => "other", "path" => relative(path)} unless File.directory?(path)

      {"state" => "directory", "path" => relative(path), "entries" => Dir.children(path).sort}
    end

    def observed(manifest: artifact_state(manifest_path), generated: artifact_state(generated_path),
                 output: artifact_state(output_path), replay: nil, results: nil)
      value = {"manifest" => manifest, "generated_build" => generated,
               "results" => results || {"state" => "absent", "completion_claimed" => false}}
      value["verified_replay"] = replay if replay
      value["output"] = output unless output["state"] == "absent"
      value
    end

    def decision(action, reason_code, evidence)
      {"contract_version" => CONTRACT_VERSION, "workload_id" => @workload_id,
       "action" => action, "reason_code" => reason_code, "observed" => evidence}
    end

    def refusal(reason_code, detail, evidence)
      decision("refuse", reason_code, evidence).merge("detail" => portable_detail(detail))
    end

    def lifecycle_snapshot
      [manifest_path, generated_path, output_path].to_h { |path| [relative(path), tree_signature(path)] }
    end

    def tree_evidence(path)
      signature = tree_signature(path)
      files = signature.count { |row| row.fetch(1) == "file" }
      bytes = signature.select { |row| row.fetch(1) == "file" }.sum { |row| row.fetch(2) }
      {"tree_sha256" => Digest::SHA256.hexdigest(JSON.generate(signature)), "files" => files, "bytes" => bytes}
    end

    def tree_signature(path)
      return [[".", "absent"]] unless File.exist?(path) || File.symlink?(path)
      return [[".", "symlink", File.readlink(path)]] if File.symlink?(path)
      return [[".", "file", File.size(path), Digest::SHA256.file(path).hexdigest]] if File.file?(path)

      base = Pathname.new(path)
      [[".", "directory"]] + Find.find(path).filter_map do |entry|
        next if entry == path
        rel = Pathname.new(entry).relative_path_from(base).to_s
        stat = File.lstat(entry)
        if stat.symlink?
          [rel, "symlink", File.readlink(entry)]
        elsif stat.directory?
          [rel, "directory"]
        elsif stat.file?
          [rel, "file", stat.size, Digest::SHA256.file(entry).hexdigest]
        else
          [rel, "other"]
        end
      end.sort
    end

    def manifest_path = File.join(@root, "workloads", @workload_id)
    def generated_path = File.join(@root, "build", "workloads", @workload_id)
    def output_path = File.join(@root, "output", "workloads", @workload_id)

    def relative(path)
      Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(@root)).to_s
    end

    def portable_detail(value)
      value.to_s.gsub(@root, "<AFW_ROOT>")
    end
  end
end
