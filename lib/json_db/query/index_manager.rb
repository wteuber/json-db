# frozen_string_literal: true

module JsonDb
  module Query
    # Maintains +_indexes.json+ for a collection: a secondary lookup that turns
    # +where(user_id: 5)+ from an O(N) directory scan plus N file reads into a
    # single index read plus one file read per hit.
    #
    # The on-disk shape is deliberately boring so the file stays reviewable:
    #
    #   { "user_id": { "5": ["a1b2", "c3d4"], "7": ["e5f6"] } }
    #
    # Keys are +value.to_s+, which means distinct values can share a bucket
    # (+5+ and +"5"+). That is safe: the index only ever *narrows the candidate
    # set* and {Relation} still applies the real comparison to every candidate,
    # so a collision costs one wasted read and never a wrong result.
    class IndexManager
      FILENAME = "_indexes.json"
      LOCK_FILE = "_indexes.lock"

      attr_reader :adapter, :attributes, :model

      # @param adapter [Storage::FileAdapter]
      # @param attributes [Array<Symbol>] the indexed attribute names
      # @param model [Class, nil] the model whose casting rules produce bucket
      #   keys; without it {#rebuild!} can only key by the raw stored value
      def initialize(adapter, attributes, model: nil)
        @adapter = adapter
        @attributes = Array(attributes).map(&:to_sym)
        @model = model
      end

      def enabled?
        !attributes.empty?
      end

      def indexed?(attribute)
        attributes.include?(attribute.to_sym)
      end

      def path
        File.join(adapter.dir, FILENAME)
      end

      # @return [Hash{String=>Hash{String=>Array<String>}}]
      def read
        raw = File.read(path, encoding: Encoding::UTF_8)
        adapter.parse(raw, path)
      rescue Errno::ENOENT
        {}
      end

      # Candidate ids for +attribute == value+ (or +value+ being an Array of values).
      #
      # @return [Array<String>, nil] nil when the index cannot answer the question,
      #   which tells the caller to fall back to a full scan.
      def ids_for(attribute, value)
        return nil unless indexed?(attribute)

        buckets = read[attribute.to_s]
        return nil if buckets.nil?

        keys = case value
               when Array then value.map { |item| key_for(item) }
               when Range, Regexp, Proc then return nil
               else [key_for(value)]
               end

        # A key that is absent from the file is not the same as an empty bucket:
        # +compact+ deletes buckets as they empty, and the file is only a cache
        # of the documents, so "no such key" means "the index cannot answer
        # this" and the caller has to scan -- not "there are no matches".
        ids = []
        keys.each do |key|
          bucket = buckets[key]
          return nil if bucket.nil?

          ids.concat(bucket)
        end
        ids.uniq
      end

      # Moves +id+ from its old buckets to its new ones in a single locked
      # read-modify-write, so parallel writers cannot lose each other's entries.
      #
      # @param old_values [Hash{Symbol=>Object}] values before the save ({} when creating)
      # @param new_values [Hash{Symbol=>Object}] values after the save
      def update(id, old_values, new_values)
        return unless enabled?

        mutate do |index|
          attributes.each do |attribute|
            name = attribute.to_s
            buckets = (index[name] ||= {})

            if old_values.key?(attribute)
              detach(buckets, key_for(old_values[attribute]), id)
            end

            attach(buckets, key_for(new_values[attribute]), id)
          end
        end
      end

      # Drops every trace of +id+ from the index.
      def remove(id, values = nil)
        return unless enabled?

        mutate do |index|
          attributes.each do |attribute|
            buckets = index[attribute.to_s]
            next if buckets.nil?

            if values&.key?(attribute)
              detach(buckets, key_for(values[attribute]), id)
            else
              buckets.each_key { |key| detach(buckets, key, id) }
            end
          end
        end
      end

      # Rebuilds the whole index from the documents on disk. Use after adding an
      # +index+ declaration to a model that already has data, or to repair a file
      # that was edited by hand.
      def rebuild!
        return {} unless enabled?

        fresh = attributes.to_h { |attribute| [attribute.to_s, {}] }

        adapter.each_document do |id, document|
          values = indexed_values_for(document)
          attributes.each do |attribute|
            attach(fresh[attribute.to_s], key_for(values[attribute]), id)
          end
        end

        adapter.with_lock(LOCK_FILE) { store(fresh) }
        fresh
      end

      # Deletes the index file entirely.
      def clear!
        Storage::AtomicWriter.delete(path)
      end

      private

      def mutate
        adapter.with_lock(LOCK_FILE) do
          index = read
          yield index
          store(compact(index))
        end
      end

      def store(index)
        Storage::AtomicWriter.write(path, "#{adapter.dump(index)}\n")
      end

      def attach(buckets, key, id)
        bucket = (buckets[key] ||= [])
        bucket << id unless bucket.include?(id)
      end

      def detach(buckets, key, id)
        bucket = buckets[key]
        return if bucket.nil?

        bucket.delete(id)
        buckets.delete(key) if bucket.empty?
      end

      # Keeps the file from accumulating empty buckets over a record's lifetime.
      def compact(index)
        index.each_value { |buckets| buckets.reject! { |_, ids| ids.empty? } }
        index
      end

      # Buckets have to be keyed exactly the way {#update} keys them, which is by
      # the *cast* attribute value: a :datetime stored as "2020-01-01T12:00:00.000Z"
      # is keyed "2020-01-01 12:00:00 UTC". Instantiating the document is what
      # produces that, defaults for absent keys included.
      def indexed_values_for(document)
        return attributes.to_h { |attribute| [attribute, document[attribute.to_s]] } if model.nil?

        record = model.instantiate(document)
        attributes.to_h { |attribute| [attribute, record[attribute]] }
      end

      def key_for(value)
        value.nil? ? "" : value.to_s
      end
    end
  end
end
