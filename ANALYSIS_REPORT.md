# Comprehensive Architectural Analysis & Review: `has_public_record`

**Target Project:** `has_public_record` (Rails gem)  
**Report Date:** October 2026  
**Scope:** Gem internals, generators, Rake tasks, specs, dependencies, README, and Rails architectural integration (full apps, engines, multi-database, sharding).

---

## Executive Summary

`has_public_record` is an elegantly designed, high-utility Rails gem that generates short, prefixed, URL-safe identifiers (e.g., `usr_K3F9A2`) for ActiveRecord models. It prevents database ID enumeration, keeps internal foreign keys as efficient integers, and enables context-free polymorphic resolution (`HasPublicRecord.resolve("usr_K3F9A2")`).

The gem currently has **60 passing specs** with 0 failures, clean separation of concerns, and thoughtfully implemented features (e.g., `resolve_many` for polymorphic batch lookups, `with_generated_public_ids` for `insert_all`, deterministic fixture IDs, and adaptive length growth).

However, a forensic examination across edge cases, performance at scale, Rails engine architectures, database quirks, and documentation revealed several **critical bugs, performance bottlenecks, and architectural opportunities**. Addressing these will elevate `has_public_record` to feel like an official, first-class extension of Ruby on Rails.

---

## 1. Critical Edge Cases & Functional Bugs

