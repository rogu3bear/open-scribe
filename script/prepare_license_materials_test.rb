require 'minitest/autorun'
require 'tmpdir'
require_relative 'prepare_license_materials'

class LicenseMaterialsTest < Minitest::Test
  PACKAGE = { 'name' => 'example', 'version' => '1.0.0' }.freeze

  def with_archive(entries)
    Dir.mktmpdir('open-scribe-licenses-test.') do |root|
      tar_bytes = StringIO.new(''.b)
      Gem::Package::TarWriter.new(tar_bytes) do |tar|
        entries.each do |name, text|
          tar.add_file_simple(name, 0644, text.bytesize) { |file| file.write(text) }
        end
      end
      path = File.join(root, 'example.crate')
      Zlib::GzipWriter.open(path) { |gzip| gzip.write(tar_bytes.string) }
      yield path, Digest::SHA256.file(path).hexdigest
    end
  end

  def test_collects_exact_top_level_and_nested_native_text
    with_archive('example-1.0.0/LICENSE-MIT' => "copyright — MIT\n", 'example-1.0.0/native/NOTICE' => "native notice\n", 'example-1.0.0/src/lib.rs' => 'not a license') do |path, sha|
      files = LicenseMaterials.archive_texts(path, PACKAGE, sha)
      assert_equal %w[LICENSE-MIT native/NOTICE], files.map { |file| file.fetch('package_path') }
      assert_equal "copyright — MIT\n".b, files.first.fetch('text')
      assert_equal Digest::SHA256.hexdigest(files.first.fetch('text')), files.first.fetch('sha256')
    end
  end

  def test_same_length_substitution_is_rejected_by_locked_digest
    with_archive('example-1.0.0/LICENSE' => 'original') do |path, sha|
      bytes = File.binread(path)
      original_length = bytes.bytesize
      bytes.setbyte(bytes.bytesize - 1, bytes.getbyte(bytes.bytesize - 1) ^ 1)
      File.binwrite(path, bytes)
      assert_equal original_length, File.size(path)
      error = assert_raises(RuntimeError) { LicenseMaterials.archive_texts(path, PACKAGE, sha) }
      assert_includes error.message, 'Cargo.lock checksum'
    end
  end

  def test_license_shaped_archive_link_is_rejected
    Dir.mktmpdir('open-scribe-licenses-link.') do |root|
      path = File.join(root, 'example.crate')
      bytes = StringIO.new(''.b)
      Gem::Package::TarWriter.new(bytes) { |tar| tar.add_symlink('example-1.0.0/LICENSE', '../../foreign', 0777) }
      Zlib::GzipWriter.open(path) { |gzip| gzip.write(bytes.string) }
      assert_raises(RuntimeError) { LicenseMaterials.archive_texts(path, PACKAGE, Digest::SHA256.file(path).hexdigest) }
    end
  end

  def test_refuses_archive_symlink
    with_archive('example-1.0.0/LICENSE' => 'license') do |path, sha|
      link = path + '.link'
      File.symlink(path, link)
      assert_raises(RuntimeError) { LicenseMaterials.archive_texts(link, PACKAGE, sha) }
    end
  end

  def test_refuses_traversal_and_wrong_package_prefix
    ['example-1.0.0/../LICENSE', 'foreign-1.0.0/LICENSE'].each do |entry|
      with_archive(entry => 'untrusted') do |path, sha|
        assert_raises(RuntimeError) { LicenseMaterials.archive_texts(path, PACKAGE, sha) }
      end
    end
  end

  def test_refuses_duplicate_license_paths
    Dir.mktmpdir('open-scribe-licenses-duplicate.') do |root|
      path = File.join(root, 'example.crate')
      bytes = StringIO.new(''.b)
      Gem::Package::TarWriter.new(bytes) do |tar|
        2.times { tar.add_file_simple('example-1.0.0/LICENSE', 0644, 4) { |file| file.write('keep') } }
      end
      Zlib::GzipWriter.open(path) { |gzip| gzip.write(bytes.string) }
      assert_raises(RuntimeError) { LicenseMaterials.archive_texts(path, PACKAGE, Digest::SHA256.file(path).hexdigest) }
    end
  end

  def test_gnu_long_names_are_validated_before_license_collection
    Dir.mktmpdir('open-scribe-licenses-gnu.') do |root|
      path = File.join(root, 'example.crate')
      name = 'example-1.0.0/native/' + 'long/' * 25 + 'LICENSE'
      long_body = name + "\0"
      header = lambda { |entry_name, size, type| Gem::Package::TarHeader.new(name: entry_name, mode: 0644, size: size, prefix: '', typeflag: type).to_s }
      bytes = header.call('././@LongLink', long_body.bytesize, 'L') + long_body
      bytes << "\0" * ((512 - long_body.bytesize % 512) % 512)
      bytes << header.call('truncated-name', 4, '0') + 'keep' + "\0" * 508 + "\0" * 1024
      Zlib::GzipWriter.open(path) { |gzip| gzip.write(bytes) }
      files = LicenseMaterials.archive_texts(path, PACKAGE, Digest::SHA256.file(path).hexdigest)
      assert_equal name.delete_prefix('example-1.0.0/'), files.first.fetch('package_path')
      assert_equal 'keep', files.first.fetch('text')
    end
  end

  def test_missing_text_is_an_explicit_gap_input
    with_archive('example-1.0.0/src/lib.rs' => 'code') do |path, sha|
      assert_empty LicenseMaterials.archive_texts(path, PACKAGE, sha)
    end
  end

  def test_graph_excludes_dev_and_separates_build_and_proc_macro
    package = lambda { |id, kind| { 'id' => id, 'name' => id == 'root' ? 'open-scribe-uniffi' : id, 'targets' => [{ 'kind' => [kind] }] } }
    dep = lambda { |id, kind| { 'pkg' => id, 'dep_kinds' => [{ 'kind' => kind }] } }
    metadata = {
      'packages' => [package.call('root', 'staticlib'), package.call('runtime', 'lib'), package.call('build', 'lib'), package.call('macro', 'proc-macro'), package.call('test', 'lib')],
      'resolve' => { 'nodes' => [
        { 'id' => 'root', 'deps' => [dep.call('runtime', nil), dep.call('build', 'build'), dep.call('macro', nil), dep.call('test', 'dev')] },
        { 'id' => 'runtime', 'deps' => [dep.call('root', nil)] },
        { 'id' => 'build', 'deps' => [] }, { 'id' => 'macro', 'deps' => [] }, { 'id' => 'test', 'deps' => [] }
      ] }
    }
    build, normal = LicenseMaterials.graph(metadata)
    assert_equal %w[build macro root runtime], build
    assert_equal %w[root runtime], normal
  end

  def test_existing_output_is_never_replaced
    Dir.mktmpdir('open-scribe-licenses-owned.') do |root|
      marker = File.join(root, 'foreign')
      File.write(marker, 'keep')
      assert_raises(RuntimeError) { LicenseMaterials.prepare(root, root) }
      assert_equal 'keep', File.read(marker)
    end
  end

  def test_lock_parser_keeps_source_and_checksum_identity
    packages = LicenseMaterials.locked_packages("version = 4\n\n[[package]]\nname = \"example\"\nversion = \"1.0.0\"\nsource = \"registry+https://github.com/rust-lang/crates.io-index\"\nchecksum = \"#{'a' * 64}\"\n")
    assert_equal 'a' * 64, packages.first.fetch('checksum')
    assert_equal 'cargo:example@1.0.0|registry+https://github.com/rust-lang/crates.io-index', packages.first.fetch('id')
  end
end
