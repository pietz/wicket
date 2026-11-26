import AppKit
import SwiftUI

private struct RGB: Equatable {
  var r, g, b: Double
  static let white = RGB(r: 255, g: 255, b: 255)
  static let black = RGB(r: 0, g: 0, b: 0)
  func blend(_ o: RGB, _ t: Double) -> RGB {
    RGB(r: (r + (o.r - r) * t).rounded(), g: (g + (o.g - g) * t).rounded(), b: (b + (o.b - b) * t).rounded())
  }
  var luminance: Double {
    func lin(_ c: Double) -> Double {
      let c = c / 255
      return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
  }
  func cg(_ alpha: Double) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: alpha)
  }

  /// The system accent colour as macOS draws it in that appearance.
  @MainActor static func accent(dark: Bool) -> RGB {
    var rgb = RGB(r: 0, g: 122, b: 255)
    NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
      if let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) {
        rgb = RGB(r: c.redComponent * 255, g: c.greenComponent * 255, b: c.blueComponent * 255)
      }
    }
    return rgb
  }
}

/// Body is the coloured light, core its hot centre, halo the tint it throws on the glass.
private struct Palette {
  var body, halo, core: RGB
  init(_ acc: RGB, dark: Bool) {
    var body = acc
    if dark {
      // Added light needs luminance: dim accents are brightened at full saturation, then lifted to white.
      if body.luminance < 0.3 {
        let m = min(1.55, 255 / max(acc.r, acc.g, acc.b, 1))
        body = RGB(r: (body.r * m).rounded(), g: (body.g * m).rounded(), b: (body.b * m).rounded())
      }
      var i = 0
      while i < 8 && body.luminance < 0.2 {
        body = body.blend(.white, 0.07)
        i += 1
      }
      self.body = body
      halo = body
      core = body.blend(.white, 0.82)
      return
    }
    // Light glass cannot be out-shone: pale accents are deepened until the colour carries the contrast.
    let grey = max(acc.r, acc.g, acc.b) - min(acc.r, acc.g, acc.b) < 26
    let cap = grey ? 0.22 : 0.42
    var i = 0
    while i < 24 && body.luminance > cap {
      body = body.blend(.black, 0.05)
      i += 1
    }
    self.body = body
    halo = acc.blend(body, 0.6)
    core = body.blend(.white, 0.9)
  }
}

private struct Sprites {
  let line, hot, soft, glow, halo, bloom: Image

  init(_ p: Palette, dark: Bool) {
    line = Self.sprite([(0, p.body, 1), (0.45, p.body, 0.7), (1, p.body, 0)])
    // The hot centre falls away from its very middle: no plateau, so no disc and no edge.
    hot = Self.sprite([
      (0, p.core, 1), (0.22, p.core, 0.7), (0.5, p.core, 0.3), (0.78, p.core, 0.08), (1, p.core, 0),
    ])
    soft = Self.sprite([
      (0, p.body, 1), (0.25, p.body, 0.66), (0.55, p.body, 0.24), (0.8, p.body, 0.06), (1, p.body, 0),
    ])
    glow = Self.sprite([(0, p.halo, 0.6), (0.35, p.halo, 0.3), (0.7, p.halo, 0.08), (1, p.halo, 0)])
    halo = Self.sprite([(0, p.halo, dark ? 0.5 : 0.58), (0.4, p.halo, dark ? 0.15 : 0.2), (1, p.halo, 0)])
    bloom = Self.sprite([(0, p.halo, dark ? 0.4 : 0.36), (0.5, p.halo, 0.11), (1, p.halo, 0)])
  }

  private static func sprite(_ stops: [(Double, RGB, Double)]) -> Image {
    let px = 96
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
      data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let gradient = CGGradient(
      colorsSpace: space, colors: stops.map { $0.1.cg($0.2) } as CFArray,
      locations: stops.map { CGFloat($0.0) })!
    let c = CGPoint(x: px / 2, y: px / 2)
    ctx.drawRadialGradient(
      gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(px / 2), options: [])
    return Image(decorative: ctx.makeImage()!, scale: 1)
  }

  @MainActor private static var cache: [Bool: (accent: RGB, light: Sprites, grey: Sprites)] = [:]
  /// The accent light and the grey it drains to when cancelled.
  @MainActor static func pair(dark: Bool) -> (Sprites, Sprites) {
    let acc = RGB.accent(dark: dark)
    if let hit = cache[dark], hit.accent == acc { return (hit.light, hit.grey) }
    let grey = dark ? RGB(r: 150, g: 150, b: 158) : RGB(r: 140, g: 140, b: 148)
    let made = (Sprites(Palette(acc, dark: dark), dark: dark), Sprites(Palette(grey, dark: dark), dark: dark))
    cache[dark] = (acc, made.0, made.1)
    return made
  }
}

