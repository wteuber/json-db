# frozen_string_literal: true

# Reproduces the figures in the README's "Performance and trade-offs" section.
#
#   bundle exec ruby benchmark/run.rb [record_count]
#
# Everything runs in a temporary directory that is removed afterwards.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "json_db"
require "tmpdir"

COUNT = (ARGV[0] || 5_000).to_i

def timed
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
end

def report(label, value)
  puts format("  %-46s %s", label, value)
end

class Plain < JsonDb::Base
  attribute :name, :string
  attribute :email, :string
  attribute :n, :integer
end

class Indexed < JsonDb::Base
  attribute :name, :string
  attribute :email, :string
  attribute :n, :integer

  index :email
end

class Bulk < JsonDb::Base
  attribute :email, :string
end

Dir.mktmpdir("json-db-benchmark") do |root|
  JsonDb.storage_root = root

  puts "json-db #{JsonDb::VERSION} | ruby #{RUBY_VERSION} | #{COUNT} records"
  puts "storage root: #{JsonDb.storage_root}"
  puts

  puts "writes"
  plain_write = timed { COUNT.times { |i| Plain.create!(name: "u#{i}", email: "u#{i}@example.com", n: i) } }
  indexed_write = timed { COUNT.times { |i| Indexed.create!(name: "u#{i}", email: "u#{i}@example.com", n: i) } }
  report("create! without indexes", format("%.0f records/s", COUNT / plain_write))
  report("create! with one index", format("%.0f records/s", COUNT / indexed_write))
  report("index write penalty", format("%.1fx", plain_write.zero? ? 0 : indexed_write / plain_write))
  puts

  puts "reads"
  sample = Plain.all.ids.first(2_000)
  find_time = timed { sample.each { |id| Plain.find(id) } }
  report("find(id)", format("%.3f ms/record (%.0f records/s)", find_time / sample.size * 1000, sample.size / find_time))

  reps = 200
  scan = timed { reps.times { |i| Plain.find_by(email: "u#{i}@example.com") } }
  index = timed { reps.times { |i| Indexed.find_by(email: "u#{i}@example.com") } }
  report("find_by, un-indexed attribute", format("%.2f ms/lookup", scan / reps * 1000))
  report("find_by, indexed attribute", format("%.2f ms/lookup (%.0fx faster)", index / reps * 1000, scan / index))

  scan_all = timed { 5.times { Plain.all.to_a } }
  report("Model.all.to_a", format("%.0f ms", scan_all / 5 * 1000))
  puts

  puts "bulk import strategy"
  load_time = timed { COUNT.times { |i| Bulk.create!(email: "u#{i}@example.com") } }
  Bulk.index(:email)
  rebuild_time = timed { Bulk.rebuild_index! }
  report("import into an indexed collection", format("%.2f s", indexed_write))
  report("import then rebuild_index!", format("%.2f s (%.2f + %.2f)", load_time + rebuild_time, load_time, rebuild_time))
  puts

  puts "disk"
  report("apparent size of #{COUNT} records", `du -sh #{Plain.storage_path} 2>/dev/null`.split.first.to_s)
end
