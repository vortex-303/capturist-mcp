import Foundation
import Testing
@testable import CapturistStore

@Suite("SQLite database")
struct SQLiteDatabaseTests {
    @Test("executes statements, binds values, and reads rows")
    func basicRoundTrip() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
            .path
        let database = try SQLiteDatabase(path: path)

        try database.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, size REAL, payload BLOB)")
        try database.execute(
            "INSERT INTO items (name, size, payload) VALUES (?, ?, ?)",
            [.text("hello"), .real(1.5), .blob(Data([9, 8, 7]))]
        )

        let rows = try database.query("SELECT * FROM items WHERE name = ?", [.text("hello")])
        #expect(rows.count == 1)
        #expect(rows[0].string("name") == "hello")
        #expect(rows[0].double("size") == 1.5)
        #expect(rows[0].data("payload") == Data([9, 8, 7]))

        #expect(try database.userVersion == 0)
        try database.setUserVersion(3)
        #expect(try database.userVersion == 3)
    }
}
