import AppKit
import SwiftUI
import WebKit

/// An AppKit text field, so input methods, paste and editing shortcuts work: the input and each
/// argument slot. `focused` says whether the model wants it to have the keys; it takes them when that
/// turns true, and reports a click into it through `onFocus`.
struct SearchField: NSViewRepresentable {
  @Binding var text: String
  let placeholder: String
  var size: CGFloat = 21
  /// Room the field may draw into before, above and below its frame, never after it: AppKit puts the
  /// field editor a few points left of and above the field while editing, so clipping at the frame cut
  /// the first letter. Zero clips at the frame.
  var bleed: CGFloat = 0
  var focused = false
  var onFocus: () -> Void = {}
  var register: (NSTextField) -> Void = { _ in }
  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
  func makeNSView(context: Context) -> NSTextField {
    let field = FocusReportingField(string: "")
    field.isBordered = false
    field.drawsBackground = false
    field.font = .systemFont(ofSize: size)
    field.textColor = .labelColor
    field.focusRingType = .none
    // Since macOS 14 views draw outside their bounds by default; text longer than the field must not.
    field.bleed = bleed
    field.delegate = context.coordinator
    register(field)
    return field
  }
  /// Exactly the width it is given: the layout sizes fields from their text, never the reverse, and
  /// AppKit's intrinsic width would let long text push the field past the slots. Always its own height:
  /// a text field draws its text at the top, so a taller frame would lift the text above the centre.
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
    guard let width = proposal.width else { return nil }
    return CGSize(width: width, height: nsView.intrinsicContentSize.height)
  }
  func updateNSView(_ field: NSTextField, context: Context) {
    context.coordinator.text = $text
    (field as? FocusReportingField)?.onFocus = onFocus
    field.placeholderString = placeholder
    field.setAccessibilityLabel(placeholder)
    Self.updateText(text, in: field)
    // Only a change takes the keys, so a button that Tab reached keeps them on later updates.
    if focused, !context.coordinator.focused, field.currentEditor() == nil, let window = field.window {
      window.makeFirstResponder(field)
      Self.moveCaretToEnd(of: field)
    }
    context.coordinator.focused = focused
  }
  static func updateText(_ text: String, in field: NSTextField) {
    guard field.stringValue != text else { return }
    field.stringValue = text
    // AppKit selects the whole replacement. Typing after dictation should append at the caret.
    moveCaretToEnd(of: field)
  }
  static func moveCaretToEnd(of field: NSTextField) {
    (field.currentEditor() as? NSTextView)?.setSelectedRange(
      NSRange(location: field.stringValue.utf16.count, length: 0))
  }
  final class Coordinator: NSObject, NSTextFieldDelegate {
    var text: Binding<String>
    var focused = false
    init(text: Binding<String>) { self.text = text }
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      // AppKit owns marked text and all composition keystrokes.
      text.wrappedValue = field.stringValue
    }
  }
}

/// Says when it takes the keys, whether by a click or by the model.
final class FocusReportingField: NSTextField {
  var onFocus: () -> Void = {}
  /// Clips at the trailing edge only, with this much room on the other sides (`SearchField.bleed`).
  /// `clipsToBounds` has no insets, so a mask layer does it.
  var bleed: CGFloat = 0 {
    didSet {
      clipsToBounds = bleed == 0
      wantsLayer = true
      layer?.mask = bleed == 0 ? nil : CALayer()
      layer?.mask?.backgroundColor = NSColor.black.cgColor
      updateMask()
    }
  }
  override func setFrameSize(_ size: NSSize) {
    super.setFrameSize(size)
    updateMask()
  }
  private func updateMask() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer?.mask?.frame = CGRect(
      x: -bleed, y: -bleed, width: bounds.width + bleed, height: bounds.height + 2 * bleed)
    CATransaction.commit()
  }
  override func becomeFirstResponder() -> Bool {
    guard super.becomeFirstResponder() else { return false }
    onFocus()
    return true
  }
}

