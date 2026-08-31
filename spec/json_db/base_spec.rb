# frozen_string_literal: true

RSpec.describe JsonDb::Base do
  describe "configuration" do
    it "derives the collection directory from the model name" do
      expect(User.collection_name).to eq("users")
      expect(User.storage_path).to eq(File.join(JsonDb.storage_root, "users"))
    end

    it "namespaces collections for namespaced models" do
      expect(Blog::Post.collection_name).to eq("blog/posts")
    end

    it "honours an explicit collection name" do
      expect(Ledger.collection_name).to eq("ledgers-v2")
    end

    it "lets a subclass override a setting without affecting its siblings" do
      expect(Ledger.json_indent).to eq(0)
      expect(User.json_indent).to eq(2)
      expect(JsonDb::Base.json_indent).to eq(2)
    end

    it "inherits settings through a subclass of a model" do
      admin_class = Class.new(User) do
        def self.name = "Admin"
      end

      expect(admin_class.storage_root).to eq(User.storage_root)
      expect(admin_class.indexed_attributes).to eq(User.indexed_attributes)
    end

    it "uses a per-model storage root when one is set" do
      root = File.join(JsonDb.storage_root, "elsewhere")
      klass = Class.new(JsonDb::Base) do
        def self.name = "Sample"
        attribute :label, :string
      end
      klass.storage_root = root

      record = klass.create!(label: "x")

      expect(record.storage_path).to start_with(root)
      expect(File).to exist(record.storage_path)
    end
  end

  describe "writing documents" do
    it "stores one pretty-printed JSON file per record" do
      user = User.create!(name: "Ada", email: "ada@example.com", age: 36)

      expect(user.storage_path).to eq(File.join(User.storage_path, "#{user.id}.json"))
      expect(File.read(user.storage_path)).to eq(<<~JSON)
        {
          "id": "#{user.id}",
          "name": "Ada",
          "email": "ada@example.com",
          "age": 36,
          "admin": false
        }
      JSON
    end

    it "writes compact JSON when json_indent is zero" do
      ledger = Ledger.create!(amount: 42)

      expect(File.read(ledger.storage_path)).to eq(%({"id":"#{ledger.id}","amount":42}\n))
    end

    it "round-trips typed attributes" do
      task = Task.create!(title: "Ship", done: "1", priority: "3")

      reloaded = Task.find(task.id)
      expect(reloaded.done).to be(true)
      expect(reloaded.priority).to eq(3)
      expect(document_for(task)).to eq(
        "id" => task.id, "title" => "Ship", "done" => true, "priority" => 3, "user_id" => nil
      )
    end

    it "replaces the document in place on update, leaving exactly one file" do
      user = User.create!(name: "Ada")

      user.update!(name: "Ada Lovelace")

      expect(record_files_in(User)).to eq(["#{user.id}.json"])
      expect(document_for(user)["name"]).to eq("Ada Lovelace")
    end

    it "leaves no temporary files behind" do
      3.times { |i| User.create!(name: "user-#{i}") }

      expect(temp_files_in(User)).to be_empty
    end
  end

  describe "identity and id generation" do
    it "defaults to a 16 character hex id" do
      expect(User.create!(name: "Ada").id).to match(/\A[0-9a-f]{16}\z/)
    end

    it "supports :uuid" do
      klass = Class.new(User) do
        def self.name = "UuidUser"
        self.id_generator = :uuid
      end

      expect(klass.create!(name: "Ada").id).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
    end

    it "supports :sequence and keeps counting across records" do
      ids = Array.new(3) { |i| Counter.create!(label: "c#{i}").id }

      expect(ids).to eq(%w[000000001 000000002 000000003])
      expect(File.read(File.join(Counter.storage_path, "_sequence.txt"))).to eq("3\n")
    end

    it "zero-pads :sequence ids so string order matches numeric order" do
      12.times { |i| Counter.create!(label: "c#{i}") }

      expect(Counter.first.label).to eq("c0")
      expect(Counter.last.label).to eq("c11")
      expect(Counter.order(:id).pluck(:label)).to eq(Array.new(12) { |i| "c#{i}" })
    end

    it "supports a Proc generator and a custom primary key" do
      widget = Widget.create!(name: "Cog")

      expect(widget.sku).to match(/\Asku-\h{8}\z/)
      expect(widget.id).to eq(widget.sku)
      expect(document_for(widget)).to include("sku" => widget.sku)
    end

    it "raises for an unusable generator" do
      klass = Class.new(User) do
        def self.name = "BadUser"
        self.id_generator = :nope
      end

      expect { klass.create!(name: "Ada") }.to raise_error(JsonDb::ConfigurationError, /nope/)
    end

    it "keeps an explicitly assigned id" do
      user = User.create!(id: "ada", name: "Ada")

      expect(user.id).to eq("ada")
      expect(record_files_in(User)).to eq(["ada.json"])
    end

    it "refuses ids that would escape the collection directory" do
      expect { User.create!(id: "../../etc/passwd", name: "Mallory") }
        .to raise_error(JsonDb::InvalidId)
      expect { User.create!(id: "_indexes", name: "Mallory") }
        .to raise_error(JsonDb::InvalidId)
    end

    it "compares records by class and id" do
      user = User.create!(name: "Ada")

      expect(User.find(user.id)).to eq(user)
      expect(User.find(user.id)).to eql(user)
      expect([User.find(user.id), user].uniq.size).to eq(1)
      expect(user).not_to eq(User.create!(name: "Grace"))
    end
  end

  describe "validations" do
    it "does not touch the filesystem when a record is invalid" do
      user = User.new(name: "")

      expect(user.save).to be(false)
      expect(user.errors[:name]).to include("can't be blank")
      expect(record_files_in(User)).to be_empty
      expect(user).not_to be_persisted
    end

    it "raises RecordInvalid from the bang variants" do
      expect { User.create!(name: nil) }
        .to raise_error(JsonDb::RecordInvalid, /Name can't be blank/)
      expect { User.create!(name: "Ada", email: "nope") }
        .to raise_error(JsonDb::RecordInvalid, /must look like an address/)
    end

    it "does not overwrite a stored document with an invalid update" do
      user = User.create!(name: "Ada")

      expect(user.update(name: "")).to be(false)
      expect(document_for(user)["name"]).to eq("Ada")
    end

    it "can skip validations explicitly" do
      user = User.new(name: "")

      expect(user.save(validate: false)).to be(true)
      expect(File).to exist(user.storage_path)
    end
  end

  describe "callbacks" do
    it "runs save and create callbacks in order" do
      widget = Widget.create!(name: "Cog")

      expect(widget.events).to eq("before_save;before_create;after_create;")
      expect(widget.events_after_save).to be(true)
      expect(document_for(widget)["events"]).to eq("before_save;before_create;")
    end

    it "runs update callbacks instead of create callbacks on the second save" do
      widget = Widget.create!(name: "Cog")
      widget.update!(name: "Sprocket")

      expect(widget.events).to eq("before_save;before_create;after_create;before_save;")
    end

    it "aborts the save when a before callback throws :abort" do
      klass = Class.new(User) do
        def self.name = "Vetoed"
        before_save { throw :abort }
      end

      user = klass.new(name: "Ada")

      expect(user.save).to be(false)
      expect(user).not_to be_persisted
      expect(record_files_in(klass)).to be_empty
      expect { user.save! }.to raise_error(JsonDb::RecordNotSaved)
    end

    it "runs destroy callbacks" do
      widget = Widget.create!(name: "Cog")

      widget.destroy

      expect(Widget.destroy_log).to include(widget.sku)
    end
  end

  describe "dirty tracking" do
    it "reports changes until the record is saved" do
      user = User.create!(name: "Ada")
      expect(user).not_to be_changed

      user.name = "Ada Lovelace"

      expect(user.changed).to eq(["name"])
      expect(user.name_was).to eq("Ada")
      expect(user.changed_attributes).to eq("name" => "Ada")

      user.save!

      expect(user).not_to be_changed
      expect(user.previous_changes["name"]).to eq(%w[Ada Ada\ Lovelace])
    end

    it "starts clean when loaded from disk" do
      user = User.create!(name: "Ada")

      expect(User.find(user.id)).not_to be_changed
    end
  end

  describe ".find and friends" do
    it "finds a persisted record" do
      user = User.create!(name: "Ada", age: 36)

      found = User.find(user.id)

      expect(found).to be_persisted
      expect(found.name).to eq("Ada")
      expect(found.age).to eq(36)
    end

    it "raises RecordNotFound with useful context" do
      expect { User.find("missing") }.to raise_error(JsonDb::RecordNotFound) do |error|
        expect(error.model).to eq(User)
        expect(error.id).to eq("missing")
        expect(error.message).to include("User", "missing")
      end
      expect { User.find(nil) }.to raise_error(JsonDb::RecordNotFound)
    end

    it "returns nil from find_by_id and find_by" do
      expect(User.find_by_id("missing")).to be_nil
      expect(User.find_by_id("../escape")).to be_nil
      expect(User.find_by(name: "Nobody")).to be_nil
    end

    it "answers exists? for ids and conditions" do
      user = User.create!(name: "Ada")

      expect(User.exists?(user.id)).to be(true)
      expect(User.exists?("missing")).to be(false)
      expect(User.exists?("../../etc/passwd")).to be(false)
      expect(User.exists?(name: "Ada")).to be(true)
      expect(User.exists?).to be(true)
    end

    it "ignores unknown keys in a hand-edited document" do
      user = User.create!(name: "Ada")
      File.write(user.storage_path, JSON.pretty_generate(document_for(user).merge("legacy_field" => "x")))

      expect(User.find(user.id).name).to eq("Ada")
    end

    it "raises SerializationError for a corrupt document" do
      user = User.create!(name: "Ada")
      File.write(user.storage_path, "{ this is not json")

      expect { User.find(user.id) }.to raise_error(JsonDb::SerializationError, /Malformed JSON/)
    end
  end

  describe "changing the primary key" do
    it "moves the record instead of leaving a duplicate behind" do
      user = User.create!(name: "Ada", email: "ada@example.com")
      old_path = user.storage_path

      user.id = "renamed"
      user.save!

      expect(File).not_to exist(old_path)
      expect(File).to exist(user.storage_path)
      expect(User.count).to eq(1)
      expect(User.where(email: "ada@example.com").map(&:id)).to eq(["renamed"])
    end
  end

  describe "#reload" do
    it "discards unsaved changes and picks up external edits" do
      user = User.create!(name: "Ada")
      User.find(user.id).update!(name: "Ada Lovelace")

      user.name = "scratch"
      user.reload

      expect(user.name).to eq("Ada Lovelace")
      expect(user).not_to be_changed
    end

    it "raises when the document is gone" do
      user = User.create!(name: "Ada")
      FileUtils.rm(user.storage_path)

      expect { user.reload }.to raise_error(JsonDb::RecordNotFound)
    end
  end

  describe "#destroy" do
    it "removes the document and marks the record destroyed" do
      user = User.create!(name: "Ada")

      expect(user.destroy).to be(true)
      expect(user).to be_destroyed
      expect(user).not_to be_persisted
      expect(File).not_to exist(user.storage_path)
      expect(User.count).to eq(0)
    end

    it "is idempotent" do
      user = User.create!(name: "Ada")
      user.destroy

      expect(user.destroy).to be(true)
    end

    it "is a no-op on a record that was never written" do
      user = User.new(name: "Ada")

      expect(user.destroy).to be(true)
      expect(user).not_to be_persisted
    end

    it "unlinks the document before dropping it from the index" do
      user = User.create!(name: "Ada", email: "ada@example.com")
      order = []
      allow_any_instance_of(JsonDb::Storage::FileAdapter).to receive(:delete).and_wrap_original do |original, id|
        order << :unlink
        original.call(id)
      end
      allow_any_instance_of(JsonDb::Query::IndexManager).to receive(:remove).and_wrap_original do |original, *args|
        order << :deindex
        original.call(*args)
      end

      user.destroy

      expect(order).to eq(%i[unlink deindex])
      expect(User.where(email: "ada@example.com").to_a).to be_empty
    end

    it "reports an aborted destroy" do
      klass = Class.new(User) do
        def self.name = "Undestroyable"
        before_destroy { throw :abort }
      end
      user = klass.create!(name: "Ada")

      expect(user.destroy).to be(false)
      expect(user).not_to be_destroyed
      expect(File).to exist(user.storage_path)
      expect { user.destroy! }.to raise_error(JsonDb::RecordNotSaved)
    end

    it "destroys every record in the collection" do
      3.times { |i| User.create!(name: "user-#{i}") }

      User.destroy_all

      expect(User.count).to eq(0)
      expect(record_files_in(User)).to be_empty
    end
  end

  describe "serialization" do
    it "exposes the stored hash through as_json" do
      user = User.create!(name: "Ada", age: 36)

      expect(user.as_json).to eq(
        "id" => user.id, "name" => "Ada", "email" => nil, "age" => 36, "admin" => false
      )
    end
  end
end
