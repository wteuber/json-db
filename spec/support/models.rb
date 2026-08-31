# frozen_string_literal: true

# Models used across the suite. They deliberately rely on the *global*
# JsonDb.storage_root, which spec_helper repoints at a fresh temp directory
# for every example.

class User < JsonDb::Base
  attribute :name, :string
  attribute :email, :string
  attribute :age, :integer
  attribute :admin, :boolean, default: false

  index :email

  has_many :tasks, dependent: :destroy
  has_one :profile, dependent: :destroy

  validates :name, presence: true
  validates :email, format: { with: /@/, message: "must look like an address" }, allow_nil: true
end

class Task < JsonDb::Base
  attribute :title, :string
  attribute :done, :boolean, default: false
  attribute :priority, :integer, default: 0

  index :user_id

  belongs_to :user
  validates :title, presence: true
end

class Profile < JsonDb::Base
  attribute :bio, :string

  belongs_to :user
end

class Counter < JsonDb::Base
  self.id_generator = :sequence

  attribute :label, :string
end

class Ledger < JsonDb::Base
  self.collection_name = "ledgers-v2"
  self.json_indent = 0

  attribute :amount, :integer
end

module Blog
  class Author < JsonDb::Base
    attribute :name, :string
    has_many :posts
  end

  class Post < JsonDb::Base
    attribute :title, :string
    belongs_to :author
  end
end

# Exercises callbacks and a non-default primary key.
class Widget < JsonDb::Base
  self.primary_key = :sku
  self.id_generator = -> { "sku-#{SecureRandom.hex(4)}" }

  attribute :name, :string
  attribute :events, :string, default: ""

  before_save { self.events += "before_save;" }
  after_save { self.events_after_save = true }
  before_create { self.events += "before_create;" }
  after_create { self.events += "after_create;" }
  before_destroy { self.class.destroy_log << sku }

  attr_accessor :events_after_save

  def self.destroy_log
    @destroy_log ||= []
  end
end