### 1.1 Format Validation Allows Arbitrary Characters (Security & Data Integrity)
- **Files:** [`lib/has_public_record/model.rb`](file:///data/data/com.termux/files/home/projects/has_public_record/lib/has_public_record/model.rb#L146-L152), [`lib/has_public_record.rb`](file:///data/data/com.termux/files/home/projects/has_public_record/lib/has_public_record.rb#L61-L72)
- **The Bug:**
  In `Model#validate_public_record_format`:
  ```ruby
  def validate_public_record_format
    column = self.class.public_id_column
    value = self[column]
    return if value.blank? || self.class.normalize_public_id(value) == value

    errors.add(column, :invalid)
  end
  ```
  `normalize_public_id(value)` delegates to `HasPublicRecord.canonicalize(value, prefix)`:
  ```ruby
  head, separator, tail = text.partition(SEPARATOR)
  if separator.empty?
    "#{prefix}#{SEPARATOR}#{fold_case(head)}"
  elsif head.downcase == prefix && !tail.empty?
    "#{prefix}#{SEPARATOR}#{fold_case(tail)}"
  end
  ```
  Notice that `canonicalize` only checks that `head.downcase == prefix` and `!tail.empty?`. It **never checks** whether the characters in `tail` belong to `config.alphabet`!
  As a result:
  ```ruby
  user = User.new(public_id: "usr_!@#$%^&*")
  user.valid? # => TRUE! No errors!
  ```
  Arbitrary garbage, punctuation, and non-alphabet characters pass ActiveRecord format validation. However, `User.public_id_format` (the route constraint regex) strictly checks the alphabet. This means an invalid ID can be saved to the database, but routes will reject it.
- **Suggested Fix:**
  Format validation should ensure that the bare code consists strictly of characters in `config.alphabet` (respecting case-folding rules).

---

### 1.2 Case-Folding Rejection on Assignment / Create
- **Files:** [`lib/has_public_record/model.rb`](file:///data/data/com.termux/files/home/projects/has_public_record/lib/has_public_record/model.rb#L146-L152)
- **The Bug:**
  The gem promotes case-insensitivity: *"Ids are matched in any letter case (`usr_k3f9a2` finds `usr_K3F9A2`)"* and *"people type ids"*.
  However, if a user or controller instantiates a record with lowercase characters:
  ```ruby
  user = User.new(public_id: "usr_k3f9a2")
  user.valid? # => FALSE!
  user.errors.full_messages # => ["Public is invalid"]
  ```
  Why? Because `normalize_public_id("usr_k3f9a2")` uppercases the string to `"usr_K3F9A2"`. Since `"usr_K3F9A2" != "usr_k3f9a2"`, validation fails!
  Also notice the error message: `public_id` is humanized by Rails to `"Public"` because Rails strips `_id` assuming a foreign key.
- **Suggested Fix:**
  Either normalize `public_id` in a `before_validation` callback / attribute setter (`self[column] = self.class.normalize_public_id(self[column]) if self[column].present?`), or use an ActiveRecord Custom Type (detailed in Section 3).

---

### 1.3 Discrepancy Between `missing_public_id` and `Maintenance.report`
- **Files:** [`lib/has_public_record/model.rb`](file:///data/data/com.termux/files/home/projects/has_public_record/lib/has_public_record/model.rb#L68), [`lib/has_public_record/maintenance.rb`](file:///data/data/com.termux/files/home/projects/has_public_record/lib/has_public_record/maintenance.rb#L47)
- **The Bug:**
  In `Maintenance.report`:
  ```ruby
  missing: scope.where(column => [nil, ""]).count
  ```
  `Maintenance.report` treats both `nil` and `""` (empty string) as missing IDs.
  However, in `Model.missing_public_id`:
  ```ruby
  def missing_public_id = where(public_id_column => nil)
  ```
  `missing_public_id` only queries `WHERE public_id IS NULL`.
  If a legacy database or CSV import contains empty strings `""`:
  1. `rails has_public_record:report` flags them as `missing: 5`.
  2. `rails has_public_record:backfill` runs `missing_public_id.find_each` and updates **0 rows**.
  3. `rails has_public_record:report` will continue to fail forever on that table.
- **Suggested Fix:**
  Update `missing_public_id` to match `Maintenance.report`:
  ```ruby
  def missing_public_id = where(public_id_column => [nil, ""])
  ```

---

### 1.4 Abstract Classes Declare `has_public_record` and Crash Resolvers
- **Files:** [`lib/has_public_record/model.rb`](file:///data/data/com.termux/files/home/projects/has_public_record/lib/has_public_record/model.rb#L18-L26), [`lib/has_public_record.rb`](file:///data/data/com.termux/files/home/projects/has_public_record/lib/has_public_record.rb#L80-L95)
- **The Bug:**
  If a developer declares `has_public_record prefix: "cnt"` on an abstract class (e.g., `class Content < ApplicationRecord; self.abstract_class = true; has_public_record prefix: "cnt"`):
  1. `Registry` registers `"cnt" => "Content"`.
  2. Later, when resolving `HasPublicRecord.resolve("cnt_ABC123")`, `model_for` returns `Content`.
  3. `Content.find_by_public_id("cnt_ABC123")` is called.
  4. ActiveRecord raises: `ActiveRecord::TableNotSpecified: Content is an abstract class and does not have an associated table`.
- **Suggested Fix:**
  Raise a descriptive error in `declare_public_record` if `abstract_class?` is true:
  ```ruby
  raise HasPublicRecord::Error, "Cannot declare has_public_record on abstract class #{name}" if abstract_class?
  ```

---

### 1.5 Runaway Length Inflation in `Generator` Across Iterations
- **Files:** [`lib/has_public_record/generator.rb`](file:///data/data/com.termux/files/home/projects/has_public_record/lib/has_public_record/generator.rb#L31-L49)
- **The Bug:**
  In `Generator.generate`:
  ```ruby
  current = [starting_length(table || key, length), LEARNED[key].to_i].max
  bumps = 0
  ...
  bumps += 1
  current += 1
  learn(key, current)
  ```
  `bumps` is local to each call to `generate`.
  Suppose a table experiences high collision or an outage where `free.call(candidate)` returns false:
  - Call 1: bumps 4 times (length grows 6 -> 10), raises `ExhaustedError`. `LEARNED[key]` is now 10.
  - Call 2: starts at 10, bumps 4 times (length grows 10 -> 14), raises `ExhaustedError`. `LEARNED[key]` is now 14.
  - Call 3: starts at 14, bumps to 18...
  There is **no global ceiling** on `LEARNED[key]`. In a prolonged failure, `LEARNED[key]` ratchets up indefinitely. Once the issue is resolved, IDs will be permanently generated at hundreds of characters in length for that process.
- **Suggested Fix:**
  Cap learned length based on `starting_length + limit`:
  ```ruby
  max_allowed_length = starting_length(table || key, length) + limit
  ```
  If `current >= max_allowed_length`, raise `ExhaustedError` immediately rather than inflating `LEARNED[key]`.

---

### 1.6 `Maintenance.rename_prefix` Count & Instrument Accuracy
- **Files:** [`lib/has_public_record/maintenance.rb`](file:///data/data/com.termux/files/home/projects/has_public_record/lib/has_public_record/maintenance.rb#L62-L76)
- **The Bug:**
  In `rename_prefix`:
  ```ruby
  count = scope.count
  return count unless apply && count.positive?

  model.transaction do
    scope.find_each(batch_size: batch_size) do |record|
      next unless record[column].start_with?(old) # line 68
      ...
    end
  end
  ActiveSupport::Notifications.instrument("rename.has_public_record", count: count)
  count
  ```
  `count` is precalculated from `scope.count`. If any records are skipped by `next unless record[column].start_with?(old)` (for instance, due to collation differences or case mismatches between the database LIKE match and ruby `start_with?`), the actual number of updated records will be less than `count`. Yet `count` is reported in the notification and returned by the method.
- **Suggested Fix:**
  Track the actual `renamed_count = 0` updated within the loop and report `renamed_count`.

---

## 2. Performance & Scalability Bottlenecks

### 2.1 Bulk Operations: `with_generated_public_ids` Causes N+1 Queries
- **Files:** [`lib/has_public_record/model.rb`](file:///data/data/com.termux/files/home/projects/has_public_record/lib/has_public_record/model.rb#L97-L112)
- **The Problem:**
  `with_generated_public_ids` is designed to prepare rows for bulk insertion:
  `User.insert_all(User.with_generated_public_ids(rows))`
  However, look at the implementation:
  ```ruby
  rows.map do |row|
    ...
    id = generate_public_id # Executes SELECT 1 FROM users WHERE public_id = '...'
    taken << id
    row.merge(column => id)
  end
  ```
  If inserting 10,000 rows, `with_generated_public_ids` executes **10,000 separate `SELECT` queries** against the database before running `insert_all`! This eliminates the primary performance benefit of `insert_all`.
- **Suggested Refactor:**
  At length 6 (with ~2.17 billion combinations), generating 10,000 unique IDs in memory has near-zero collision probability.
  Instead of probing the database 10,000 times:
  1. Generate the required count of unique random IDs in memory.
  2. Perform **one single query** to check if any of those candidate IDs already exist in the database:
     `existing = where(column => candidate_ids).pluck(column).to_set`
  3. Replace any rare colliding candidates.
  4. Merge into rows.
  This transforms 10,000 queries into **1 query**, yielding a 100x–500x speedup for bulk imports.

---

### 2.2 `backfill_public_ids!` Executes 2N Queries Without Transactions
- **Files:** [`lib/has_public_record/model.rb`](file:///data/data/com.termux/files/home/projects/has_public_record/lib/has_public_record/model.rb#L87-L93)
- **The Problem:**
  ```ruby
  def backfill_public_ids!(batch_size: 1000)
    count = 0
    missing_public_id.find_each(batch_size: batch_size) do |record|
      count += public_record_row_scope(record).update_all(public_id_column => generate_public_id)
    end
    count
  end
  ```
  For 100,000 missing records:
  - 100,000 `SELECT` queries (`generate_public_id`)
  - 100,000 `UPDATE` queries (`update_all`)
  - 100,000 database commits (each `update_all` runs in autocommit mode since there is no wrapping transaction).
- **Suggested Refactor:**
  Use `in_batches` wrapped in batch-level transactions:
  ```ruby
  def backfill_public_ids!(batch_size: 1000)
    count = 0
    missing_public_id.in_batches(of: batch_size) do |batch|
      records = batch.to_a
      next if records.empty?

      # Pre-generate IDs in memory
      ids = generate_unique_batch(records.size)
      transaction do
        records.each_with_index do |record, idx|
          public_record_row_scope(record).update_all(public_id_column => ids[idx])
        end
      end
      count += records.size
    end
    count
  end
  ```
  Grouping updates inside batch transactions reduces disk I/O and commit overhead significantly.

---

### 2.3 Database Collision Race Condition on High-Concurrency `INSERT`
- **Files:** [`lib/has_public_record/model.rb`](file:///data/data/com.termux/files/home/projects/has_public_record/lib/has_public_record/model.rb#L28-L29, #L141-L144)
- **The Scenario:**
  `before_create :assign_public_record` calls `generate_public_id`.
  Under high concurrency, two parallel threads or processes can probe `exists?` simultaneously, get `false`, and both attempt an `INSERT` with the same ID. The database unique index throws `ActiveRecord::RecordNotUnique`.
- **Recommendation:**
  In high-traffic applications, catching `ActiveRecord::RecordNotUnique` on `public_id` and retrying with a fresh ID (up to 2–3 times) provides seamless reliability. Document this behavior or provide a `create_with_public_id_retry` helper.

---

## 3. Rails Native Integration ("Feeling Like Part of Rails")

To make `has_public_record` feel like a core extension of Rails (such as `has_secure_password` or `has_secure_token`), the following enhancements should be considered:

### 3.1 Custom `ActiveRecord::Type` for Public ID Columns
Currently, ActiveRecord treats `:public_id` as a generic `:string` column.
If `has_public_record` registers a custom ActiveRecord type:
```ruby
class PublicIdType < ActiveRecord::Type::String
  def cast(value)
    return super if value.nil?
    HasPublicRecord.canonicalize(value, @prefix) || super
  end
end
```
And registers it on the model:
`attribute column, PublicIdType.new(prefix: prefix)`
**Benefits:**
1. `user = User.new(public_id: "usr_k3f9a2")` automatically casts and normalizes to `"usr_K3F9A2"` on assignment!
2. Standard Rails queries like `User.where(public_id: "usr_k3f9a2")` or `User.find_by(public_id: "usr_k3f9a2")` automatically cast the query parameter through the type, eliminating case-sensitivity failures on PostgreSQL.
3. Form helpers, nested attributes, and parameters seamlessly normalize without custom controller code.

---

### 3.2 Rails Development Reloader Synchronization
- **Files:** [`lib/has_public_record.rb`](file:///data/data/com.termux/files/home/projects/has_public_record/lib/has_public_record.rb#L29-L32, #L147-L153), [`lib/has_public_record/railtie.rb`](file:///data/data/com.termux/files/home/projects/has_public_record/lib/has_public_record/railtie.rb#L7-L9)
- **The Issue in Development Mode:**
  In Rails development (`config.enable_reloading = true`):
  1. `@models_loaded = false` is set on gem load. Once set to `true`, `load_models!` never runs again.
  2. If a developer edits a model, deletes a model, or renames a prefix in `app/models/user.rb`:
     `HasPublicRecord.registry` retains stale strings from the previous class definition.
     If a developer renames a prefix or changes a class name, `Registry#register` will raise `DuplicatePrefixError` during code reload, forcing a server restart.
- **Suggested Fix:**
  Hook into `ActiveSupport::Reloader` in `Railtie`:
  ```ruby
  class Railtie < ::Rails::Railtie
    initializer "has_public_record.reloader" do
      ActiveSupport::Reloader.to_prepare do
        HasPublicRecord.reset_on_reload!
      end
    end
  end
  ```
  Where `reset_on_reload!` clears stale registry mappings and resets `@models_loaded = false`.

---

### 3.3 Rails Engines & Namespaced Architectures
- **Prefix Isolation:**
  Engines often define models within namespaces (e.g., `Spree::Order`, `Forem::Post`). `has_public_record` handles namespaced class strings well (`"Spree::Order"` in `Registry`).
- **Engine Migrations & Generators:**
  Engine migrations usually reside in `db/migrate` or `spec/dummy/db/migrate`.
  `ActiveRecord::Generators::Base` supports engine paths when invoked from within an engine.
- **Multi-Database & Sharding Warning:**
  In `Maintenance.models`:
  ```ruby
  found = found.uniq { |model| [model.table_name, model.public_id_column] }.sort_by(&:to_s)
  ```
  In a multi-database Rails application (Rails 6.1+ `connects_to`), two different base models in different databases can have the same table name (`users` in Primary DB, `users` in Shard DB). Deduplicating purely on `[model.table_name, model.public_id_column]` will drop models from secondary databases!
  Since `model == model.base_class` already filters out STI subclasses, `uniq { |model| [model.table_name, model.public_id_column] }` is unnecessary and harmful for multi-database apps.

---

### 3.4 Rotating / Regenerating IDs (`regenerate_public_id`)
Rails' `has_secure_token` provides `regenerate_<token>`.
In `has_public_record`, `attr_readonly column` makes the ID immutable.
However, in security events (e.g., a public ID leaked in a screenshot, API key rotation, or private invite URLs), applications occasionally must rotate a public ID.
Providing an explicit method:
```ruby
def regenerate_public_id!
  new_id = self.class.generate_public_id
  public_record_row_scope.update_all(self.class.public_id_column => new_id)
  self[self.class.public_id_column] = new_id
end
```
gives developers a secure, controlled way to rotate IDs without disabling `attr_readonly`.

---

## 4. Generators & Database Migrations

### 4.1 Migration Generator: `--concurrently` on SQLite and MySQL
- **Files:** [`lib/generators/has_public_record/migration/templates/add.rb.tt`](file:///data/data/com.termux/files/home/projects/has_public_record/lib/generators/has_public_record/migration/templates/add.rb.tt#L8-L15)
- **The Issue:**
  The migration generator accepts `--concurrently`:
  ```ruby
  add_index :<%= table_name %>, :<%= public_column %>, unique: true<%= ", algorithm: :concurrently" if options[:concurrently] %>
  ```
  If a developer passes `--concurrently` in SQLite or MySQL:
  ActiveRecord raises `ArgumentError: Algorithm must be one of the following: ...` and migration execution fails immediately.
- **Suggested Fix:**
  Add a warning or conditional guard in the template:
  ```ruby
  <% if options[:concurrently] -%>
    disable_ddl_transaction! if connection.adapter_name =~ /postgresql/i

  <% end -%>
  ...
  add_index :<%= table_name %>, :<%= public_column %>, unique: true<%= ", algorithm: :concurrently" if options[:concurrently] && connection.adapter_name =~ /postgresql/i %>
  ```

---

### 4.2 Enforcing `NOT NULL` on Huge Existing Tables
- **Files:** [`lib/generators/has_public_record/migration/templates/enforce.rb.tt`](file:///data/data/com.termux/files/home/projects/has_public_record/lib/generators/has_public_record/migration/templates/enforce.rb.tt)
- **Insight:**
  `change_column_null :users, :public_id, false` acquires an `ACCESS EXCLUSIVE` table lock in PostgreSQL to verify that no rows contain NULL. On a table with 50 million rows, this can cause downtime or query timeouts.
  In modern PostgreSQL (PostgreSQL 12+), the zero-downtime standard is:
  1. `add_check_constraint :users, "public_id IS NOT NULL", validate: false`
  2. `validate_check_constraint :users, "public_id IS NOT NULL"`
  Adding a tip in the generator template or README for high-volume PostgreSQL setups would be an excellent senior developer touch.

---

### 4.3 Test Coverage Gap: Zero Generator Tests
- **Files:** [`spec/`](file:///data/data/com.termux/files/home/projects/has_public_record/spec/)
- Neither `InstallGenerator` nor `MigrationGenerator` has automated RSpec tests.
- **Suggested Fix:**
  Add generator specs using `Ammeter` or standard `Rails::Generators::TestCase` to test initializer creation and migration generation (with and without `--enforce` and `--concurrently`).

---

## 5. Maintenance & Rake Tasks

### 5.1 Top-Level Method Pollution on `Object`
- **Files:** [`lib/tasks/has_public_record.rake`](file:///data/data/com.termux/files/home/projects/has_public_record/lib/tasks/has_public_record.rake#L9-L14)
- **The Issue:**
  ```ruby
  namespace :has_public_record do
    def hpr_models
      ...
    end
  ```
  In Ruby/Rake, defining `def hpr_models` inside `namespace` defines a private method on `Object` globally across the entire host application!
- **Suggested Fix:**
  Encapsulate helper methods inside `HasPublicRecord::Maintenance` (e.g., `Maintenance.target_models(env_model)`).

---

### 5.2 Case and Pluralization in `MODEL=...` Parameter
- **Files:** [`lib/tasks/has_public_record.rake`](file:///data/data/com.termux/files/home/projects/has_public_record/lib/tasks/has_public_record.rake#L10-L13)
- If a user runs:
  `rails has_public_record:backfill MODEL=user` or `MODEL=users`
  `Maintenance.models(only: only)` performs exact equality: `model.name == only.to_s`.
  It rejects `"user"` with `"No model named user declares has_public_record."`.
- **Suggested Fix:**
  Normalize the parameter: `target_name = only.to_s.singularize.camelize`.

---

### 5.3 Abrupt Termination via `exit 1` in Rake Tasks
- **Files:** [`lib/tasks/has_public_record.rake`](file:///data/data/com.termux/files/home/projects/has_public_record/lib/tasks/has_public_record.rake#L43)
- `task :report` executes `exit 1 unless reports.all?(&:ok?)`.
- Calling `exit 1` abruptly kills the Ruby VM. If `has_public_record:report` is part of a composite Rake task or CI pipeline with cleanup hooks, `exit 1` bypasses standard Rake error handling.
- **Suggested Fix:**
  Use `abort("has_public_record:report failed with issues detected above") unless reports.all?(&:ok?)`.

---

## 6. Packaging, Gemspec & Dependencies

### 6.1 Missing `LICENSE.txt` File
- **Files:** [`has_public_record.gemspec`](file:///data/data/com.termux/files/home/projects/has_public_record/has_public_record.gemspec#L16)
- The gemspec specifies:
  `spec.files = Dir["lib/**/*", "README.md", "LICENSE.txt"]`
  `spec.license = "MIT"`
  However, **there is no `LICENSE.txt` file in the repository**. As a result, the packaged `.gem` file will not contain a license file, causing compliance issues for commercial users.

---

### 6.2 Missing Direct Runtime Dependency: `concurrent-ruby`
- **Files:** [`has_public_record.gemspec`](file:///data/data/com.termux/files/home/projects/has_public_record/has_public_record.gemspec#L18-L22), [`lib/has_public_record/generator.rb`](file:///data/data/com.termux/files/home/projects/has_public_record/lib/has_public_record/generator.rb#L4, #L17)
- `Generator` explicitly executes:
  ```ruby
  require "concurrent/map"
  LEARNED = Concurrent::Map.new
  ```
  `concurrent-ruby` is currently inherited transitively through ActiveSupport. Gems that directly require and instantiate `Concurrent::Map` should declare `spec.add_dependency "concurrent-ruby"` explicitly in their gemspec.

---

### 6.3 Missing Gemspec Metadata & Homepage Warning
- Running `gem build has_public_record.gemspec` outputs:
  `WARNING: no homepage specified`
- Adding `spec.homepage = "https://github.com/.../has_public_record"` and standard metadata (`source_code_uri`, `changelog_uri`) will ensure clean gem builds.

---

## 7. README.md Comprehensive Audit

### 7.1 Missing Methods in Documentation Tables
The README has two reference tables ("On the model" and "On the module"), but several public methods are missing:

| Missing Method | Target | Current Status in README |
|---|---|---|
| `with_generated_public_ids(rows)` | Model | Only shown in a code snippet under Testing, omitted from the table |
| `fixture_public_id(label)` | Model | Shown in a snippet under Testing, omitted from the table |
| `from_param(param)` / `from_param!` | Model | Described in Lookup Helpers, omitted from the table |
| `public_id_format` | Model | Described in Lookup Helpers, omitted from the table |
| `normalize_public_id(ref)` | Model | Omitted completely |
| `resolve_many(*refs)` | Module | Described in Lookup Helpers, omitted from the table |
| `identifier(prefix, ...)` | Module | Described in Standalone, omitted from the table |
| `fixture_id(prefix, label)` | Module | Omitted from the table |
| `canonicalize(ref, prefix)` | Module | Omitted completely |
| `fold_case(text)` | Module | Omitted completely |

Updating the tables to be exhaustive will make the README an authoritative reference.

---

### 7.2 Misleading Standalone Identifier Example
- **Files:** [`README.md`](file:///data/data/com.termux/files/home/projects/has_public_record/README.md#L143-L153)
- The README states:
  ```ruby
  invoices = HasPublicRecord.identifier("inv", length: 8) { |id| !Invoice.exists?(number: id) }
  ```
  And then warns: *"A prefix a model already declared is refused."*
  Because the example uses `Invoice.exists?(number: id)`, readers may naturally assume `Invoice` is an ActiveRecord model using `has_public_record prefix: "inv"`. If someone tries this on an existing model, it raises `DuplicatePrefixError`!
  Using non-model examples like `api_keys = HasPublicRecord.identifier("key", ...) { ... }` or `coupons = HasPublicRecord.identifier("cpn", ...) { ... }` would eliminate confusion.

---

### 7.3 Clarify Prefix Rules (Lowercase Constraint)
- **Files:** [`README.md`](file:///data/data/com.termux/files/home/projects/has_public_record/README.md#L26)
- The README notes:
  `prefix: "usr" # required, unique across the app: a-z and 0-9, starts with a letter, max 10`
  It should explicitly say: *"starts with a **lowercase** letter, lowercase alphanumeric only, 1–10 characters"*, because prefixes like `"Usr"` or `"USR"` raise `InvalidPrefixError`.

---

### 7.4 Consistency in Batch Insertion Instructions
- **Files:** [`README.md`](file:///data/data/com.termux/files/home/projects/has_public_record/README.md#L64-L65, #L165)
- Line 64 states:
  *"`insert_all` and `upsert_all` skip callbacks, so rows inserted that way get no id; fill them with `backfill_public_ids!`."*
  This implies the only way to handle bulk inserts is a retrospective backfill.
  However, line 165 shows the proactive solution:
  `User.insert_all(User.with_generated_public_ids(rows))`
  Line 64 should directly cross-reference `with_generated_public_ids` as the primary approach for bulk inserts.

---

### 7.5 Code Block Syntax
- Migration instructions use `~~~zsh`. Markdown highlighters and GitHub renderers standardize on ````bash or ````sh.

---

## 8. Prioritized Recommendations & Action Plan

| Priority | Category | Task | Impact |
|:---:|---|---|---|
| **P0** | Bug Fix | Fix `validate_public_record_format` to enforce alphabet characters and handle case normalization | Fixes invalid characters being accepted and lowercase valid inputs being rejected |
| **P0** | Bug Fix | Align `missing_public_id` with `Maintenance.report` to check `[nil, ""]` | Prevents infinite reporting errors on empty string rows |
| **P0** | Compliance | Create `LICENSE.txt` (MIT) in project root and add `concurrent-ruby` to gemspec dependencies | Prevents broken gem packages and missing license compliance |
| **P1** | Performance | Optimize `with_generated_public_ids` from N queries to 1 query | 100x–500x speedup for bulk imports (`insert_all`) |
| **P1** | Performance | Batch `backfill_public_ids!` in transactions | Prevents transaction/commit bottlenecks on large table migrations |
| **P1** | Reliability | Cap generator length growth to `starting_length + limit` | Prevents runaway ID length inflation during outages |
| **P1** | Rails Native | Add `PublicIdType` custom ActiveRecord Type | Enables seamless `where(public_id: ...)` and assignment casting |
| **P2** | Dev Experience | Add `ActiveSupport::Reloader` hook in `Railtie` to reset registry on code reload | Eliminates `DuplicatePrefixError` during development reloads |
| **P2** | Multi-DB | Fix `Maintenance.models` deduplication to support multi-database setups | Prevents dropping models in sharded / multi-db apps |
| **P2** | Documentation | Update README reference tables and clarify identifier examples | Complete, unambiguous developer reference |
| **P2** | Test Suite | Add specs for generators, rake tasks, and CPK | Ensures regression safety across Rails versions |

---
*Report prepared for discussion prior to code implementation.*
