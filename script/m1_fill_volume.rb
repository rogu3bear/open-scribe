#!/usr/bin/env ruby
# Only the task-created mounted disk image may be filled, never the host volume.
require 'json'

begin
  volume, proof_root = ARGV
  raise 'usage: m1_fill_volume.rb VOLUME PROOF_ROOT' unless ARGV.length == 2
  raise 'volume is not isolated from the host' if File.stat(volume).dev == File.stat(proof_root).dev
  raise 'unexpected volume path' unless File.realpath(volume) == File.join(File.realpath(proof_root), 'volume')
  filler = File.join(volume, 'owned-pressure-fill')
  written = 0
  begin
    File.open(filler, File::WRONLY | File::CREAT | File::EXCL, 0600) do |file|
      chunk = Random.new(1).bytes(1024 * 1024)
      # A hard bound also protects against a wrongly sized image.
      while written < 2 * 1024 * 1024 * 1024
        written += file.syswrite(chunk)
      end
      raise 'volume did not exhaust within its 2 GiB bound'
    end
  rescue Errno::ENOSPC
    puts "ENOSPC_OBSERVED bytes_written=#{written}"
  end
rescue StandardError => error
  warn "M1_VOLUME_RED: #{error.message}"
  exit 1
end
