require 'minitest/autorun'
require 'tmpdir'
require_relative 'sync_policy_documents'

class PolicyDocumentsTest < Minitest::Test
  def with_sources
    Dir.mktmpdir('open-scribe-policy-test.') do |root|
      PolicyDocuments::SOURCES.each_value do |source|
        path = File.join(root, source)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, "# Draft — café\n#{source}\n")
      end
      yield root
    end
  end

  def test_copies_exact_unicode_bytes_and_detects_drift
    with_sources do |root|
      assert_raises(RuntimeError) { PolicyDocuments.sync(root, check: true) }
      PolicyDocuments.sync(root, check: false)
      PolicyDocuments.sync(root, check: true)
      path = File.join(root, PolicyDocuments::DESTINATION, 'privacy.md')
      assert_equal File.binread(File.join(root, 'docs/legal/privacy.md')), File.binread(path)
      File.binwrite(path, 'altered draft')
      assert_raises(RuntimeError) { PolicyDocuments.sync(root, check: true) }
    end
  end

  def test_refuses_redirected_parent_without_writing
    with_sources do |root|
      parent = File.join(root, 'apps')
      Dir.mktmpdir('open-scribe-policy-foreign.') do |foreign|
        File.symlink(foreign, parent)
        assert_raises(RuntimeError) { PolicyDocuments.sync(root, check: false) }
        assert_empty Dir.children(foreign)
      end
    end
  end

  def test_refuses_unknown_files_without_deleting_them
    with_sources do |root|
      PolicyDocuments.sync(root, check: false)
      path = File.join(root, PolicyDocuments::DESTINATION, 'foreign.md')
      File.binwrite(path, 'keep')
      assert_raises(RuntimeError) { PolicyDocuments.sync(root, check: false) }
      assert_equal 'keep', File.binread(path)
    end
  end

  def test_compiled_digests_cannot_drift_from_canonical_bytes
    with_sources do |root|
      PolicyDocuments.sync(root, check: false)
      File.write(File.join(root, PolicyDocuments::DIGESTS), 'stale compiled hashes')
      assert_raises(RuntimeError) { PolicyDocuments.sync(root, check: true) }
    end
  end
end
