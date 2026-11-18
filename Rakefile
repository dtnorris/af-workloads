# frozen_string_literal: true

require "minitest/test_task"
require "rbconfig"
require "open3"
require "shellwords"
require "tmpdir"

TEST_RUNTIME_WARNING_SECONDS = 14.0
TEST_RUNTIME_CEILING_SECONDS = 20.0

functional_tests = Minitest::TestTask.create do |task|
  task.test_globs = ["test/**/*_test.rb"]
  task.test_prelude = 'require "simplecov"; SimpleCov.start { cover "lib/**/*.rb"; enable_coverage :branch }' if ENV["COVERAGE"]
end

test_suites = lambda do
  isolated = {
    "staged_sources" => ["test/staged_selection_source_policy_test.rb"],
    "workload_roots" => ["test/workload_roots_integration_test.rb"],
    "input_identities" => ["test/afw_identity_binding_integration_test.rb"]
  }
  files = Dir[*functional_tests.test_globs].uniq.sort
  missing = isolated.values.flatten - files
  abort "Missing workload proof suites: #{missing.join(', ')}" unless missing.empty?
  { "ordinary" => files - isolated.values.flatten }.merge(isolated)
end

Rake::Task["test:cmd"].clear_actions
task "test:cmd" do
  if ENV["COVERAGE"]
    puts "COVERAGE=1 bundle exec rake test"
  else
    test_suites.call.each_value do |paths|
      puts "ruby #{functional_tests.make_test_cmd(paths)}"
    end
  end
end

Rake::Task[:test].clear_actions
task :test do
  suites = test_suites.call

  Dir.mktmpdir("afw-test-coverage-") do |coverage_root|
    commands = suites.map do |name, paths|
      environment = {}
      if ENV["COVERAGE"]
        environment["AFW_TEST_COVERAGE_DIR"] = File.join(coverage_root, name)
        # Store slices without reporting partial coverage. This hook runs
        # before SimpleCov's after_run hook; collate enforces all rules below.
        functional_tests.test_prelude = <<~RUBY.strip
          require "minitest/autorun";
          require "simplecov";
          SimpleCov.start do
            coverage_dir ENV.fetch("AFW_TEST_COVERAGE_DIR");
            cover "lib/**/*.rb";
            enable_coverage :branch;
          end;
          Minitest.after_run { SimpleCov.result }
        RUBY
      end
      [name, environment, Shellwords.split(functional_tests.make_test_cmd(paths))]
    end

    # Join every child before reporting a failure; each suite retains its own
    # Minitest counts and exit status. At most four test processes run at once.
    workers = commands.map do |name, environment, arguments|
      Thread.new do
        output, status = Open3.capture2e(environment, RbConfig.ruby, *arguments)
        [name, output, status]
      rescue StandardError => error
        [name, "#{error.class}: #{error.message}\n", nil]
      end
    end
    results = workers.map(&:value)
    results.each do |name, output, status|
      puts "AFW #{name} suite: #{status || 'could not start'}"
      $stdout.write(output)
    end
    abort "AFW functional suite failed" unless results.all? { |_name, _output, status| status&.success? }

    if ENV["COVERAGE"]
      reports = suites.keys.map { |name| File.join(coverage_root, name, ".resultset.json") }
      abort "Missing AFW coverage slice" unless reports.all? { |path| File.file?(path) && File.size?(path) }
      collate = <<~RUBY
        require "simplecov"
        directory = ARGV.shift
        SimpleCov.collate(ARGV) do
          coverage_dir File.join(directory, "merged")
          cover "lib/**/*.rb"
          enable_coverage :branch
        end
      RUBY
      sh RbConfig.ruby, "-e", collate, coverage_root, *reports
    end
  end
end

desc "Enforce the functional test runtime ceiling with coverage enabled"
task "test:coverage" do
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  sh({"COVERAGE" => "1"}, RbConfig.ruby, "-S", "rake", "test")
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  puts format("Coverage test suite runtime %.3fs (limit %.1fs)", elapsed, TEST_RUNTIME_CEILING_SECONDS)
  warn "AFW coverage suite reached its runtime warning" if elapsed >= TEST_RUNTIME_WARNING_SECONDS
  abort "AFW coverage suite reached its runtime ceiling" if elapsed >= TEST_RUNTIME_CEILING_SECONDS
end

desc "Check structural test lint"
task "test:lint" do
  sh "bundle", "exec", "rubocop", "--cache", "false", "--config", ".rubocop.yml", "test"
end

desc "Run the complete public workload test contract"
task "test:contract" => ["test:coverage", "test:lint", "test:deps"]
task default: "test:contract"
