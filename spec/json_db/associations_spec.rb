# frozen_string_literal: true

RSpec.describe JsonDb::Associations do
  let!(:ada) { User.create!(name: "Ada", email: "ada@example.com") }
  let!(:grace) { User.create!(name: "Grace", email: "grace@example.com") }

  describe "belongs_to" do
    it "declares the foreign key attribute" do
      expect(Task.attribute_types).to have_key("user_id")
      expect(Task.new.user_id).to be_nil
    end

    it "traverses to the owner" do
      task = Task.create!(title: "Write specs", user_id: ada.id)

      expect(task.user).to eq(ada)
      expect(task.user.name).to eq("Ada")
    end

    it "resolves the owner with a single keyed read, not a collection scan" do
      task = Task.create!(title: "Write specs", user_id: ada.id)
      task = Task.find(task.id)
      reads = 0
      allow_any_instance_of(JsonDb::Storage::FileAdapter).to receive(:read).and_wrap_original do |original, id|
        reads += 1
        original.call(id)
      end

      expect(task.user).to eq(ada)
      expect(reads).to eq(1)
    end

    it "writes the foreign key through the setter" do
      task = Task.new(title: "Write specs")
      task.user = ada

      expect(task.user_id).to eq(ada.id)

      task.save!

      expect(document_for(task)["user_id"]).to eq(ada.id)
    end

    it "returns nil without a foreign key and nil for a dangling one" do
      expect(Task.create!(title: "Orphan").user).to be_nil
      expect(Task.create!(title: "Dangling", user_id: "gone").user).to be_nil
    end

    it "memoises the owner until reloaded" do
      task = Task.create!(title: "Write specs", user_id: ada.id)

      expect(task.user).to be(task.user)

      User.find(ada.id).update!(name: "Ada Lovelace")

      expect(task.user.name).to eq("Ada")
      expect(task.reload_user.name).to eq("Ada Lovelace")
    end

    it "can validate the presence of the owner" do
      klass = Class.new(JsonDb::Base) do
        def self.name = "Comment"
        attribute :body, :string
        belongs_to :user, optional: false
      end

      expect(klass.new(body: "hi").valid?).to be(false)
      expect(klass.new(body: "hi", user: ada).valid?).to be(true)
    end

    it "honours class_name and foreign_key" do
      klass = Class.new(JsonDb::Base) do
        def self.name = "Assignment"
        attribute :label, :string
        belongs_to :owner, class_name: "User", foreign_key: :assignee_id
      end

      record = klass.create!(label: "x", owner: grace)

      expect(record.assignee_id).to eq(grace.id)
      expect(record.owner).to eq(grace)
    end

    it "resolves the target class within the owner's namespace" do
      author = Blog::Author.create!(name: "Ada")
      post = Blog::Post.create!(title: "Notes", author: author)

      expect(Blog::Post.reflect_on(:author).klass).to eq(Blog::Author)
      expect(post.author).to eq(author)
    end

    it "raises a helpful error for an unresolvable class" do
      klass = Class.new(JsonDb::Base) do
        def self.name = "Broken"
        belongs_to :nowhere
      end

      expect { klass.new(nowhere_id: "x").nowhere }
        .to raise_error(JsonDb::AssociationError, /Nowhere/)
    end
  end

  describe "has_many" do
    it "returns a lazy relation scoped by the foreign key" do
      Task.create!(title: "A", user: ada)
      Task.create!(title: "B", user: ada)
      Task.create!(title: "C", user: grace)

      expect(ada.tasks).to be_a(JsonDb::Query::Relation)
      expect(ada.tasks).not_to be_loaded
      expect(ada.tasks.order(:title).pluck(:title)).to eq(%w[A B])
      expect(grace.tasks.count).to eq(1)
    end

    it "is chainable" do
      Task.create!(title: "A", user: ada, done: true)
      Task.create!(title: "B", user: ada)

      expect(ada.tasks.where(done: false).pluck(:title)).to eq(["B"])
      expect(ada.tasks.where(done: true).count).to eq(1)
    end

    it "is empty for a user without children" do
      expect(ada.tasks.to_a).to be_empty
    end

    it "resolves within the owner's namespace" do
      author = Blog::Author.create!(name: "Ada")
      Blog::Post.create!(title: "Notes", author: author)

      expect(Blog::Author.reflect_on(:posts).klass).to eq(Blog::Post)
      expect(author.posts.pluck(:title)).to eq(["Notes"])
    end
  end

  describe "has_one" do
    it "returns the single child or nil" do
      expect(ada.profile).to be_nil

      profile = Profile.create!(bio: "Mathematician", user: ada)

      expect(ada.reload_profile).to eq(profile)
      expect(grace.profile).to be_nil
    end

    it "assigns the foreign key through the setter" do
      profile = Profile.new(bio: "Mathematician")
      ada.profile = profile
      profile.save!

      expect(profile.user_id).to eq(ada.id)
      expect(ada.reload_profile).to eq(profile)
    end

    it "persists the foreign key when the owner is already saved" do
      profile = Profile.new(bio: "Mathematician")

      ada.profile = profile

      expect(Profile.find(profile.id).user_id).to eq(ada.id)
    end

    it "defers the foreign key to the owner's save when the owner is new" do
      user = User.new(name: "Alan", email: "alan@example.com")
      profile = Profile.new(bio: "Cryptanalyst")
      user.profile = profile

      user.save!

      expect(Profile.find(profile.id).user_id).to eq(user.id)
      expect(user.reload_profile).to eq(profile)
    end
  end

  describe "an unsaved owner" do
    # A nil id must not be read as "matches every child whose owner is nil".
    let!(:orphan_task) { Task.create!(title: "Unowned") }
    let!(:orphan_profile) { Profile.create!(bio: "Unowned") }

    it "has an empty has_many without touching the unowned children" do
      relation = User.new(name: "Nobody").tasks

      expect(relation.to_a).to be_empty
      expect(relation.count).to eq(0)
    end

    it "has a nil has_one" do
      expect(User.new(name: "Nobody").profile).to be_nil
    end

    it "destroys without cascading over unowned children" do
      expect(User.new(name: "Nobody").destroy).to be(true)

      expect(Task.find_by_id(orphan_task.id)).to eq(orphan_task)
      expect(Profile.find_by_id(orphan_profile.id)).to eq(orphan_profile)
    end
  end

  describe "dependent: :destroy" do
    it "destroys children before the parent document disappears" do
      Task.create!(title: "A", user: ada)
      Task.create!(title: "B", user: ada)
      Task.create!(title: "C", user: grace)
      Profile.create!(bio: "Mathematician", user: ada)

      ada.destroy

      expect(Task.count).to eq(1)
      expect(Task.first.title).to eq("C")
      expect(Profile.count).to eq(0)
      expect(record_files_in(User)).to eq(["#{grace.id}.json"])
    end

    it "runs the children's own destroy callbacks, cascading further" do
      cascade_log = []
      grandchild = Class.new(JsonDb::Base) do
        def self.name = "Subtask"
        attribute :task_id, :string
        define_singleton_method(:log) { cascade_log }
        after_destroy { self.class.log << id }
      end
      stub_const("Subtask", grandchild)

      task_class = Class.new(JsonDb::Base) do
        def self.name = "Chore"
        attribute :user_id, :string
        has_many :subtasks, class_name: "Subtask", foreign_key: :task_id, dependent: :destroy
      end
      stub_const("Chore", task_class)

      chore = Chore.create!(user_id: ada.id)
      sub = Subtask.create!(task_id: chore.id)

      chore.destroy

      expect(cascade_log).to eq([sub.id])
      expect(Subtask.count).to eq(0)
    end
  end

  describe "dependent: :nullify" do
    it "clears the foreign key instead of deleting children" do
      klass = Class.new(JsonDb::Base) do
        def self.name = "Team"
        attribute :name, :string
        has_many :tasks, foreign_key: :user_id, dependent: :nullify
      end
      stub_const("Team", klass)

      team = Team.create!(name: "Core")
      task = Task.create!(title: "A", user_id: team.id)

      team.destroy

      expect(Task.count).to eq(1)
      expect(task.reload.user_id).to be_nil
    end
  end

  describe "dependent: :restrict" do
    it "refuses to destroy a parent that still has children" do
      klass = Class.new(JsonDb::Base) do
        def self.name = "Project"
        attribute :name, :string
        has_many :tasks, foreign_key: :user_id, dependent: :restrict
      end
      stub_const("Project", klass)

      project = Project.create!(name: "Core")
      Task.create!(title: "A", user_id: project.id)

      expect(project.destroy).to be(false)
      expect(project.errors[:base].first).to match(/cannot destroy/)
      expect(File).to exist(project.storage_path)
    end
  end

  describe "reflections" do
    it "exposes declared associations without leaking into siblings" do
      expect(User.reflections.keys).to contain_exactly(:tasks, :profile)
      expect(Task.reflections.keys).to eq([:user])
      expect(JsonDb::Base.reflections).to be_empty
      expect { User.reflect_on(:nope) }.to raise_error(JsonDb::AssociationError)
    end

    it "rejects an unknown :dependent option" do
      expect do
        Class.new(JsonDb::Base) do
          def self.name = "Bad"
          has_many :tasks, dependent: :explode
        end
      end.to raise_error(JsonDb::ConfigurationError, /:explode/)
    end
  end
end
