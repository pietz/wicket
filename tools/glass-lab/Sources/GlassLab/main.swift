import AppKit
import SwiftUI
import WebKit

// Glass Lab: Wicket's panel look with a list of looks inside it. ↑/↓ switch live, ⌘D cycles appearance, ⌘Q quits.

enum Rim { case none, gloss, soft, hairline }

struct Look: Identifiable {
  let id: Int
  let name: String
  let note: String
  var pillClear = false
  var cardClear = false
  var tint = 0.2  // Wicket today: 0.8 × (1 − 0.75)
  var rim = Rim.none
  var backing = 0.0
  var lightInk = false
  var interactive = false
  var onePiece = false
  var blur = false  // a system blur under clear glass
  var scrim = 0.0  // a plain window-color fill under clear glass
  var blurCardOnly = false
  var native = 0  // 1: AppKit clear glass with its own blur turned up (private), 2: clear rim + centre frost
}

let looks: [Look] = [
  Look(id: 0, name: "Glass", note: "Clear glass with its own blur; light or dark follows ⌘D", pillClear: true, cardClear: true, tint: 0, backing: 0.5, native: 1),
]

@MainActor final class Lab: ObservableObject {
  @Published var selection = 0
  @Published var appearance = 1  // 0 system, 1 light, 2 dark
  @Published var amount: [Int: Double] = [:]  // ←/→ per look: tint, or backing for dark-backed looks
  @Published var joined: Set<Int> = []  // ⌘J flips one piece per look
  @Published var radius: Double = 5  // ⇧←/→: blur strength, 0–10
  @Published var matchBar = true  // ⌘M: scale the bar's blur like the system does (bar default 5.6 vs card 10)
  var look: Look {
    var l = looks[selection]
    if let a = amount[l.id] {
      if l.scrim > 0 { l.scrim = a } else if l.backing > 0 { l.backing = a } else { l.tint = a }
    }
    if joined.contains(l.id) { l.onePiece.toggle() }
    return l
  }
  var amountLabel: String {
    let l = look
    if l.scrim > 0 { return "scrim \(Int((l.scrim * 100).rounded()))%" }
    return l.backing > 0 ? "transparency \(Int(((1 - l.backing) * 100).rounded()))%" : "tint \(Int((l.tint * 100).rounded()))%"
  }
  func nudge(_ step: Double) {
    let l = look
    let current = l.scrim > 0 ? l.scrim : l.backing > 0 ? l.backing : l.tint
    amount[l.id] = min(1, max(0.01, current + step))
  }
  var appearanceName: String { ["System", "Light", "Dark"][appearance] }
}

struct Canvas: NSViewRepresentable {
  let lightInk: Bool
  /// Wicket's own canvas stylesheet, read from the repo so the lab always shows the current one.
  static let css =
    (try? String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/WicketApp/Resources/answers.css"),
      encoding: .utf8)) ?? ""
  static let body = """
    <main>
    <h1>9° · light rain</h1>
    <p>Hamburg · feels like 6° · wind 18 km/h</p>
    <p>Rain eases by <strong>4 pm</strong>, then dry and bright tomorrow. Details on <a href="#">the forecast page</a>, or run <code>wicket weather --hourly</code>.</p>
    <table><thead><tr><th>Day</th><th align="right">High</th><th align="right">Low</th><th>Sky</th></tr></thead>
    <tbody><tr><td>Fri</td><td align="right">12°</td><td align="right">5°</td><td>Showers</td></tr>
    <tr><td>Sat</td><td align="right">14°</td><td align="right">7°</td><td>Cloudy</td></tr>
    <tr><td>Sun</td><td align="right">16°</td><td align="right">8°</td><td>Sunny</td></tr></tbody></table>
    <pre><code>curl wttr.in/Hamburg?format=3</code></pre>
    <blockquote>Grey quote text: is this still easy to read?</blockquote>
    </main>
    """
  final class Coordinator { var ink: Bool? }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> WKWebView {
    let view = WKWebView()
    view.setValue(false, forKey: "drawsBackground")
    return view
  }
  func updateNSView(_ view: WKWebView, context: Context) {
    if context.coordinator.ink != lightInk {
      context.coordinator.ink = lightInk
      load(view)
    }
  }
  private func load(_ view: WKWebView) {
    let ink =
      lightInk
      ? ":root { color-scheme: dark; --muted: rgb(255 255 255 / 72%); --secondary: rgb(255 255 255 / 70%); --surface: rgb(255 255 255 / 12%); }"
      : ""
    view.loadHTMLString(
      "<!doctype html><html><head><meta charset=utf-8><style>\(Self.css)\n\(ink)</style></head><body>\(Self.body)</body></html>",
      baseURL: nil)
  }
}

