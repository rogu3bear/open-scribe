import AppKit
import CoreGraphics

/// One active display in global Core Graphics points (top-left origin, so a
/// display above the main one has a negative y).
struct ContextDisplay: Equatable, Sendable {
  let id: CGDirectDisplayID
  let name: String
  let frame: CGRect
  let scale: Double
  let rotation: Double
  let isMain: Bool
}

/// Actual display topology and the names every scope uses (ADR 0011,
/// Selection and topology). Color and position alone never identify a display.
enum ContextTopology {
  /// Reads the active displays, their bounds, scale, and rotation.
  @MainActor
  static func current() -> [ContextDisplay] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
    let screens = Dictionary(
      NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, NSScreen)? in
        guard
          let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber
        else { return nil }
        return (CGDirectDisplayID(number.uint32Value), screen)
      }, uniquingKeysWith: { first, _ in first })
    return ids.prefix(Int(count)).map { id in
      let screen = screens[id]
      return ContextDisplay(
        id: id,
        name: screen?.localizedName ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display"),
        frame: CGDisplayBounds(id),
        scale: Double(screen?.backingScaleFactor ?? 1),
        rotation: CGDisplayRotation(id),
        isMain: CGDisplayIsMain(id) != 0)
    }
  }

  /// Names made unique in a stable left-to-right, top-to-bottom order, so two
  /// identical monitors read as "DELL U2720Q" and "DELL U2720Q (2)".
  static func uniqueNames(_ displays: [ContextDisplay]) -> [CGDirectDisplayID: String] {
    let ordered = displays.sorted {
      ($0.frame.minX, $0.frame.minY, $0.id) < ($1.frame.minX, $1.frame.minY, $1.id)
    }
    var seen: [String: Int] = [:]
    var names: [CGDirectDisplayID: String] = [:]
    for display in ordered {
      let count = (seen[display.name] ?? 0) + 1
      seen[display.name] = count
      names[display.id] = count == 1 ? display.name : "\(display.name) (\(count))"
    }
    return names
  }

  /// "Built-in Display, left of Studio Display": the display's name and its
  /// relation to the nearest other display.
  static func describe(_ display: ContextDisplay, in displays: [ContextDisplay]) -> String {
    let names = uniqueNames(displays)
    let name = names[display.id] ?? display.name
    let others = displays.filter { $0.id != display.id }
    func distance(_ other: ContextDisplay) -> CGFloat {
      hypot(other.frame.midX - display.frame.midX, other.frame.midY - display.frame.midY)
    }
    guard let nearest = others.min(by: { (distance($0), $0.id) < (distance($1), $1.id) }) else {
      return name
    }
    let other = names[nearest.id] ?? nearest.name
    let tolerance: CGFloat = 1
    let relation: String
    if display.frame.maxX <= nearest.frame.minX + tolerance {
      relation = "left of"
    } else if display.frame.minX >= nearest.frame.maxX - tolerance {
      relation = "right of"
    } else if display.frame.maxY <= nearest.frame.minY + tolerance {
      relation = "above"
    } else if display.frame.minY >= nearest.frame.maxY - tolerance {
      relation = "below"
    } else {
      relation = "overlapping"
    }
    return "\(name), \(relation) \(other)"
  }

  static func native(_ displays: [ContextDisplay]) -> [NativeDisplayTopology] {
    let names = uniqueNames(displays)
    return displays.map { display in
      NativeDisplayTopology(
        displayId: String(display.id), name: names[display.id] ?? display.name,
        x: display.frame.minX, y: display.frame.minY,
        width: display.frame.width, height: display.frame.height,
        scale: display.scale, rotation: display.rotation, isMain: display.isMain)
    }
  }

  /// Changes whenever a display is added, removed, moved, resized, rescaled,
  /// or rotated; a scope authorized under another signature must pause.
  static func signature(_ displays: [ContextDisplay]) -> String {
    displays.sorted { $0.id < $1.id }.map { display in
      "\(display.id):\(display.frame.minX),\(display.frame.minY),\(display.frame.width),"
        + "\(display.frame.height)@\(display.scale)r\(display.rotation)"
    }.joined(separator: ";")
  }
}
