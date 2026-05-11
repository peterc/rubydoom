#!/usr/bin/env ruby
# Wraps bin/rubydoom in StackProf.run for a fixed wall-clock duration,
# then exits (closes the window). Output: tmp/rubydoom-stackprof.dump.
#
# Usage:
#   bundle exec ruby scripts/profile_game.rb [seconds]    # default 8
#
# After running:
#   bundle exec stackprof tmp/rubydoom-stackprof.dump --text --limit 40
require "stackprof"

DURATION = (ARGV[0] || ENV["RUBYDOOM_PROFILE_SECONDS"] || 8).to_f
OUTPUT   = File.expand_path("../tmp/rubydoom-stackprof.dump", __dir__)
ARGV.clear   # don't let bin/rubydoom see our duration arg

RubyVM::YJIT.enable if defined?(RubyVM::YJIT) && !RubyVM::YJIT.enabled?

require_relative "../lib/rubydoom"

# Auto-close the window after DURATION seconds. We hook the Gosu update
# loop on the App's update method (App < Gosu::Window).
module ProfileTimer
  def initialize(*args, **kwargs)
    super
    @profile_start = Gosu.milliseconds
  end

  def update
    super
    if Gosu.milliseconds - @profile_start > DURATION * 1000
      close
    end
  end
end
Rubydoom::App.prepend(ProfileTimer)

# Skip the title hold so we profile actual gameplay rendering.
Rubydoom::App.send(:remove_const, :TITLE_HOLD_TICS) rescue nil
Rubydoom::App.const_set(:TITLE_HOLD_TICS, 0)

puts "[profile] capturing #{DURATION}s into #{OUTPUT}"
StackProf.run(mode: :cpu, raw: false, interval: 1000, out: OUTPUT) do
  Rubydoom::App.new(
    wad_path: File.expand_path("../doom1.wad", __dir__),
    map_name: "E1M1",
  ).show
end
puts "[profile] done"
