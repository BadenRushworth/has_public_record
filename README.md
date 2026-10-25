# has_public_record

Short, prefixed, URL-safe public ids for ActiveRecord models: `usr_K3F9A2`. The prefix says what the id
belongs to, the random part is short, and it grows by itself as a table fills.

~~~ruby
class User < ApplicationRecord
  has_public_record prefix: "usr"
end

user = User.create!
user.public_id        # => "usr_K3F9A2"
user.public_id_bare   # => "K3F9A2"
user_path(user)       # => "/users/usr_K3F9A2"   (to_param)
User.find_by_public_id!("usr_K3F9A2")
~~~

## Why prefixed, and why not the database id

Database ids leak counts and invite enumeration. A prefixed id is safe to put in URLs and logs, and the prefix
lets you resolve an id with no other context: `HasPublicRecord.resolve("usr_K3F9A2")` returns the `User`.

## Options

~~~ruby
has_public_record prefix: "usr",          # required, unique across the app: a-z and 0-9, starts with a letter, max 10
                  column: :public_id,     # where the id is stored
                  length: 8,              # starting length of the random part for this model
                  max_bumps: 4            # how far the length may grow before ExhaustedError
~~~

Declare it on the base class of an STI hierarchy. Declaring costs no database access, so it is safe while the
app boots.

## Methods

On the model:

| Method | What it does |
| --- | --- |
| `find_by_public_id(ref)` | Finds by `usr_K3F9A2` or the bare `K3F9A2`; another model's id or junk gives nil |
| `find_by_public_id!(ref)` | Same, raises `ActiveRecord::RecordNotFound` |
| `with_public_id(*refs)` | A relation for several ids; ids of other models are ignored |
| `public_id?(ref)` | Whether the ref belongs to this model |
| `public_id_prefix`, `public_id_column` | What the model declared |
| `missing_public_id` | Rows with no id yet |
| `generate_public_id` | A fresh unused id |
| `backfill_public_ids!` | Gives every row without an id one; returns the count |

On a record: `public_id`, `public_id_bare`, `public_id_prefix`, `to_param`.

On the module:

| Method | What it does |
| --- | --- |
| `HasPublicRecord.resolve(ref)` / `resolve!` | The record a ref points at, or nil / raises |
| `HasPublicRecord.model_for(ref)` | The model class for a ref |
| `HasPublicRecord.parse(ref)` | `Parsed(prefix:, bare:)` or nil |
| `HasPublicRecord.valid?(ref)` | Whether the ref is shaped like an id |
| `HasPublicRecord.prefixes` | `{ "usr" => "User", ... }` |
| `HasPublicRecord.prefix_for(model)` | The prefix a model declared |
| `HasPublicRecord.generate(...)` | Makes an id for a scope |

The id is read-only once created. `insert_all` and `upsert_all` skip callbacks, so rows inserted that way get
no id; fill them with `backfill_public_ids!`.

## Length growth

Ids start at `default_length` (6 by default, about 2 billion codes). When random tries keep hitting existing
codes, the length grows by one and is remembered per table and column for the life of the process. Each growth
is announced (see Notifications), so you can see a table getting dense before it matters.

## Configuration

~~~ruby
# config/initializers/has_public_record.rb  (rails g has_public_record:install writes it, all commented out)
HasPublicRecord.configure do |config|
  config.default_length = 6
  config.attempts_per_length = 10
  config.max_length_bumps = 4
  config.alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"   # 2+ distinct, no "_", no whitespace
  config.lengths = { "users" => 8 }                          # per table; beats a model's length:
end
~~~

Settings are read when an id is made, never copied at load, so an app that keeps its settings elsewhere can
simply assign them from its own boot code. Prefixes are code, not settings.

## Adding it to an existing table

Two steps, so a populated table never needs a NOT NULL column it cannot satisfy:

~~~zsh
rails g has_public_record:migration users              # nullable column + unique index
rails db:migrate
rails has_public_record:backfill MODEL=User            # gives every row an id
rails has_public_record:report                         # all clean?
rails g has_public_record:migration users --enforce    # now NOT NULL
rails db:migrate
~~~

Options: `--column=name`, and `--concurrently` (PostgreSQL only: builds the index without locking writes).
For new tables, `t.string :public_id, null: false, index: { unique: true }` is enough.

## Rake tasks

| Task | What it does |
| --- | --- |
| `has_public_record:backfill` | Fills missing ids (`MODEL=User` to limit) |
| `has_public_record:report` | Counts missing ids, wrong prefixes and duplicates, and shows how full each table's code space is; exits 1 if anything is off |
| `has_public_record:rename MODEL=User FROM=old` | Previews moving stored ids from an old prefix to the declared one; add `APPLY=1` to do it, in one transaction |

Renaming a prefix breaks every stored URL and any id saved in another table.

## Notifications

Through ActiveSupport::Notifications, never a logger of its own:

- `grow.has_public_record` with `key`, `table`, `column` (both nil for a standalone generator), `from`, `to`
- `rename.has_public_record` with `table`, `column`, `from`, `to`, `count`

## Engines

Works inside an engine. Prefixes are global per process, so choose distinctive ones. An engine should not call
`HasPublicRecord.configure` (it is process-wide); use the per-model `length:` and `max_bumps:` instead.

## Lookup helpers

Ids are matched in any letter case (`usr_k3f9a2` finds `usr_K3F9A2`) when the alphabet has one case; an alphabet
with both cases is left as typed.

| Helper | What it does |
| --- | --- |
| `User.from_param(params[:id])` / `from_param!` | What a controller has: nil-safe and raising versions |
| `User.public_id_format` | A regexp for route constraints: `resources :users, constraints: { id: User.public_id_format }` |
| `HasPublicRecord.resolve_many(*refs)` | Mixed refs (an audit log) in one query per model; returns `{ ref => record }` |

## Ids without a model

The generator needs no model. Whether a code is free is a block:

~~~ruby
HasPublicRecord.generate("inv", length: 8) { |id| !Invoice.exists?(number: id) }   # => "inv_7K2QX9AB"
HasPublicRecord.generate(nil, length: 5, key: "codes") { |id| !Redis.exists?(id) } # bare code: key names its growth

invoices = HasPublicRecord.identifier("inv", length: 8) { |id| !Invoice.exists?(number: id) }
invoices.generate                  # grows and notifies exactly like models do
invoices.valid?("inv_7K2QX9AB")    # => true
invoices.bare("inv_7K2QX9AB")      # => "7K2QX9AB"
~~~

Standalone prefixes are not registered for `HasPublicRecord.resolve`; only models are. A prefix a model already
declared is refused.

## Testing

Rails fixtures and `insert_all` skip callbacks, so rows get no id unless you supply one:

~~~ruby
# fixtures: the same label always gives the same id
alice:
  public_id: <%= User.fixture_public_id(:alice) %>

# bulk inserts
User.insert_all(User.with_generated_public_ids(rows))
~~~

## Alphabets

`config.alphabet = :unambiguous` leaves out 0/O and 1/I/L, which makes ids easier to read aloud. The default
is `0-9A-Z`.

## Associations

Plain Rails associations are enough. Keep integer foreign keys inside the system and use the public id only at
the edge, scoped through the owner so one person cannot reach another's records:

~~~ruby
current_user.sessions.find_by_public_id!(params[:id])
~~~

## Capacity

`has_public_record:report` shows how full each table's code space is. Growth starts well before 100%: at half
full, ten random tries in a row all hit taken codes about once in a thousand.

## License

MIT.
