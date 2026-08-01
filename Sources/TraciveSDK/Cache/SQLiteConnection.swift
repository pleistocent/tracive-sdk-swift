import Foundation
import SQLite3

/// `SQLITE_TRANSIENT` tells SQLite to copy the bound bytes immediately.
///
/// It is a `#define` for `((sqlite3_destructor_type)-1)`, which does not survive the C-to-Swift
/// import, so it has to be reconstructed. Using `SQLITE_STATIC` instead would be a use-after-free
/// waiting to happen: the `Data` we bind from is a local whose buffer is gone by the time
/// `sqlite3_step` runs.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A minimal wrapper over the system `libsqlite3` C API.
///
/// Deliberately not a general-purpose SQLite library: it exposes exactly what
/// `SQLiteCheckCache` needs. Anything more would be a database layer we have to maintain, and the
/// alternative — taking a dependency — is the one thing this package will not do.
///
/// Not thread-safe by itself. `SQLiteCheckCache` owns the only instance and serialises every call
/// behind its own lock.
final class SQLiteConnection {

  /// `fileprivate` so `SQLiteStatement`, which lives in this file, can reach it. Nothing outside
  /// this file ever sees the raw C handle.
  fileprivate let handle: OpaquePointer

  /// - Parameter path: a filesystem path, or `":memory:"` for a private in-memory database.
  init(path: String) throws {
    var db: OpaquePointer?
    // FULLMUTEX so a stray call from another thread cannot corrupt the connection even though the
    // store already serialises. Belt and braces on a shared mutable C handle is cheap insurance.
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    let code = sqlite3_open_v2(path, &db, flags, nil)

    guard code == SQLITE_OK, let opened = db else {
      let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
      // sqlite3_open_v2 may hand back a handle even on failure; it still has to be closed.
      if let db { sqlite3_close_v2(db) }
      throw CheckCacheError.cannotOpenStore(path: path, code: code, message: message)
    }
    self.handle = opened
  }

  deinit {
    // `_v2` so the handle is released once any straggling statement is finalised, rather than
    // leaking on `SQLITE_BUSY`.
    sqlite3_close_v2(handle)
  }

  /// Runs one or more statements that return no rows.
  func execute(_ sql: String) throws {
    var errorPointer: UnsafeMutablePointer<CChar>?
    let code = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
    guard code == SQLITE_OK else {
      let message = errorPointer.map { String(cString: $0) } ?? lastErrorMessage
      sqlite3_free(errorPointer)
      throw CheckCacheError.storageFailure(code: code, message: message)
    }
    sqlite3_free(errorPointer)
  }

  func prepare(_ sql: String) throws -> SQLiteStatement {
    try SQLiteStatement(connection: self, sql: sql)
  }

  /// Rows changed by the most recent statement.
  var changes: Int { Int(sqlite3_changes(handle)) }

  var lastErrorMessage: String { String(cString: sqlite3_errmsg(handle)) }

  /// Runs `body` inside `BEGIN IMMEDIATE` / `COMMIT`, rolling back on any throw.
  ///
  /// `IMMEDIATE` rather than the default deferred transaction: it takes the write lock up front, so
  /// two processes sharing the file (an app and its extension) fail fast instead of deadlocking
  /// halfway through and surfacing `SQLITE_BUSY` at commit time.
  func transaction<T>(_ body: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE;")
    do {
      let value = try body()
      try execute("COMMIT;")
      return value
    } catch {
      // A failed rollback is not worth masking the original error with.
      try? execute("ROLLBACK;")
      throw error
    }
  }
}

/// One prepared statement. Finalised on deinit, so no `defer` dance at the call sites.
final class SQLiteStatement {

  private let handle: OpaquePointer

  /// A **strong** reference to the connection that prepared this statement, not just its raw
  /// pointer.
  ///
  /// A statement is only valid while its database handle is open, and holding the bare
  /// `OpaquePointer` made that an invariant the *caller* had to maintain. It happened to hold —
  /// `SQLiteCheckCache` keeps its connection alive for the whole lifetime of every statement — but
  /// nothing enforced it, and both types are visible across the module, so the first caller to
  /// outlive a statement past its connection would get a use-after-free rather than a compile
  /// error. Owning the connection makes the lifetime correct by construction.
  ///
  /// This does not defeat `sqlite3_close_v2`, which already defers the real close until every
  /// outstanding statement is finalised. It removes the window before that: with only a raw
  /// pointer, the wrapper could deinit and call `close_v2` while a statement still held a dangling
  /// copy of the handle.
  private let connection: SQLiteConnection

