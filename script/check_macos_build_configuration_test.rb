#!/usr/bin/env ruby
require 'fileutils'
require 'tmpdir'
require_relative 'check_macos_build_configuration'

root = File.expand_path('..', __dir__)
policy_path = File.join(root, '.cargo/config.toml')
rejections = 0
Dir.mktmpdir('open-scribe-build-configuration.') do |fixture|
  build = File.join(fixture, 'debug/build/whisper-rs-sys-fixture/out/build')
  FileUtils.mkdir_p(build)
  cache_path = File.join(build, 'CMakeCache.txt')
  commands_path = File.join(build, 'compile_commands.json')
  cache = {
    'GGML_NATIVE' => 'OFF', 'GGML_CPU_ARM_ARCH' => 'armv8-a',
    'GGML_METAL' => 'ON', 'GGML_ACCELERATE' => 'ON',
    'CMAKE_EXPORT_COMPILE_COMMANDS' => 'ON',
    'CMAKE_OSX_ARCHITECTURES' => 'arm64', 'CMAKE_OSX_DEPLOYMENT_TARGET' => '13.0',
    'CMAKE_C_COMPILER' => '/usr/bin/cc', 'CMAKE_CXX_COMPILER' => '/usr/bin/c++',
    'CMAKE_COMMAND' => Open3.capture2('which', 'cmake').first.strip
  }
  command = {
    'file' => '/fixture/ggml-cpu/arch/arm/quants.c',
    'command' => '/usr/bin/cc -arch arm64 -march=armv8-a -c "/fixture/source with spaces.c"'
  }
  write = lambda do |settings = cache, entries = [command]|
    File.write(cache_path, settings.map { |key, value| "#{key}:STRING=#{value}\n" }.join)
    File.write(commands_path, JSON.generate(entries))
  end
  audit = lambda { MacOSBuildConfiguration.new(policy_path, fixture).audit }
  reject = lambda do |label, &operation|
    begin
      operation.call
    rescue StandardError
      rejections += 1
      puts "rejected=#{label}"
    else
      raise "MACOS_BUILD_CONFIGURATION_TEST_RED: accepted #{label}"
    end
  end

  write.call
  raise 'valid build did not pass' unless audit.call[:result] == 'MACOS_BUILD_CONFIGURATION_GREEN'
  arguments = command.reject { |key, _| key == 'command' }.merge(
    'arguments' => ['/usr/bin/cc', '-arch', 'arm64', '-march=armv8-a', '-c', '/fixture/source with spaces.c']
  )
  write.call(cache, [arguments])
  audit.call

  %w[GGML_NATIVE GGML_CPU_ARM_ARCH GGML_METAL GGML_ACCELERATE CMAKE_OSX_ARCHITECTURES CMAKE_OSX_DEPLOYMENT_TARGET].each do |key|
    write.call(cache.merge(key => 'wrong'))
    reject.call("cache-#{key}") { audit.call }
  end
  %w[-mcpu=native -mcpu=apple-m4 -march=armv9.2-a+sme -mtune=native].each do |flag|
    write.call(cache, [command.merge('command' => "#{command.fetch('command')} #{flag}")])
    reject.call("compiler-#{flag}") { audit.call }
  end
  write.call(cache, [command.merge('command' => command.fetch('command').sub(' -march=armv8-a', ''))])
  reject.call('missing-baseline') { audit.call }
  write.call(cache, [command.merge('file' => '/fixture/whisper.cpp', 'command' => "#{command.fetch('command')} -Xclang +sve")])
  reject.call('feature-override-outside-cpu-backend') { audit.call }
  write.call(cache, [])
  reject.call('empty-compiler-commands') { audit.call }
  write.call
  File.unlink(commands_path)
  reject.call('missing-compiler-commands') { audit.call }
  write.call
  File.unlink(cache_path)
  reject.call('missing-cache') { audit.call }
end
puts "MACOS_BUILD_CONFIGURATION_TEST_GREEN rejections=#{rejections}"
