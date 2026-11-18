# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"
require "adventure_ingest"

class AfwXlsxDependencyTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_real_xlsx_loading_path_resolves_rexml_from_afw_bundle
    Dir.mktmpdir("afw-xlsx-dependency-test") do |root|
      scorer = File.join(root, "scorer")
      library = File.join(scorer, "lib/af_scoring")
      FileUtils.mkdir_p(library)
      File.write(File.join(library, "errors.rb"), <<~RUBY)
        module AFScoring
          class Error < StandardError; end
        end
      RUBY
      File.write(File.join(library, "xlsx_reader.rb"), <<~RUBY)
        require "rexml/document"

        module AFScoring
          class XlsxReader
            def initialize(path)
              @path = path
            end

            def rows(sheet_name:)
              [[sheet_name, File.basename(@path), REXML::VERSION]]
            end
          end
        end
      RUBY

      script = <<~'RUBY'
        root, scorer, expected_gemfile = ARGV
        actual_gemfile = File.realpath(ENV.fetch("BUNDLE_GEMFILE"))
        abort "wrong bundle: #{actual_gemfile}" unless actual_gemfile == File.realpath(expected_gemfile)

        batch = AdventureIngest::Batch.new(
          root: root,
          batch: 1,
          catalog: "catalog.xlsx",
          ids: ["ADV-0001"],
          scorer_repo: scorer
        )
        rows = batch.read_rows(File.join(root, "catalog.xlsx"))
        abort "XLSX reader was not used" unless rows.dig(0, 0) == "Adventure Catalog"
        abort "REXML was not loaded" unless defined?(REXML::Document)
      RUBY
      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        "-I#{File.join(ROOT, 'lib')}",
        "-radventure_ingest",
        "-e",
        script,
        root,
        scorer,
        File.join(ROOT, "Gemfile")
      )

      assert status.success?, stderr
    end
  end
end
