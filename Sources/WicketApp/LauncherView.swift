import AppKit
import SwiftUI
import WebKit

/// An AppKit text field, so input methods, paste and editing shortcuts work: the input and each
/// argument slot. `focused` says whether the model wants it to have the keys; it takes them when that
/// turns true, and reports a click into it through `onFocus`.
struct SearchField: NSViewRepresentable {
  let text: String
  /// An edit of the field by typing, paste or an input method's commit.
  let edit: (InputEdit) -> Void
  let placeholder: String
  var size: CGFloat = 21
  /// Room the field may draw into before, above and below its frame, never after it: AppKit puts the
  /// field editor a few points left of and above the field while editing, so clipping at the frame cut
  /// the first letter. Zero clips at the frame.
  var bleed: CGFloat = 0
  var focused = false
  var onFocus: () -> Void = {}
  var register: (NSTextField) -> Void = { _ in }
  func makeCoordinator() -> Coordinator { Coordinator(text: text, edit: edit) }
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
    context.coordinator.field = field
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
    context.coordinator.text = text
    context.coordinator.edit = edit
    (field as? FocusReportingField)?.onFocus = onFocus
    field.placeholderString = placeholder
    field.setAccessibilityLabel(placeholder)
    context.coordinator.write(text, to: field)
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
  @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
    /// What the model shows, which an edit is made on.
    var text: String
    var edit: (InputEdit) -> Void
    var focused = false
    /// A write that waits for an input method's composition: the field's text without the marked part
    /// and where that part is in it, and what the field was to show.
    private var held: (from: String, marked: Int, to: String)?
    weak var field: NSTextField?
    /// The lowest UTF-16 offset that the field's edits changed since the last one reported. A composition
    /// edits the field without reporting it, from where it replaced the selection, and its commit then
    /// reports only its own end (the caret); the old text alone cannot tell where the replacement began
    /// when it starts with what it replaced (`か` → `かな`).
    private var changedFrom: Int?
    init(text: String, edit: @escaping (InputEdit) -> Void) {
      self.text = text
      self.edit = edit
      super.init()
      NotificationCenter.default.addObserver(
        self, selector: #selector(edited), name: NSTextStorage.didProcessEditingNotification, object: nil)
    }
    /// One field editor serves every field of the panel; only edits of this field's text count.
    @objc private func edited(_ notification: Notification) {
      guard let storage = notification.object as? NSTextStorage,
        storage.editedMask.contains(.editedCharacters),
        let editor = field?.currentEditor() as? NSTextView, editor.textStorage === storage
      else { return }
      changedFrom = min(changedFrom ?? .max, storage.editedRange.location)
    }
    /// Writing the field while an input method composes would commit the composition after the old text,
    /// so the write waits for the commit (`controlTextDidChange`), and the composition goes after the
    /// new text instead, as typing during a screen switch does.
    func write(_ text: String, to field: NSTextField) {
      if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() {
        let marked = editor.markedRange()
        let from = (editor.string as NSString).replacingCharacters(in: marked, with: "")
        held = from == text ? nil : (from, marked.location, text)
        return
      }
      held = nil
      SearchField.updateText(text, in: field)
      changedFrom = nil
    }
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      // AppKit owns marked text and all composition keystrokes.
      let value = field.stringValue
      let from = changedFrom
      defer {
        held = nil
        changedFrom = nil
      }
      if let held {
        // Only what the composition committed, found where it was composed: before the held text's
        // remainder, which is the field's old text, not the model's.
        let end = value.utf16.count - (held.from.utf16.count - held.marked)
        let committed = InputEdit(value, from: held.from, endingAt: end).inserted
        return edit(InputEdit(text: held.to + committed, base: held.to, inserted: committed))
      }
      let caret = (field.currentEditor() as? NSTextView)?.selectedRange().location
      edit(InputEdit(value, from: text, startingBy: from, endingAt: caret))
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

/// The panel's content: the input and its slots, then the card with the screen shown. It draws the
/// presentation the panel committed (`PaletteController.presentation`), reads what is typed and filled in
/// as it is, and sends what the user does to the panel (`PaletteController`) or the navigator.
struct LauncherView: View {
  unowned let panel: PaletteController
  var drawsGlass = true
  private var model: LauncherModel { panel.model }
  private var navigator: Navigator { panel.navigator }
  private var input: PanelInput { panel.input }
  private var recorder: ShortcutRecorder { panel.recorder }
  private var renderer: AnswerRenderer { panel.renderer }
  /// What the screens show, as committed.
  private var shown: PalettePresentation { panel.presentation }
  /// The agent's screen, nil while another one shows.
  private var agent: AgentPresentation? { shown.agent }
  private var textSize: Configuration.TextSize { model.configuration.textSize }
  var body: some View {
    ZStack(alignment: .top) {
      VStack(spacing: PaletteLayout.gap) {
        GlassSurface(role: .pill, radius: 28, configuration: model.configuration, drawsGlass: drawsGlass)
          .frame(height: PaletteLayout.search)
        GlassSurface(role: .card, radius: 22, configuration: model.configuration, drawsGlass: drawsGlass)
          .frame(height: cardHeight)
      }
      VStack(spacing: PaletteLayout.gap) {
        HStack(spacing: 12) {
          Image(systemName: agent != nil ? "sparkles" : "magnifyingglass").font(
            .system(size: 19, weight: .medium)
          ).foregroundStyle(.secondary).frame(width: 24)
          InputBar {
            inputField
            ForEach(navigator.declaredArguments, id: \.name) { argumentSlot($0) }
          }
          .frame(height: 30)
          // The free space after the slots belongs to the input.
          .contentShape(Rectangle())
          .onTapGesture { navigator.focusedArgument = nil }
          if input.offersVoice {
            Button {
              input.toggle()
            } label: {
              Image(systemName: input.voice?.state == .listening ? "mic.fill" : "mic")
                .font(.system(size: 18)).foregroundStyle(input.speaking ? Color.accentColor : Color.secondary)
            }.buttonStyle(.plain)
              .help(input.speaking ? "Stop listening" : "Start listening")
              .accessibilityLabel(input.speaking ? "Stop listening" : "Start listening")
          }
        }
        .padding(.horizontal, 18).frame(height: PaletteLayout.search)

        VStack(spacing: 0) {
          // The action panel lists over a conversation or page, which stay as they were, hidden, for Escape.
          let actions = shown.actionsTitle != nil
          ZStack(alignment: .top) {
            Group {
              if let agent {
                agentContent(agent)
              } else if shown.problem != nil || shown.page != nil {
                extensionContent
              }
            }
            .opacity(actions ? 0 : 1).allowsHitTesting(!actions).accessibilityHidden(actions)
            if shown.splits {
              split
            } else if actions || agent == nil && shown.problem == nil && shown.page == nil {
              list
            }
          }
          .frame(height: actions ? cardHeight - PaletteLayout.footer : nil, alignment: .top).clipped()
          Divider()
          HStack(spacing: 12) {
            if voiceStatus == nil, let agent, agent.footerBusy {
              ProgressView().controlSize(.small).padding(.trailing, -4)
            }
            Text(
              voiceStatus
                ?? (agent.map { renderer.problem ?? $0.footer }
                  ?? (model.problem ?? shown.commandName ?? "Wicket"))
            ).lineLimit(1).help(
              voiceStatus ?? agent.map { renderer.problem ?? $0.footer } ?? model.problem ?? "")
            Spacer()
            if shown.permissionPending {
              Text("⌘↩ Allow")
              Text("Esc Don't allow")
            } else if shown.actionsTitle != nil {
              Text("↩ " + (shown.selected?.row.actions.first?.label ?? "Enter"))
              Text("esc Back")
            } else if let agent {
              if let action = shown.selected?.row.actions.first {
                Text("↩ " + action.label)
              } else if agent.busy {
                Button("Cancel") { navigator.cancelTurn() }.buttonStyle(.plain)
              } else if agent.question.isEmpty {
                Text("↩ Ask")
              } else {
                Text("↩ Follow up")
              }
              if shown.offersActions { Text("⌘K Actions") }
              Text(
                shown.inDetail || shown.returnsOnEscape
                  ? "Esc Back"
                  : agent.busy
                    ? "Esc Cancel" : agent.question.isEmpty ? "Esc Discard" : "Esc End conversation")
            } else {
              if !shown.refusesReturn { Text("↩ " + (shown.selected?.row.actions.first?.label ?? "Enter")) }
              if shown.offersActions { Text("⌘K Actions").lineLimit(1) }
              // The one hint that may grow with a name: it gives way first.
              Text("⌘↩ " + (shown.askingAbout.map { "Ask about \($0)" } ?? "Ask agent")).lineLimit(1)
                .layoutPriority(-1)
              Text(shown.command == nil ? "esc Close" : "esc Back")
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
  private var inputField: some View {
    // The action panel's field is empty and says what the panel is for; typing returns to the input.
    let text = shown.actionsTitle == nil ? navigator.input : ""
    let placeholder =
      shown.actionsTitle.map { "Actions for \($0)" }
      ?? (agent.map {
        $0.question.isEmpty
          ? shown.askingAbout.map { "Ask about \($0)…" } ?? "Ask \(shown.askingName)…"
          : "Ask a follow-up…"
      } ?? (shown.commandName ?? "Search or ask anything…"))
    return Text(text.isEmpty ? placeholder : String(text.prefix(200)))
      .font(.system(size: 21)).lineLimit(1).hidden()
      .padding(.trailing, 8)  // Room for the caret and the field's own inset.
      .frame(minWidth: 0, maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
      .overlay {
        SearchField(
          text: text, edit: { input.edit($0) }, placeholder: placeholder, bleed: 6,
          focused: navigator.focusedArgument == nil,
          onFocus: { if navigator.focusedArgument != nil { navigator.focusedArgument = nil } },
          // The native panel, weakly: the controller owns this view, so capturing it would keep both alive.
          register: { [weak native = panel.panel] in native?.field = $0 })
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
          text: value, edit: { input.edit(argument: argument.name, to: $0.text) }, placeholder: label,
          size: 15, focused: navigator.focusedArgument == argument.name,
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
          if shown.rows.isEmpty {
            Text(shown.showsBusy ? "Running…" : shown.busy || shown.awaitsPattern ? " " : "No results")
              .foregroundStyle(.secondary).frame(height: PaletteLayout.header)
          }
          ForEach(shown.rows) { result in resultRow(result) }
        }.padding(10)
      }
      .frame(height: PaletteLayout.listHeight(shown))
      .onChange(of: shown.selection) { _, id in if let id { proxy.scrollTo(id) } }
      .onChange(of: shown.rows.map(\.id)) { _, _ in
        if let id = shown.selection { proxy.scrollTo(id) }
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
            renderer.renderedTurn.hasPrefix(Navigator.previewTurn(shown.command ?? "", nil)) ? 1 : 0)
      } else {
        Spacer()
      }
    }
    .frame(height: PaletteLayout.listHeight(shown))
  }
  /// One row of the native list. A page draws its own rows in the same metrics (`answers.css`).
  private func resultRow(_ result: Result) -> some View {
    HStack(spacing: 10) {
      icon(result).frame(width: 26, height: 26)
      if result.row.prominent == true, result.id == shown.rows.first?.id {
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
        if let subtitle = result.row.subtitle, result.provider != "apps", !shown.splits {
          Text(subtitle).font(.system(size: 14 * textSize.scale)).foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      if result.provider == "apps", let subtitle = result.row.subtitle {
        Text(subtitle).font(.system(size: 13 * textSize.scale)).foregroundStyle(.secondary)
          .lineLimit(1)
      }
      if recorder.target != nil, recorder.target == navigator.hotkeyTarget(of: result) {
        Text(recorder.rejected ? "Add ⌘, ⌃ or ⌥ · Esc cancels" : "Press a shortcut · Esc cancels")
          .font(.system(size: 13 * textSize.scale)).foregroundStyle(.secondary).lineLimit(1)
      } else if let hotkey = navigator.hotkey(of: result) {
        Text(hotkey.symbols).font(.system(size: 13 * textSize.scale)).foregroundStyle(.tertiary)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 10).frame(
      height: (result.row.prominent == true)
        && result.id == shown.rows.first?.id ? textSize.rowHeight + 20 : textSize.rowHeight
    )
    .background {
      if result.id == shown.selection {
        // Clear glass shows more of what is behind it than the old frosted glass, so the highlight is stronger.
        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(
          .primary.opacity(0.16))
      }
    }
    .contentShape(Rectangle()).id(result.id)
    .onTapGesture(count: 2) {
      navigator.select(result.id)
      panel.run()
    }
    .onTapGesture { if navigator.click(result.id) { panel.run() } }
    .contextMenu {
      ForEach(Array(navigator.actions(of: result).enumerated()), id: \.offset) { _, action in
        Button(action.label) {
          navigator.select(result.id)
          panel.run(action)
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(
      result.id == shown.selection ? [.isSelected, .isButton] : .isButton)
  }
  private var voiceStatus: String? {
    if input.voice?.state == .starting { return "Starting voice…" }
    if input.voice?.state == .listening { return "Listening…" }
    return input.voice?.problem
  }
  private var cardHeight: CGFloat {
    PaletteLayout.cardHeight(shown, answer: renderer.height, cap: renderer.cap)
  }
  private var extensionContent: some View {
    VStack(spacing: 0) {
      HStack {
        Text(shown.commandName ?? "Extension").font(.system(size: 13, weight: .medium))
          .lineLimit(1)
        Spacer()
        if shown.showsBusy { ProgressView().controlSize(.small) }
        if let error = shown.problem {
          Button("Copy") { Pasteboard.write(error) }
          Button("Ask agent") { navigator.send(error) }
        } else if !shown.viewActions.isEmpty {
          Button("Actions") { navigator.toggleActions(shown.viewRow) }
        }
      }.buttonStyle(.plain).padding(.horizontal, 20).frame(height: PaletteLayout.header)
      if let error = shown.problem {
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
  @ViewBuilder private func agentContent(_ agent: AgentPresentation) -> some View {
    if agent.question.isEmpty {
      // A draft from the `agent` action or Cmd+Return: nothing is asked yet.
      Text(
        shown.returnsOnEscape
          ? shown.askingAbout.map { "\(shown.askingName) will see what \($0) shows." }
            ?? "Type a question for \(shown.askingName)."
          : "Press Return to ask \(shown.askingName), or edit the question first."
      )
      .font(.system(size: textSize.points)).foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 18)
      .frame(height: PaletteLayout.answerMin)
    } else {
      conversation(agent)
    }
  }
  private func conversation(_ agent: AgentPresentation) -> some View {
    ScrollView {
      VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 6) {
          if let source = agent.source {
            Text("from \(source)").font(.system(size: 11)).foregroundStyle(.tertiary)
          }
          Text(agent.question).font(.system(size: 13, weight: .medium))
            .lineLimit(agent.expanded ? nil : 2).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
          if Self.isLong(agent.question) {
            Button(agent.expanded ? "Show less" : "Show more") { navigator.toggleQuestion() }
              .font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(.secondary)
          }
          if let notice = agent.notice {
            Text(notice).font(.system(size: 11)).foregroundStyle(.tertiary)
          }
        }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 2)
          .onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: {
            navigator.conversationHeaderHeight = $0
          }
        if let permission = agent.permission {
          ConfirmationView(
            content: .agent(permission, name: agent.agentName, folder: agent.folder),
            size: textSize, decide: { navigator.decide($0) }
          )
          .id(permission.id).onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: {
            navigator.confirmationHeight = $0
          }
        } else if let problem = agent.problem ?? renderer.problem {
          Text(problem).font(.system(size: textSize.points)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 18)
            .frame(minHeight: renderer.height)
        } else if agent.working {
          HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(agent.status).font(.system(size: textSize.points)).lineLimit(1).help(agent.status)
          }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 18)
            .frame(height: PaletteLayout.answerMin)
        } else {
          answerBody
        }
      }
    }
  }
  private static func isLong(_ question: String) -> Bool {
    (question as NSString).boundingRect(
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
    case .grant: "Allow"
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
    case .grant: "lock.open"
    }
  }
}