/// A pure behind-window Gaussian blur: the system blur view, whose window-server backdrop works, with its
/// material layers hidden and its backdrop filters replaced by one fresh Gaussian blur on every change (a
/// layer copies its filters, so editing the old ones does nothing). Private internals; lab only.
final class PureBlurView: NSVisualEffectView {
  var radius: Double = 14 { didSet { apply() } }
  override func layout() {
    super.layout()
    apply()
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    apply()
  }
  private func apply() {
    walk(layer)
  }
  private func walk(_ layer: CALayer?) {
    guard let layer else { return }
    for sub in layer.sublayers ?? [] {
      let name = String(describing: type(of: sub))
      if name.contains("Backdrop") {
        let type = NSClassFromString("CAFilter") as! NSObject.Type
        if let blur = type.perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?
          .takeUnretainedValue() as? NSObject
        {
          blur.setValue(radius, forKey: "inputRadius")
          blur.setValue(true, forKey: "inputNormalizeEdges")
          sub.filters = [blur]
        }
      } else if (sub.sublayers ?? []).isEmpty {
        sub.opacity = 0
      }
      walk(sub)
    }
  }
}

struct Blur: NSViewRepresentable {
  let radius: CGFloat
  let blur: Double
  func makeNSView(context: Context) -> PureBlurView {
    let view = PureBlurView()
    view.material = .hudWindow
    view.blendingMode = .behindWindow
    view.state = .active
    view.maskImage = Self.mask(radius)
    view.radius = blur
    return view
  }
  func updateNSView(_ view: PureBlurView, context: Context) { view.radius = blur }
  static func mask(_ r: CGFloat) -> NSImage {
    let size = NSSize(width: r * 2 + 1, height: r * 2 + 1)
    let image = NSImage(size: size, flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
    image.resizingMode = .stretch
    return image
  }
}

/// AppKit clear glass whose own backdrop blur is turned up: the glass keeps its lens and rim and blurs the
/// same pixels it refracts. Patches private `glassBackground` filter inputs; lab only.
struct GlassSlab: NSViewRepresentable {
  let radius: CGFloat
  let blur: Double
  let mix: Double
  final class Slab: NSView {
    let glass = NSGlassEffectView()
    var blur = 10.0, mix = 0.55
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
      super.layout()
      glass.frame = bounds
      DispatchQueue.main.async { [weak self] in self?.patch() }
    }
    func patch() {
      guard let layer = glass.layer else { return }
      probeGlassBlur(in: layer, radius: blur, mix: mix)
    }
  }
  func makeNSView(context: Context) -> Slab {
    let view = Slab()
    view.wantsLayer = true
    view.glass.style = .clear
    view.glass.contentView = NSView()
    view.addSubview(view.glass)
    return view
  }
  func updateNSView(_ view: Slab, context: Context) {
    view.glass.cornerRadius = radius
    view.blur = blur
    view.mix = mix
    view.patch()
  }
}

@MainActor
@discardableResult
func probeGlassBlur(in layer: CALayer, radius: Double, mix: Double) -> Int {
  var changed = 0
  if let filters = layer.filters {
    let updated = filters.map { item -> Any in
      guard let original = item as? NSObject,
        original.value(forKey: "type") as? String == "glassBackground",
        let keys = original.value(forKey: "inputKeys") as? [String],
        keys.contains("inputBlurRadius"),
        let copy = (original as? NSCopying)?.copy(with: nil) as? NSObject
      else { return item }
      copy.setValue(max(0, radius), forKey: "inputBlurRadius")
      changed += 1
      return copy
    }
    if changed > 0 { layer.filters = updated }
  }
  for child in layer.sublayers ?? [] { changed += probeGlassBlur(in: child, radius: radius, mix: mix) }
  return changed
}

struct WidgetRimSurface: NSViewRepresentable {
  let radius: CGFloat
  var coverage: CGFloat = 0.8

  final class Backdrop: NSView {
    let glass = NSGlassEffectView()
    let frost = NSVisualEffectView()
    var maskRadius: CGFloat?
    var maskCoverage: CGFloat?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }

