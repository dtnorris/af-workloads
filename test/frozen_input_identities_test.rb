# frozen_string_literal: true

require_relative "test_helper"
require "af_workloads"

# File/schema checks are local; composed owner path/preparation proof is in the
# separately run integration test and offline proof, without these fixtures.
class FrozenInputIdentitiesTest < Minitest::Test
  # Create only mechanical disposable bytes and content-free identity metadata.
  def setup
    @root = Dir.mktmpdir("identity-test")
    @path = File.join(@root, "0")
    File.write(@path, "0\n")
    @identities = {"contract_version" => AFWorkloads::FrozenInputIdentities::VERSION}
    AFWorkloads::FrozenInputIdentities::INPUTS.each do |name|
      @identities[name] = AFWorkloads::FrozenInputIdentities.binding(@path)
    end
  end

  # Remove only this test's disposable files.
  def teardown
    FileUtils.rm_rf(@root)
  end

  # Whole-file equality is required, including appended otherwise unused bytes.
  def test_whole_file_mutation_refuses
    assert_nil AFWorkloads::FrozenInputIdentities.verify!(@identities)
    File.open(@path, "a") { |file| file.write("1\n") }
    error = assert_raises(AFWorkloads::Error) { AFWorkloads::FrozenInputIdentities.verify!(@identities) }
    assert_match(/identity.*changed/, error.message)
  end

  # Missing/type-changed metadata never selects a weaker legacy path.
  def test_missing_and_malformed_bindings_refuse
    [nil, [], {}, @identities.merge(0 => nil), @identities.merge("contract_version" => nil)].each do |invalid|
      assert_raises(AFWorkloads::Error) { AFWorkloads::FrozenInputIdentities.verify!(invalid) }
    end
    AFWorkloads::FrozenInputIdentities::INPUTS.each do |name|
      invalid = @identities.reject { |key, _value| key == name }
      assert_raises(AFWorkloads::Error) { AFWorkloads::FrozenInputIdentities.verify!(invalid) }
      [nil, [], {"path" => @path, "sha256" => 0}, {"path" => "", "sha256" => "0" * 64}].each do |entry|
        assert_raises(AFWorkloads::Error) { AFWorkloads::FrozenInputIdentities.verify!(@identities.merge(name => entry)) }
      end
    end
  end

  # Identity mapping order is irrelevant, while any content change alters the
  # digest carried by the frozen runtime/index chain.
  def test_metadata_digest_is_canonical_and_binds_content
    digest = AFWorkloads::FrozenInputIdentities.digest(@identities)
    reordered = @identities.to_a.reverse.to_h.transform_values { |value| value.is_a?(Hash) ? value.to_a.reverse.to_h : value }
    assert_equal digest, AFWorkloads::FrozenInputIdentities.digest(reordered)
    @identities.fetch("source_file")["sha256"] = "0" * 64
    refute_equal digest, AFWorkloads::FrozenInputIdentities.digest(@identities)
  end

  # An owner preparation from changed bytes cannot be bound to an earlier file.
  def test_preparation_cannot_replace_capture_with_later_hash
    expected = @identities.slice(*AFWorkloads::FrozenInputIdentities::SOURCE_INPUTS)
    File.write(@path, "1\n")
    prepared = expected.merge("source_file" => AFWorkloads::FrozenInputIdentities.binding(@path))
    path = File.join(@root, "prepared.json")
    File.write(path, JSON.generate(prepared))
    error = assert_raises(AFWorkloads::Error) { AFWorkloads::FrozenInputIdentities.verify_prepared!(path, expected) }
    assert_match(/identity differs/, error.message)
  end
end
