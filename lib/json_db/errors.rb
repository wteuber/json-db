# frozen_string_literal: true

module JsonDb
  # Base class for every error raised by json-db.
  class Error < StandardError; end

  # Raised by +.find+ / +.find_by!+ when no document matches.
  class RecordNotFound < Error
    attr_reader :model, :primary_key, :id

    def initialize(message = nil, model: nil, primary_key: nil, id: nil)
      @model = model
      @primary_key = primary_key
      @id = id
      super(message || "Couldn't find #{model} with #{primary_key}=#{id.inspect}")
    end
  end

  # Raised by the bang variants of the persistence methods when validations fail.
  class RecordInvalid < Error
    attr_reader :record

    def initialize(record = nil)
      @record = record
      messages = record&.errors&.full_messages.to_a.join(", ")
      super(messages.empty? ? "Record is invalid" : "Validation failed: #{messages}")
    end
  end

  # Raised when a callback chain aborts a save or destroy.
  class RecordNotSaved < Error
    attr_reader :record

    def initialize(message = "Failed to save the record", record: nil)
      @record = record
      super(message)
    end
  end

  # Raised when an id would escape the collection directory or is otherwise unusable.
  class InvalidId < Error; end

  # Raised for unusable configuration, e.g. an unknown +id_generator+.
  class ConfigurationError < Error; end

  # Raised when an association points at a class that cannot be resolved.
  class AssociationError < Error; end

  # Raised when a stored document cannot be parsed as JSON.
  class SerializationError < Error; end
end
