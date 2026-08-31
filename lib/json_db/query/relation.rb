# frozen_string_literal: true

module JsonDb
  module Query
    # A lazy, chainable, Enumerable query over one collection.
    #
    # Nothing touches the filesystem until the relation is enumerated, and every
    # chaining method returns a *new* relation, so a relation can be stored in a
    # constant or reused as a scope without surprises.
    #
    #   Task.where(done: false).order(created_at: :desc).limit(10)
    class Relation
      include Enumerable

      # Conditions may be a plain value, or any of these matchers.
      MATCHERS = [Array, Range, Regexp, Proc].freeze

      attr_reader :klass, :where_values, :order_values, :limit_value, :offset_value

      def initialize(klass, where_values: {}, order_values: [], limit_value: nil, offset_value: nil, null: false)
        @klass = klass
        @where_values = where_values.freeze
        @order_values = order_values.freeze
        @limit_value = limit_value
        @offset_value = offset_value
        @null = null
      end

      # Narrows the relation. Values may be scalars, Arrays (IN), Ranges
      # (BETWEEN), Regexps (matched against +to_s+) or a Proc taking the value.
      def where(conditions = {})
        return self if conditions.empty?

        spawn(where_values: where_values.merge(symbolize(conditions)))
      end

      # +order(:name)+, +order(:name, :age)+ or +order(name: :desc, age: :asc)+.
      def order(*fields, **directions)
        pairs = fields.map { |field| [field.to_sym, :asc] }
        pairs += directions.map { |field, direction| [field.to_sym, normalize_direction(direction)] }
        return self if pairs.empty?

        spawn(order_values: order_values + pairs)
      end

      # Reverses every ordering clause; ordering by the primary key when none is set.
      def reverse_order
        pairs = order_values.empty? ? [[klass.primary_key, :desc]] : order_values.map { |f, d| [f, d == :asc ? :desc : :asc] }
        spawn(order_values: pairs)
      end

      def limit(value)
        spawn(limit_value: value&.to_i)
      end

      def offset(value)
        spawn(offset_value: value&.to_i)
      end

      # A relation that matches nothing and never touches the filesystem. An
      # association reader on an unsaved owner returns this rather than
      # +where(foreign_key => nil)+, which would match every unowned record.
      def none
        spawn(null: true)
      end

      def null?
        @null
      end

      # Drops every clause; the unfiltered collection.
      def unscoped
        self.class.new(klass)
      end

      def each(&block)
        return records.each unless block

        records.each(&block)
        self
      end

      def to_a
        records.dup
      end

      def records
        @records ||= load_records
      end

      def loaded?
        !@records.nil?
      end

      # Forgets the cached result set so the next enumeration re-reads from disk.
      def reload
        @records = nil
        self
      end

      def first(amount = nil)
        amount ? records.first(amount) : records.first
      end

      def last(amount = nil)
        amount ? records.last(amount) : records.last
      end

      def find_by(conditions = {})
        where(conditions).first
      end

      def find_by!(conditions = {})
        find_by(conditions) ||
          raise(RecordNotFound.new("Couldn't find #{klass} matching #{conditions.inspect}", model: klass))
      end

      # Avoids loading anything when the answer is just "how many files are there".
      def count
        return 0 if null?
        return records.size if loaded? || !where_values.empty? || limit_value || offset_value

        klass.adapter.count
      end
      alias size count

      def empty?
        count.zero?
      end

      def any?(*args, &block)
        return super if block || !args.empty?

        !empty?
      end

      def exists?(conditions = {})
        conditions.empty? ? !empty? : !where(conditions).first.nil?
      end

      # +pluck(:name)+ returns values, +pluck(:id, :name)+ returns rows.
      def pluck(*fields)
        fields = fields.map(&:to_sym)
        records.map do |record|
          fields.size == 1 ? record[fields.first] : fields.map { |field| record[field] }
        end
      end

      def ids
        pluck(klass.primary_key)
      end

      def destroy_all
        records.each(&:destroy)
      end

      def update_all(attributes = {})
        records.each { |record| record.update!(attributes) }.size
      end

      def inspect
        preview = loaded? ? records : first(11)
        suffix = preview.size > 10 ? ", ...]" : "]"
        "#<#{self.class.name} [#{preview.take(10).map(&:inspect).join(', ')}#{suffix}>"
      end

      private

      def spawn(**overrides)
        self.class.new(
          klass,
          where_values: overrides.fetch(:where_values, where_values),
          order_values: overrides.fetch(:order_values, order_values),
          limit_value: overrides.fetch(:limit_value, limit_value),
          offset_value: overrides.fetch(:offset_value, offset_value),
          null: overrides.fetch(:null, null?)
        )
      end

      def load_records
        return [] if null?

        result = candidate_ids.filter_map do |id|
          document = klass.adapter.read(id)
          document && klass.instantiate(document)
        end

        result = result.select { |record| match?(record) } unless where_values.empty?
        result = sort_records(result) unless order_values.empty?
        result = result.drop(offset_value) if offset_value
        result = result.first(limit_value) if limit_value
        result
      end

      # Uses the narrowest index that can answer one of the conditions; falls back
      # to a directory listing when no condition is indexed.
      def candidate_ids
        return klass.adapter.ids if where_values.empty?

        index = klass.index_manager
        narrowed = nil

        where_values.each do |attribute, value|
          ids = index.ids_for(attribute, value)
          next if ids.nil?

          narrowed = narrowed.nil? ? ids : (narrowed & ids)
          break if narrowed.empty?
        end

        narrowed ? narrowed.sort : klass.adapter.ids
      end

      def match?(record)
        where_values.all? do |attribute, expected|
          compare_value(record[attribute], expected, attribute)
        end
      end

      def compare_value(actual, expected, attribute)
        case expected
        when Array then expected.any? { |item| compare_value(actual, item, attribute) }
        when Range then !actual.nil? && expected.cover?(actual)
        when Regexp then expected.match?(actual.to_s)
        when Proc then expected.call(actual)
        else actual == cast(attribute, expected)
        end
      end

      # Lets +where(age: "30")+ find a record whose +:integer+ attribute is 30.
      def cast(attribute, value)
        type = klass.attribute_types[attribute.to_s]
        return value if type.nil? || value.nil?

        type.cast(value)
      rescue StandardError
        value
      end

      def sort_records(records)
        records.sort do |a, b|
          result = 0
          order_values.each do |attribute, direction|
            comparison = compare_for_sort(a[attribute], b[attribute])
            next if comparison.zero?

            result = direction == :desc ? -comparison : comparison
            break
          end
          result
        end
      end

      # nil sorts last in ascending order (and therefore first descending), and
      # values that are not mutually comparable are treated as equal rather than
      # blowing up a whole query.
      def compare_for_sort(left, right)
        return 0 if left.nil? && right.nil?
        return 1 if left.nil?
        return -1 if right.nil?

        (left <=> right) || 0
      end

      def normalize_direction(direction)
        case direction.to_s.downcase
        when "asc" then :asc
        when "desc" then :desc
        else raise ArgumentError, "Direction must be :asc or :desc, got #{direction.inspect}"
        end
      end

      def symbolize(conditions)
        conditions.to_h { |key, value| [key.to_sym, value] }
      end
    end
  end
end
