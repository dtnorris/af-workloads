# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "yaml"
require "json"
require "digest"
require_relative "support/public_workload_fixture"

# Exercises a real compiler-produced mechanical case through the actual CLI.
# The offline proof prepares this case using genuine owner Git history; no
# validators, source readers, factories or preflight calls are replaced here.
class AfwIdentityBindingIntegrationTest < Minitest::Test
  include PublicWorkloadFixture

  # Compile a mechanical case against a disposable copy of the public code.
  def setup
    public_code = File.expand_path("..", __dir__)
    @code_root = Dir.mktmpdir("afw-identity-code-")
    %w[bin lib config production_backlog Gemfile.lock].each do |relative|
      FileUtils.cp_r(File.join(public_code, relative), @code_root)
    end
    scorer_root = ENV.fetch("AFW_TEST_SCORER_ROOT")
    if name == "test_pinned_scorer_head_and_protected_paths_refuse"
      @scorer_copy = Dir.mktmpdir("afw-identity-scorer-")
      system("git", "clone", "--quiet", "--shared", scorer_root, @scorer_copy, exception: true)
      system("git", "-C", @scorer_copy, "checkout", "--quiet", "--detach",
        "fdd620850b24a5b801eb68391ca3e98c22d4b28a", exception: true)
      scorer_root = @scorer_copy
    end
    prepare_workload_fixture(scorer_root:)
    stdout, stderr, status = invoke("afw-build-workload", *arguments, "--scorer-config", @config)
    raise "fixture compilation failed: #{stdout} #{stderr}" unless status.success?
    @case_path = File.join(@store, "build/workloads/#{@workload}/cases/#{@workload}-adv0001-ee.yml")
    @data = YAML.safe_load_file(@case_path)
    identities = @data.fetch("frozen_input_identities")
    @source = identities.fetch("source_file").fetch("path")
    @ontology = identities.fetch("ontology").fetch("path")
    @assessment_spec = identities.fetch("assessment_spec").fetch("path")
  end

  # Remove the mutable code copy and mechanical data from this check.
  def teardown
    remove_workload_fixture if @scratch
    FileUtils.remove_entry(@code_root) if @code_root
    FileUtils.remove_entry(@scorer_copy) if @scorer_copy
  end

  # Whole source bytes must remain bound even outside the selected page range.
  def test_source_outside_selected_pages_refuses
    drift(@source, "<!-- Printed Page 2 -->\n1\n")
  end

  # Parsed-version and prompt equality cannot substitute for ontology identity.
  def test_ontology_comment_refuses
    drift(@ontology, "\n<!-- identity probe -->\n")
  end

  # The other operative specification is independently bound as well.
  def test_assessment_comment_refuses
    drift(@assessment_spec, "\n<!-- identity probe -->\n")
  end

  # Replay must validate the current alias/model/exact digest registry entry.
  def test_model_digest_refuses
    path = File.join(@code_root, "config/models.yml")
    mutate(path) { |bytes| bytes.sub(@data.fetch("qualified_model_digest"), "0" * 64) }
  end

  # Reject missing or changed code-owned qualifications and restore exact bytes.
  def test_qualification_identity_refuses
    path = File.join(@code_root, @data.fetch("qualification_path"))
    bytes = File.binread(path)
    File.unlink(path)
    _stdout, stderr, status = verify
    refute status.success?
    assert_match(/missing qualification/, stderr)
    File.binwrite(path, bytes + "\n")
    _stdout, stderr, status = verify
    refute status.success?
    assert_match(/qualification changed/, stderr)
    File.binwrite(path, bytes)
    stdout, stderr, status = verify
    assert status.success?, "#{stdout} #{stderr}"
  end

  # Exercise public scorer Git/dirty-path controls on a disposable checkout.
  def test_pinned_scorer_head_and_protected_paths_refuse
    pin = @data.fetch("scorer_commit")
    system("git", "-C", @scorer_copy, "checkout", "--quiet", "--detach", "#{pin}^", exception: true)
    _stdout, stderr, status = verify
    refute status.success?
    assert_match(/scorer HEAD changed/, stderr)
    system("git", "-C", @scorer_copy, "checkout", "--quiet", "--detach", pin, exception: true)

    protected_path = File.join(@scorer_copy, "config/default.yml")
    bytes = File.binread(protected_path)
    File.binwrite(protected_path, bytes + "\n")
    _stdout, stderr, status = verify
    refute status.success?
    assert_match(/scorer protected paths/, stderr)
    File.binwrite(protected_path, bytes)
    stdout, stderr, status = verify
    assert status.success?, "#{stdout} #{stderr}"
  end

  # Current bytes and a rewritten case hash cannot replace immutable identity.
  def test_rewriting_identity_to_match_changed_source_refuses
    source = File.binread(@source)
    original_case = File.binread(@case_path)
    begin
      File.binwrite(@source, source + "<!-- Printed Page 2 -->\n1\n")
      @data.fetch("frozen_input_identities").fetch("source_file")["sha256"] = Digest::SHA256.file(@source).hexdigest
      File.write(@case_path, YAML.dump(@data))
      stdout, stderr, status = verify
      refute status.success?, "rewritten identity accepted: #{stdout} #{stderr}"
      assert_match(/identity.*frozen runtime binding/, stderr)
    ensure
      File.binwrite(@source, source)
      File.binwrite(@case_path, original_case)
    end
    stdout, stderr, status = verify
    assert status.success?, "restored replay failed: #{stdout} #{stderr}"
  end

  private

  # Append bytes, assert identity refusal, restore and prove a clean replay.
  def drift(path, suffix)
    mutate(path) { |bytes| bytes + suffix }
  end

  # Restore bytes after each isolated mutation, including assertion failures.
  def mutate(path)
    original = File.binread(path)
    begin
      changed = yield original
      refute_equal original, changed
      File.binwrite(path, changed)
      stdout, stderr, status = verify
      refute status.success?, "identity drift accepted: #{stdout} #{stderr}"
      assert_match(/identity/i, stderr)
    ensure
      File.binwrite(path, original)
    end
    stdout, stderr, status = verify
    assert status.success?, "restored replay failed: #{stdout} #{stderr}"
  end

  # Invoke the public verify-only entry point without any prepared-source cache.
  def verify
    invoke("afw-score-job", "--verify-only", @case_path)
  end
end