/// The input followed directly by its argument slots, like `Caffeinate [hours] [minutes]`: the input is
/// as wide as its text up to the room the slots leave, so the slots sit where the eyes are and stay
/// fully visible; past that the input scrolls. Without slots the input takes the whole width. The
/// input's start never moves.
struct InputBar: Layout {
  var spacing: CGFloat = 6
  /// Scrolled text stops this far before the slots, the room text that fits keeps for its caret.
  var scrollGap: CGFloat = 8
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    return CGSize(
      width: proposal.width ?? sizes.reduce(0) { $0 + $1.width + spacing },
      height: proposal.height ?? sizes.map(\.height).max() ?? 0)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard let input = subviews.first else { return }
    let slots = subviews.dropFirst().map { $0.sizeThatFits(.unspecified) }
    let room = bounds.width - slots.reduce(0) { $0 + spacing + $1.width }
    let natural = input.sizeThatFits(.unspecified).width
    let width = slots.isEmpty ? bounds.width : max(0, min(natural, room))
    // Text longer than the room is clipped a little before the first slot, not at its edge; the slots
    // stay where they are.
    input.place(
      at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
      proposal: ProposedViewSize(
        width: !slots.isEmpty && natural > room ? max(0, room - scrollGap) : width, height: bounds.height))
    var x = bounds.minX + width
    for (slot, size) in zip(subviews.dropFirst(), slots) {
      x += spacing
      slot.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(size))
      x += size.width
    }
  }
}

