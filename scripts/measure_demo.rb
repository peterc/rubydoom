#!/usr/bin/env ruby
# Repeated headless measurements, or a separate all-frame verification pass.
# Examples:
#   bundle exec ruby scripts/measure_demo.rb --yjit scripts/demo.rdm
#   bundle exec ruby scripts/measure_demo.rb --verify scripts/demo.rdm
#   bundle exec ruby scripts/measure_demo.rb --lib /path/to/baseline/lib scripts/demo.rdm
require "optparse"
require "json"
require "digest"
$stdout.sync = true

options = { runs: 5, warmup: 1, lib: File.expand_path("../lib", __dir__) }
parser = OptionParser.new do |o|
  o.banner = "Usage: ruby scripts/measure_demo.rb [options] demo.rdm [wad]"
  o.on("--runs N", Integer, "Measured replays (default 5)") { |n| options[:runs] = n }
  o.on("--warmup N", Integer, "Unmeasured replays (default 1)") { |n| options[:warmup] = n }
  o.on("--yjit", "Enable YJIT") { options[:yjit] = true }
  o.on("--verify", "Hash every frame in one untimed replay") { options[:verify] = true }
  o.on("--lib PATH", "Library directory for baseline comparisons") { |p| options[:lib] = File.expand_path(p) }
end
parser.parse!
abort parser.to_s unless (1..2).cover?(ARGV.length)
abort "runs must be positive; warmup must be nonnegative" unless options[:runs] > 0 && options[:warmup] >= 0
if options[:yjit]
  abort "YJIT is unavailable in this Ruby" unless defined?(RubyVM::YJIT)
  RubyVM::YJIT.enable
end
require File.join(options[:lib], "rubydoom")

demo = File.expand_path(ARGV[0])
wad = ARGV[1] ? File.expand_path(ARGV[1]) : File.expand_path("../wads/doom1.wad", __dir__)
metadata = {
  ruby: RUBY_DESCRIPTION, library: options[:lib],
  demo_sha256: Digest::SHA256.file(demo).hexdigest,
  wad_sha256: Digest::SHA256.file(wad).hexdigest,
}

if options[:verify]
  module VerifyDemoFrames
    DIGEST = Digest::SHA256.new
    def draw(...)
      super
      DIGEST.update(framebuffer.rgba)
    end
  end
  Rubydoom::Renderer3D.prepend(VerifyDemoFrames)
  result = Rubydoom::HeadlessRunner.new(wad_path: wad, demo_path: demo, quiet: true).run
  puts JSON.generate(metadata.merge(tics: result[:tics], final_frame_sha1: result[:sha1],
                                    all_frames_sha256: VerifyDemoFrames::DIGEST.hexdigest))
else
  samples = []
  (options[:warmup] + options[:runs]).times do |i|
    runner = Rubydoom::HeadlessRunner.new(wad_path: wad, demo_path: demo, quiet: true)
    # Exclude construction and begin each replay with collected garbage.
    GC.start
    result = runner.run
    next if i < options[:warmup]
    samples << result
    puts JSON.generate(result.merge(sample: samples.length))
  end
  abort "Replay outputs differ" unless samples.map { |s| [s[:tics], s[:sha1]] }.uniq.length == 1
  median = lambda do |values|
    sorted = values.sort
    (sorted[(sorted.length - 1) / 2] + sorted[sorted.length / 2]) / 2.0
  end
  puts JSON.generate(metadata.merge(warmup: options[:warmup], runs: options[:runs],
    median_wall: median.call(samples.map { |s| s[:wall] }),
    median_tps: median.call(samples.map { |s| s[:tps] }),
    median_alloc: median.call(samples.map { |s| s[:alloc] }),
    min_wall: samples.map { |s| s[:wall] }.min,
    max_wall: samples.map { |s| s[:wall] }.max))
end