  private var database: OpaquePointer { connection.handle }

  fileprivate init(connection: SQLiteConnection, sql: String) throws {
    var statement: OpaquePointer?
    let code = sqlite3_prepare_v2(connection.handle, sql, -1, &statement, nil)
    guard code == SQLITE_OK, let prepared = statement else {
      let message = String(cString: sqlite3_errmsg(connection.handle))
      if let statement { sqlite3_finalize(statement) }
      throw CheckCacheError.storageFailure(code: code, message: message)
    }
    self.handle = prepared
    self.connection = connection
  }

  deinit {
    sqlite3_finalize(handle)
  }

  // MARK: - Binding
  //
  // Parameter indices are 1-based, unlike column indices below, which are 0-based. That is SQLite's
  // convention, not a mistake.

  func bind(_ index: Int32, text: String) throws {
    try check(sqlite3_bind_text(handle, index, text, -1, SQLITE_TRANSIENT))
  }

  func bind(_ index: Int32, blob: Data) throws {
    let code = blob.withUnsafeBytes { buffer -> Int32 in
      guard let base = buffer.baseAddress, buffer.count > 0 else {
        // An empty payload is never legitimate here (a sealed box is at least 28 bytes), but bind a
        // zero-length blob rather than a NULL so a NOT NULL column still rejects it loudly.
        return sqlite3_bind_zeroblob(handle, index, 0)
      }
      return sqlite3_bind_blob(handle, index, base, Int32(buffer.count), SQLITE_TRANSIENT)
    }
    try check(code)
  }

  func bind(_ index: Int32, double: Double) throws {
    try check(sqlite3_bind_double(handle, index, double))
  }

  func bind(_ index: Int32, int: Int64) throws {
    try check(sqlite3_bind_int64(handle, index, int))
  }

  // MARK: - Stepping

  /// Releases the statement's cursor without finalising it.
  ///
  /// Needed because a `SELECT` that has returned `SQLITE_ROW` and has not been stepped to
  /// completion still holds a read cursor on the table. Issuing a `DELETE` on that same table over
  /// the same connection while the cursor is open is permitted by SQLite but can return
  /// `SQLITE_LOCKED` under some configurations — and at the one call site that does it, the
  /// `DELETE` is a `try?`, so the failure would be swallowed and the row would silently survive.
  ///
  /// The return code is deliberately ignored: `sqlite3_reset` re-reports the error from the most
  /// recent `step`, which the caller has already seen and handled. It is not a new failure.
  func reset() {
    sqlite3_reset(handle)
  }

  /// Advances the statement.
  ///
  /// - Returns: `true` when a row is available, `false` when the statement is done.
  @discardableResult
  func step() throws -> Bool {
    let code = sqlite3_step(handle)
    switch code {
    case SQLITE_ROW: return true
    case SQLITE_DONE: return false
    default:
      throw CheckCacheError.storageFailure(code: code, message: String(cString: sqlite3_errmsg(database)))
    }
  }

  // MARK: - Reading (0-based columns)

  func text(_ column: Int32) -> String? {
    guard let pointer = sqlite3_column_text(handle, column) else { return nil }
    return String(cString: pointer)
  }

  func blob(_ column: Int32) -> Data {
    let count = Int(sqlite3_column_bytes(handle, column))
    guard count > 0, let pointer = sqlite3_column_blob(handle, column) else { return Data() }
    return Data(bytes: pointer, count: count)
  }

  func double(_ column: Int32) -> Double {
    sqlite3_column_double(handle, column)
  }

  func int(_ column: Int32) -> Int64 {
    sqlite3_column_int64(handle, column)
  }

  private func check(_ code: Int32) throws {
    guard code == SQLITE_OK else {
      throw CheckCacheError.storageFailure(code: code, message: String(cString: sqlite3_errmsg(database)))
    }
  }
}