struct LauncherView: View {
  @Bindable var model: LauncherModel
  private var navigator: Navigator { model.navigator }
  let renderer: AnswerRenderer
  let registerInput: (NSTextField) -> Void
  let run: (RowAction?) -> Void
  var flatSurfaces = false
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  private var textSize: Configuration.TextSize { model.configuration.textSize }
  var body: some View {
    ZStack(alignment: .top) {
      GlassEffectContainer(spacing: PaletteLayout.gap) {
        VStack(spacing: PaletteLayout.gap) {
          surface(radius: 28).frame(height: PaletteLayout.search)
          surface(radius: 22).frame(height: cardHeight)
        }
      }
      VStack(spacing: PaletteLayout.gap) {
        HStack(spacing: 12) {
          Image(systemName: model.agent.active ? "sparkles" : "magnifyingglass").font(
            .system(size: 19, weight: .medium)
          ).foregroundStyle(.secondary).frame(width: 24)
          InputBar {
            input
            ForEach(navigator.declaredArguments, id: \.name) { argumentSlot($0) }
          }
          .frame(height: 30)
          // The free space after the slots belongs to the input.
          .contentShape(Rectangle())
          .onTapGesture { navigator.focusedArgument = nil }
          if model.configuration.voice.enabled, model.agent.takesSpeech {
            Button {
              model.toggleVoice()
            } label: {
              Image(systemName: model.voice?.state == .listening ? "mic.fill" : "mic")
                .font(.system(size: 18)).foregroundStyle(
                  model.voice?.active == true ? Color.accentColor : Color.secondary)
            }.buttonStyle(.plain)
              .help(model.voice?.active == true ? "Stop listening" : "Start listening")
              .accessibilityLabel(model.voice?.active == true ? "Stop listening" : "Start listening")
          }
        }
        .padding(.horizontal, 18).frame(height: PaletteLayout.search)

        VStack(spacing: 0) {
          // The action panel lists over a conversation or page, which stay as they were, hidden, for Escape.
          let actions = navigator.actionsTitle != nil
          ZStack(alignment: .top) {
            Group {
              if model.agent.active {
                agentContent
              } else if navigator.command?.problem != nil || navigator.page != nil {
                extensionContent
              }
            }
            .opacity(actions ? 0 : 1).allowsHitTesting(!actions).accessibilityHidden(actions)
            if navigator.splits {
              split
            } else if actions
              || !model.agent.active && navigator.command?.problem == nil && navigator.page == nil
            {
              list
            }
          }
          .frame(height: actions ? cardHeight - PaletteLayout.footer : nil, alignment: .top).clipped()
          Divider()
          HStack(spacing: 12) {
            // Busy once the answer has begun: before that the answer area shows its own spinner.
            if voiceStatus == nil, model.agent.active, model.agent.busy, !model.agent.answer.isEmpty {
              ProgressView().controlSize(.small).padding(.trailing, -4)
            }
            Text(
              voiceStatus
                ?? (model.agent.active
                  ? (model.agent.continuing && !model.agent.busy && !model.agent.question.isEmpty
                    ? "Continuing conversation" : (renderer.problem ?? model.agent.status))
                  : (model.problem ?? navigator.commandName ?? "Wicket"))
            ).lineLimit(1).help(
              voiceStatus ?? (model.agent.active ? model.agent.status : (model.problem ?? "")))
            Spacer()
            if !model.agent.permissions.isEmpty {
              Text("⌘↩ Allow")
              Text("Esc Don't allow")
            } else if navigator.actionsTitle != nil {
              Text("↩ " + (navigator.selected?.row.actions.first?.label ?? "Enter"))
              Text("esc Back")
            } else if model.agent.active {
              if let action = navigator.selected?.row.actions.first {
                Text("↩ " + action.label)
              } else if model.agent.busy {
                Button("Cancel") { model.agent.cancel() }.buttonStyle(.plain)
              } else if model.agent.question.isEmpty {
                Text("↩ Ask")
              } else {
                Text("↩ Follow up")
              }
              if navigator.offersActions { Text("⌘K Actions") }
              Text(
                navigator.inDetail || navigator.returnsOnEscape
                  ? "Esc Back"
                  : model.agent.busy
                    ? "Esc Cancel" : model.agent.question.isEmpty ? "Esc Discard" : "Esc End conversation")
            } else {
              Text("↩ " + (navigator.selected?.row.actions.first?.label ?? "Enter"))
              if navigator.offersActions { Text("⌘K Actions").lineLimit(1) }
              // The one hint that may grow with a name: it gives way first.
              Text("⌘↩ " + (navigator.askingAbout.map { "Ask about \($0)" } ?? "Ask agent")).lineLimit(1)
                .layoutPriority(-1)
              Text(navigator.command == nil ? "esc Close" : "esc Back")
            }
          }
          .font(.system(size: 12)).foregroundStyle(.secondary)
          .padding(.horizontal, 20).frame(height: PaletteLayout.footer - 1)
        }
        .frame(height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
      }
    }
    .padding(PaletteLayout.margin)

    // The host can briefly be taller than its new content. Never centre the input in it.
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
  /// The main input, sized by a hidden copy of its text (or placeholder) so the slots can follow it; the
  /// field itself never sizes itself. The first 200 characters are enough to fill any width.
  private var input: some View {
    // The action panel's field is empty and says what the panel is for; typing returns to the input.
    let text = navigator.actionsTitle == nil ? navigator.input : ""
    let placeholder =
      navigator.actionsTitle.map { "Actions for \($0)" }
      ?? (model.agent.active
        ? (model.agent.question.isEmpty
          ? navigator.askingAbout.map { "Ask about \($0)…" } ?? "Ask \(navigator.askingName)…"
          : "Ask a follow-up…")
        : (navigator.commandName ?? "Search or ask anything…"))
    return Text(text.isEmpty ? placeholder : String(text.prefix(200)))
      .font(.system(size: 21)).lineLimit(1).hidden()
      .padding(.trailing, 8)  // Room for the caret and the field's own inset.
      .frame(minWidth: 0, maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
      .overlay {
        SearchField(
          text: Binding(get: { text }, set: { navigator.editInput($0) }),
          placeholder: placeholder, bleed: 6,
          focused: navigator.focusedArgument == nil,
          onFocus: { if navigator.focusedArgument != nil { navigator.focusedArgument = nil } },
          register: registerInput)
      }
  }
  /// A declared argument's slot after the input's text: as wide as its own text within fixed bounds.
  /// Fixed sizes, like the input.
  private func argumentSlot(_ argument: ExtensionManifest.Argument) -> some View {
    let label = argument.placeholder ?? argument.name
    let value = navigator.argumentValues[argument.name] ?? ""
    return Text(value.isEmpty ? label : value).font(.system(size: 15)).lineLimit(1).hidden()
      .padding(.trailing, 4)  // Room for the caret.
      .frame(minWidth: 24, maxWidth: 150).fixedSize()
      .overlay {
        SearchField(
          text: Binding(get: { value }, set: { navigator.setArgument(argument.name, to: $0) }),
          placeholder: label, size: 15, focused: navigator.focusedArgument == argument.name,
          onFocus: {
            if navigator.focusedArgument != argument.name { navigator.focusedArgument = argument.name }
          })
      }
      .padding(.horizontal, 9).frame(height: 28)
      .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.08)))
  }
  /// The native list: search results, a command's items, or the action panel's actions.
  private var list: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 2) {
          if navigator.results.isEmpty {
            Text(navigator.command?.busy == true ? "Running…" : "No results").foregroundStyle(.secondary)
              .frame(height: PaletteLayout.header)
          }
          ForEach(navigator.results) { result in resultRow(result) }
        }.padding(10)
      }
      .frame(height: navigator.listHeight)
      .onChange(of: navigator.selection) { _, id in if let id { proxy.scrollTo(id) } }
      .onChange(of: navigator.results.map(\.id)) { _, _ in
        if let id = navigator.selection { proxy.scrollTo(id) }
      }
    }
  }
  /// A command's list with the selected item's detail beside it on the canvas. The pane shows only this
  /// command's details, so another screen's page never flashes in it while the first one renders; the
  /// web view stays mounted meanwhile, since one added after its page rendered stayed blank offscreen.
  private var split: some View {
    HStack(spacing: 0) {
      list.frame(width: PaletteLayout.splitList)
      Divider()
      if let page = renderer.page {
        WebView(page).webViewContentBackground(.hidden)
          .opacity(
            renderer.renderedTurn.hasPrefix(Navigator.previewTurn(navigator.command?.id ?? "", nil)) ? 1 : 0)
      } else {
        Spacer()
      }
    }
    .frame(height: navigator.listHeight)
  }
  /// One row of the native list. A page draws its own rows in the same metrics (`answers.css`).
  private func resultRow(_ result: Result) -> some View {
    HStack(spacing: 10) {
      icon(result).frame(width: 26, height: 26)
      if result.row.prominent == true, result.id == navigator.results.first?.id {
        VStack(alignment: .leading, spacing: 0) {
          Text(result.row.title).font(
            .system(size: 24 * textSize.scale, weight: .medium).monospacedDigit())
          Text(result.row.subtitle ?? "").font(.system(size: 12)).foregroundStyle(
            .secondary)
        }.lineLimit(1)
      } else {
        Text(result.row.title).font(.system(size: 14 * textSize.scale)).lineLimit(1)
          .layoutPriority(
            1)
        // Beside a detail the list is narrow, and the detail says more.
        if let subtitle = result.row.subtitle, result.provider != "apps", !navigator.splits {
          Text(subtitle).font(.system(size: 14 * textSize.scale)).foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      if result.provider == "apps", let subtitle = result.row.subtitle {
        Text(subtitle).font(.system(size: 13 * textSize.scale)).foregroundStyle(.secondary)
          .lineLimit(1)
      }
      if model.recordsHotkey(of: result) {
        Text(model.recorder.rejected ? "Add ⌘, ⌃ or ⌥ · Esc cancels" : "Press a shortcut · Esc cancels")
          .font(.system(size: 13 * textSize.scale)).foregroundStyle(.secondary).lineLimit(1)
      } else if let hotkey = navigator.hotkey(of: result) {
        Text(hotkey.symbols).font(.system(size: 13 * textSize.scale)).foregroundStyle(.tertiary)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 10).frame(
      height: (result.row.prominent == true)
        && result.id == navigator.results.first?.id ? textSize.rowHeight + 20 : textSize.rowHeight
    )
    .background {
      if result.id == navigator.selection {
        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(
          .primary.opacity(0.1))
      }
    }
    .contentShape(Rectangle()).id(result.id)
    .onTapGesture(count: 2) {
      navigator.select(result.id)
      run(nil)
    }
    .onTapGesture { if navigator.click(result.id) { run(nil) } }
    .contextMenu {
      ForEach(Array(navigator.actions(of: result).enumerated()), id: \.offset) { _, action in
        Button(action.label) {
          navigator.select(result.id)
          run(action)
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(
      result.id == navigator.selection ? [.isSelected, .isButton] : .isButton)
  }
  private var voiceStatus: String? {
    if model.voice?.state == .starting { return "Starting voice…" }
    if model.voice?.state == .listening { return "Listening…" }
    return model.voice?.problem
  }
  private var cardHeight: CGFloat { navigator.cardHeight(answer: renderer.height, cap: renderer.cap) }
  private var extensionContent: some View {
    VStack(spacing: 0) {
      HStack {
        Text(navigator.commandName ?? "Extension").font(.system(size: 13, weight: .medium))
          .lineLimit(1)
        Spacer()
        if navigator.command?.busy == true { ProgressView().controlSize(.small) }
        if let error = navigator.command?.problem {
          Button("Copy") {
            model.writePasteboard(error)
          }
          Button("Ask agent") { navigator.send(error) }
        } else if !navigator.viewActions.isEmpty {
          Button("Actions") { navigator.toggleActions(navigator.viewRow) }
        }
      }.buttonStyle(.plain).padding(.horizontal, 20).frame(height: PaletteLayout.header)
      if let error = navigator.command?.problem {
        ScrollView {
          Text(error).font(.system(size: 13)).textSelection(.enabled).frame(
            maxWidth: .infinity, alignment: .leading
          ).padding(.horizontal, 20).padding(.vertical, 18)
        }.frame(height: PaletteLayout.error)
      } else {
        answerBody
      }
    }
  }
  @ViewBuilder private var agentContent: some View {
    if model.agent.question.isEmpty {
      // A draft from the `agent` action or Cmd+Return: nothing is asked yet.
      Text(
        navigator.returnsOnEscape
          ? navigator.askingAbout.map { "\(navigator.askingName) will see what \($0) shows." }
            ?? "Type a question for \(navigator.askingName)."
          : "Press Return to ask \(navigator.askingName), or edit the question first."
      )
      .font(.system(size: textSize.points)).foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 18)
      .frame(height: PaletteLayout.answerMin)
    } else {
      conversation
    }
  }
  private var conversation: some View {
    ScrollView {
      VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 6) {
          if let source = model.agent.source {
            Text("from \(source)").font(.system(size: 11)).foregroundStyle(.tertiary)
          }
          Text(model.agent.question).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            .lineLimit(navigator.questionExpanded ? nil : 2).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
          if longQuestion {
            Button(navigator.questionExpanded ? "Show less" : "Show more") {
              navigator.questionExpanded.toggle()
            }
            .font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(.secondary)
          }
          if let notice = model.agent.notice {
            Text(notice).font(.system(size: 11)).foregroundStyle(.tertiary)
          }
        }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 2)
          .onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: {
            navigator.conversationHeaderHeight = $0
          }
        if let permission = model.agent.permissions.first {
          ConfirmationView(
            content: .agent(permission, name: model.agent.agentName, folder: model.agent.folder),
            size: textSize, decide: { model.agent.decide($0) }
          )
          .id(permission.id).onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: {
            navigator.confirmationHeight = $0
          }
        } else if let problem = model.agent.problem ?? renderer.problem {
          Text(problem).font(.system(size: textSize.points)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 18)
            .frame(minHeight: renderer.height)
        } else if model.agent.busy && model.agent.answer.isEmpty {
          HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(model.agent.status).font(.system(size: textSize.points)).foregroundStyle(.secondary)
          }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 18)
            .frame(height: PaletteLayout.answerMin)
        } else {
          answerBody
        }
      }
    }
  }
  private var longQuestion: Bool {
    (model.agent.question as NSString).boundingRect(
      with: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin], attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]
    ).height > 34
  }
  @ViewBuilder private var answerBody: some View {
    if let page = renderer.page {
      WebView(page).webViewContentBackground(.hidden).frame(height: renderer.height)
    } else {
      Color.clear.frame(height: renderer.height)
    }
  }
  /// Regular (frosted) glass for the search pill and the card alike, tinted with the window background;
  /// Reduce Transparency gets the flat surface.
  @ViewBuilder private func surface(radius: CGFloat) -> some View {
    if flatSurfaces || reduceTransparency {
      RoundedRectangle(cornerRadius: radius).fill(Color(nsColor: .windowBackgroundColor))
    } else {
      Color.clear.glassEffect(
        .regular.tint(
          Color(nsColor: .windowBackgroundColor).opacity(
            0.8 * (1 - model.configuration.backgroundTransparency))),
        in: .rect(cornerRadius: radius, style: .continuous))
    }
  }

  @ViewBuilder private func icon(_ result: Result) -> some View {
    if let url = result.row.actions.first?.fileURL {
      Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
    } else {
      Image(systemName: result.row.icon ?? "app").font(.system(size: 20)).foregroundStyle(
        .secondary)
    }
  }
}

