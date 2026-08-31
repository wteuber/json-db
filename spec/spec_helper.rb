# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json_db"

require_relative "support/models"

RSpec.configure do |config|
  config.expect_with(:rspec) { |expectations| expectations.include_chain_clauses_in_custom_matcher_descriptions = true }
  config.mock_with(:rspec) { |mocks| mocks.verify_partial_doubles = true }
  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  # Every example gets its own throwaway storage root, so nothing leaks between
  # examples and no example can touch the developer's working tree.
  config.around do |example|
    Dir.mktmpdir("json-db-spec") do |dir|
      previous = JsonDb.storage_root
      JsonDb.storage_root = dir
      begin
        example.run
      ensure
        JsonDb.storage_root = previous
      end
    end
  end
end

module StorageHelpers
  # Absolute path of a model's collection directory.
  def collection_dir(klass)
    klass.storage_path
  end

  def document_for(record)
    JSON.parse(File.read(record.storage_path))
  end

  def files_in(klass)
    Dir.children(collection_dir(klass)).sort
  rescue Errno::ENOENT
    []
  end

  # Just the record documents -- index and sequence bookkeeping filtered out.
  def record_files_in(klass)
    files_in(klass).grep(/\.json\z/).reject { |name| name.start_with?("_") }
  end

  def temp_files_in(klass)
    files_in(klass).grep(/\.tmp\z/)
  end
end

RSpec.configure { |config| config.include StorageHelpers }
