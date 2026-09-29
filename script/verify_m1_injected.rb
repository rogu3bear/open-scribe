#!/usr/bin/env ruby
# Independent readback of the app's injected proof, SQLite, JSONL, and CAFs.
require 'json'
require 'digest'
require 'open3'

def demand(value, message)
  raise message unless value
end

def read_json(path)
  demand(File.file?(path) && !File.symlink?(path), "missing/redirected report: #{path}")
  JSON.parse(File.read(path))
end

def command(*arguments)
  stdout, stderr, status = Open3.capture3(*arguments)
  demand(status.success?, "#{arguments.first} failed: #{stderr}")
  stdout
end

def query(database, sql)
  result = command('sqlite3', '-readonly', '-json', database, sql)
  JSON.parse(result.strip.empty? ? '[]' : result)
end

def verify_media(root, session, segments, proof_root)
  demand(!segments.empty?, 'no source media')
  segments.each_with_index do |segment, index|
    path = File.expand_path("Sessions/#{session}/#{segment.fetch('relative_path')}", root)
    demand(path.start_with?("#{File.expand_path(root)}/Sessions/#{session}/") && !File.symlink?(path), 'media escaped root')
    demand(segment['lifecycle'] == 'sealed', 'unsealed media after recovery/finalization')
    demand(Digest::SHA256.file(path).hexdigest == segment.fetch('digest'), 'Rust media digest differs')
    demand(File.size(path) == segment.fetch('byte_length'), 'Rust media byte count differs')
    demand(segment.fetch('sample_count') >= 48_000, 'lost pre-event audio')
    command('/usr/bin/afinfo', path)
    wave = File.join(proof_root, "decoded-#{index}.wav")
    command('/usr/bin/afconvert', path, wave, '-f', 'WAVE', '-d', 'LEI16')
    bytes = File.binread(wave)
    demand(bytes[0, 4] == 'RIFF' && bytes[8, 4] == 'WAVE', 'independent decode is not WAVE')
    offset = 12
    pcm = nil
    while offset + 8 <= bytes.bytesize
      size = bytes[offset + 4, 4].unpack1('V')
      pcm = bytes[offset + 8, size] if bytes[offset, 4] == 'data'
      offset += 8 + size + size % 2
    end
    channels = segment.fetch('channels')
    demand([1, 2].include?(channels) && pcm, 'missing PCM channel layout')
    demand(pcm.bytesize == segment.fetch('sample_count') * channels * 2, 'independent decoded frame count differs')
    expected = channels == 1 ? [8192] : [16384, -8192]
    demand(pcm.unpack('s<*').each_slice(channels).all? { |frame| frame == expected },
      'pre-event PCM or channel identity changed')
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    scenario, proof_root, media_root = ARGV
    demand(ARGV.length == 3, 'usage: verify_m1_injected.rb CASE PROOF_ROOT MEDIA_ROOT')
    demand(!File.exist?(File.join(proof_root, 'proof-error')), 'app reported proof-error')
    forced = scenario.start_with?('kill-')
    exhausted = scenario == 'storage-exhaustion'
    report = read_json(File.join(proof_root, forced ? 'checkpoint.json' : 'outcome.json'))
    session = report.fetch('session_id')
    demand(session.match?(/\A[0-9a-f-]{36}\z/), 'invalid session identity')
    database = File.join(media_root, 'Library.sqlite3')
    sessions = query(database, 'SELECT id, lifecycle FROM sessions;')
    demand(sessions.length == 1 && sessions[0]['id'] == session, 'unexpected session set')
    events = query(database, "SELECT id, sequence, event_kind, payload_json FROM session_events WHERE session_id = '#{session}' ORDER BY sequence;")
    journal = File.readlines(File.join(media_root, 'Sessions', session, 'recovery.jsonl')).map { |line| JSON.parse(line) }
    demand(!journal.empty?, 'empty activity journal')
    # Preparation intentionally creates a SQLite intent before the directory
    # exists, then independently creates journal sequence 1. Those two SQLite
    # events have distinct IDs/payloads; subsequent events share journal IDs.
    demand(events.length >= 3 && events[0]['sequence'] == 1 &&
      events[0]['event_kind'] == 'session_create_intent' &&
      JSON.parse(events[0]['payload_json']) == { 'origin' => 'capture' } &&
      events[1]['sequence'] == 2 && events[1]['event_kind'] == 'session_directory_ready' &&
      JSON.parse(events[1]['payload_json']) == { 'relative_path' => '.' }, 'invalid database preparation')
    first = journal.first
    demand(first['sequence'] == 1 && first['session_id'] == session &&
      first['event_kind'] == 'session_directory_ready' && first['relative_path'] == '.' &&
      first['prior_digest'].nil? && first['payload'] == { 'subdirectories' => %w[audio video context exports] },
      'missing or invalid independent preparation journal')
    demand(journal.length == events.length - 1, 'journal/database event counts differ')
    events.drop(2).zip(journal.drop(1)).each do |event, record|
      demand(record['event_id'] == event['id'] &&
        record['session_id'] == session && record['event_kind'] == event['event_kind'] &&
        record['sequence'] == event['sequence'] - 1 &&
        record['payload'] == JSON.parse(event['payload_json']), 'database event lacks matching journal record')
    end
    kinds = events.map { |event| event['event_kind'] }
    if forced || exhausted
      recovery = read_json(File.join(proof_root, 'recovery.json'))
      demand(recovery['result'] == 'INJECTED_RECOVERY_GREEN' && recovery['session_id'] == session,
        'recovery report is not green for this session')
      demand(recovery == read_json(File.join(proof_root, 'recovery-first.json')), 'recovery projection is not idempotent')
      before = read_json(File.join(proof_root, 'media-before.json'))
      before.each do |path, digest|
        demand(Digest::SHA256.file(path).hexdigest == digest, 'pre-recovery source media changed')
      end
      demand(File.read(File.join(proof_root, 'journal-first.sha256')).strip ==
        Digest::SHA256.file(File.join(media_root, 'Sessions', session, 'recovery.jsonl')).hexdigest,
        'second launch appended recovery events')
    end
    if forced
      demand(report['phase'] == scenario.delete_prefix('kill-'), 'wrong termination checkpoint')
    else
      demand(report['scenario'] == scenario && !report.fetch('visible_message').empty?, 'event lacks native visible projection')
      demand(!report.fetch('fallback').empty?, 'no explicit fallback/stop')
      if exhausted
        demand(report['result'] == 'EXHAUSTION_OBSERVED_REQUIRES_RECOVERY' && report['write_failed'],
          'real media write did not fail on the dedicated full volume')
        demand(File.read(File.join(proof_root, 'volume-fill.log')).include?('ENOSPC_OBSERVED'), 'no real filesystem exhaustion')
        # Recovery by itself cannot qualify the failure event. The disk/source
        # failure must also have reached Rust's activity journal.
        before_events = read_json(File.join(proof_root, 'events-before-recovery.json'))
        failures = before_events.select { |event| ['source_failed', 'session_interrupted'].include?(event['event_kind']) ||
          (event['event_kind'] == 'storage_observed' && JSON.parse(event['payload_json'])['level'] == 'critical') }
        before_journal = File.readlines(File.join(proof_root, 'journal-before-free.jsonl')).map { |line| JSON.parse(line) }
        demand(!failures.empty? && failures.all? { |event| before_journal.any? { |record|
          record['event_id'] == event['id'] && record['session_id'] == session &&
            record['event_kind'] == event['event_kind'] && record['payload'] == JSON.parse(event['payload_json']) } },
          'exhaustion event was not durably logged before freeing space')
      else
        demand(report['result'] == 'INJECTED_CASE_GREEN', 'app did not pass')
        expected = case scenario
                   when 'storage-warning', 'storage-critical' then ['storage_observed']
                   when 'sleep-wake' then ['system_sleep_observed', 'capture_paused', 'system_wake_observed']
                   when 'microphone-loss', 'system-loss', 'application-loss', 'selected-app-exit' then ['source_failed']
                   else raise 'unknown scenario'
                   end
        demand(expected.all? { |kind| kinds.include?(kind) && report.fetch('visible_events').include?(kind) },
          'event is not present in both journal and visible projection')
        demand(kinds.include?('marker_added'), 'durable marker missing')
      end
    end
    segments = query(database, 'SELECT relative_path, digest, byte_length, sample_count, channels, lifecycle FROM segments ORDER BY relative_path;')
    if scenario == 'kill-preparation'
      demand(segments.empty? && sessions[0]['lifecycle'] == 'interrupted', 'preparation falsely claims preserved audio')
      demand(!kinds.include?('recording_started'), 'preparation was reported Recording')
    else
      demand(sessions[0]['lifecycle'] == 'ready_for_review', 'media is not reviewable')
      verify_media(media_root, session, segments, proof_root)
    end
    puts "M1_INJECTED_#{scenario.tr('-', '_').upcase}_GREEN"
    puts 'proof=production_controller_projection,rust_activity_journal,source_media_digests,independent_pcm_decode,explicit_fallback_or_stop'
    puts 'excludes=physical_device_events,tcc,rendered_accessibility,perceptual_playback,long_session_drift,m1_completion'
  rescue StandardError => error
    warn "M1_INJECTED_RED: #{error.message}"
    exit 1
  end
end
