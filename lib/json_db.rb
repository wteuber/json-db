# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"

require "active_model"
require "active_support"
require "active_support/core_ext/object/json"
require "active_support/core_ext/object/deep_dup"
require "active_support/core_ext/string/inflections"

require_relative "json_db/version"
require_relative "json_db/errors"
require_relative "json_db/storage/atomic_writer"
require_relative "json_db/storage/file_adapter"

# A zero-database ORM that stores every record as its own JSON document.
#
#   JsonDb.configure { |config| config.storage_root = "db/json" }
#
# Models inherit from {JsonDb::Base}; individual models may override the
# root with +self.storage_root = ...+.
module JsonDb
  DEFAULT_STORAGE_ROOT = "db"

  module Storage; end
  module Query; end
  module Associations; end

  class << self
    attr_writer :storage_root

    # Root directory every collection lives under.
    # @return [String]
    def storage_root
      @storage_root ||= DEFAULT_STORAGE_ROOT
    end

    # @yieldparam config [Module] self
    def configure
      yield self
      self
    end
  end
end
