import Foundation

public enum BudgetInput {
    public static func parseHours(_ text: String, locale: Locale = .current) -> Int64? {
        let separator = locale.decimalSeparator ?? "."
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: separator)
        guard (1...2).contains(parts.count), !parts.last!.isEmpty,
              parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        let digits = parts.joined()
        guard !digits.isEmpty else { return nil }
        // Multiply digit-by-digit: Decimal parsing can silently round a long input.
        var carry = 0
        var product: [UInt8] = []
        for digit in digits.utf8.reversed() {
            let value = Int(digit - 48) * 3600 + carry
            product.append(UInt8(value % 10))
            carry = value / 10
        }
        while carry > 0 { product.append(UInt8(carry % 10)); carry /= 10 }
        let scale = parts.count == 2 ? parts[1].utf8.count : 0
        guard product.prefix(scale).allSatisfy({ $0 == 0 }) else { return nil }
        let whole = product.dropFirst(scale).reversed().map { Character(String($0)) }
        guard let seconds = Int64(String(whole)), seconds > 0 else { return nil }
        return seconds
    }

    public static func text(_ seconds: Int64, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 9
        return formatter.string(from: NSDecimalNumber(decimal: Decimal(seconds) / 3600))!
    }
}

public struct BudgetAllocation: Equatable, Sendable {
    public let taskID: UUID
    public let limitSeconds: Int64
    public let allocatedSeconds: Decimal
}

public struct BudgetAllowance: Equatable, Sendable {
    public let limitingAncestorID: UUID?
    public let maximumSeconds: Decimal?
    public let minimumSeconds: Decimal
}

public struct BudgetWarning: Equatable, Sendable {
    public let taskID: UUID
    public let threshold: WarningThreshold
}

public struct BudgetWarningBatch: Identifiable, Sendable {
    public let id: UUID
    public let warnings: [BudgetWarning]
}

public enum BudgetRules {
    private struct Tree {
        let tasks: [UUID: TaskRecord]
        let bottomUp: [UUID]
        let frontier: [UUID: Decimal]

        init(_ snapshot: LibrarySnapshot) throws {
            let errors = SnapshotValidator.violations(in: snapshot, now: nil, includingBudgets: false)
            guard errors.isEmpty else { throw LibraryError.invalid(errors) }
            tasks = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0) })
            let children = Dictionary(grouping: snapshot.tasks.compactMap { task in
                task.parentTaskID.map { (parent: $0, child: task.id) }
            }, by: \.parent)
            var remaining = children.mapValues(\.count)
            var order = snapshot.tasks.filter { children[$0.id] == nil }.map(\.id)
            var sums: [UUID: Decimal] = [:]
            var index = 0
            while index < order.count {
                let id = order[index]
                index += 1
                let task = tasks[id]!
                if let parent = task.parentTaskID {
                    sums[parent, default: 0] += task.budgetSeconds.map { Decimal($0) } ?? sums[id, default: 0]
                    remaining[parent, default: 0] -= 1
                    if remaining[parent] == 0 { order.append(parent) }
                }
            }
            bottomUp = order
            frontier = sums
        }
    }

    public static func allocations(in snapshot: LibrarySnapshot) throws -> [BudgetAllocation] {
        let tree = try Tree(snapshot)
        return snapshot.tasks.sorted { $0.id.uuidString < $1.id.uuidString }.compactMap { task in
            task.budgetSeconds.map {
                BudgetAllocation(taskID: task.id, limitSeconds: $0,
                                 allocatedSeconds: tree.frontier[task.id, default: 0])
            }
        }
    }

    public static func allowance(in snapshot: LibrarySnapshot, projectID: UUID,
                                 parentTaskID: UUID?, editingTaskID: UUID?) throws -> BudgetAllowance {
        let tree = try Tree(snapshot)
        guard snapshot.projects.contains(where: { $0.id == projectID }),
              parentTaskID == nil || tree.tasks[parentTaskID!]?.projectID == projectID else {
            throw LibraryError.invalid([Violation(.hierarchy, editingTaskID)])
        }
        let edited = editingTaskID.flatMap { tree.tasks[$0] }
        if let editingTaskID {
            guard let edited, edited.projectID == projectID, edited.parentTaskID == parentTaskID else {
                throw LibraryError.invalid([Violation(.hierarchy, editingTaskID)])
            }
        }
        let minimum = editingTaskID.map { tree.frontier[$0, default: 0] } ?? 0
        let oldContribution = edited?.budgetSeconds.map { Decimal($0) } ?? minimum
        var cursor = parentTaskID
        while let id = cursor, let ancestor = tree.tasks[id] {
            if let limit = ancestor.budgetSeconds {
                return BudgetAllowance(limitingAncestorID: id,
                    maximumSeconds: Decimal(limit) - tree.frontier[id, default: 0] + oldContribution,
                    minimumSeconds: minimum)
            }
            cursor = ancestor.parentTaskID
        }
        return BudgetAllowance(limitingAncestorID: nil, maximumSeconds: nil, minimumSeconds: minimum)
    }

    public static func usage(in snapshot: LibrarySnapshot, liveEnd: Int64? = nil) throws -> [UUID: Decimal] {
        let tree = try Tree(snapshot)
        var totals = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, Decimal.zero) })
        for entry in snapshot.entries {
            let end: Int64
            if let closedEnd = entry.endAt { end = closedEnd }
            else {
                guard let active = snapshot.activeTimer, active.entryID == entry.id else {
                    throw LibraryError.invalid([Violation(.timer, entry.id)])
                }
                end = liveEnd ?? active.checkpointAt
                guard end >= active.checkpointAt else {
                    throw LibraryError.invalid([Violation(.timer, entry.id)])
                }
            }
            if end == entry.startAt && entry.endAt == nil { continue }
            guard let interval = try? EntryInterval(startAt: entry.startAt, endAt: end) else {
                throw LibraryError.invalid([Violation(.interval, entry.id)])
            }
            totals[entry.taskID, default: 0] += Decimal(interval.durationSeconds)
        }
        for id in tree.bottomUp {
            if let parent = tree.tasks[id]?.parentTaskID {
                totals[parent, default: 0] += totals[id, default: 0]
            }
        }
        return totals
    }

    public static func band(used: Decimal, budget: Int64?) -> WarningThreshold {
        guard let budget, budget > 0 else { return .none }
        if used >= Decimal(budget) { return .hundred }
        let eighty = (budget / 5) * 4 + ((budget % 5) * 4 + 4) / 5
        return used >= Decimal(eighty) ? .eighty : .none
    }
}
