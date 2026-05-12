require "rake/testtask"
require "fileutils"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning    = false
end

task default: :test

namespace :playground do
  desc "Synthetic arenas for testing"
  task :caco do
    ruby "-Ilib scripts/playground_caco.rb"
  end
  task :bfg do
    ruby "-Ilib scripts/playground_bfg.rb"
  end
  task :skull do
    ruby "-Ilib scripts/playground_skull.rb"
  end
end

namespace :profile do
  desc "Run rubydoom under stackprof (MAP=E1M1 WAD=doom1.wad OUT=tmp/rubydoom-stackprof.dump)"
  task :game do
    require "stackprof"

    out = ENV.fetch("OUT", "tmp/rubydoom-stackprof.dump")
    FileUtils.mkdir_p(File.dirname(out))

    args = ["bin/rubydoom"]
    args += ["--map", ENV["MAP"]] if ENV["MAP"]
    args << ENV["WAD"] if ENV["WAD"]

    puts "Profiling: #{args.join(" ")}"
    puts "Output: #{out}"

    StackProf.run(mode: :cpu, out: out, interval: Integer(ENV.fetch("INTERVAL", "1000"))) do
      ARGV.replace(args[1..])
      load args[0]
    end
  end
end