/// The sweep lab's divider light. The Canvas adds light internally in dark mode, then composites
/// normally over the glass.
struct AgentSweepLight: View {
  let timing: AgentTurnTiming
  let dividerY: CGFloat
  let visible: Bool
  /// A fixed moment for offscreen renders.
  let frozen: Date?
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var finishedEnding: AgentTurnTiming.Ending?

  var body: some View {
    let dark = scheme == .dark
    let ended = timing.ending.map { $0 == finishedEnding || $0.deadline <= Date() } ?? false
    let (light, grey) = Sprites.pair(dark: dark)
    Group {
      if let frozen {
        canvas(frozen, dark: dark, light: light, grey: grey)
      } else {
        TimelineView(.animation(paused: !visible || ended)) { timeline in
          if !ended { canvas(timeline.date, dark: dark, light: light, grey: grey) }
        }
      }
    }
    .opacity(visible ? 0.7 : 0)
    .animation(.easeInOut(duration: 0.15), value: visible)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
    .task(id: timing.ending) {
      guard frozen == nil, let ending = timing.ending else { return }
      let remaining = ending.deadline.timeIntervalSinceNow
      if visible, remaining > 0 {
        do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
      }
      finishedEnding = ending
    }
  }

  private func canvas(_ now: Date, dark: Bool, light: Sprites, grey: Sprites) -> some View {
    Canvas { context, size in
      let clock = Clock(timing, now: now, reduce: reduceMotion)
      let painter = Painter(dark: dark, clock: clock, width: size.width, y: dividerY)
      var context = context
      context.blendMode = dark ? .plusLighter : .normal
      if clock.grey < 1 { painter.paint(context, light, clock.base * (1 - clock.grey)) }
      if clock.grey > 0 { painter.paint(context, grey, clock.base * clock.grey) }
    }
  }
}

extension AgentTurnTiming.Ending {
  fileprivate var date: Date {
    switch self {
    case .done(let date), .cancelled(let date): date
    }
  }

  fileprivate var duration: Double {
    switch self {
    case .done: 0.5
    case .cancelled: 0.16 + 0.4
    }
  }

  fileprivate var deadline: Date { date.addingTimeInterval(duration) }
}

/// The light's state at one moment, computed from the turn's clock.
private struct Clock {
  let elapsed: Double
  let cancelAt: Double?
  let base, grey, bloom: Double
  let reduce: Bool
  // One pass per real second, with the lab's motion clock for the tail.
  static let speed = 1.7
  static let phase = -Double.pi / 2 + 0.36

  init(_ timing: AgentTurnTiming, now: Date, reduce: Bool) {
    elapsed = max(0, now.timeIntervalSince(timing.start))
    self.reduce = reduce
    let fadeIn = 1 - exp(-elapsed / 0.15)
    let dim = timing.streamingAt.map { 1 - 0.24 * (1 - exp(-max(0, now.timeIntervalSince($0)) / 0.45)) } ?? 1
    let fade: Double
    if let ending = timing.ending, case .cancelled = ending {
      cancelAt = ending.date.timeIntervalSince(timing.start)
      let age = now.timeIntervalSince(ending.date)
      grey = Self.smooth(age / 0.16)
      fade = 1 - Self.smooth((age - 0.16) / (ending.duration - 0.16))
    } else {
      cancelAt = nil
      grey = 0
      fade = timing.ending.map { 1 - Self.smooth(now.timeIntervalSince($0.date) / $0.duration) } ?? 1
    }
    let breath = reduce ? 0.62 + 0.38 * sin(elapsed * 2 * Double.pi / 3.2) : 1
    base = fadeIn * dim * fade * breath
    bloom = 1 - (1 - dim) * 2.2
  }

  func angle(at elapsed: Double) -> Double {
    var travelled = max(0, elapsed)
    if let cancelAt, elapsed > cancelAt {
      travelled = cancelAt + 0.075 * (1 - exp(-(elapsed - cancelAt) / 0.075))
    }
    return Self.phase + Double.pi * travelled
  }

  var lag: Double {
    let brake = cancelAt.map { exp(-max(0, elapsed - $0) / 0.075) } ?? 1
    return cos(angle(at: elapsed)) * brake
  }

  private static func smooth(_ value: Double) -> Double {
    let t = min(1, max(0, value))
    return t * t * (3 - 2 * t)
  }
}

private struct Painter {
  let dark: Bool
  let clock: Clock
  let width, y: Double

