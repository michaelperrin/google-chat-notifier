import Foundation

/// Exécute `transform` sur chaque élément avec un parallélisme borné, en préservant l'ordre.
/// Utilisé pour les appels « un par conversation » (état de lecture, messages) sans saturer
/// l'API Chat ni la machine.
func mapConcurrently<Element: Sendable, Output: Sendable>(
    _ elements: [Element],
    limit: Int,
    _ transform: @escaping @Sendable (Element) async -> Output
) async -> [Output] {
    guard !elements.isEmpty else { return [] }
    let bound = max(1, min(limit, elements.count))
    var results = [Output?](repeating: nil, count: elements.count)

    await withTaskGroup(of: (Int, Output).self) { group in
        var next = 0
        while next < bound {
            let index = next
            group.addTask { (index, await transform(elements[index])) }
            next += 1
        }
        for await (index, output) in group {
            results[index] = output
            if next < elements.count {
                let index = next
                group.addTask { (index, await transform(elements[index])) }
                next += 1
            }
        }
    }
    return results.compactMap { $0 }
}
