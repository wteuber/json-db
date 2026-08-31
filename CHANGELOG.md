# Changelog

All notable changes to this project are documented in this file. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-08-31

### Added

- `JsonDb::Base`, built on `ActiveModel::Model`, `Attributes`, `Dirty`,
  `Validations` and `Callbacks`, with one JSON document per record at
  `storage_root/collection/id.json`.
- `JsonDb::Storage::AtomicWriter`: temp-file + `fsync` + `rename` writes, so a
  crash mid-write can never corrupt an existing document.
- `JsonDb::Storage::FileAdapter`: path resolution, id validation against
  directory traversal, configurable JSON indentation, and `flock`-protected
  sequence allocation.
- `JsonDb::Query::Relation`: lazy, chainable, `Enumerable` queries with
  `where` / `order` / `limit` / `offset` / `none` / `pluck` / `count` / `first` /
  `last`, supporting scalar, `Array`, `Range`, `Regexp` and `Proc` conditions.
- `JsonDb::Query::IndexManager`: optional `_indexes.json` secondary indexes
  declared with `index :attr`, plus `rebuild_index!`.
- Associations: `belongs_to`, `has_many` and `has_one`, with lazy class
  resolution and `dependent: :destroy | :nullify | :restrict`.
- Primary key generators: `:hex`, `:uuid`, `:sequence`, or any callable.
- RBS type signatures for the public interface in `sig/json_db.rbs`.

[0.1.0]: https://github.com/wteuber/json-db/releases/tag/v0.1.0