  private var center: Double { width / 2 }
  private func position(at time: Double) -> Double { center + (center - 16) * sin(clock.angle(at: time)) }
  private func rect(_ x: Double, _ radius: Double) -> CGRect {
    CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius)
  }

  func paint(_ base: GraphicsContext, _ sprites: Sprites, _ alpha: Double) {
    guard alpha > 0.003 else { return }
    let line = base.resolve(sprites.line)
    let bloom = base.resolve(sprites.bloom)
    let halo = base.resolve(sprites.halo)
    if clock.reduce {
      still(base, bloom: bloom, halo: halo, alpha: alpha)
      hotLine(base, sprites, line: line, x: center, alpha: alpha * 0.9, stretch: 6)
    } else {
      let head = position(at: clock.elapsed)
      comet(base, line: line, bloom: bloom, halo: halo, head: head, alpha: alpha)
      hotLine(base, sprites, line: line, x: head - 4 * clock.lag, alpha: alpha, stretch: 1)
    }
  }

  private func comet(
    _ base: GraphicsContext, line: GraphicsContext.ResolvedImage, bloom: GraphicsContext.ResolvedImage,
    halo: GraphicsContext.ResolvedImage, head: Double, alpha: Double
  ) {
    var context = base
    // A pool above the line, a tight halo, and a catch as the light reaches either glass edge.
    context.opacity = alpha * clock.bloom * (dark ? 0.5 : 0.56)
    context.draw(bloom, in: CGRect(x: head - 150, y: y - 62, width: 300, height: 100))
    context.opacity = alpha * 0.82
    context.draw(halo, in: CGRect(x: head - 37.5, y: y - 8.7, width: 75, height: 17.4))
    for edge in 0..<2 {
      let x = edge == 0 ? 0 : width
      let near = pow(max(0, 1 - abs(head - x) / 110), 2)
      if near > 0.01 {
        context.opacity = alpha * near * 0.8
        context.draw(bloom, in: CGRect(x: x - 8, y: y - 30, width: 16, height: 44))
      }
    }
    // Sample the tail back along the light's path so it stretches with speed and folds at the ends.
    let ink = alpha * (dark ? 0.27 : 0.5)
    let radius = 2.4 * (dark ? 1 : 1.16)
    let spacing = 1.1
    let step = 1.0 / 240
    let speed = Clock.speed
    let decay = 0.1
    let maxAge = min(decay * 3.8, speed * clock.elapsed)
    var previousAge = 0.0
    var previousX = head
    var carry = 0.0
    var age = step
    while previousAge < maxAge {
      let sampleAge = min(age, maxAge)
      let x = position(at: clock.elapsed - sampleAge / speed)
      let dx = x - previousX
      let distance = abs(dx)
      if distance > 1e-3 {
        var point = spacing - carry
        while point <= distance {
          let fraction = point / distance
          let weight = exp(-(previousAge + (sampleAge - previousAge) * fraction) / decay)
          context.opacity = ink * weight
          context.draw(line, in: rect(previousX + dx * fraction, radius * (0.5 + 0.5 * weight)))
          point += spacing
        }
        carry = distance - (point - spacing)
      }
      previousAge = sampleAge
      previousX = x
      age += step
    }
  }

  // Three tapered spindles, each shorter, slimmer and whiter than the last.
  private func hotLine(
    _ base: GraphicsContext, _ sprites: Sprites, line: GraphicsContext.ResolvedImage,
    x: Double, alpha: Double, stretch: Double
  ) {
    var context = base
    let scale = dark ? 1.0 : 1.12
    func lay(
      _ image: GraphicsContext.ResolvedImage, _ half: Double, _ sigma: Double,
      _ radius: Double, _ opacity: Double, _ spacing: Double
    ) {
      var offset = -half
      while offset <= half {
        let weight = exp(-pow(offset / sigma, 2))
        context.opacity = alpha * opacity * weight
        context.draw(image, in: rect(x + offset * stretch, radius * scale * (0.6 + 0.4 * weight)))
        offset += spacing / stretch
      }
    }
    if dark {
      lay(base.resolve(sprites.glow), 34, 16, 6, 0.16, 2)
      lay(line, 26, 12, 2.7, 0.24, 1)
      lay(base.resolve(sprites.hot), 24, 10, 1.7, 0.42, 0.5)
    } else {
      lay(base.resolve(sprites.glow), 36, 17, 7, 0.2, 2)
      lay(base.resolve(sprites.soft), 32, 14, 4.4, 0.3, 1)
      lay(base.resolve(sprites.hot), 24, 9.5, 1.3, 0.55, 0.5)
    }
  }

  private func still(
    _ base: GraphicsContext, bloom: GraphicsContext.ResolvedImage, halo: GraphicsContext.ResolvedImage,
    alpha: Double
  ) {
    var context = base
    context.opacity = alpha * 0.5
    context.draw(bloom, in: CGRect(x: center - 186, y: y - 52, width: 372, height: 80))
    context.opacity = alpha * 0.8
    context.draw(halo, in: CGRect(x: center - 117.6, y: y - 5, width: 235.2, height: 10))
  }
}
