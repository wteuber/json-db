# frozen_string_literal: true

module JsonDb
  module Storage
    # Owns one collection directory (+storage_root/collection+) and maps ids to
    # +<id>.json+ documents inside it.
    #
    # Names starting with an underscore are reserved for adapter bookkeeping
    # (+_indexes.json+, +_sequence.txt+, +_sequence.lock+) and are never reported
    # as record ids.
    class FileAdapter
      EXTENSION = ".json"
      SEQUENCE_FILE = "_sequence.txt"
      RESERVED_PREFIX = "_"

      # Ids must be filesystem-safe and may not begin with the reserved prefix,
      # which also rules out "." and ".." and therefore any directory traversal.
      ID_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_.\-]{0,254}\z/

      attr_reader :dir, :indent

      # @param dir [String] the collection directory
      # @param indent [Integer] spaces per JSON level; 0 writes compact JSON
      def initialize(dir, indent: 2)
        @dir = dir.to_s
        @indent = indent.to_i
      end

      # @return [String] absolute-or-relative path of the document for +id+
      def path_for(id)
        File.join(dir, "#{validate_id!(id)}#{EXTENSION}")
      end

      def exist?(id)
        File.file?(path_for(id))
      end

      # @return [Hash{String=>Object}, nil] the parsed document, or nil when absent
      def read(id)
        raw = File.read(path_for(id), encoding: Encoding::UTF_8)
        parse(raw, path_for(id))
      rescue Errno::ENOENT
        nil
      end

      # Atomically replaces the document for +id+.
      # @return [Hash] the attributes that were written
      def write(id, attributes)
        AtomicWriter.write(path_for(id), "#{dump(attributes)}\n")
        attributes
      end

      def delete(id)
        AtomicWriter.delete(path_for(id))
      end

      # @return [Array<String>] every record id in the collection, sorted
      def ids
        return [] unless Dir.exist?(dir)

        Dir.children(dir).filter_map do |entry|
          next unless entry.end_with?(EXTENSION)

          id = entry.delete_suffix(EXTENSION)
          next if id.start_with?(RESERVED_PREFIX)

          id
        end.sort
      end

      def count
        ids.size
      end

      # Yields every stored document as a Hash, skipping ids that vanish mid-scan.
      def each_document
        return enum_for(:each_document) unless block_given?

        ids.each do |id|
          document = read(id)
          yield id, document if document
        end
      end

      # Reads and increments +_sequence.txt+ under an exclusive lock, so that
      # concurrent processes never hand out the same number twice.
      # @return [Integer] the freshly allocated value, starting at 1
      def next_sequence_value
        FileUtils.mkdir_p(dir)
        path = File.join(dir, SEQUENCE_FILE)

        File.open(path, File::RDWR | File::CREAT, 0o644) do |file|
          file.flock(File::LOCK_EX)
          current = file.read.to_s.strip
          value = (current.empty? ? 0 : Integer(current, 10)) + 1

          file.rewind
          file.truncate(0)
          file.write("#{value}\n")
          file.flush
          file.fsync
          value
        end
      end

      # Runs the block while holding an exclusive lock on +name+ inside the collection.
      # Used by the index manager for its read-modify-write cycle.
      def with_lock(name)
        FileUtils.mkdir_p(dir)
        File.open(File.join(dir, name), File::RDWR | File::CREAT, 0o644) do |file|
          file.flock(File::LOCK_EX)
          yield
        end
      end

      # Removes the whole collection directory. Mostly useful in tests.
      def destroy_all!
        FileUtils.rm_rf(dir)
      end

      def dump(attributes)
        if indent <= 0
          JSON.generate(attributes)
        else
          JSON.generate(attributes, indent: " " * indent, space: " ", object_nl: "\n", array_nl: "\n")
        end
      end

      def parse(raw, source = nil)
        JSON.parse(raw)
      rescue JSON::ParserError => e
        raise SerializationError, "Malformed JSON in #{source || 'document'}: #{e.message}"
      end

      private

      def validate_id!(id)
        string = id.to_s
        return string if ID_PATTERN.match?(string)

        raise InvalidId,
              "#{string.inspect} is not a usable record id " \
              "(expected #{ID_PATTERN.source}, and ids may not start with #{RESERVED_PREFIX.inspect})"
      end
    end
  end
end
