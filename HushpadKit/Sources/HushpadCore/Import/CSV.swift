import Foundation

/// RFC 4180 CSV: quoted fields, escaped quotes (""), commas and newlines inside quotes, CRLF, UTF-8 BOM.
public enum CSV {
    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = iterator.next()
        if pending == "\u{FEFF}" { pending = iterator.next() }

        func endField() { row.append(field); field = "" }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while let scalar = pending {
            pending = iterator.next()
            if inQuotes {
                if scalar == "\"" {
                    if pending == "\"" {
                        field.unicodeScalars.append("\"")
                        pending = iterator.next()
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.unicodeScalars.append(scalar)
                }
                continue
            }
            switch scalar {
            case "\"" where field.isEmpty: inQuotes = true
            case ",": endField()
            case "\r":
                if pending == "\n" { pending = iterator.next() }
                endRow()
            case "\n": endRow()
            default: field.unicodeScalars.append(scalar)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    /// Rows as dictionaries keyed by lower-cased header names.
    public static func records(_ text: String) -> [[String: String]] {
        let rows = parse(text)
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) else { return [] }
        return rows.dropFirst().map { row in
            var record: [String: String] = [:]
            for (index, key) in header.enumerated() where index < row.count { record[key] = row[index] }
            return record
        }
    }
}
