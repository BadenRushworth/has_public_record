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

Requires Ruby 3.2+ and Rails 7.1+.

## Why prefixed, and why not the database id

Database ids leak counts and invite enumeration. A prefixed id is safe to put in URLs and logs, and the prefix
lets you resolve an id with no other context: `HasPublicRecord.resolve("usr_K3F9A2")` returns the `User`.

## Options

~~~ruby
has_public_record prefix: "usr",          # required, unique across the app
                  column: :public_id,     # where the id is stored
                  length: 8,              # starting length of the random part for this model
                  max_bumps: 4            # how far the length may grow before ExhaustedError
~~~

A prefix is 1 to 10 characters: lower-case letters and digits only, starting with a lower-case letter
(`"usr"` and `"inv2"` are fine; `"Usr"`, `"2fa"` and `"a_b"` raise `InvalidPrefixError`). Two models cannot share
a prefix (`DuplicatePrefixError`).

Declare it on the base class of an STI hierarchy, once. A subclass cannot declare it again, and an abstract class
cannot declare it at all (it has no table). Declaring costs no database access, so it is safe while the app boots.

## The column

The column is a string with a unique index. It uses a custom attribute type, so anything assigned or queried is
normalized: `User.new(public_id: "usr_k3f9a2")` stores `usr_K3F9A2`, and `User.where(public_id: "k3f9a2")`
finds it. Reading a row returns exactly what is stored, so a legacy bare code stays visible as bare until you
migrate it. Raw SQL (`update_all` with a string, `execute`) bypasses the type, and `insert_all` may or may not use
it depending on your Rails version, so do not rely on either.

The id is read-only once created (`regenerate_public_id!` is the one way to replace it). Ids you supply on create
must start with the model's prefix and use only alphabet characters.

## Reference

On the model:

| Method | What it does |
| --- | --- |
| `find_by_public_id(ref)` / `find_by_public_id!(ref)` | Finds by `usr_K3F9A2` or the bare `K3F9A2`, in any letter case. Another model's id or junk gives nil (or raises `RecordNotFound`) |
| `from_param(param)` / `from_param!(param)` | The same, named for what a controller has: `User.from_param!(params[:id])` |
| `with_public_id(*refs)` | A relation for several ids; ids of other models are ignored |
| `public_id?(ref)` | Whether the ref belongs to this model |
| `normalize_public_id(ref)` | The stored form of a ref (`"usr_K3F9A2"`), or nil. The alphabet is not checked, so old ids stay findable |
| `public_id_prefix`, `public_id_column` | What the model declared |
| `public_id_format` | A regexp for route constraints: `resources :users, constraints: { id: User.public_id_format }` |
| `missing_public_id` | Rows with a NULL or empty id |
| `generate_public_id` | One fresh unused id |
| `generate_public_ids(count, reserved: [])` | `count` distinct fresh ids with one existence query. `reserved` are ids to avoid that are not in the table yet |
| `backfill_public_ids!(batch_size: 1000)` | Gives every row without an id one; one query and one transaction per batch; returns the count |
| `with_generated_public_ids(rows)` | Fills the id into rows for `insert_all` / `upsert_all`, keeping ids you supplied |
| `fixture_public_id(label)` | A stable id for a fixture label |

On a record:

| Method | What it does |
| --- | --- |
| `public_id`, `public_id_bare`, `public_id_prefix` | The id, the id without its prefix, the prefix |
| `to_param` | The public id once saved (so `user_path(user)` uses it), nil before |
| `regenerate_public_id!` | Replaces the id (a leaked link, a rotated invite); every old URL stops working. Returns the new id |

On the module:

| Method | What it does |
| --- | --- |
| `HasPublicRecord.resolve(ref)` / `resolve!` | The record a ref points at, or nil / raises `RecordNotFound` |
| `HasPublicRecord.resolve_many(*refs)` | Mixed refs in one query per model; returns `{ ref => record }` |
| `HasPublicRecord.model_for(ref)` | The model class for a ref |
| `HasPublicRecord.parse(ref)` | `Parsed(prefix:, bare:)` or nil |
| `HasPublicRecord.valid?(ref)` | Whether the ref is shaped like an id (any prefix) |
| `HasPublicRecord.well_formed?(ref, prefix)` | Whether the ref is an id that prefix could have issued, with the current alphabet |
| `HasPublicRecord.canonicalize(ref, prefix)` | The stored form of a ref for a prefix, or nil |
| `HasPublicRecord.fold_case(text)` | Folds to the alphabet's letter case (or leaves a mixed-case alphabet alone) |
| `HasPublicRecord.prefixes` / `prefix_for(model)` | `{ "usr" => "User", ... }` / one model's prefix |
| `HasPublicRecord.generate(prefix = nil, ...) { }` | Makes an id without a model |
| `HasPublicRecord.identifier(prefix = nil, ...) { }` | A reusable generator without a model |
| `HasPublicRecord.fixture_id(prefix, label, length:)` | A stable id for a label, for fixtures and seeds |
| `HasPublicRecord.configure { }` / `config` | Settings |
| `HasPublicRecord.reset_registry!` / `reset!` | Forget declared prefixes / everything (for tests; Rails calls the first on code reload in development) |

## Lookup

Ids are matched in any letter case (`usr_k3f9a2` finds `usr_K3F9A2`) when the alphabet has one case; an alphabet
with both cases is left as typed. Lookups do not check the alphabet, so ids made under an older alphabet stay
findable. `public_id_format` follows the current alphabet: when you change the alphabet, widen it.

