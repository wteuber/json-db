# frozen_string_literal: true

RSpec.describe JsonDb::Query::Relation do
  let!(:ada)   { User.create!(name: "Ada",   email: "ada@example.com",   age: 36, admin: true) }
  let!(:grace) { User.create!(name: "Grace", email: "grace@example.com", age: 45) }
  let!(:alan)  { User.create!(name: "Alan",  email: "alan@example.com",  age: 41) }

  describe "laziness" do
    it "does not read anything until the relation is enumerated" do
      relation = User.where(name: "Ada")

      expect(relation).not_to be_loaded

      relation.to_a

      expect(relation).to be_loaded
    end

    it "returns a new relation from every chaining method" do
      base = User.all
      chained = base.where(admin: true).order(:name).limit(1)

      expect(chained).not_to be(base)
      expect(base.count).to eq(3)
    end

    it "re-reads from disk after #reload" do
      relation = User.all
      expect(relation.count).to eq(3)

      User.create!(name: "Katherine")

      expect(relation.reload.count).to eq(4)
    end
  end

  describe "#where" do
    it "matches on a scalar" do
      expect(User.where(name: "Ada").to_a).to eq([ada])
    end

    it "matches on multiple attributes" do
      expect(User.where(name: "Ada", admin: true).to_a).to eq([ada])
      expect(User.where(name: "Ada", admin: false).to_a).to be_empty
    end

    it "treats an Array as IN" do
      expect(User.where(name: %w[Ada Alan]).order(:name).pluck(:name)).to eq(%w[Ada Alan])
    end

    it "treats a Range as BETWEEN" do
      expect(User.where(age: 40..50).order(:age).pluck(:name)).to eq(%w[Alan Grace])
      expect(User.where(age: 40...41).count).to eq(0)
    end

    it "matches a Regexp against the string form" do
      expect(User.where(email: /\Aa/).order(:name).pluck(:name)).to eq(%w[Ada Alan])
    end

    it "accepts a Proc predicate" do
      expect(User.where(age: ->(value) { value&.odd? }).order(:name).pluck(:name)).to eq(%w[Alan Grace])
    end

    it "matches nil" do
      nameless = User.create!(name: "Nobody")

      expect(User.where(age: nil).to_a).to eq([nameless])
    end

    it "casts the condition to the attribute type" do
      expect(User.where(age: "36").to_a).to eq([ada])
      expect(User.where(admin: "1").to_a).to eq([ada])
    end

    it "chains cumulatively" do
      expect(User.where(age: 30..50).where(admin: true).to_a).to eq([ada])
    end
  end

  describe "#order" do
    it "sorts ascending by default" do
      expect(User.order(:age).pluck(:name)).to eq(%w[Ada Alan Grace])
    end

    it "sorts descending" do
      expect(User.order(age: :desc).pluck(:name)).to eq(%w[Grace Alan Ada])
    end

    it "sorts by several attributes" do
      User.create!(name: "Alan", email: "alan2@example.com", age: 30)

      expect(User.order(:name, age: :desc).pluck(:name, :age))
        .to eq([["Ada", 36], ["Alan", 41], ["Alan", 30], ["Grace", 45]])
    end

    it "puts nil last when ascending and first when descending" do
      unknown = User.create!(name: "Nobody")

      expect(User.order(:age).pluck(:name).last).to eq(unknown.name)
      expect(User.order(age: :desc).pluck(:name).first).to eq(unknown.name)
    end

    it "reverses an existing order" do
      expect(User.order(:age).reverse_order.pluck(:name)).to eq(%w[Grace Alan Ada])
    end

    it "rejects an unknown direction" do
      expect { User.order(age: :sideways) }.to raise_error(ArgumentError, /:asc or :desc/)
    end
  end

  describe "#limit and #offset" do
    it "slices after ordering" do
      expect(User.order(:age).limit(2).pluck(:name)).to eq(%w[Ada Alan])
      expect(User.order(:age).offset(1).pluck(:name)).to eq(%w[Alan Grace])
      expect(User.order(:age).offset(1).limit(1).pluck(:name)).to eq(%w[Alan])
    end
  end

  describe "#count" do
    it "counts files directly when the relation is unfiltered" do
      expect(User.all).not_to be_loaded
      expect(User.count).to eq(3)
    end

    it "counts matches for a filtered relation" do
      expect(User.where(admin: true).count).to eq(1)
      expect(User.where(age: 40..50).count).to eq(2)
    end

    it "respects limit and offset" do
      expect(User.limit(2).count).to eq(2)
      expect(User.offset(2).count).to eq(1)
    end
  end

  describe "#none" do
    it "matches nothing without touching the filesystem" do
      relation = User.all.none
      expect_any_instance_of(JsonDb::Storage::FileAdapter).not_to receive(:ids)
      expect_any_instance_of(JsonDb::Storage::FileAdapter).not_to receive(:read)

      expect(relation.to_a).to be_empty
      expect(relation.count).to eq(0)
      expect(relation.any?).to be(false)
      expect(relation.where(name: "Ada").to_a).to be_empty
    end
  end

  describe "#any?" do
    it "honours a pattern argument instead of answering \"not empty\"" do
      expect(User.all.any?(User)).to be(true)
      expect(User.all.any?(Task)).to be(false)
    end

    it "still answers emptiness with no argument and no block" do
      expect(User.all.any?).to be(true)
      expect(User.where(name: "Nobody").any?).to be(false)
    end
  end

  describe "#first, #last and #pluck" do
    it "returns single records or arrays" do
      relation = User.order(:name)

      expect(relation.first).to eq(ada)
      expect(relation.last).to eq(grace)
      expect(relation.first(2)).to eq([ada, alan])
      expect(relation.last(2)).to eq([alan, grace])
    end

    it "plucks one or many attributes" do
      expect(User.order(:name).pluck(:name)).to eq(%w[Ada Alan Grace])
      expect(User.order(:name).pluck(:name, :age)).to eq([["Ada", 36], ["Alan", 41], ["Grace", 45]])
      expect(User.order(:name).ids).to eq([ada.id, alan.id, grace.id])
    end

    it "orders class level .first/.last by primary key" do
      expect(User.first).to eq(User.order(:id).first)
      expect(User.last).to eq(User.order(:id).last)
    end
  end

  describe "Enumerable integration" do
    it "supports map, select and friends" do
      expect(User.all.map(&:name).sort).to eq(%w[Ada Alan Grace])
      expect(User.all.select(&:admin).map(&:name)).to eq(["Ada"])
      expect(User.all.min_by(&:age)).to eq(ada)
      expect(User.where(name: "Nobody")).to be_empty
      expect(User.where(name: "Ada")).to be_any
    end
  end

  describe "bulk operations" do
    it "updates and destroys through the relation" do
      expect(User.where(age: 40..50).update_all(admin: true)).to eq(2)
      expect(User.where(admin: true).count).to eq(3)

      User.where(age: 40..50).destroy_all

      expect(User.count).to eq(1)
    end
  end

  describe "indexes" do
    it "maintains _indexes.json for declared attributes" do
      index = JSON.parse(File.read(File.join(User.storage_path, "_indexes.json")))

      expect(index.keys).to eq(["email"])
      expect(index["email"]["ada@example.com"]).to eq([ada.id])
    end

    it "moves an id between buckets when the indexed value changes" do
      ada.update!(email: "ada@lovelace.example")

      index = User.index_manager.read

      expect(index["email"]).not_to have_key("ada@example.com")
      expect(index["email"]["ada@lovelace.example"]).to eq([ada.id])
      expect(User.find_by(email: "ada@lovelace.example")).to eq(ada)
      expect(User.find_by(email: "ada@example.com")).to be_nil
    end

    it "drops an id from the index when the record is destroyed" do
      ada.destroy

      expect(User.index_manager.read["email"]).not_to have_key("ada@example.com")
      expect(User.find_by(email: "ada@example.com")).to be_nil
    end

    it "narrows the candidate set instead of scanning the directory" do
      allow(User).to receive(:adapter).and_wrap_original do |original, *args|
        original.call(*args).tap { |adapter| allow(adapter).to receive(:ids).and_call_original }
      end

      relation = User.where(email: "ada@example.com")
      candidates = relation.send(:candidate_ids)

      expect(candidates).to eq([ada.id])
    end

    it "falls back to a full scan for an un-indexed attribute" do
      relation = User.where(name: "Ada")

      expect(relation.send(:candidate_ids)).to match_array(User.all.ids)
      expect(relation.to_a).to eq([ada])
    end

    it "still returns correct results when index keys collide" do
      collider = Class.new(JsonDb::Base) do
        def self.name = "Collider"
        attribute :token, :string
        index :token
      end
      # "1" and 1 share the "1" bucket; the relation must still compare exactly.
      one = collider.create!(token: "1")
      collider.create!(token: "other")

      expect(collider.index_manager.read["token"]["1"]).to eq([one.id])
      expect(collider.where(token: "1").to_a).to eq([one])
      expect(collider.where(token: 1).to_a).to eq([one])
    end

    it "unions buckets for an Array condition" do
      expect(User.where(email: ["ada@example.com", "alan@example.com"]).order(:name).pluck(:name))
        .to eq(%w[Ada Alan])
    end

    it "rebuilds buckets with the same keys the incremental update writes" do
      klass = Class.new(JsonDb::Base) do
        def self.name = "Event"
        attribute :at, :datetime
        index :at
      end
      stub_const("Event", klass)
      at = Time.utc(2020, 1, 1, 12, 0, 0)
      event = Event.create!(at: at)
      incremental = Event.index_manager.read["at"].keys

      Event.rebuild_index!

      expect(Event.index_manager.read["at"].keys).to eq(incremental)
      expect(Event.where(at: at).to_a).to eq([event])
    end

    it "falls back to a scan for a value the index has no bucket for" do
      # index :tag is declared after the first record is written, so its value
      # never reaches _indexes.json. A missing bucket means "cannot answer".
      klass = Class.new(JsonDb::Base) do
        def self.name = "Note"
        attribute :tag, :string
      end
      stub_const("Note", klass)
      unindexed = Note.create!(tag: "old")
      Note.index(:tag)
      Note.create!(tag: "new")

      expect(Note.where(tag: "old").to_a).to eq([unindexed])
      expect(Note.where(tag: "absent").to_a).to be_empty
    end

    it "rebuilds the index from the documents on disk" do
      User.index_manager.clear!
      expect(File).not_to exist(File.join(User.storage_path, "_indexes.json"))

      User.rebuild_index!

      expect(User.index_manager.read["email"].keys)
        .to match_array(%w[ada@example.com grace@example.com alan@example.com])
      expect(User.find_by(email: "grace@example.com")).to eq(grace)
    end

    it "keeps working when the index file is deleted mid-flight" do
      FileUtils.rm_f(File.join(User.storage_path, "_indexes.json"))

      expect(User.where(email: "ada@example.com").to_a).to eq([ada])
    end

    it "does not write an index file for models without index declarations" do
      Profile.create!(bio: "hi")

      expect(File).not_to exist(File.join(Profile.storage_path, "_indexes.json"))
    end
  end
end
