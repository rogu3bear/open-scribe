#!/usr/bin/env ruby
# Structural source/generated API validation. Generated-binding identity is checked
# independently by build_and_run/build_candidate against fresh UniFFI output.
require 'pathname'

module CoarseFFI
  GEOMETRY = %w[NativeContextBounds NativeDisplayTopology NativeContextTextBlock].freeze
  def self.code(source)
    output = +''
    i = 0
    while i < source.length
      if source[i, 2] == '//'
        i = source.index("\n", i) || source.length
      elsif source[i, 2] == '/*'
        depth = 1; i += 2
        while i < source.length && depth > 0
          if source[i, 2] == '/*' then depth += 1; i += 2
          elsif source[i, 2] == '*/' then depth -= 1; i += 2
          else i += 1 end
        end
        output << ' '
      elsif source[i] == 'r' && (raw = source[i..].match(/\Ar(\#*)"/))
        ending = '"' + raw[1]
        i = (source.index(ending, i + raw[0].length) || (source.length - ending.length)) + ending.length
        output << '""'
      elsif source[i] == '"'
        i += 1
        while i < source.length
          if source[i] == '\\' then i += 2
          elsif source[i] == '"' then i += 1; break
          else i += 1 end
        end
        output << '""'
      else
        output << source[i]; i += 1
      end
    end
    output
  end
  def self.bodies(source, pattern)
    source.to_enum(:scan, pattern).map do
      match = Regexp.last_match
      depth = 1
      index = match.end(0)
      start = index
      while index < source.length && depth > 0
        depth += 1 if source[index] == '{'
        depth -= 1 if source[index] == '}'
        index += 1
      end
      [match[1], source[start...index - 1]]
    end
  end
  def self.validate(source, name, shared_aliases = {})
    source = code(source)
    aliases = shared_aliases.merge(source.scan(/\btype\s+(\w+)\s*=\s*([^;]+);/m).to_h)
    failures = []
    # Every public signature is an over-approximation of exported impl methods.
    surfaces = source.scan(/pub\s+fn\s+\w+\s*\([^{};]*?\)(?:\s*->\s*[^{};]+)?\s*\{/m).map { |signature| ['signature', signature] }
    surfaces.concat(bodies(source, /#\s*\[derive\([^\]]*uniffi::(?:Record|Enum|Error)[^\]]*\)\](?:\s*#\[[^\]]*\])*\s*(?:pub(?:\([^)]*\))?\s+)?(?:struct|enum)\s+(\w+)\s*\{/m))
    surfaces.each do |owner, surface|
      aliases.length.times do
        changed = surface.gsub(/\b\w+\b/) { |type| aliases.fetch(type, type) }
        break if changed == surface
        surface = changed
      end
      # Nullability cannot turn a numeric collection into coarse metadata.
      loop do
        changed = surface.gsub(/\b(?:\w+::)*Option\s*<\s*([^<>]+)\s*>/, '\1')
        break if changed == surface
        surface = changed
      end
      # Numeric vectors/slices/arrays and opaque buffers are media-shaped even
      # with neutral names. Native geometry has narrowly listed scalar owners.
      if surface.match?(/(?:Vec|Box|Arc)\s*<\s*(?:Vec\s*<\s*)?(?:u\d+|i\d+|f\d+|\[)/) ||
         surface.match?(/\[\s*(?:u\d+|i\d+|f\d+)\s*(?:;|\])/ ) ||
         surface.match?(/\b(?:RustBuffer|ForeignBytes|c_void|RawPointer|NonNull)\b|\*\s*(?:const|mut)\b/) ||
         (surface.match?(/\bf(?:32|64)\b/) && !GEOMETRY.include?(owner))
        failures << "#{name}: #{owner}: disallowed payload type"
      end
    end
    failures
  end

  def self.validate_swift(source, name)
    source = code(source)
    surfaces = bodies(source, /(?:public|open)\s+(?:struct|enum|class|protocol)\s+(\w+)[^{]*\{/m)
    failures = []
    surfaces.each do |owner, body|
      next if owner.start_with?('FfiConverter')
      fields = body.scan(/public\s+(?:let|var)\s+\w+\s*:\s*([^\n{]+)/).flatten
      signatures = body.scan(/(?:public|open)\s+(?:static\s+)?func\s+[^{}]+(?=\{)/m)
      variants = body.scan(/case\s+\w+\s*\([^\n]+/m)
      (fields + signatures + variants).each do |surface|
        if surface.match?(/\[\s*(?:U?Int\d*|Float|Double)\s*\??\s*\]|\bArray\s*<\s*(?:U?Int\d*|Float|Double)/) ||
           surface.match?(/\b(?:Data|RustBuffer|ForeignBytes|OpaquePointer|Unsafe\w*Pointer)\b/) ||
           (surface.match?(/\b(?:Float|Double)\b/) && !GEOMETRY.include?(owner))
          failures << "#{name}: #{owner}: disallowed generated API payload type"
        end
      end
    end
    failures
  end
end

if $PROGRAM_NAME == __FILE__
  if ARGV == ['--self-test']
    comment = "// no PCM or pointer samples cross here\n#[derive(uniffi::Record)] pub struct Receipt { pub count: u64 }"
    neutral = '#[derive(uniffi::Record)] pub struct Notice { pub values: Vec<u8> }'
    signature = '#[uniffi::export] impl Bridge { pub fn notice(&self) -> Vec<f32> { unreachable!() } }'
    alias_payload = 'type Notice = Vec<u8>; #[derive(uniffi::Record)] pub struct Envelope { pub values: Notice }'
    raise 'harmless comment rejected' unless CoarseFFI.validate(comment, 'comment').empty?
    raise 'neutral record bypassed' if CoarseFFI.validate(neutral, 'neutral').empty?
    raise 'optional numeric collection bypassed' if CoarseFFI.validate('#[derive(uniffi::Record)] pub struct Notice { pub values: Vec<Option<u8>> }', 'optional').empty?
    raise 'optional text metadata rejected' unless CoarseFFI.validate('#[derive(uniffi::Record)] pub struct Receipt { pub labels: Vec<Option<String>> }', 'optional-text').empty?
    raise 'neutral signature bypassed' if CoarseFFI.validate(signature, 'signature').empty?
    raise 'alias bypassed' if CoarseFFI.validate(alias_payload, 'alias').empty?
    raise 'cross-module alias bypassed' if CoarseFFI.validate('#[derive(uniffi::Record)] pub struct Envelope { pub values: Neutral }', 'module', {'Neutral' => 'Vec<u8>'}).empty?
    raise 'enum payload bypassed' if CoarseFFI.validate('#[derive(uniffi::Enum)] pub enum Notice { Data { values: Vec<u8> } }', 'enum').empty?
    raise 'generated numeric collection bypassed' if CoarseFFI.validate_swift('public struct Notice { public let values: [UInt8] }', 'swift').empty?
    raise 'generated optional numeric collection bypassed' if CoarseFFI.validate_swift('public struct Notice { public let values: [UInt8?] }', 'swift-optional').empty?
    raise 'generated optional text metadata rejected' unless CoarseFFI.validate_swift('public struct Receipt { public let labels: [String?] }', 'swift-optional-text').empty?
    raise 'generated method bypassed' if CoarseFFI.validate_swift('open class Notice { open func next() -> [Double] { fatalError() } }', 'swift-method').empty?
    raise 'generated enum bypassed' if CoarseFFI.validate_swift('public enum Notice { case item(values: [UInt8]) }', 'swift-enum').empty?
    raise 'generated scalar receipt rejected' unless CoarseFFI.validate_swift("public struct Receipt { public let count: UInt64\n public let id: String }", 'swift-receipt').empty?
    raise 'nested comment changed code' unless CoarseFFI.validate('/* outer /* inner */ pub fn neutral()->Vec<u8>{} */' + comment, 'nested').empty?
    puts 'FFI_SURFACE_TEST_GREEN: comments, aliases, nullable/neutral payloads, generated APIs, coarse metadata'
  else
    paths = ARGV.empty? ? Dir['crates/open-scribe-uniffi/src/*.rs'] : ARGV
    aliases = paths.reject { |path| path.end_with?('.swift') }.flat_map { |path| CoarseFFI.code(File.read(path)).scan(/\btype\s+(\w+)\s*=\s*([^;]+);/m) }.to_h
    paths << 'apps/macos/Sources/OpenScribeApp/Generated/OpenScribeCore.swift' if ARGV.empty?
    failures = paths.flat_map do |path|
      path.end_with?('.swift') ? CoarseFFI.validate_swift(File.read(path), path) : CoarseFFI.validate(File.read(path), path, aliases)
    end
    abort failures.join("\n") unless failures.empty?
    puts 'FFI_SURFACE_GREEN: Rust and generated Swift API types; static scope only'
  end
end
