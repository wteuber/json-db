# frozen_string_literal: true

require_relative "lib/json_db/version"

Gem::Specification.new do |spec|
  spec.name    = "json-db"
  spec.version = JsonDb::VERSION
  spec.authors = ["Wolfgang Teuber"]
  spec.email   = ["email@wteuber.com"]

  spec.summary     = "A zero-database ORM that persists ActiveModel records as human-readable JSON files."
  spec.description = <<~DESC
    json-db is a lightweight, dependency-light ORM built on ActiveModel. Every record is
    stored as its own pretty-printed JSON document (storage_root/collection/id.json) and written
    atomically, so a crash or SIGKILL mid-write can never corrupt an existing file. It ships with
    chainable lazy queries, optional on-disk indexes, associations and pluggable primary keys.
  DESC

  spec.homepage = "https://github.com/wteuber/json-db"
  spec.license  = "MIT"

  spec.required_ruby_version = ">= 3.3.0"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[
    "lib/**/*.rb",
    "sig/**/*.rbs",
    "README.md",
    "LICENSE.txt",
    "CHANGELOG.md"
  ]
  spec.require_paths = ["lib"]

  spec.add_dependency "activemodel", ">= 7.1", "< 9"
  spec.add_dependency "activesupport", ">= 7.1", "< 9"
end