`resolve_many` is for a pile of mixed refs (an audit log, polymorphic references). It groups refs by prefix and
runs one query per model, and refs that match nothing are left out of the result:

~~~ruby
HasPublicRecord.resolve_many("usr_K3F9A2", "ses_7QX2B1", "zzz_nope")
# => { "usr_K3F9A2" => #<User>, "ses_7QX2B1" => #<Session> }
~~~

## Length growth

Ids start at `default_length` (6 by default, about 2 billion codes). When random tries keep hitting existing
codes, the length grows by one and is remembered per table and column for the life of the process. It never grows
past the starting length plus `max_bumps`, so a long outage cannot ratchet it up for good. Each growth is announced
(see Notifications), so you can see a table getting dense before it matters.

Two inserts racing on the same random code raise `ActiveRecord::RecordNotUnique` from the unique index. That is
very rare (it needs the same code from two writers in the same moment), so there is no built-in retry; rescue and
retry in your own code if your traffic makes it worth it.

## Configuration

~~~ruby
# config/initializers/has_public_record.rb  (rails g has_public_record:install writes it, all commented out)
HasPublicRecord.configure do |config|
  config.default_length = 6
  config.attempts_per_length = 10
  config.max_length_bumps = 4
  config.alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"   # 2+ distinct, no "_", no whitespace; or :unambiguous
  config.lengths = { "users" => 8 }                          # per table; beats a model's length:
end
~~~

Settings are read when an id is made, never copied at load, so an app that keeps its settings elsewhere can assign
them from its own boot code. `config.alphabet = :unambiguous` leaves out 0/O and 1/I/L, which makes ids easier to
read aloud. Prefixes are code, not settings.

## Adding it to an existing table

Two steps, so a populated table never needs a NOT NULL column it cannot satisfy:

~~~bash
rails g has_public_record:migration users              # nullable column + unique index
rails db:migrate
rails has_public_record:backfill MODEL=User            # gives every row an id
rails has_public_record:report                         # all clean?
rails g has_public_record:migration users --enforce    # now NOT NULL
rails db:migrate
~~~

Options: `--column=name`, and `--concurrently` (builds the index without locking writes on PostgreSQL; other
databases build it normally). For new tables, `t.string :public_id, null: false, index: { unique: true }` is enough.

On a very large PostgreSQL table, `change_column_null` scans the table under a lock. The lock-light route
(PostgreSQL 12+) is a CHECK constraint added unvalidated and then validated, after which NOT NULL needs no scan;
the `--enforce` migration carries the lines as a comment.

## Rake tasks

`MODEL=` accepts `User`, `user` or `users`.

| Task | What it does |
| --- | --- |
| `has_public_record:backfill` | Fills missing ids (`MODEL=User` to limit) |
| `has_public_record:report` | Counts missing ids, wrong prefixes and duplicates, and shows how full each table's code space is; fails if anything is off |
| `has_public_record:rename MODEL=User FROM=old` | Previews moving stored ids from an old prefix to the declared one; add `APPLY=1` to do it, in one transaction |

Renaming a prefix breaks every stored URL and any id saved in another table.

## Ids without a model

The generator needs no model. Whether a code is free is a block. The examples use things that are not models with
`has_public_record` (a model that declares a prefix cannot also be used as a standalone prefix):

~~~ruby
HasPublicRecord.generate("key", length: 10) { |id| !Redis.exists?(id) }        # => "key_7K2QX9ABCD"
HasPublicRecord.generate(nil, length: 5, key: "codes") { |id| !Redis.exists?(id) }  # bare code: key names its growth

coupons = HasPublicRecord.identifier("cpn", length: 8) { |id| !Coupon.exists?(code: id) }
coupons.generate                  # grows and notifies exactly like models do
coupons.valid?("cpn_7K2QX9AB")    # => true
coupons.bare("cpn_7K2QX9AB")      # => "7K2QX9AB"
~~~

Standalone prefixes are not registered for `HasPublicRecord.resolve`; only models are.

## Testing

Rails fixtures and `insert_all` skip callbacks, so rows get no id unless you supply one:

~~~ruby
# fixtures: the same label always gives the same id
alice:
  public_id: <%= User.fixture_public_id(:alice) %>

# bulk inserts: one existence query for the whole batch
User.insert_all(User.with_generated_public_ids(rows))
~~~

`backfill_public_ids!` is the after-the-fact fix for rows that were inserted without an id.

## Associations

Plain Rails associations are enough. Keep integer foreign keys inside the system and use the public id only at
the edge, scoped through the owner so one person cannot reach another's records:

~~~ruby
current_user.sessions.find_by_public_id!(params[:id])
~~~

## Notifications

Through ActiveSupport::Notifications, never a logger of its own:

| Event | Payload |
| --- | --- |
| `grow.has_public_record` | `key`, `table`, `column` (both nil for a standalone generator), `from`, `to` |
| `rename.has_public_record` | `table`, `column`, `from`, `to`, `count` (rows actually changed) |
| `regenerate.has_public_record` | `table`, `column`, `from`, `to` |

## Engines

Works inside an engine. Prefixes are global per process, so choose distinctive ones. An engine should not call
`HasPublicRecord.configure` (it is process-wide); use the per-model `length:` and `max_bumps:` instead.

## License

MIT.
