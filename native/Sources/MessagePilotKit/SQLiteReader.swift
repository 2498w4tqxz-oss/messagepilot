import Foundation
import SQLite3

public struct KitError: Error, CustomStringConvertible, Equatable {
  public let description: String
  public init(_ description: String) { self.description = description }
}

/// Read-only SQLite access with bound parameters only. Used for Messages' chat.db and the
/// Accounts store. Opening never creates or migrates a database.
public final class SQLiteReader {
  public let path: String
  private var db: OpaquePointer?

  public init(path: String) throws {
    self.path = path
    guard FileManager.default.fileExists(atPath: path) else {
      throw KitError("Database not found: \(URL(fileURLWithPath: path).lastPathComponent)")
    }
    guard
      sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
    else {
      sqlite3_close(db)
      db = nil
      throw KitError(
        "Cannot open \(URL(fileURLWithPath: path).lastPathComponent) read-only; Full Disk Access may be required"
      )
    }
    sqlite3_busy_timeout(db, 2000)
  }
  deinit { sqlite3_close(db) }

  public enum Value: Equatable {
    case int(Int64), double(Double), text(String), blob(Data), null
  }

  public func rows(_ sql: String, _ args: [Any?] = []) throws -> [[String: Value]] {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      throw KitError("Query unavailable on this schema: \(String(cString: sqlite3_errmsg(db)))")
    }
    defer { sqlite3_finalize(stmt) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (i, arg) in args.enumerated() {
      let index = Int32(i + 1)
      switch arg {
      case let v as String: sqlite3_bind_text(stmt, index, v, -1, transient)
      case let v as Int: sqlite3_bind_int64(stmt, index, Int64(v))
      case let v as Int64: sqlite3_bind_int64(stmt, index, v)
      case let v as Double: sqlite3_bind_double(stmt, index, v)
      case let v as Data:
        _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(v.count), transient) }
      default: sqlite3_bind_null(stmt, index)
      }
    }
    var out: [[String: Value]] = []
    var status = sqlite3_step(stmt)
    while status == SQLITE_ROW {
      var row: [String: Value] = [:]
      for i in 0..<sqlite3_column_count(stmt) {
        let key = String(cString: sqlite3_column_name(stmt, i))
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_INTEGER: row[key] = .int(sqlite3_column_int64(stmt, i))
        case SQLITE_FLOAT: row[key] = .double(sqlite3_column_double(stmt, i))
        case SQLITE_TEXT: row[key] = .text(String(cString: sqlite3_column_text(stmt, i)))
        case SQLITE_BLOB:
          if let bytes = sqlite3_column_blob(stmt, i) {
            row[key] = .blob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, i))))
          } else {
            row[key] = .blob(Data())
          }
        default: row[key] = .null
        }
      }
      out.append(row)
      status = sqlite3_step(stmt)
    }
    guard status == SQLITE_DONE else {
      throw KitError("Read failed: \(String(cString: sqlite3_errmsg(db)))")
    }
    return out
  }

  /// Column names of a table, used to stay compatible across macOS schema revisions.
  public func columns(_ table: String) throws -> Set<String> {
    guard table.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
      throw KitError("Invalid table name")
    }
    return Set(try rows("PRAGMA table_info(\(table))").compactMap { $0["name"]?.string })
  }
}

extension SQLiteReader.Value {
  public var string: String? { if case .text(let s) = self { return s } else { return nil } }
  public var int: Int64? {
    switch self {
    case .int(let v): return v
    case .double(let v): return Int64(v)
    case .text(let s): return Int64(s)
    default: return nil
    }
  }
  public var data: Data? { if case .blob(let d) = self { return d } else { return nil } }
  /// JSON-safe representation (blobs are omitted by callers; this encodes them as base64).
  public var json: Any {
    switch self {
    case .int(let v): return v
    case .double(let v): return v
    case .text(let s): return s
    case .blob(let d): return d.base64EncodedString()
    case .null: return NSNull()
    }
  }
}
