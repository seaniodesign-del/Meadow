import CoreGraphics

/// Buckets items into fixed-size cells for O(1) radius queries.
struct SpatialGrid<T> {
    private var cells: [CellKey: [T]]
    private let cellSize: Float
    private let positionOf: (T) -> CGPoint

    init(items: [T], cellSize: Float, positionOf: @escaping (T) -> CGPoint) {
        self.cellSize = cellSize
        self.positionOf = positionOf
        var cells = [CellKey: [T]]()
        for item in items {
            let key = CellKey(point: positionOf(item), cellSize: cellSize)
            cells[key, default: []].append(item)
        }
        self.cells = cells
    }

    /// Returns all items whose position falls within `radius` of `point`.
    func items(near point: CGPoint, radius: Float) -> [T] {
        let minCell = CellKey(x: Int(floor((Float(point.x) - radius) / cellSize)),
                              y: Int(floor((Float(point.y) - radius) / cellSize)))
        let maxCell = CellKey(x: Int(floor((Float(point.x) + radius) / cellSize)),
                              y: Int(floor((Float(point.y) + radius) / cellSize)))

        var result = [T]()
        let r2 = radius * radius
        for cx in minCell.x...maxCell.x {
            for cy in minCell.y...maxCell.y {
                let key = CellKey(x: cx, y: cy)
                guard let bucket = cells[key] else { continue }
                for item in bucket {
                    let p = positionOf(item)
                    let dx = Float(p.x) - Float(point.x)
                    let dy = Float(p.y) - Float(point.y)
                    if dx * dx + dy * dy <= r2 {
                        result.append(item)
                    }
                }
            }
        }
        return result
    }

    private struct CellKey: Hashable {
        let x: Int
        let y: Int
        init(x: Int, y: Int) { self.x = x; self.y = y }
        init(point: CGPoint, cellSize: Float) {
            x = Int(floor(Float(point.x) / cellSize))
            y = Int(floor(Float(point.y) / cellSize))
        }
    }
}

// MARK: - GrassBlade convenience init
extension SpatialGrid where T == GrassBlade {
    init(items: [GrassBlade], cellSize: Float) {
        self.init(items: items, cellSize: cellSize) { blade in
            CGPoint(x: CGFloat(blade.rootPosition.x), y: CGFloat(blade.rootPosition.y))
        }
    }
}