extension RowAction {
  /// The file an open or reveal action is about, whose system icon the row shows.
  var fileURL: URL? {
    switch kind {
    case .open(let url), .reveal(let url): url.isFileURL ? url : nil
    default: nil
    }
  }
  /// The action's own title, or the label of its kind.
  var label: String {
    if let title { return title }
    return switch kind {
    case .open: "Open"
    case .copy: "Copy"
    case .paste: "Paste into previous app"
    case .reveal: "Reveal in Finder"
    case .run(let address):
      address.extensionName == nil ? "Run" : address.targetID == "agent" ? "Ask agent…" : "Open"
    case .send: "Ask"
    case .detail: "Show details"
    case .clip(_, let paste): paste ? "Paste into previous app" : "Copy"
    case .hotkey(_, let record): record ? "Set Hotkey…" : "Remove Hotkey"
    }
  }
  /// The SF Symbol of its kind: its row in the action panel, and a page's target row without an icon.
  var symbol: String {
    switch kind {
    case .open: "link"
    case .copy: "doc.on.doc"
    case .paste: "doc.on.clipboard"
    case .reveal: "folder"
    case .run(let address): address.targetID == "agent" ? "sparkles" : "arrow.right"
    case .send: "sparkles"
    case .detail: "text.page"
    case .hotkey(_, let record): record ? "keyboard" : "xmark.circle"
    case .clip(_, let paste): paste ? "doc.on.clipboard" : "doc.on.doc"
    }
  }
}

extension Navigator {
  /// The list's height: as tall as its rows, or beside a detail always eight rows, so that arrowing
  /// through details of different lengths never changes it; a longer detail scrolls.
  var listHeight: CGFloat {
    PaletteLayout.rowsHeight(
      splits ? 8 : sizedRows, prominentFirst: !splits && prominentFirst,
      rowHeight: configuration.textSize.rowHeight)
  }
  func cardHeight(answer: CGFloat, cap: Double) -> CGFloat {
    let list = listHeight + PaletteLayout.footer
    // The action panel is a list, over whatever it was opened on.
    if actionsTitle != nil { return list }
    if agent.active, agent.question.isEmpty { return PaletteLayout.answerMin + PaletteLayout.footer }
    if agent.active {
      return min(
        560,
        conversationHeaderHeight
          + (agent.permissions.isEmpty
            ? (agent.busy && agent.answer.isEmpty ? PaletteLayout.answerMin : answer)
            : confirmationHeight))
        + PaletteLayout.footer
    }
    if command?.problem != nil { return PaletteLayout.header + PaletteLayout.error + PaletteLayout.footer }
    if page != nil { return PaletteLayout.header + min(answer, CGFloat(cap)) + PaletteLayout.footer }
    return list
  }
}
