// Portions adapted from Cowlick (MIT).
// Copyright (c) 2026 Cowlick contributors.

import Foundation

struct JSONRPCResponseCursor {
    private var lineStart = 0
    private var searchOffset = 0

    mutating func containsResponse(id: Int, in data: Data) -> Bool {
        if data.count < searchOffset {
            lineStart = 0
            searchOffset = 0
        }

        while searchOffset < data.endIndex {
            guard data[searchOffset] == 0x0A else {
                searchOffset += 1
                continue
            }
            let line = data[lineStart..<searchOffset]
            searchOffset += 1
            lineStart = searchOffset
            guard line.first(where: { !Self.isWhitespace($0) }) == 0x7B,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let dictionary = object as? [String: Any]
            else { continue }
            if dictionary["id"] as? Int == id { return true }
        }
        return false
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0D
    }
}
