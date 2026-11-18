# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

module CommittedScorerFixture
  def self.build(files:, executable: "bin/af-score")
    root = Dir.mktmpdir("afw-scorer-template-")
    at_exit { FileUtils.remove_entry(root) if File.exist?(root) }

    files.each do |path, contents|
      destination = File.join(root, path)
      FileUtils.mkdir_p(File.dirname(destination))
      File.write(destination, contents)
    end
    FileUtils.chmod(0o755, File.join(root, executable))
    run_git!("init", "-q", root)
    run_git!("-C", root, "add", ".")
    run_git!("-C", root, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
             "commit", "-qm", "fixture")
    [root, run_git!("-C", root, "rev-parse", "HEAD").strip]
  end

  def self.run_git!(*args)
    output, error, status = Open3.capture3("git", *args)
    raise "git #{args.first} failed: #{error}" unless status.success?

    output
  end
  private_class_method :run_git!
end
