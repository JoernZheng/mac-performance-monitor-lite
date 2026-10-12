// SPDX-License-Identifier: MIT
import Foundation

/// A small LRU cache. An entry wrapper also preserves cached optional nil values.
struct BoundedCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var access: UInt64
    }

    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    let capacity: Int
    var count: Int { entries.count }

    init(capacity: Int = 1024) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    mutating func value(forKey key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        clock &+= 1
        entries[key]?.access = clock
        return entry.value
    }

    mutating func insert(_ value: Value, forKey key: Key) {
        if entries[key] == nil, entries.count == capacity,
            let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key
        {
            entries.removeValue(forKey: oldest)
        }
        clock &+= 1
        entries[key] = Entry(value: value, access: clock)
    }

    mutating func removeAll() {
        entries.removeAll()
        clock = 0
    }
}
