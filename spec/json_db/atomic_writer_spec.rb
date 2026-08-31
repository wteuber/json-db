# frozen_string_literal: true

RSpec.describe JsonDb::Storage::AtomicWriter do
  let(:dir) { File.join(JsonDb.storage_root, "atomic") }
  let(:path) { File.join(dir, "record.json") }

  describe ".write" do
    it "creates the destination directory and the file" do
      described_class.write(path, %({"a":1}\n))

      expect(File.read(path)).to eq(%({"a":1}\n))
      expect(File.stat(path).mode & 0o777).to eq(0o644)
    end

    it "returns the number of bytes written" do
      expect(described_class.write(path, "hello")).to eq(5)
    end

    it "renames a temporary file inside the destination directory" do
      renamed = nil
      allow(File).to receive(:rename).and_wrap_original do |original, from, to|
        renamed = [from, to]
        original.call(from, to)
      end

      described_class.write(path, "hi")

      from, to = renamed
      expect(from).to end_with(".tmp")
      expect(File.dirname(from)).to eq(File.dirname(to)),
                                    "the temp file must share a filesystem with the target for rename to be atomic"
    end

    it "never exposes partial content: the target is untouched until the rename" do
      described_class.write(path, "original")

      observed = nil
      allow(File).to receive(:rename).and_wrap_original do |original, from, to|
        observed = File.read(to)
        original.call(from, to)
      end

      described_class.write(path, "replacement")

      expect(observed).to eq("original")
      expect(File.read(path)).to eq("replacement")
    end

    it "leaves the previous content intact when the rename fails" do
      described_class.write(path, "original")
      allow(File).to receive(:rename).and_raise(Errno::EIO)

      expect { described_class.write(path, "replacement") }.to raise_error(Errno::EIO)

      expect(File.read(path)).to eq("original")
      expect(Dir.children(dir)).to eq(["record.json"])
    end

    it "cleans up the temporary file when the write itself fails" do
      exploding = Object.new
      def exploding.to_s = raise(IOError, "boom")

      expect { described_class.write(path, exploding) }.to raise_error(StandardError)

      expect(Dir.children(dir).grep(/\.tmp\z/)).to be_empty
    end

    it "uses a distinct temporary file per writer" do
      names = []
      allow(File).to receive(:rename).and_wrap_original do |original, from, to|
        names << File.basename(from)
        original.call(from, to)
      end

      3.times { |i| described_class.write(path, "content-#{i}") }

      expect(names.uniq.size).to eq(3)
    end
  end

  describe ".delete" do
    it "removes the file and reports whether it did" do
      described_class.write(path, "hi")

      expect(described_class.delete(path)).to be(true)
      expect(described_class.delete(path)).to be(false)
      expect(File).not_to exist(path)
    end
  end

  describe "concurrent writers" do
    # A payload large enough that a plain File.write would be split across
    # several physical writes, making a torn read observable.
    def payload(marker)
      JSON.generate("marker" => marker, "filler" => marker * 40_000)
    end

    it "keeps each record valid when many threads create records at once" do
      threads = Array.new(20) do |i|
        Thread.new { User.create!(name: "user-#{i}", email: "user-#{i}@example.com") }
      end
      records = threads.map(&:value)

      expect(records.map(&:id).uniq.size).to eq(20)
      expect(User.count).to eq(20)
      expect(record_files_in(User).size).to eq(20)
      expect(temp_files_in(User)).to be_empty
      records.each { |record| expect(User.find(record.id).name).to eq(record.name) }
    end

    it "hands out unique sequence ids to concurrent threads" do
      threads = Array.new(25) { Thread.new { Counter.create!(label: "x").id } }
      ids = threads.map(&:value)

      expect(ids.map(&:to_i).sort).to eq((1..25).to_a)
    end

    it "never lets a reader observe a torn document while threads rewrite it" do
      valid = (0...4).map { |i| payload("t#{i}") }
      described_class.write(path, valid.first)
      stop = false
      errors = []

      writers = valid.each_with_index.map do |content, i|
        Thread.new do
          until stop
            described_class.write(path, content)
            Thread.pass
          end
        rescue StandardError => e
          errors << e
        end
      end

      seen = []
      reader = Thread.new do
        300.times do
          observed = File.read(path)
          if valid.include?(observed)
            seen << observed
          else
            errors << "torn read (#{observed.bytesize} bytes)"
          end
          Thread.pass
        end
      end

      reader.join
      stop = true
      writers.each(&:join)

      expect(errors).to be_empty
      expect(seen.uniq.size).to be > 1,
                                "the reader never observed a concurrent rewrite, so this example proved nothing"
    end

    it "never lets a reader observe a torn document while separate processes rewrite it" do
      skip "fork is unavailable on this platform" unless Process.respond_to?(:fork)

      valid = (0...4).map { |i| payload("p#{i}") }
      described_class.write(path, valid.first)

      pids = valid.each_with_index.map do |content, _i|
        fork do
          200.times { described_class.write(path, content) }
          exit!(0)
        end
      end

      torn = []
      seen = []
      400.times do
        observed = File.read(path)
        valid.include?(observed) ? seen << observed : torn << observed.bytesize
      end

      # SIGKILL mid-write is exactly the crash the rename protects against.
      pids.each { |pid| Process.kill("KILL", pid) rescue nil }
      pids.each { |pid| Process.waitpid(pid) rescue nil }

      expect(torn).to be_empty
      expect(seen.uniq.size).to be > 1,
                                "the reader never observed a concurrent rewrite, so this example proved nothing"
      expect(valid).to include(File.read(path)),
                       "a crashed writer must leave the previous complete document in place"
    end

    it "keeps the index consistent when threads write indexed records concurrently" do
      users = Array.new(12) { |i| { name: "user-#{i}", email: "user-#{i}@example.com" } }

      users.map { |attrs| Thread.new { User.create!(**attrs) } }.each(&:join)

      index = User.index_manager.read

      expect(index["email"].keys).to match_array(users.map { |attrs| attrs[:email] })
      expect(index["email"].values.flatten.uniq.size).to eq(12)
      users.each { |attrs| expect(User.find_by(email: attrs[:email])).not_to be_nil }
    end
  end
end
