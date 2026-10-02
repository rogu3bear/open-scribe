#!/usr/bin/env ruby
# Only the task-created mounted disk image may be filled, never the host volume.
require 'json'

# A refused 1 MiB write can leave most of a MiB free, enough for a later media
# write to succeed. Step down to the 4 KiB APFS block so the volume is full.
CHUNK_SIZES = [1024 * 1024, 64 * 1024, 4096].freeze

begin
  volume, proof_root = ARGV
  raise 'usage: m1_fill_volume.rb VOLUME PROOF_ROOT' unless ARGV.length == 2
  raise 'volume is not isolated from the host' if File.stat(volume).dev == File.stat(proof_root).dev
  raise 'unexpected volume path' unless File.realpath(volume) == File.join(File.realpath(proof_root), 'volume')
  filler = File.join(volume, 'owned-pressure-fill')
  written = 0
  File.open(filler, File::WRONLY | File::CREAT | File::EXCL, 0600) do |file|
    random = Random.new(1)
    CHUNK_SIZES.each do |size|
      chunk = random.bytes(size)
      begin
        # A hard bound also protects against a wrongly sized image.
        while written < 2 * 1024 * 1024 * 1024
          written += file.syswrite(chunk)
        end
        raise 'volume did not exhaust within its 2 GiB bound'
      rescue Errno::ENOSPC
        next
      end
    end
  end
  puts "ENOSPC_OBSERVED bytes_written=#{written} smallest_refused_bytes=#{CHUNK_SIZES.last}"
rescue StandardError => error
  warn "M1_VOLUME_RED: #{error.message}"
  exit 1
end
