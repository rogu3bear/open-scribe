#!/usr/bin/env ruby
# Explicit, read-only counterexamples. No builds, capture, network, or settings.
require 'digest'
require 'fiddle'

ROOT = File.expand_path('..', __dir__)
MACROS = [
  ['cold-web-before', 'librustversion-17dac35b24647178.dylib',
   '11077e2cf6f5ad7583ffc05896f0271b990da0600e1602d3e11eac9e26468b71'],
  ['cold-web-after', 'librustversion-5dd8ff292c2c4f88.dylib',
   '5fc0ec3394b575426b91c6003f1a24b5641f5144060672d110f913b4a0c29593']
].freeze

def macro_result(path, expected, rejection_expected, loader = Fiddle.method(:dlopen))
  return ['STALE', 'artifact_missing'] unless File.file?(path)
  return ['STALE', 'artifact_hash_changed'] unless Digest::SHA256.file(path).hexdigest == expected

  begin
    loader.call(path)
    rejection_expected ? ['FAIL', 'counterexample_now_loads'] : ['PASS', 'control_loads']
  rescue Fiddle::DLError => error
    if rejection_expected && error.message.include?('mis-aligned LINKEDIT string pool')
      ['PASS', 'existing_artifact_rejected_by_loader']
    else
      ['STALE', 'expected_loader_observation_unavailable']
    end
  end
end

def sampling_result(samples, interval)
  observed = samples.count { |instant| interval.cover?(instant) }
  observed.zero? ? ['PASS', 'short_lived_socket_missed'] : ['FAIL', 'socket_sampled']
end

mode = ARGV.shift || '--all'
abort 'usage: ruby script/check_nuance.rb [--all|--proc-macro|--sampling|--self-test]' unless
  ARGV.empty? && %w[--all --proc-macro --sampling --self-test].include?(mode)
results = []
if %w[--all --proc-macro].include?(mode)
  MACROS.each_with_index do |(target, name, digest), index|
    path = File.join(ROOT, 'artifacts/build-once', target, 'release/deps', name)
    results << [target, *macro_result(path, digest, index.zero?)]
  end
end
if %w[--all --sampling].include?(mode)
  # Same sampling schedule, independent of the production workflow. A positive
  # control overlapping a sample prevents a vacuous always-zero detector.
  missed = sampling_result([0, 1, 2], (0.2...0.3))
  detected = sampling_result([0, 1, 2], (0.2...1.3))
  status = missed.first == 'PASS' && detected.first == 'FAIL' ? 'PASS' : 'FAIL'
  results << ['sampling', status, 'missed_between_samples_and_detected_at_sample']
end
if mode == '--self-test'
  require 'tmpdir'
  Dir.mktmpdir('open-scribe-nuance-') do |root|
    path = File.join(root, 'artifact')
    File.write(path, 'controlled fixture')
    digest = Digest::SHA256.file(path).hexdigest
    loadable = ->(_) { true }
    rejected = ->(_) { raise Fiddle::DLError, 'mis-aligned LINKEDIT string pool' }
    unavailable = ->(_) { raise Fiddle::DLError, 'unsupported loader' }
    cases = [
      [macro_result(path, digest, true, rejected).first, 'PASS'],
      [macro_result(path, digest, true, loadable).first, 'FAIL'],
      [macro_result(path, digest, false, loadable).first, 'PASS'],
      [macro_result(path, digest, true, unavailable).first, 'STALE'],
      [macro_result(path, 'changed digest', true, rejected).first, 'STALE'],
      [macro_result(File.join(root, 'missing'), digest, true, rejected).first, 'STALE']
    ]
    results << ['status-controls', cases.all? { |actual, expected| actual == expected } ? 'PASS' : 'FAIL',
                'pass_fail_missing_changed_and_unavailable_controls']
  end
end
results.each { |name, status, reason| puts "#{status} #{name} #{reason}" }
exit(results.any? { |_, status, _| status == 'FAIL' } ? 1 :
     results.any? { |_, status, _| status == 'STALE' } ? 2 : 0)
