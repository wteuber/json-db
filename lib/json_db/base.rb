# frozen_string_literal: true

module JsonDb
  # The class user models inherit from.
  #
  #   class User < JsonDb::Base
  #     self.storage_root = "db/json"
  #     self.id_generator = :uuid
  #
  #     attribute :name,  :string
  #     attribute :email, :string
  #     attribute :admin, :boolean, default: false
  #
  #     index :email
  #     has_many :tasks, dependent: :destroy
  #
  #     validates :name, presence: true
  #   end
  #
  # Each record lives in its own document at
  # +#{storage_root}/#{collection_name}/#{id}.json+.
  class Base
    include ActiveModel::Model
    include ActiveModel::Attributes
    include ActiveModel::Dirty
    extend ActiveModel::Callbacks

    define_model_callbacks :save, :create, :update, :destroy

    # Ids are compared as strings everywhere -- by the directory listing, by
    # +order(:id)+, by every index bucket -- so :sequence values are zero-padded
    # to keep lexicographic order and numeric order the same thing.
    SEQUENCE_ID_DIGITS = 9

    include Associations::BelongsTo
    include Associations::HasMany
    include Associations::HasOne

    class << self
      # Declares a class-level setting that subclasses inherit but may override
      # without mutating the parent. A Proc default is evaluated in the context of
      # the class that reads it, which is what lets +collection_name+ default to
      # each subclass's own +model_name+.
      def class_setting(name, default)
        ivar = :"@#{name}"

        define_singleton_method(name) do
          klass = self
          while klass.is_a?(Class) && klass <= Base
            return klass.instance_variable_get(ivar) if klass.instance_variable_defined?(ivar)

            klass = klass.superclass
          end

          default.is_a?(Proc) ? instance_exec(&default) : default
        end

        define_singleton_method(:"#{name}=") { |value| instance_variable_set(ivar, value) }
        name
      end
      private :class_setting
    end

    # Where collections are rooted. Defaults to the global JsonDb.storage_root.
    class_setting :storage_root, -> { JsonDb.storage_root }

    # Directory name for this model's documents, e.g. "users".
    class_setting :collection_name, -> { model_name.collection }

    # Attribute holding the record identity.
    class_setting :primary_key, :id

    # :hex, :uuid, :sequence, or any callable returning an id.
    class_setting :id_generator, :hex

    # Spaces per JSON indent level; 0 writes compact one-line documents.
    class_setting :json_indent, 2

    # Attributes maintained in _indexes.json.
    class_setting :indexed_attributes, [].freeze

    # Declared associations, keyed by name.
    class_setting :reflections, {}.freeze

    attribute :id, :string

    class << self
      # --- configuration -------------------------------------------------

      # Assigning a custom primary key also declares the attribute if needed.
      def primary_key=(name)
        @primary_key = name.to_sym
        attribute(@primary_key, :string) unless attribute_types.key?(@primary_key.to_s)
        @primary_key
      end

      # Declares one or more attributes as indexed. Existing documents are not
      # re-scanned automatically -- call +.rebuild_index!+ for that.
      def index(*names)
        self.indexed_attributes = (indexed_attributes | names.map(&:to_sym)).freeze
      end

      def add_reflection(reflection)
        self.reflections = reflections.merge(reflection.name => reflection).freeze
        reflection
      end

      def reflect_on(name)
        reflections[name.to_sym] ||
          raise(AssociationError, "#{self} has no association #{name.inspect}")
      end

      # --- storage -------------------------------------------------------

      def storage_path
        File.join(storage_root.to_s, collection_name.to_s)
      end

      # Rebuilt per call so that changing +storage_root+ (typically in tests)
      # takes effect immediately.
      def adapter
        Storage::FileAdapter.new(storage_path, indent: json_indent)
      end

      def index_manager
        Query::IndexManager.new(adapter, indexed_attributes, model: self)
      end

      # Re-derives _indexes.json from the documents on disk.
      def rebuild_index!
        index_manager.rebuild!
      end

      # --- querying ------------------------------------------------------

      def all
        Query::Relation.new(self)
      end

      def where(conditions = {})
        all.where(conditions)
      end

      def order(*fields, **directions)
        all.order(*fields, **directions)
      end

      def limit(value)
        all.limit(value)
      end

      def offset(value)
        all.offset(value)
      end

      def find_by(conditions = {})
        all.find_by(conditions)
      end

      def find_by!(conditions = {})
        all.find_by!(conditions)
      end

      def pluck(*fields)
        all.pluck(*fields)
      end

      def count
        all.count
      end

      def first(amount = nil)
        order(primary_key).first(amount)
      end

      def last(amount = nil)
        order(primary_key).last(amount)
      end

      def exists?(id_or_conditions = nil)
        case id_or_conditions
        when nil then !all.empty?
        when Hash then all.exists?(id_or_conditions)
        else
          begin
            adapter.exist?(id_or_conditions)
          rescue InvalidId
            # An id that cannot name a document cannot name an existing one, and
            # exists?(params[:id]) should answer the question, not raise.
            false
          end
        end
      end

      # Reads one document by id.
      #
      # @raise [RecordNotFound] when there is no such document
      def find(id)
        raise RecordNotFound.new(model: self, primary_key: primary_key, id: id) if id.nil?

        document = adapter.read(id)
        raise RecordNotFound.new(model: self, primary_key: primary_key, id: id) if document.nil?

        instantiate(document)
      end

      # Like {find}, but returns nil instead of raising.
      def find_by_id(id)
        find(id)
      rescue RecordNotFound, InvalidId
        nil
      end

      # Builds a record from a stored document and marks it persisted.
      # Unknown keys are ignored so that a stale field in a hand-edited file
      # cannot make a whole collection unreadable.
      def instantiate(document)
        record = allocate
        record.send(:initialize_from_document, document)
        record
      end

      # --- writing -------------------------------------------------------

      def new(attributes = {})
        super
      end

      def create(attributes = {})
        new(attributes).tap(&:save)
      end

      def create!(attributes = {})
        new(attributes).tap(&:save!)
      end

      def destroy_all
        all.destroy_all
      end

      # Removes the collection directory, indexes and sequence included.
      def delete_all!
        adapter.destroy_all!
      end

      # --- ids -----------------------------------------------------------

      # @return [String] a fresh id according to +id_generator+
      def generate_id
        case id_generator
        when :hex then SecureRandom.hex(8)
        when :uuid then SecureRandom.uuid
        when :sequence then format("%0#{SEQUENCE_ID_DIGITS}d", adapter.next_sequence_value)
        when Proc then (id_generator.arity.zero? ? id_generator.call : id_generator.call(self)).to_s
        else
          if id_generator.respond_to?(:call)
            id_generator.call.to_s
          else
            raise ConfigurationError,
                  "Unknown id_generator #{id_generator.inspect} " \
                  "(expected :hex, :uuid, :sequence or a callable)"
          end
        end
      end
    end

    def initialize(attributes = {})
      @persisted = false
      @destroyed = false
      super
    end

    # --- identity ---------------------------------------------------------

    def id
      self[self.class.primary_key]
    end

    def id=(value)
      self[self.class.primary_key] = value
    end

    def to_key
      persisted? ? [id] : nil
    end

    def to_param
      id&.to_s
    end

    def persisted?
      @persisted && !@destroyed
    end

    def new_record?
      !@persisted
    end

    def destroyed?
      @destroyed
    end

    # Reads a cast attribute value by name.
    def [](name)
      @attributes.fetch_value(name.to_s)
    end

    # Writes a cast attribute value, keeping dirty tracking intact.
    def []=(name, value)
      @attributes.write_from_user(name.to_s, value)
    end

    # Two records are the same record when they are the same class with the same id.
    def ==(other)
      return super if id.nil?

      other.instance_of?(self.class) && other.id == id
    end
    alias eql? ==

    def hash
      id.nil? ? super : [self.class, id].hash
    end

    def inspect
      pairs = attributes.map { |key, value| "#{key}: #{value.inspect}" }.join(", ")
      "#<#{self.class.name} #{pairs}>"
    end

    # --- persistence ------------------------------------------------------

    # Validates, then writes the document atomically.
    # @return [Boolean] false when validations or a callback abort the save
    def save(validate: true)
      return false if validate && invalid?

      create_or_update
    rescue RecordNotSaved
      false
    end

    # @raise [RecordInvalid] when validations fail
    # @raise [RecordNotSaved] when a callback throws +:abort+
    def save!(validate: true)
      raise RecordInvalid, self if validate && invalid?

      create_or_update || raise(RecordNotSaved.new("Failed to save #{self.class.name}", record: self))
    end

    def update(attributes = {})
      assign_attributes(attributes)
      save
    end

    def update!(attributes = {})
      assign_attributes(attributes)
      save!
    end

    # Deletes the document, running destroy callbacks (and therefore any
    # +dependent:+ cleanup).
    # @return [Boolean] false when a callback aborted the destroy
    def destroy
      # A record that was never written -- or is already gone -- has nothing to
      # delete. Running the callbacks anyway would cascade +dependent:+ cleanup
      # against a nil foreign key, which matches every unowned child.
      return true unless persisted?

      aborted = false

      run_callbacks(:destroy) do
        # Unlink first: a stale index entry only costs a wasted read, whereas a
        # document that survives a failed unlink after being de-indexed is
        # invisible to every indexed query while +find+ still returns it.
        self.class.adapter.delete(id)
        self.class.index_manager.remove(id, indexed_values)
        @destroyed = true
        @persisted = false
        true
      end || (aborted = true)

      !aborted
    end

    def destroy!
      destroy || raise(RecordNotSaved.new("Failed to destroy #{self.class.name}", record: self))
    end

    # Re-reads the document from disk, discarding unsaved changes.
    # @raise [RecordNotFound] when the document is gone
    def reload
      document = self.class.adapter.read(id)
      raise RecordNotFound.new(model: self.class, primary_key: self.class.primary_key, id: id) if document.nil?

      initialize_from_document(document)
      self
    end

    # The exact Hash that is serialised into the document.
    def as_json(*)
      attributes.transform_values { |value| value.as_json }
    end

    def to_json(*args)
      as_json.to_json(*args)
    end

    # Path of this record's document on disk.
    def storage_path
      self.class.adapter.path_for(id)
    end

    private

    def association_cache
      @association_cache ||= {}
    end

    def initialize_from_document(document)
      @attributes = self.class._default_attributes.deep_dup
      @persisted = true
      @destroyed = false
      @association_cache = {}

      known = self.class.attribute_types
      document.each do |key, value|
        @attributes.write_from_database(key.to_s, value) if known.key?(key.to_s)
      end

      clear_changes_information
      self
    end

    def create_or_update
      creating = new_record?
      result = false

      run_callbacks(:save) do
        run_callbacks(creating ? :create : :update) do
          self[self.class.primary_key] = self.class.generate_id if creating && id.nil?

          previous = creating ? {} : indexed_values(before: true)
          previous_id = creating ? nil : changed_attributes[self.class.primary_key.to_s]

          self.class.adapter.write(id, as_json)
          self.class.index_manager.update(id, previous, indexed_values)

          # A changed primary key means a different document path. The record
          # moved rather than forked, so the document it came from goes -- after
          # the new one is on disk, so an interruption duplicates rather than loses.
          if previous_id && previous_id != id
            self.class.index_manager.remove(previous_id, previous)
            self.class.adapter.delete(previous_id)
          end

          @persisted = true
          changes_applied
          result = true
        end
      end

      result
    end

    # Current (or pre-change) values of the indexed attributes.
    def indexed_values(before: false)
      self.class.indexed_attributes.to_h do |attribute|
        value = if before
                  changed_attributes.fetch(attribute.to_s) { self[attribute] }
                else
                  self[attribute]
                end
        [attribute, value]
      end
    end
  end
end