  func makeNSView(context: Context) -> Backdrop {
    let view = Backdrop()
    view.glass.style = .clear
    view.glass.contentView = NSView()
    view.frost.material = .hudWindow
    view.frost.blendingMode = .behindWindow
    view.frost.state = .active
    view.addSubview(view.glass)
    view.addSubview(view.frost, positioned: .above, relativeTo: view.glass)
    for child in [view.glass as NSView, view.frost] {
      child.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        child.topAnchor.constraint(equalTo: view.topAnchor),
        child.bottomAnchor.constraint(equalTo: view.bottomAnchor)
      ])
    }
    return view
  }

  func updateNSView(_ view: Backdrop, context: Context) {
    let opacity = min(1, max(0, coverage))
    view.glass.cornerRadius = radius
    view.frost.isHidden = opacity == 0
    guard view.maskRadius != radius || view.maskCoverage != opacity else { return }
    view.frost.maskImage = Self.centerMask(radius: radius, opacity: opacity)
    view.maskRadius = radius
    view.maskCoverage = opacity
  }

  private static func centerMask(radius: CGFloat, opacity: CGFloat) -> NSImage {
    let rim: CGFloat = 10
    let feather: CGFloat = 20
    let cap = max(radius, rim + feather)
    let side = cap * 2 + 1
    let size = NSSize(width: side, height: side)
    let image = NSImage(size: size, flipped: false) { bounds in
      guard let context = NSGraphicsContext.current?.cgContext else { return false }
      context.setBlendMode(.copy)
      for step in 1...20 {
        let progress = CGFloat(step) / 20
        let inset = rim + feather * progress
        let corner = max(0, radius - inset)
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let alpha = opacity * progress * progress * (3 - 2 * progress)
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: alpha)
        if corner > 0 {
          context.addPath(CGPath(roundedRect: rect, cornerWidth: corner,
                                 cornerHeight: corner, transform: nil))
          context.fillPath()
        } else {
          context.fill(rect)
        }
      }
      return true
    }
    image.capInsets = NSEdgeInsets(top: cap, left: cap, bottom: cap, right: cap)
    image.resizingMode = .stretch
    return image
  }
}

struct LabView: View {
  @ObservedObject var lab: Lab
  @State private var query = "weather hamburg"
  @Namespace private var glassSpace
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorScheme) private var colorScheme
  static let listHeight: CGFloat = 5 * 42 - 2 + 20
  static let canvasHeight: CGFloat = 330
  static let cardHeight: CGFloat = listHeight + 1 + canvasHeight + 35

  var body: some View {
    let look = lab.look
    ZStack(alignment: .top) {
      GlassEffectContainer(spacing: look.onePiece ? 30 : 8) {
        VStack(spacing: 8) {
          surface(radius: 28, clear: look.pillClear, look: look, card: false).frame(height: 56)
          surface(radius: 22, clear: look.cardClear, look: look, card: true).frame(height: Self.cardHeight)
        }
      }
      VStack(spacing: 8) {
        HStack(spacing: 12) {
          Image(systemName: "magnifyingglass").font(.system(size: 19, weight: .medium))
            .foregroundStyle(.secondary).frame(width: 24)
          TextField("Search or ask…", text: $query).textFieldStyle(.plain).font(.system(size: 21))
          Text("⌘D \(lab.appearanceName)").font(.system(size: 12)).foregroundStyle(.tertiary)
          Image(systemName: "mic").font(.system(size: 18)).foregroundStyle(.secondary)
        }.padding(.horizontal, 18).frame(height: 56)
        .overlay { border(look.rim, shape: RoundedRectangle(cornerRadius: 28, style: .continuous)) }
        VStack(spacing: 0) {
          ScrollViewReader { proxy in
            ScrollView {
              VStack(spacing: 2) { ForEach(looks) { row($0) } }.padding(10)
            }
            .scrollIndicators(.never)
            .frame(height: Self.listHeight)
            .onChange(of: lab.selection) { _, id in withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) } }
          }
          Divider().opacity(0.6)
          Canvas(lightInk: look.lightInk && !reduceTransparency).frame(height: Self.canvasHeight)
          Divider().opacity(0.6)
          HStack {
            Text(lab.look.blur || lab.look.native == 1
              ? "↑↓ look · ←→ \(lab.amountLabel) · ⇧←→ blur \(Int(lab.radius)) · ⌘M bar \(lab.matchBar ? "matched" : "same") · ⌘D \(lab.appearanceName) · ⌘Q"
              : "↑↓ look · ←→ \(lab.amountLabel) · ⌘D \(lab.appearanceName) · ⌘Q")
            Spacer()
            Text("\(lab.selection + 1)/\(looks.count)")
          }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 20).frame(height: 34)
        }
        .frame(height: Self.cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay { border(look.rim, shape: RoundedRectangle(cornerRadius: 22, style: .continuous)) }
      }
    }
    .padding(40)
    .frame(width: 720)
    .environment(\.colorScheme, look.lightInk && !reduceTransparency ? .dark : colorScheme)
  }

  private func row(_ item: Look) -> some View {
    HStack(spacing: 10) {
      Image(systemName: item.id == lab.selection ? "circle.inset.filled" : "circle")
        .font(.system(size: 16)).foregroundStyle(item.id == lab.selection ? Color.accentColor : .secondary)
        .frame(width: 26, height: 26)
      Text(item.name).font(.system(size: 14)).lineLimit(1)
      Text(item.note).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
      Spacer(minLength: 8)
    }
    .padding(.horizontal, 10).frame(height: 40)
    .background {
      if item.id == lab.selection {
        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(lab.look.cardClear ? 0.16 : 0.1))
      }
    }
    .contentShape(Rectangle()).id(item.id)
    .onTapGesture { lab.selection = item.id }
  }

  @ViewBuilder private func surface(radius: CGFloat, clear: Bool, look: Look, card: Bool) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    if reduceTransparency {
      shape.fill(Color(nsColor: .windowBackgroundColor))
    } else {
      ZStack {
        if look.native == 1 {
          shape.fill((colorScheme == .dark ? Color.black : Color.white).opacity(look.backing))
          GlassSlab(radius: radius, blur: card || !lab.matchBar ? lab.radius : lab.radius * 0.56, mix: look.tint)
        } else if look.native == 2 {
          WidgetRimSurface(radius: radius, coverage: look.tint)
        }
        if look.native == 0 && look.blur && (card || !look.blurCardOnly) { Blur(radius: radius, blur: lab.radius) }
        if look.scrim > 0 { shape.fill(Color(nsColor: .windowBackgroundColor).opacity(look.scrim)) }
        if look.native == 0 {
          if look.backing > 0 { shape.fill(.black.opacity(look.backing)) }
          glass(clear: clear, look: look, shape: shape)
        }
      }
    }
  }

  @ViewBuilder private func glass(clear: Bool, look: Look, shape: RoundedRectangle) -> some View {
    let base = (clear ? Glass.clear : .regular).tint(Color(nsColor: .windowBackgroundColor).opacity(look.tint))
    let g = look.interactive ? base.interactive() : base
    if look.onePiece {
      Color.clear.glassEffect(g, in: shape).glassEffectUnion(id: "panel", namespace: glassSpace)
    } else {
      Color.clear.glassEffect(g, in: shape)
    }
  }

  @ViewBuilder private func border(_ rim: Rim, shape: RoundedRectangle) -> some View {
    switch rim {
    case .none: EmptyView()
    case .gloss:
      shape.strokeBorder(
        LinearGradient(
          colors: [.white.opacity(0.55), .white.opacity(0.08), .black.opacity(0.18)],
          startPoint: .top, endPoint: .bottom), lineWidth: 1
      ).allowsHitTesting(false)
    case .soft:
      shape.strokeBorder(
        LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0)], startPoint: .top, endPoint: .center),
        lineWidth: 0.5
      ).allowsHitTesting(false)
    case .hairline:
      shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5).allowsHitTesting(false)
    }
  }
}

