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
    field.clipsToBounds = true
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
  let renderer: AnswerRenderer
  let registerInput: (NSTextField) -> Void
  let run: (RowAction?) -> Void
  var flatSurfaces = false
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
            ForEach(model.declaredArguments, id: \.name) { argumentSlot($0) }
          }
          .frame(height: 30)
          // The free space after the slots belongs to the input.
          .contentShape(Rectangle())
          .onTapGesture { model.focusedArgument = nil }
          if model.configuration.voice.enabled, model.takesSpeech {
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
          if model.agent.active {
            agentContent
          } else if model.command?.problem != nil || model.body != nil {
            extensionContent
          } else {
            ScrollViewReader { proxy in
              ScrollView {
                LazyVStack(spacing: 2) {
                  if model.results.isEmpty {
                    Text(model.command?.busy == true ? "Running…" : "No results").foregroundStyle(.secondary)
                      .frame(height: PaletteLayout.header)
                  }
                  ForEach(model.results) { result in resultRow(result) }
                }.padding(10)
              }
              .frame(
                height: PaletteLayout.rowsHeight(
                  model.sizedRows,
                  prominentFirst: model.prominentFirst, rowHeight: textSize.rowHeight)
              )
              .onChange(of: model.selection) { _, id in if let id { proxy.scrollTo(id) } }
              .onChange(of: model.results.map(\.id)) { _, _ in
                if let id = model.selection { proxy.scrollTo(id) }
              }
            }
          }
          Divider()
          HStack(spacing: 12) {
            Text(
              voiceStatus
                ?? (model.agent.active
                  ? (model.agent.continuing && !model.agent.busy && !model.agent.question.isEmpty
                    ? "Continuing conversation" : (renderer.problem ?? model.agent.status))
                  : (model.problem ?? model.commandName ?? "Wicket"))
            ).lineLimit(1).help(
              voiceStatus ?? (model.agent.active ? model.agent.status : (model.problem ?? "")))
            Spacer()
            if !model.agent.permissions.isEmpty {
              Text("⌘↩ Allow")
              Text("Esc Don't allow")
            } else if model.agent.active {
              if let action = model.selected?.row.actions.first {
                Text("↩ " + action.label)
              } else if model.agent.busy {
                Button("Cancel") { model.agent.cancel() }.buttonStyle(.plain)
              } else if model.agent.question.isEmpty {
                Text("↩ Ask")
              } else {
                Text("↩ Follow up")
              }
              Text(
                model.agent.busy
                  ? "Esc Cancel" : model.agent.question.isEmpty ? "Esc Discard" : "Esc End conversation")
            } else {
              Text("↩ " + (model.selected?.row.actions.first?.label ?? "Enter"))
              Text(model.command == nil ? "esc Close" : "esc Back")
            }
          }
          .font(.system(size: 12)).foregroundStyle(.secondary)
          .padding(.horizontal, 16).frame(height: PaletteLayout.footer - 1)
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
    let placeholder =
      model.agent.active
      ? (model.agent.question.isEmpty ? "Ask \(model.askingName)…" : "Ask a follow-up…")
      : (model.commandName ?? "Search or ask anything…")
    return Text(model.input.isEmpty ? placeholder : String(model.input.prefix(200)))
      .font(.system(size: 21)).lineLimit(1).hidden()
      .padding(.trailing, 8)  // Room for the caret and the field's own inset.
      .frame(minWidth: 0, maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
      .overlay {
        SearchField(
          text: Binding(get: { model.input }, set: { model.editInput($0) }),
          placeholder: placeholder,
          focused: model.focusedArgument == nil,
          onFocus: { if model.focusedArgument != nil { model.focusedArgument = nil } },
          register: registerInput)
      }
  }
  /// A declared argument's slot after the input's text: as wide as its own text within fixed bounds.
  /// Fixed sizes, like the input.
  private func argumentSlot(_ argument: ExtensionManifest.Argument) -> some View {
    let label = argument.placeholder ?? argument.name
    let value = model.argumentValues[argument.name] ?? ""
    return Text(value.isEmpty ? label : value).font(.system(size: 15)).lineLimit(1).hidden()
      .padding(.trailing, 4)  // Room for the caret.
      .frame(minWidth: 24, maxWidth: 150).fixedSize()
      .overlay {
        SearchField(
          text: Binding(get: { value }, set: { model.setArgument(argument.name, to: $0) }),
          placeholder: label, size: 15, focused: model.focusedArgument == argument.name,
          onFocus: {
            if model.focusedArgument != argument.name { model.focusedArgument = argument.name }
          })
      }
      .padding(.horizontal, 9).frame(height: 28)
      .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.08)))
  }
  /// One item row, shared by the list and the items below a body.
  private func resultRow(_ result: Result) -> some View {
    HStack(spacing: 10) {
      icon(result).frame(width: 26, height: 26)
      if result.row.prominent == true, result.id == model.results.first?.id {
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
        if let subtitle = result.row.subtitle, result.provider != "apps" {
          Text(subtitle).font(.system(size: 14 * textSize.scale)).foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      if result.provider == "apps", let subtitle = result.row.subtitle {
        Text(subtitle).font(.system(size: 13 * textSize.scale)).foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 10).frame(
      height: (result.row.prominent == true)
        && result.id == model.results.first?.id ? textSize.rowHeight + 20 : textSize.rowHeight
    )
    .background {
      if result.id == model.selection {
        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(
          .primary.opacity(0.1))
      }
    }
    .contentShape(Rectangle()).id(result.id)
    .onTapGesture(count: 2) {
      model.select(result.id)
      run(nil)
    }
    .onTapGesture { if model.click(result.id) { run(nil) } }
    .contextMenu {
      ForEach(Array(result.row.actions.enumerated()), id: \.offset) { _, action in
        Button(action.label) {
          model.select(result.id)
          run(action)
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(
      result.id == model.selection ? [.isSelected, .isButton] : .isButton)
  }
  private var voiceStatus: String? {
    if model.voice?.state == .starting { return "Starting voice…" }
    if model.voice?.state == .listening { return "Listening…" }
    return model.voice?.problem
  }
  private var cardHeight: CGFloat { model.cardHeight(answer: renderer.height, cap: renderer.cap) }
  private var extensionContent: some View {
    VStack(spacing: 0) {
      HStack {
        Text(model.commandName ?? "Extension").font(.system(size: 13, weight: .medium))
          .lineLimit(1)
        Spacer()
        if model.command?.busy == true { ProgressView().controlSize(.small) }
        if let error = model.command?.problem {
          Button("Copy") {
            model.writePasteboard(error)
          }
          Button("Ask agent") { model.send(error) }
        } else if !model.viewActions.isEmpty {
          Menu("Actions") {
            ForEach(Array(model.viewActions.enumerated()), id: \.offset) { _, action in
              Button(action.label) { run(action) }
            }
          }.menuStyle(.borderlessButton).fixedSize()
        }
      }.buttonStyle(.plain).padding(.horizontal, 18).frame(height: PaletteLayout.header)
      if let error = model.command?.problem {
        ScrollView {
          Text(error).font(.system(size: 13)).textSelection(.enabled).frame(
            maxWidth: .infinity, alignment: .leading
          ).padding(18)
        }.frame(height: PaletteLayout.error)
      } else {
        if model.results.isEmpty {
          answerBody
        } else {
          // One scroll region: the page at its full height, then the native items.
          ScrollViewReader { proxy in
            ScrollView {
              VStack(spacing: 0) {
                answerBody
                itemList
              }
            }
            .onChange(of: model.selection) { _, id in if let id { proxy.scrollTo(id) } }
          }
        }
      }
    }
  }
  /// The native items below a page, shared by a command's view and a conversation's answer.
  private var itemList: some View {
    VStack(spacing: 0) {
      Divider()
      LazyVStack(spacing: 2) { ForEach(model.results) { result in resultRow(result) } }.padding(10)
    }
  }
  private var agentContent: some View {
    ScrollViewReader { proxy in
      agentScroll.onChange(of: model.selection) { _, id in if let id { proxy.scrollTo(id) } }
    }
  }
  @ViewBuilder private var agentScroll: some View {
    if model.agent.question.isEmpty {
      // A draft from the `agent` action: nothing is asked yet.
      Text("Press Return to ask \(model.askingName), or edit the question first.")
        .font(.system(size: textSize.points)).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading).padding(18).frame(height: PaletteLayout.answerMin)
    } else {
      conversation
    }
  }
  private var conversation: some View {
    ScrollView {
      VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 12) {
          if !model.agent.previous.isEmpty {
            DisclosureGroup(
              "Previous questions · \(model.agent.previous.count)", isExpanded: $model.historyExpanded
            ) {
              ForEach(model.agent.previous) { turn in
                VStack(alignment: .leading, spacing: 8) {
                  Text(turn.question).fontWeight(.medium)
                  Text(turn.answer).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
              }
            }.font(.system(size: textSize.points)).foregroundStyle(.secondary)
          }
          HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
              Text(model.agent.question).font(.system(size: 15, weight: .medium))
                .lineLimit(model.questionExpanded ? nil : 2).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
              if longQuestion {
                Button(model.questionExpanded ? "Show less" : "Show more") { model.questionExpanded.toggle() }
                  .font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(.secondary)
              }
            }
            Button {
              model.writePasteboard(model.agent.view.body ?? "")
            } label: {
              Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain).help("Copy answer as Markdown").disabled(model.agent.answer.isEmpty)
          }
        }.padding(.horizontal, 18).padding(.vertical, 16)
          .onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: {
            model.conversationHeaderHeight = $0
          }
        if let permission = model.agent.permissions.first {
          ConfirmationView(
            content: .agent(permission, name: model.agent.agentName, folder: model.agent.folder),
            size: textSize, decide: { model.agent.decide($0) }
          )
          .id(permission.id).onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: {
            model.confirmationHeight = $0
          }
        } else if let problem = model.agent.problem ?? renderer.problem {
          Text(problem).font(.system(size: textSize.points)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(18).frame(minHeight: renderer.height)
        } else if model.agent.busy && model.agent.answer.isEmpty {
          HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(model.agent.status).font(.system(size: textSize.points)).foregroundStyle(.secondary)
          }.frame(maxWidth: .infinity, alignment: .leading).padding(18).frame(height: PaletteLayout.answerMin)
        } else {
          answerBody
          if !model.results.isEmpty { itemList }
        }
      }
    }
  }
  private var longQuestion: Bool {
    (model.agent.question as NSString).boundingRect(
      with: NSSize(width: 560, height: CGFloat.greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin], attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .medium)]
    ).height > 38
  }
  @ViewBuilder private var answerBody: some View {
    if let page = renderer.page {
      WebView(page).webViewContentBackground(.hidden).frame(height: renderer.height)
    } else {
      Color.clear.frame(height: renderer.height)
    }
  }
  @ViewBuilder private func surface(radius: CGFloat) -> some View {
    if flatSurfaces {
      RoundedRectangle(cornerRadius: radius).fill(Color(nsColor: .windowBackgroundColor))
    } else {
      Color.clear.glassEffect(
        .regular.tint(
          Color(nsColor: .windowBackgroundColor).opacity(
            0.55 * (1 - model.configuration.backgroundTransparency))),
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
    }
  }
}

extension LauncherModel {
  /// The native items under a page, with their divider; none when the list is empty.
  var itemsHeight: CGFloat {
    results.isEmpty || agent.problem != nil
      ? 0
      : PaletteLayout.itemsHeight(
        results.count, prominentFirst: prominentFirst, rowHeight: configuration.textSize.rowHeight)
  }
  func cardHeight(answer: CGFloat, cap: Double) -> CGFloat {
    if agent.active, agent.question.isEmpty { return PaletteLayout.answerMin + PaletteLayout.footer }
    if agent.active {
      return min(
        560,
        conversationHeaderHeight
          + (agent.permissions.isEmpty
            ? (agent.busy && agent.answer.isEmpty ? PaletteLayout.answerMin : answer + itemsHeight)
            : confirmationHeight))
        + PaletteLayout.footer
    }
    if command?.problem != nil { return PaletteLayout.header + PaletteLayout.error + PaletteLayout.footer }
    if body != nil {
      return PaletteLayout.header + min(answer + itemsHeight, CGFloat(cap)) + PaletteLayout.footer
    }
    return PaletteLayout.rowsHeight(
      sizedRows, prominentFirst: prominentFirst, rowHeight: configuration.textSize.rowHeight)
      + PaletteLayout.footer
  }
}
