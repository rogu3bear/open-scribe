#!/usr/bin/env ruby
# Audit retained compiler input, not an environment variable's intended value.
# The candidate's existing build-log digest binds this configuration readback.
require 'digest'
require 'json'
require 'open3'
require 'shellwords'

class MacOSBuildConfiguration
  SETTINGS = %w[GGML_NATIVE GGML_CPU_ARM_ARCH GGML_METAL GGML_ACCELERATE
                CMAKE_EXPORT_COMPILE_COMMANDS MACOSX_DEPLOYMENT_TARGET].freeze

  def initialize(policy_path, target_dir)
    @policy_path = policy_path
    @target_dir = File.realpath(target_dir)
    env_section = File.read(policy_path).split(/^\[env\]\s*$/, 2)[1]
    raise 'Cargo env policy is missing' unless env_section

    env_section = env_section.split(/^\[/, 2).first
    @policy = SETTINGS.to_h do |name|
      match = env_section.match(/^#{Regexp.escape(name)}\s*=\s*\{\s*value\s*=\s*"([^"]+)"\s*,\s*force\s*=\s*true\s*\}\s*$/)
      raise "forced Cargo policy is missing: #{name}" unless match

      [name, match[1]]
    end
    raise 'native CPU selection is forbidden' unless @policy.fetch('GGML_NATIVE') == 'OFF'
  end

  def audit
    caches = Dir.glob(File.join(@target_dir, '**/whisper-rs-sys-*/out/build/CMakeCache.txt')).sort
    raise 'no built Whisper configuration found' if caches.empty?

    {
      result: 'MACOS_BUILD_CONFIGURATION_GREEN',
      policy: @policy,
      policy_source: evidence(@policy_path),
      builds: caches.map { |path| audit_build(path) }
    }
  end

  private

  def evidence(path)
    raise "missing or redirected build evidence: #{path}" unless File.file?(path) && !File.symlink?(path)

    { path: File.realpath(path), sha256: Digest::SHA256.file(path).hexdigest }
  end

  def audit_build(cache_path)
    cache = File.readlines(cache_path).map do |line|
      match = line.chomp.match(/^([^#\/][^:]*):[^=]+=(.*)$/)
      [match[1], match[2]] if match
    end.compact.to_h
    expected = @policy.reject { |key, _| key == 'MACOSX_DEPLOYMENT_TARGET' }.merge(
      'CMAKE_OSX_ARCHITECTURES' => 'arm64',
      'CMAKE_OSX_DEPLOYMENT_TARGET' => @policy.fetch('MACOSX_DEPLOYMENT_TARGET')
    )
    expected.each do |key, value|
      raise "#{cache_path}: #{key}=#{cache[key].inspect}; expected #{value}" unless cache[key] == value
    end

    commands_path = File.join(File.dirname(cache_path), 'compile_commands.json')
    commands_evidence = evidence(commands_path)
    commands = JSON.parse(File.read(commands_path))
    raise 'compiler commands must be a nonempty array' unless commands.is_a?(Array) && !commands.empty?

    cpu_commands = []
    commands.each do |entry|
      args = entry['arguments'] || Shellwords.split(entry.fetch('command'))
      raise 'compiler arguments must be strings' unless args.is_a?(Array) && args.all? { |arg| arg.is_a?(String) }

      cpu_flags = args.select { |arg| arg.match?(/\A-m(?:arch|cpu|tune)=/) }
      baseline = "-march=#{@policy.fetch('GGML_CPU_ARM_ARCH')}"
      raise "unexpected CPU selection in #{entry.fetch('file')}: #{cpu_flags.join(' ')}" unless cpu_flags.all? { |arg| arg == baseline }
      if args.any? { |arg| arg.match?(/\A\+(?:sve|sme)/) || arg.match?(/\A-D__ARM_FEATURE_(?:SVE|SME)/) }
        raise "unsupported CPU feature override in #{entry.fetch('file')}"
      end
      if entry.fetch('file').match?(%r{/ggml-cpu(?:/|\.)})
        raise "CPU backend lacks explicit baseline: #{entry.fetch('file')}" unless cpu_flags == [baseline]

        cpu_commands << { file: entry.fetch('file'), cpu_flags: cpu_flags }
      end
    end
    raise 'no CPU backend compiler commands found' if cpu_commands.empty?

    {
      cache: evidence(cache_path),
      compile_commands: commands_evidence,
      cpu_commands: cpu_commands,
      c_compiler: compiler_identity(cache.fetch('CMAKE_C_COMPILER')),
      cxx_compiler: compiler_identity(cache.fetch('CMAKE_CXX_COMPILER')),
      cmake: compiler_identity(cache.fetch('CMAKE_COMMAND'))
    }
  end

  def compiler_identity(path)
    output, status = Open3.capture2e(path, '--version')
    raise "cannot read toolchain identity: #{path}" unless status.success?

    { path: File.realpath(path), version: output.strip }
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    raise 'usage: check_macos_build_configuration.rb /absolute/cargo-target-directory' unless ARGV.length == 1 && ARGV[0].start_with?('/')

    root = File.expand_path('..', __dir__)
    readback = MacOSBuildConfiguration.new(File.join(root, '.cargo/config.toml'), ARGV[0]).audit
    readback[:cargo_lock] = { path: File.join(root, 'Cargo.lock'), sha256: Digest::SHA256.file(File.join(root, 'Cargo.lock')).hexdigest }
    readback[:rustc] = Open3.capture2e('rustc', '--version', '--verbose').then do |output, status|
      raise 'cannot read Rust toolchain identity' unless status.success?

      output.strip
    end
    readback[:sdk] = Open3.capture2e('xcrun', '--sdk', 'macosx', '--show-sdk-version').then do |output, status|
      raise 'cannot read macOS SDK identity' unless status.success?

      output.strip
    end
    puts JSON.generate(readback)
  rescue StandardError => e
    warn "MACOS_BUILD_CONFIGURATION_RED: #{e.message}"
    exit 1
  end
end
