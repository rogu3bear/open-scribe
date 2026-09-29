#!/usr/bin/env ruby
# Verifier regression fixtures only; no app, audio devices, build, or mount.
require 'tmpdir'
require 'fileutils'
require_relative 'verify_m1_injected'

Dir.mktmpdir('open-scribe-m1-verifier.') do |root|
  session = '01900000-0000-7000-8000-000000000001'
  directory = File.join(root, 'Sessions', session)
  FileUtils.mkdir_p(directory)
  database = File.join(root, 'Library.sqlite3')
  journal_path = File.join(directory, 'recovery.jsonl')
  verifier = File.join(__dir__, 'verify_m1_injected.rb')
  recovery = { 'session_id' => session, 'result' => 'INJECTED_RECOVERY_GREEN',
    'lifecycle' => 'interrupted', 'rendered_frames' => 0, 'recovery_projection' => 'none' }
  checkpoint = { 'session_id' => session, 'phase' => 'preparation', 'pid' => 1 }
  event = { 'event_id' => 'e1', 'session_id' => session, 'event_kind' => 'session_interrupted', 'payload' => {} }
  write = ->(name, value) { File.write(File.join(root, name), JSON.generate(value)) }
  write.call('checkpoint.json', checkpoint)
  write.call('recovery.json', recovery)
  write.call('recovery-first.json', recovery)
  write.call('media-before.json', {})
  File.write(journal_path, JSON.generate(event) + "\n")
  File.write(File.join(root, 'journal-first.sha256'), Digest::SHA256.file(journal_path).hexdigest)
  command('sqlite3', database, <<~SQL)
    CREATE TABLE sessions(id TEXT, lifecycle TEXT);
    CREATE TABLE session_events(id TEXT, session_id TEXT, event_kind TEXT, payload_json TEXT, sequence INTEGER);
    CREATE TABLE segments(relative_path TEXT, digest TEXT, byte_length INTEGER, sample_count INTEGER, channels INTEGER, lifecycle TEXT);
    INSERT INTO sessions VALUES('#{session}', 'interrupted');
    INSERT INTO session_events VALUES('e1', '#{session}', 'session_interrupted', '{}', 1);
  SQL
  run = -> { Open3.capture3('ruby', verifier, 'kill-preparation', root, root) }
  output, error, status = run.call
  demand(status.success? && output.include?('M1_INJECTED_KILL_PREPARATION_GREEN'), "control fixture failed: #{error}")
  cases = [
    ['wrong checkpoint', -> { write.call('checkpoint.json', checkpoint.merge('phase' => 'recording')) },
      -> { write.call('checkpoint.json', checkpoint) }],
    ['foreign session', -> { write.call('recovery.json', recovery.merge('session_id' => 'other')) },
      -> { write.call('recovery.json', recovery) }],
    ['false Recording', -> { command('sqlite3', database, "UPDATE sessions SET lifecycle='recording';") },
      -> { command('sqlite3', database, "UPDATE sessions SET lifecycle='interrupted';") }],
    ['changed recovery', -> { write.call('recovery-first.json', recovery.merge('rendered_frames' => 1)) },
      -> { write.call('recovery-first.json', recovery) }],
    ['missing activity record', -> { File.write(journal_path, JSON.generate(event.merge('event_id' => 'other')) + "\n") },
      -> { File.write(journal_path, JSON.generate(event) + "\n") }],
    ['app error', -> { File.write(File.join(root, 'proof-error'), 'injected failure') },
      -> { File.unlink(File.join(root, 'proof-error')) }],
    ['journal changed on second recovery', -> { File.write(File.join(root, 'journal-first.sha256'), '0' * 64) },
      -> { File.write(File.join(root, 'journal-first.sha256'), Digest::SHA256.file(journal_path).hexdigest) }],
    ['redirected report', -> { File.rename(File.join(root, 'checkpoint.json'), File.join(root, 'saved.json')); File.symlink('saved.json', File.join(root, 'checkpoint.json')) },
      -> { File.unlink(File.join(root, 'checkpoint.json')); File.rename(File.join(root, 'saved.json'), File.join(root, 'checkpoint.json')) }],
  ]
  cases.each do |name, break_fixture, restore|
    break_fixture.call
    _, error, status = run.call
    demand(!status.success? && error.include?('M1_INJECTED_RED:'), "accepted #{name}")
    restore.call
  end
  # The fill helper must refuse the host before opening a filler file.
  volume = File.join(root, 'volume')
  Dir.mkdir(volume)
  _, error, status = Open3.capture3('ruby', File.join(__dir__, 'm1_fill_volume.rb'), volume, root)
  demand(!status.success? && error.include?('not isolated from the host'), 'fill helper admitted host volume')
  demand(!File.exist?(File.join(volume, 'owned-pressure-fill')), 'fill helper wrote before volume admission')
  puts "M1_HARNESS_CONTRACT_GREEN cases=#{cases.length + 2}"
  puts 'proof=verifier_control_and_rejection_fixtures,host_volume_refused_before_write'
  puts 'excludes=app_build,app_runtime,injected_failure_acceptance,m1_completion'
end
