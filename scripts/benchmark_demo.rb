#!/usr/bin/env ruby
# Headless benchmark: run a recorded demo as fast as Ruby can drive
# the sim + framebuffer rasterizer. No Gosu window, no GL, no vsync,
# no GPU upload. Reports tics/sec, GC, and a final-frame SHA-1 so the
# byte-output can be compared across JIT modes.
#
#   Record a demo (interactive, normal play):
#     RUBYDOOM_RECORD=demo.rdm RUBYDOOM_SEED=42 bin/rubydoom
#
#   Benchmark it:
#     bundle exec ruby scripts/benchmark_demo.rb demo.rdm
#
#   Compare JIT modes (same SHA-1 expected):
#     bundle exec ruby scripts/benchmark_demo.rb demo.rdm
#     RUBYDOOM_DISABLE_YJIT=1 bundle exec ruby scripts/benchmark_demo.rb demo.rdm
#
# This is a wrapper around Rubydoom::HeadlessRunner — bin/rubydoom
# dispatches there too when RUBYDOOM_BENCHMARK is set. The script
# exists so you don't have to remember the env-var dance.

RubyVM::YJIT.enable if defined?(RubyVM::YJIT) && !RubyVM::YJIT.enabled? &&
                      ENV["RUBYDOOM_DISABLE_YJIT"].nil?

require_relative "../lib/rubydoom"

demo_path = ARGV[0] or abort "Usage: ruby scripts/benchmark_demo.rb path/to/demo.rdm [wad]"
abort "demo file not found: #{demo_path}" unless File.exist?(demo_path)
wad_path  = ARGV[1] || File.expand_path("../wads/doom1.wad", __dir__)
abort "wad not found: #{wad_path}" unless File.exist?(wad_path)

Rubydoom::HeadlessRunner.new(wad_path: wad_path, demo_path: demo_path).run
