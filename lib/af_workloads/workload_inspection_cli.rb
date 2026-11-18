# frozen_string_literal: true

require "json"
require "optparse"

module AFWorkloads
  class WorkloadInspectionCLI
    def self.run(argv, out: $stdout, err: $stderr, environment: ENV)
      new(out:, err:, environment:).run(argv)
    end

    def initialize(out:, err:, environment:)
      @out = out
      @err = err
      @environment = environment
    end

    def run(argv)
      options = parse(argv)
      split = options.key?(:data_root) || Roots.public_distribution?
      code_root = split ? Roots::CODE : resolve_root(options.delete(:root))
      raise Error, "use --data-root for inspection with separate storage" if split && options[:root]
      data_root = Roots.data(options[:data_root], code: code_root) if split
      scorer_repo = options[:scorer_repo]
      scorer_repo ||= component_root("AF_SCORER_ROOT", code_root, "af-cli-scoring-utility") unless split
      staged = staged_options(options, code_root, scorer_repo, split:)
      validator = FrozenWorkloadValidator.new(
        root: code_root, data_root:, workload_id: options.fetch(:workload), catalog_path: options.fetch(:catalog),
        ids: options.fetch(:ids), dimensions: options.fetch(:dimensions),
        scorer_repo:, scorer_config: options[:scorer_config],
        worker_name: options[:worker], plan_version: options[:plan_version],
        required_context_length: options[:context], require_fully_gpu_resident: options[:gpu_resident],
        required_gpu_id: options[:gpu_id], staged_scoring: staged
      )
      result = WorkloadInspector.new(root: data_root || code_root, workload_id: options.fetch(:workload), validator:).inspect
      @out.puts JSON.pretty_generate(result)
      0
    rescue Error, OptionParser::ParseError => e
      @err.puts "ERROR: #{e.message}"
      @err.puts @parser if e.is_a?(OptionParser::ParseError)
      2
    end

    private

    def parse(argv)
      options = {ids: [], dimensions: [], gpu_resident: false, staged_mode: "production"}
      @parser = OptionParser.new do |opts|
        opts.banner = "Usage: bin/afw-inspect-workload --workload ID --catalog FILE.xlsx --ids IDS [options]"
        opts.on("--data-root DIR") { |value| options[:data_root] = value }
        opts.on("--root DIR") { |value| options[:root] = value }
        opts.on("--workload ID") { |value| options[:workload] = value }
        opts.on("--catalog FILE") { |value| options[:catalog] = value }
        opts.on("--ids IDS") { |value| options[:ids] << value }
        opts.on("--dimension NAME") { |value| options[:dimensions] << value }
        opts.on("--wlo-plan-version VERSION", %w[0.2 0.3]) { |value| options[:plan_version] = value }
        opts.on("--worker NAME") { |value| options[:worker] = value }
        opts.on("--scorer-repo DIR") { |value| options[:scorer_repo] = value }
        opts.on("--scorer-config FILE", "Same explicit input selection used to build the workload") { |value| options[:scorer_config] = value }
        opts.on("--required-context-length N", Integer) { |value| options[:context] = value }
        opts.on("--require-fully-gpu-resident") { options[:gpu_resident] = true }
        opts.on("--required-gpu-id ID") { |value| options[:gpu_id] = value }
        opts.on("--staged-authority-inputs FILE") { |value| options[:staged_inputs] = value }
        opts.on("--staged-authority-store DIR") { |value| options[:staged_store] = value }
        opts.on("--staged-project-state FILE") { |value| options[:staged_state] = value }
        opts.on("--staged-operation UUID") { |value| options[:staged_operation] = value }
        opts.on("--staged-selection FILE") { |value| options[:staged_selection] = value }
        opts.on("--staged-pipeline-root DIR") { |value| options[:staged_pipeline] = value }
        opts.on("--staged-authority-mode MODE", %w[production synthetic]) { |value| options[:staged_mode] = value }
      end
      @parser.parse!(argv)
      raise OptionParser::MissingArgument, "--workload ID" if options[:workload].to_s.empty?
      raise OptionParser::MissingArgument, "--catalog FILE" if options[:catalog].to_s.empty?
      raise OptionParser::MissingArgument, "--ids IDS" if options[:ids].empty?
      raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?
      options
    end

    def staged_options(options, root, scorer_repo, split:)
      keys = %i[staged_inputs staged_store staged_state staged_operation]
      supplied = keys.select { |key| options[key] }
      if options[:staged_selection] && supplied.empty?
        raise OptionParser::MissingArgument, "--staged-selection requires complete staged authority options"
      end
      return nil if supplied.empty?
      missing = keys - supplied
      raise OptionParser::MissingArgument, "staged mode also requires #{missing.join(', ')}" unless missing.empty?

      raise OptionParser::MissingArgument, "--staged-pipeline-root DIR" if split && !options[:staged_pipeline]

      {
        pipeline_root: options[:staged_pipeline] || component_root("AF_DATA_PIPELINE_ROOT", root, "af-data-pipeline"),
        inputs_path: options.fetch(:staged_inputs), store_root: options.fetch(:staged_store),
        project_state_path: options.fetch(:staged_state), operation_id: options.fetch(:staged_operation),
        selection_path: options[:staged_selection], scorer_repo:, scorer_config: options[:scorer_config], mode: options.fetch(:staged_mode)
      }.compact
    end

    def resolve_root(explicit)
      return File.expand_path(explicit) if explicit
      return File.expand_path(@environment.fetch("AF_AFW_ROOT")) if @environment["AF_AFW_ROOT"]
      return File.expand_path(@environment.fetch("AFW_ROOT")) if @environment["AFW_ROOT"]
      return File.join(File.expand_path(@environment.fetch("AF_PROJECT_ROOT")), "af-workloads") if @environment["AF_PROJECT_ROOT"]

      File.expand_path("../..", __dir__)
    end

    def component_root(environment_name, afw_root, name)
      return File.expand_path(@environment.fetch(environment_name)) if @environment[environment_name]
      return File.join(File.expand_path(@environment.fetch("AF_PROJECT_ROOT")), name) if @environment["AF_PROJECT_ROOT"]

      File.expand_path("../#{name}", afw_root)
    end
  end
end
