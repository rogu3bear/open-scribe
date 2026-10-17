#!/usr/bin/env ruby
# Offline collection for human review, never release or legal admission.
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'pathname'
require 'rubygems/package'
require 'stringio'
require 'zlib'

module LicenseMaterials
  TARGET = 'aarch64-apple-darwin'.freeze
  ROOT_PACKAGE = 'open-scribe-uniffi'.freeze
  MAX_ARCHIVE = 64 * 1024 * 1024
  MAX_TEXT = 512 * 1024
  MAX_EXPANDED = 256 * 1024 * 1024

  def self.command(*args, root:)
    output, error, status = Open3.capture3(*args, chdir: root)
    raise "command failed: #{args.first(2).join(' ')}: #{error.strip}" unless status.success?
    output
  end

  def self.locked_packages(bytes)
    bytes.split(/^\[\[package\]\]\s*$/).drop(1).map do |section|
      values = section.scan(/^(name|version|source|checksum) = "([^"\r\n]+)"$/).to_h
      raise 'invalid locked package identity' unless values['name'] && values['version']
      source = values['source'] || "workspace:#{values.fetch('name')}"
      values.merge('id' => "cargo:#{values.fetch('name')}@#{values.fetch('version')}|#{source}")
    end
  end

  def self.graph(metadata)
    packages = metadata.fetch('packages').to_h { |package| [package.fetch('id'), package] }
    nodes = metadata.fetch('resolve').fetch('nodes').to_h { |node| [node.fetch('id'), node] }
    roots = packages.values.select { |package| package.fetch('name') == ROOT_PACKAGE }
    raise 'ambiguous native root package' unless roots.length == 1
    walk = lambda do |normal_only|
      pending = [roots.first.fetch('id')]
      seen = {}
      until pending.empty?
        id = pending.shift
        next if seen[id]
        seen[id] = true
        nodes.fetch(id).fetch('deps').each do |dependency|
          kinds = dependency.fetch('dep_kinds').map { |kind| kind['kind'] }
          next unless kinds.any? { |kind| kind.nil? || (!normal_only && kind == 'build') }
          package = packages.fetch(dependency.fetch('pkg'))
          next if normal_only && package.fetch('targets').any? { |target| target.fetch('kind').include?('proc-macro') }
          pending << package.fetch('id')
        end
      end
      seen.keys.sort
    end
    [walk.call(false), walk.call(true)]
  end

  def self.archive_texts(path, package, checksum)
    raise 'invalid locked archive digest' unless checksum&.match?(/\A[0-9a-f]{64}\z/)
    raise 'archive is symlinked or not a regular file' if File.symlink?(path) || !File.file?(path)
    bytes = File.binread(path, MAX_ARCHIVE + 1)
    raise 'archive exceeds size bound' if bytes.bytesize > MAX_ARCHIVE
    raise 'archive differs from Cargo.lock checksum' unless Digest::SHA256.hexdigest(bytes) == checksum
    prefix = "#{package.fetch('name')}-#{package.fetch('version')}/"
    texts = []
    total = 0
    long_name = nil
    gzip = Zlib::GzipReader.new(StringIO.new(bytes))
    Gem::Package::TarReader.new(gzip) do |tar|
      tar.each do |entry|
        total += entry.header.size
        raise 'expanded archive exceeds size bound' if total > MAX_EXPANDED
        if entry.header.typeflag == 'L'
          raise 'invalid GNU long-name entry' if long_name || entry.header.size > MAX_TEXT
          long_name = entry.read.delete_suffix("\0")
          next
        end
        # GNU long-link targets never affect regular-file content; links are
        # never extracted, and a license-shaped link is rejected below.
        next if entry.header.typeflag == 'K'
        raise 'unsupported PAX archive metadata requires independent review' if %w[x g].include?(entry.header.typeflag)
        name = long_name || entry.full_name
        long_name = nil
        next if entry.directory? && name == prefix.delete_suffix('/')
        raise "unsafe archive entry in #{prefix}: #{name}" unless name.start_with?(prefix) && !name.split('/').include?('..')
        relative = name.delete_prefix(prefix)
        # Include nested native licenses/notices, not only top-level crate files.
        next unless File.basename(relative).match?(/\A(?:LICEN[CS]E|COPYING|NOTICE|UNLICENSE)(?:\z|[._-])/i)
        next if entry.directory?
        raise 'license entry is not a regular file' unless entry.file?
        raise 'license text exceeds size bound' if entry.header.size > MAX_TEXT
        text = entry.read
        raise 'license text is empty or not UTF-8' unless !text.empty? && text.dup.force_encoding('UTF-8').valid_encoding?
        raise 'duplicate license entry' if texts.any? { |item| item.fetch('package_path') == relative }
        texts << { 'package_path' => relative, 'sha256' => Digest::SHA256.hexdigest(text), 'bytes' => text.bytesize, 'text' => text }
      end
    end
    raise 'dangling GNU long-name entry' if long_name
    gzip.close
    texts.sort_by { |item| item.fetch('package_path') }
  end

  def self.prepare(root, output)
    root = File.realpath(root)
    destination = Pathname.new(output)
    raise 'output must be an absolute new directory' unless destination.absolute? && !destination.exist? && !destination.symlink?
    raise 'output parent must exist without redirection' unless destination.parent.directory? && destination.parent.realpath == destination.parent.cleanpath
    if destination.to_s.start_with?(root + '/')
      _, _, ignored = Open3.capture3('git', 'check-ignore', '-q', '--', destination.to_s, chdir: root)
      raise 'in-repository output must be ignored' unless ignored.success?
    end
    lock_bytes = File.binread(File.join(root, 'Cargo.lock'))
    inventory_bytes = File.binread(File.join(root, 'docs/supply-chain/components.v1.json'))
    inventory = JSON.parse(inventory_bytes)
    locked = locked_packages(lock_bytes)
    raise 'inventory lock digest differs' unless inventory.fetch('cargo_lock_sha256') == Digest::SHA256.hexdigest(lock_bytes)
    inventory_ids = inventory.fetch('components').map { |component| component.fetch('id') }.grep(/\Acargo:/).sort
    raise 'inventory does not equal locked package set' unless inventory_ids == locked.map { |package| package.fetch('id') }.sort
    metadata_bytes = command('cargo', 'metadata', '--locked', '--offline', '--format-version', '1', '--filter-platform', TARGET, root: root)
    metadata = JSON.parse(metadata_bytes)
    build_graph, normal_graph = graph(metadata)
    cache = File.join(ENV.fetch('CARGO_HOME', File.expand_path('~/.cargo')), 'registry/cache')
    total_text_bytes = 0
    components = metadata.fetch('packages').select { |package| build_graph.include?(package.fetch('id')) }.sort_by { |package| package.fetch('id') }.map do |package|
      source = package['source'] || "workspace:#{package.fetch('name')}"
      id = "cargo:#{package.fetch('name')}@#{package.fetch('version')}|#{source}"
      locked_package = locked.find { |item| item.fetch('id') == id }
      raise 'metadata package is not locked' unless locked_package
      files = []
      gaps = []
      if package['source']
        if package['source'] != 'registry+https://github.com/rust-lang/crates.io-index'
          gaps << 'unsupported source requires independent material review'
        else
          archives = Dir.glob(File.join(cache, '*', "#{package.fetch('name')}-#{package.fetch('version')}.crate"))
          if archives.empty?
            gaps << 'exact archive absent from local Cargo cache; no download attempted'
          elsif archives.length != 1
            raise "ambiguous cached archive: #{id}"
          else
            files = archive_texts(archives.first, package, locked_package['checksum'])
            gaps << 'archive contains no recognized license/notice text; obtain exact upstream source material' if files.empty?
          end
        end
      end
      total_text_bytes += files.sum { |file| file.fetch('bytes') }
      raise 'collected license text exceeds total size bound' if total_text_bytes > 8 * 1024 * 1024
      {
        'id' => id, 'package_id' => package.fetch('id'), 'license_expression' => package['license'],
        'source_kind' => package['source'] ? 'external' : 'workspace',
        'locked_archive_sha256' => locked_package['checksum'],
        'in_normal_graph_without_proc_macros' => normal_graph.include?(package.fetch('id')),
        'review_state' => 'Pending', 'gaps' => gaps, 'license_files' => files
      }
    end
    draft = "# Third-Party Notice Review Materials\n\nDRAFT — NOT ADOPTED. Offline archive collection only. Not the canonical notices, a shipped-component inventory, legal clearance, or release admission.\n\n"
    components.each do |component|
      draft << "## #{component.fetch('id')}\n\nDeclared license: #{component['license_expression'] || 'UNKNOWN'}\n\nReview: Pending.\n\n"
      component.fetch('gaps').each { |gap| draft << "Unresolved: #{gap}\n\n" }
      component.fetch('license_files').each { |file| draft << "### #{file.fetch('package_path')}\n\n#{file.fetch('text').dup.force_encoding('UTF-8')}\n\n" }
    end
    report = {
      'schema' => 'open-scribe.license-materials/v1', 'admission_effect' => 'none',
      'source_sha' => command('git', 'rev-parse', 'HEAD', root: root).strip,
      'working_patch_sha256' => Digest::SHA256.hexdigest(command('git', 'diff', '--binary', 'HEAD', root: root)),
      'producer_sha256' => Digest::SHA256.file(__FILE__).hexdigest,
      'cargo_lock_sha256' => Digest::SHA256.hexdigest(lock_bytes),
      'component_inventory_sha256' => Digest::SHA256.hexdigest(inventory_bytes),
      'metadata_sha256' => Digest::SHA256.hexdigest(metadata_bytes),
      'draft_notices_sha256' => Digest::SHA256.hexdigest(draft),
      'root_package' => ROOT_PACKAGE, 'target' => TARGET,
      'scope' => 'Cargo declared native normal/build graph; no dev edges. Conservative source inputs, not actual linked/shipped code.',
      'limits' => [
        'Workspace feature resolution can overapproximate one artifact. Graph membership is not binary inclusion.',
        'Archive digest equals the checked lockfile; this is not independent publisher or legal authentication.',
        'Recognized license filenames do not prove all attribution obligations; manual source review remains required.',
        'Swift, Apple frameworks, assets, models, future Sparkle and other non-Cargo resources require separate review.',
        'Canonical notices and component/model review/adoption states are unchanged. No release receipt is produced.'
      ],
      'counts' => { 'components' => components.length, 'external' => components.count { |component| component.fetch('source_kind') == 'external' },
                    'license_files' => components.sum { |component| component.fetch('license_files').length }, 'text_bytes' => total_text_bytes,
                    'components_with_gaps' => components.count { |component| !component.fetch('gaps').empty? } },
      'components' => components.map { |component| component.merge('license_files' => component.fetch('license_files').map { |file| file.reject { |key, _| key == 'text' } }) }
    }
    # Refuse replacement. All inputs were validated before creating this owned output.
    Dir.mkdir(destination, 0700)
    components.each do |component|
      component.fetch('license_files').each do |file|
        path = destination.join('licenses', file.fetch('sha256'))
        FileUtils.mkdir_p(path.dirname, mode: 0700)
        File.binwrite(path, file.fetch('text')) unless path.exist?
      end
    end
    destination.join('cargo-metadata.json').binwrite(metadata_bytes)
    destination.join('THIRD_PARTY_NOTICES.DRAFT.md').binwrite(draft)
    destination.join('review-materials.json').write(JSON.pretty_generate(report) + "\n")
    puts "LICENSE_MATERIALS_PREPARED: admission_effect=none components=#{components.length} gaps=#{report.fetch('counts').fetch('components_with_gaps')}"
  end
end

if $PROGRAM_NAME == __FILE__
  if ARGV.length != 1 || !Pathname.new(ARGV.first).absolute?
    warn 'usage: script/prepare_license_materials.rb /absolute/new-output-directory'
    exit 64
  end
  begin
    LicenseMaterials.prepare(File.expand_path('..', __dir__), ARGV.first)
  rescue StandardError => error
    warn "LICENSE_MATERIALS_RED: #{error.message}"
    exit 2
  end
end
