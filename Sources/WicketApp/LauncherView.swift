import AppKit
import SwiftUI
import WebKit

struct SearchField: NSViewRepresentable {
  @Binding var text: String
  let register: (NSTextField) -> Void
  let placeholder: String
  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField(string: "")
    field.isBordered = false
    field.drawsBackground = false
    field.font = .systemFont(ofSize: 21)
    field.textColor = .labelColor
    field.focusRingType = .none
    field.delegate = context.coordinator
    register(field)
    return field
  }
  func updateNSView(_ field: NSTextField, context: Context) {
    context.coordinator.text = $text
    field.placeholderString = placeholder
    field.setAccessibilityLabel(placeholder)
    Self.updateText(text, in: field)
  }
  static func updateText(_ text: String, in field: NSTextField) {
    guard field.stringValue != text else { return }
    field.stringValue = text
    // AppKit selects the whole replacement. Typing after dictation should append at the caret.
    (field.currentEditor() as? NSTextView)?.setSelectedRange(
      NSRange(location: text.utf16.count, length: 0))
  }
  final class Coordinator: NSObject, NSTextFieldDelegate {
    var text: Binding<String>
    init(text: Binding<String>) { self.text = text }
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      // AppKit owns marked text and all composition keystrokes.
      text.wrappedValue = field.stringValue
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
          SearchField(
            text: Binding(get: { model.input }, set: { model.editInput($0) }), register: registerInput,
            placeholder: model.agent.active
              ? "Ask a follow-up…" : (model.commandName ?? "Search or ask anything…")
          ).frame(height: 30)
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
                  ? (model.agent.continuing && !model.agent.busy
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
              } else {
                Text("↩ Follow up")
              }
              Text(model.agent.busy ? "Esc Cancel" : "Esc End conversation")
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
    .onTapGesture { model.select(result.id) }
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
          Button("Ask agent") { model.ask(error) }
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
  private var agentScroll: some View {
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
    switch self {
    case .open(let url), .reveal(let url): url.isFileURL ? url : nil
    default: nil
    }
  }
  var label: String {
    switch self {
    case .open: "Open"
    case .copy: "Copy"
    case .paste: "Paste into previous app"
    case .reveal: "Reveal in Finder"
    case .run(let address):
      switch address.targetID {
      // A command's own run says what it asks for, as a row's ["delete", id] does.
      case nil: address.arguments?.first?.capitalized ?? "Run again"
      case "agent": "Ask agent…"
      default: "Open"
      }
    case .ask: "Ask"
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
