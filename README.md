# json-db

A lightweight, zero-database ORM for Ruby 3.3+ / Ruby 4, built on `ActiveModel`.

Every record is stored as its own human-readable JSON document:

```
db/
└── users/
    ├── _indexes.json
    ├── 0b2f9c1d4e5a6b7c.json
    └── 9a8b7c6d5e4f3a2b.json
```

Files are written **atomically**, so a crash, `SIGKILL` or power loss mid-write can
never leave a half-written document behind. That makes it a reasonable fit for
config stores, fixtures, seed data, CLI state, small internal tools, and anything
else you want to be able to open in an editor, diff, and commit to git.

It is **not** a fit for high write concurrency on a single record, large
collections (see [Performance](#performance-and-trade-offs)), or anything needing
transactions across records.

## Installation

```ruby
# Gemfile
gem "json-db"
```

```console
$ bundle install
```

## Quickstart

```ruby
require "json_db"

JsonDb.storage_root = "db"   # default: "db"

class User < JsonDb::Base
  attribute :name,  :string
  attribute :email, :string
  attribute :age,   :integer
  attribute :admin, :boolean, default: false

  index :email                       # maintained in db/users/_indexes.json
  has_many :tasks, dependent: :destroy

  validates :name, presence: true
end

class Task < JsonDb::Base
  attribute :title, :string
  attribute :done,  :boolean, default: false

  index :user_id
  belongs_to :user
end

ada = User.create!(name: "Ada", email: "ada@example.com", age: 36)
ada.id            # => "0b2f9c1d4e5a6b7c"
ada.storage_path  # => "db/users/0b2f9c1d4e5a6b7c.json"
```

`db/users/0b2f9c1d4e5a6b7c.json`:

```json
{
  "id": "0b2f9c1d4e5a6b7c",
  "name": "Ada",
  "email": "ada@example.com",
  "age": 36,
  "admin": false
}
```

```ruby
Task.create!(title: "Write specs", user: ada)
Task.create!(title: "Ship gem",    user: ada, done: true)

ada.tasks.where(done: false).pluck(:title)   # => ["Write specs"]
User.find_by(email: "ada@example.com")       # => #<User ...>  (uses the index)
ada.destroy                                  # also destroys ada's tasks
```

## Configuration

Globally:

```ruby
JsonDb.configure do |config|
  config.storage_root = "db/json"
end
```

Or per model — every setting is inherited by subclasses and overridable:

```ruby
class Ledger < JsonDb::Base
  self.storage_root    = "var/ledgers"  # default: JsonDb.storage_root
  self.collection_name = "ledgers-v2"   # default: model_name.collection, e.g. "ledgers"
  self.primary_key     = :sku           # default: :id (declares the attribute for you)
  self.id_generator    = :uuid          # default: :hex
  self.json_indent     = 0              # default: 2; 0 writes compact one-line JSON
end
```

Namespaced models nest on disk: `Blog::Post` → `db/blog/posts/<id>.json`.

## Primary keys

| Generator   | Produces                                   |
|-------------|--------------------------------------------|
| `:hex`      | `SecureRandom.hex(8)` — `"0b2f9c1d4e5a6b7c"` |
| `:uuid`     | `SecureRandom.uuid`                        |
| `:sequence` | `"000000001"`, `"000000002"` … from `_sequence.txt` |
| any callable| whatever you return, coerced with `to_s`   |

`:sequence` reads and increments `_sequence.txt` under an exclusive `flock`, so
concurrent processes never receive the same number twice. The value is
zero-padded to nine digits: ids are compared as strings everywhere — by the
directory listing, by `order(:id)`, by every index bucket — and padding is what
keeps `"10"` sorting after `"9"`.

A custom generator receives the model class (or nothing, if it takes no argument):

```ruby
class Invoice < JsonDb::Base
  self.id_generator = ->(klass) { "INV-#{Date.today.year}-#{klass.count + 1}" }
end

# Assigning an id explicitly always wins over the generator:
User.create!(id: "ada", name: "Ada")   # => db/users/ada.json
```

Ids must match `/\A[A-Za-z0-9][A-Za-z0-9_.\-]{0,254}\z/`. That rules out `/`, `..`
and the reserved `_` prefix, so a user-supplied id can never escape the collection
directory or collide with bookkeeping files. Anything else raises
`JsonDb::InvalidId`.

## Querying

`.all`, `.where`, and friends return a lazy `JsonDb::Query::Relation`. Nothing
is read from disk until you enumerate it, and every method returns a *new*
relation, so relations are safe to reuse as scopes.

```ruby
User.where(admin: true).order(name: :asc).limit(10)
User.where(age: 30..40)                       # Range  → BETWEEN
User.where(name: %w[Ada Grace])               # Array  → IN
User.where(email: /@example\.com\z/)          # Regexp → matched against to_s
User.where(age: ->(v) { v && v.even? })       # Proc   → arbitrary predicate
User.where(age: nil)                          # matches unset values

User.order(:name).offset(10).limit(10)
User.where(admin: true).pluck(:name, :email)
User.where(admin: true).count
User.order(:age).first        # or .first(3) / .last / .last(3)
User.exists?(email: "ada@example.com")
```

Relations are `Enumerable`, so `map`, `select`, `group_by`, `min_by` … all work.

Values are compared *after* type casting, so `where(age: "36")` finds a record
whose `:integer` attribute is `36`. `nil` sorts last ascending (first descending),
and values that cannot be compared are treated as equal rather than raising.

Bulk helpers: `.destroy_all`, `.update_all(attrs)`, `.delete_all!` (removes the
whole collection directory, bookkeeping included).

## Indexes

A `where` on an un-indexed attribute lists the directory and reads every document.
Declaring an index turns that into one index read plus one read per hit:

```ruby
class User < JsonDb::Base
  attribute :email, :string
  index :email
end
```

`db/users/_indexes.json` is kept in step on every save and destroy:

```json
{
  "email": {
    "ada@example.com": ["0b2f9c1d4e5a6b7c"],
    "grace@example.com": ["9a8b7c6d5e4f3a2b"]
  }
}
```

The update is a read-modify-write under an exclusive `flock` on `_indexes.lock`,
so parallel writers cannot lose each other's entries.

Two details worth knowing:

- **Buckets are keyed by `value.to_s`**, so `1` and `"1"` share a bucket. This is
  safe by construction: the index only *narrows the candidate set*, and the
  relation still applies the real comparison to every candidate. A collision costs
  one wasted file read, never a wrong result.
- **The index is a cache, not the truth.** If it is deleted or hand-edited into
  nonsense, queries still return correct results — they just fall back to a scan
  for the buckets they cannot find. `Model.rebuild_index!` re-derives the whole
  file from the documents on disk; `Model.index_manager.clear!` deletes it.

Adding `index :email` to a model that already has data does **not** backfill.
Run `Model.rebuild_index!` once after deploying the change.

## Associations

```ruby
class User < JsonDb::Base
  has_many :tasks, dependent: :destroy   # :destroy, :nullify or :restrict
  has_one  :profile, dependent: :destroy
end

class Task < JsonDb::Base
  belongs_to :user                       # declares the user_id attribute
end

class Comment < JsonDb::Base
  belongs_to :author, class_name: "User", foreign_key: :author_id, optional: false
end
```

- `belongs_to` declares the foreign key attribute if you have not, adds
  `user` / `user= ` / `reload_user`, memoises the target, and with
  `optional: false` adds a presence validation on the key.
- `has_many` returns a **lazy relation**, so `user.tasks.where(done: false).count`
  never materialises the whole collection.
- `has_one` returns a single record or `nil`.
- Foreign keys default to the demodulized model name — `Blog::Author has_many :posts`
  looks for `Blog::Post#author_id`, not `blog_author_id`.
- Target classes are resolved **lazily** and prefer the owner's namespace, so
  models may reference each other in a cycle.

`dependent: :destroy` runs the children's own destroy callbacks, so cascades
propagate. Children are removed *before* the parent document is unlinked: an
interrupted destroy leaves the parent behind to retry with, rather than orphaning
records nothing points at any more.

## Validations, callbacks, and dirty tracking

Everything `ActiveModel` gives you is available, because these *are* ActiveModel
objects:

```ruby
class User < JsonDb::Base
  validates :name, presence: true

  before_save   { self.email = email&.downcase }
  after_create  { AuditLog.record(self) }
  before_destroy { throw :abort if admin? }   # aborts, destroy returns false
end

user.save     # => false, and nothing is written, if the record is invalid
user.save!    # raises JsonDb::RecordInvalid
user.save(validate: false)

user.name = "Ada Lovelace"
user.changed          # => ["name"]
user.name_was         # => "Ada"
user.save!
user.previous_changes # => {"name" => ["Ada", "Ada Lovelace"]}
```

Callbacks: `before/after_save`, `before/after_create`, `before/after_update`,
`before/after_destroy`. Throwing `:abort` from a `before` callback aborts the
operation, which returns `false` (the bang variants raise
`JsonDb::RecordNotSaved`).

## How atomic writes work

`JsonDb::Storage::AtomicWriter` never writes to the destination path. It:

1. writes the complete document to a uniquely named `.tmp` file **inside the
   destination directory**, so the following `rename` stays on one filesystem;
2. `flush`es and `fsync`s that file, so the bytes are on the device;
3. `File.rename`s it over the target — atomic at the POSIX level, so a reader sees
   either the whole old document or the whole new one;
4. `fsync`s the directory, so the rename itself survives a power loss.

A failure at any step leaves the previous document untouched and cleans up the
temporary file.

The suite verifies this rather than asserting it: four processes rewrite a 160 KB
document in a tight loop while a reader reads it 400 times, and every read is a
complete document. The same test against a plain `File.write` observes 353 torn
reads out of 400.

One caveat: a process `SIGKILL`ed *between* steps 1 and 3 leaves its `.tmp` file
behind. It is inert — it is never read and never listed as a record — but a
long-lived crashy process will accumulate them, so sweep `*.tmp` in your storage
root if that applies to you.

## Errors

| Error | Raised when |
|---|---|
| `JsonDb::RecordNotFound` | `.find` / `.find_by!` / `#reload` finds no document |
| `JsonDb::RecordInvalid` | a bang method hits a failed validation |
| `JsonDb::RecordNotSaved` | a `before` callback threw `:abort` |
| `JsonDb::InvalidId` | an id is unusable or would escape the directory |
| `JsonDb::SerializationError` | a document on disk is not valid JSON |
| `JsonDb::ConfigurationError` | e.g. an unknown `id_generator` or `dependent:` |
| `JsonDb::AssociationError` | an association's class cannot be resolved |

All inherit from `JsonDb::Error`.

## Performance and trade-offs

Measured on Ruby 4.0.2, macOS, APFS on SSD, 5,000 records of ~100 bytes each.
Reproduce with `bundle exec ruby benchmark/run.rb` — these are order-of-magnitude
figures, not a promise.

| Operation | Result |
|---|---|
| `create!` without indexes | ~1,560 records/s |
| `create!` with one index | ~320 records/s |
| `find(id)` | ~0.07 ms (~15,300 records/s) |
| `find_by` on an indexed attribute (N=5,000) | ~1.9 ms |
| `find_by` on an un-indexed attribute (N=5,000) | ~360 ms (**~190× slower**) |
| `Model.all.to_a` (N=5,000) | ~380 ms |
| Disk usage | 20 MB for 5,000 records |

What those numbers mean in practice:

- **`find(id)` is the fast path.** It is one `File.read` and one `JSON.parse`, and
  it does not care how large the collection is. Design around it.
- **Un-indexed `where` is O(N) file reads.** At 5,000 records a single `find_by`
  costs a third of a second. Index anything you filter on, or keep collections
  small.
- **Indexed writes cost ~5×.** Every save rewrites the whole `_indexes.json`, so
  bulk-inserting into an indexed collection degrades quadratically. For a large
  import, load without the index and call `rebuild_index!` afterwards: for the
  5,000 records above that is **3.4 s instead of 15.9 s**.
- **A record costs a filesystem block.** 5,000 × ~100-byte records occupy 20 MB,
  not 500 KB. Filesystems allocate in 4 KB blocks. Also mind your inode budget and
  your directory listing performance past ~10,000 files.
- **There are no transactions.** Each document is written atomically; a multi-record
  update is not. A crash halfway through `dependent: :destroy` leaves some children
  deleted and the parent intact.
- **Concurrency is last-write-wins.** Writes never corrupt a document, and the
  sequence counter and index are `flock`-protected, but there is no optimistic
  locking: two processes updating the same record will have one silently overwrite
  the other.
- **Queries read whole documents.** Filtering happens after type casting in Ruby,
  which is what makes `where(age: "36")` and `Regexp`/`Proc` conditions work — at
  the cost of parsing every candidate.

Rules of thumb: comfortable up to a few thousand records per collection, reads
heavily outnumbering writes, one writer at a time. Past that, use a database.

## Development

```console
$ bundle install
$ bundle exec rspec                 # 113 examples
$ bundle exec ruby benchmark/run.rb # the figures above
$ bundle exec rake                  # the suite, via the default task
$ rbs -I sig validate               # type signatures in sig/json_db.rbs
```

The suite points `JsonDb.storage_root` at a fresh temporary directory for each
example, so it never touches your working tree.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
