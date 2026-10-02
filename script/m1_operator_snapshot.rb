#!/usr/bin/env ruby
# Supporting observations only. This never admits M1 or starts capture.
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'time'

options = {}
parser = OptionParser.new do |p|
  p.banner = 'Usage: ruby script/m1_operator_snapshot.rb --candidate RECORD --library ROOT --step NAME --phase before|after|recovery --notes JSON --output NEW_DIRECTORY'
  %w[candidate library step phase notes output].each do |name|
    p.on("--#{name} VALUE") { |value| options[name] = value }
  end
  p.on('--help') { puts p; exit }
end

def regular_file!(path)
  raise "missing or redirected file: #{path}" unless File.file?(path) && !File.symlink?(path)
end

def command!(*arguments)
  output, error, status = Open3.capture3(*arguments)
  raise "command failed (#{arguments.first}): #{error.strip}" unless status.success?
  output
end

begin
  parser.parse!
  raise 'unexpected positional arguments' unless ARGV.empty?
  required = %w[candidate library step phase notes output]
  raise "required: #{required.join(', ')}" unless required.all? { |key| options[key] }
  %w[candidate library notes output].each do |key|
    value = options.fetch(key)
    raise "#{key} must be an absolute path" unless value.start_with?('/') && !value.include?("\n")
  end
  raise 'invalid step name' unless options['step'].match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
  raise 'invalid phase' unless %w[before after recovery].include?(options['phase'])
  record_path = options.fetch('candidate')
  notes_path = options.fetch('notes')
  regular_file!(record_path)
  regular_file!(notes_path)
  notes_bytes = File.binread(notes_path)
  notes = JSON.parse(notes_bytes)
  %w[observer observation_source action visible_state recovery_outcome].each do |key|
    raise "notes require a nonempty #{key}" unless notes[key].is_a?(String) && !notes[key].strip.empty?
  end
  unless %w[operator native_and_operator].include?(notes['observation_source'])
    raise 'observation_source must distinguish operator from native_and_operator'
  end
  repo = File.realpath(File.join(__dir__, '..'))
  helper = File.join(repo, 'script/candidate.sh')
  # Arguments are data; no paths or notes are interpolated into shell code.
  admission = 'set -euo pipefail; repo_root="$2"; cd "$repo_root"; source "$3"; candidate_load "$1"; candidate_require_checks; candidate_receipt'
  binding = command!('bash', '-c', admission, 'operator-snapshot', record_path, repo, helper)
  record = JSON.parse(File.read(record_path))
  record_digest = Digest::SHA256.file(record_path).hexdigest
  root = options.fetch('library')
  raise 'library must be an existing canonical directory' unless File.directory?(root) && File.realpath(root) == root
  output = options.fetch('output')
  parent = File.dirname(output)
  raise 'output parent must be a canonical directory' unless File.directory?(parent) && File.realpath(parent) == parent
  raise 'preserve existing output; choose a new directory' if File.exist?(output) || File.symlink?(output)
  raise 'snapshot output must be outside the managed library' if output == root || output.start_with?(root + '/')
  Dir.mkdir(output, 0o700)
  File.binwrite(File.join(output, 'notes.json'), notes_bytes)
  File.write(File.join(output, 'candidate-binding.log'), binding)
  FileUtils.copy_file(record_path, File.join(output, 'candidate.json'))
  receipt = {
    schema: 1, result: 'OPERATOR_OBSERVATION', human_acceptance: false,
    candidate_sha256: record_digest, commit: record.fetch('sha'), tree: record.fetch('tree'),
    artifacts: record.fetch('artifacts'), observed_at_utc: Time.now.utc.iso8601(6),
    step: options.fetch('step'), phase: options.fetch('phase'), library: root,
    notes_sha256: Digest::SHA256.hexdigest(notes_bytes), observation_source: notes.fetch('observation_source'),
    platform: {version: command!('sw_vers', '-productVersion').strip,
               build: command!('sw_vers', '-buildVersion').strip},
    journals: [], media: [], evidence_errors: []
  }
  database = File.join(root, 'Library.sqlite3')
  segments = []
  if File.exist?(database)
    regular_file!(database)
    backup = File.join(output, 'projection.sqlite3')
    command!('sqlite3', '-readonly', database, ".backup #{backup.dump}")
    %w[sessions required_sources sources tracks segments session_events markers imports recovery_runs].each do |table|
      body = command!('sqlite3', '-readonly', '-json', backup, "SELECT * FROM #{table};")
      rows = body.strip.empty? ? [] : JSON.parse(body)
      File.write(File.join(output, "#{table}.json"), JSON.pretty_generate(rows) + "\n")
      segments = rows if table == 'segments'
    end
    receipt[:projection_sha256] = Digest::SHA256.file(backup).hexdigest
  else
    receipt[:projection_state] = 'not_created'
  end
  Dir.glob(File.join(root, 'Sessions', '*', 'recovery.jsonl')).sort.each_with_index do |path, index|
    regular_file!(path)
    raise "redirected journal: #{path}" unless File.realpath(path).start_with?(root + '/')
    bytes = File.binread(path)
    destination = "journal-#{index}.jsonl"
    File.binwrite(File.join(output, destination), bytes)
    receipt[:journals] << {path: path.delete_prefix(root + '/'), saved_as: destination,
                          sha256: Digest::SHA256.hexdigest(bytes), bytes: bytes.bytesize,
                          trailing_partial_line: !bytes.empty? && !bytes.end_with?("\n")}
  end
  Dir.glob(File.join(root, 'Sessions', '**', '*.{caf,m4a,wav}')).sort.each do |path|
    relative = path.delete_prefix(root + '/')
    if File.symlink?(path) || !File.file?(path) || !File.realpath(path).start_with?(root + '/')
      receipt[:evidence_errors] << "redirected media: #{relative}"
      next
    end
    before = File.stat(path)
    digest = Digest::SHA256.file(path).hexdigest
    after = File.stat(path)
    stable = [before.size, before.mtime, before.ino, before.dev] == [after.size, after.mtime, after.ino, after.dev]
    entry = {path: relative, sha256: digest, bytes: after.size, stable_during_read: stable}
    segment = segments.find { |row| relative == "Sessions/#{row['session_id']}/#{row['relative_path']}" }
    if segment
      entry[:seal_state] = segment['seal_state']
      entry[:expected_sha256] = segment['digest']
      if segment['digest']
        entry[:matches_rust_receipt] = stable && digest == segment['digest'] && after.size == segment['byte_length']
        receipt[:evidence_errors] << "sealed media differs: #{relative}" unless entry[:matches_rust_receipt]
      end
    end
    receipt[:media] << entry
  end
  segments.select { |row| row['digest'] }.each do |row|
    expected = "Sessions/#{row['session_id']}/#{row['relative_path']}"
    unless receipt[:media].any? { |entry| entry[:path] == expected }
      receipt[:evidence_errors] << "sealed media missing: #{expected}"
    end
  end
  # Rebind after reading. A changed candidate never acquires an observation receipt.
  command!('bash', '-c', admission, 'operator-snapshot', record_path, repo, helper)
  raise 'candidate record changed' unless Digest::SHA256.file(record_path).hexdigest == record_digest
  receipt[:excludes] = %w[atomic_journal_and_projection_snapshot live_media_immutability audible_playback
                          human_matrix_acceptance two_hour_drift m1_completion signing release]
  File.write(File.join(output, 'observation.json'), JSON.pretty_generate(receipt) + "\n")
  puts "OPERATOR_SNAPSHOT_SAVED output=#{output} candidate_sha256=#{record_digest} evidence_errors=#{receipt[:evidence_errors].length}"
  exit(receipt[:evidence_errors].empty? ? 0 : 1)
rescue StandardError => error
  warn "OPERATOR_SNAPSHOT_RED: #{error.message}"
  exit 1
end