final class LabWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  let lab = Lab()
  var window: LabWindow!
  var monitor: Any?

  func applicationDidFinishLaunching(_ note: Notification) {
    let host = NSHostingView(rootView: LabView(lab: lab))
    let size = host.fittingSize
    window = LabWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.isMovableByWindowBackground = true
    window.level = .floating
    window.contentView = host
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.appearance = NSAppearance(named: .aqua)
    NSApp.activate()
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self else { return event }
      let cmd = event.modifierFlags.contains(.command)
      switch (event.keyCode, cmd, event.charactersIgnoringModifiers) {
      case (125, false, _): self.lab.selection = min(looks.count - 1, self.lab.selection + 1); return nil
      case (126, false, _): self.lab.selection = max(0, self.lab.selection - 1); return nil
      case (123, false, _) where event.modifierFlags.contains(.shift): self.lab.radius = max(0, self.lab.radius - 1); return nil
      case (124, false, _) where event.modifierFlags.contains(.shift): self.lab.radius = min(10, self.lab.radius + 1); return nil
      case (123, false, _): self.lab.nudge(self.lab.look.backing > 0 ? 0.05 : -0.05); return nil
      case (124, false, _): self.lab.nudge(self.lab.look.backing > 0 ? -0.05 : 0.05); return nil
      case (_, true, "d"): self.cycleAppearance(); return nil
      case (_, true, "m"): self.lab.matchBar.toggle(); return nil
      case (_, true, "j"): self.lab.joined.formSymmetricDifference([self.lab.look.id]); return nil
      case (_, true, "q"): NSApp.terminate(nil); return nil
      default: return event
      }
    }
  }

  /// ←/→ adjust the look unless the caret is mid-text in the search field.
  var editing: Bool { false }

  func cycleAppearance() {
    lab.appearance = (lab.appearance + 1) % 3
    NSApp.appearance = [nil, NSAppearance(named: .aqua), NSAppearance(named: .darkAqua)][lab.appearance]
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
