import AppKit
import SwiftUI
import ZacroServices

struct NativeAIContextTab: Identifiable, Equatable {
  var id: String
  var title: String
  var url: String
  var profileID: String
  var isPDF: Bool = false
  var isReadable: Bool = true
}

struct NativeAIMessage: Identifiable {
  let id = UUID()
  var role: String
  var text: String
  var requestID: String
  var request: ServiceJSON = [:]
  var result: ServiceJSON = [:]
  var incomplete = false
  var error = false
}

/// Window-owned memory keeps an unfinished question and streamed answer when the Library closes.
/// It is deliberately not persisted to disk and is cleared when the browsing profile changes.
@MainActor final class NativeAIConversationState: ObservableObject {
  @Published var draft = ""
  @Published var savedQuestions: [String] = []
  @Published var messages: [NativeAIMessage] = []
  @Published var grants: [NativeAIContextTab] = []
  @Published var context = "research"
  @Published var busy = false
  @Published var progress = ""
  @Published var notice = ""
  @Published var pendingReview: String?
  private(set) var profileID = ""
  private var requestID = ""
  var sources: [ServiceJSON] { messages.last(where: { $0.role == "assistant" && !$0.error && !$0.incomplete })?.result["sources"].array ?? [] }
  func activate(profileID: String, isPrivate: Bool = false) {
    guard self.profileID != profileID || isPrivate else { return }
    self.profileID = profileID; draft = ""; savedQuestions = []; grants = []; context = "research"; pendingReview = nil; reset()
  }
  func reset() { messages = []; requestID = ""; busy = false; progress = ""; notice = "" }
  func prepare(_ question: String) {
    let question = String(question.prefix(8000))
    if draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { draft = question }
    else if draft != question && !savedQuestions.contains(question) { savedQuestions.append(question) }
  }
  func begin(question: String, request: ServiceJSON) {
    requestID = request["requestId"].string; busy = true; progress = "Preparing your question…"; notice = ""
    messages.append(NativeAIMessage(role:"user",text:question,requestID:requestID,request:request))
    messages.append(NativeAIMessage(role:"assistant",text:"",requestID:requestID))
    if draft.trimmingCharacters(in:.whitespacesAndNewlines) == question { draft = "" }
  }
  func receive(_ event: ServiceJSON) {
    guard event["profileId"].string == profileID else { return }
    if event["type"] == "ai:reset" { reset(); return }
    guard !requestID.isEmpty, event["requestId"].string == requestID,
      let index = messages.lastIndex(where: { $0.role == "assistant" && $0.requestID == requestID }) else { return }
    switch event["type"].string {
    case "ai:progress": progress = event["message"].string
    case "ai:delta": if busy { messages[index].text += event["delta"].string }
    case "ai:answer":
      messages[index].text = event["answer"].string; messages[index].result = event
      messages[index].incomplete = false; messages[index].error = false; busy = false; progress = ""
    case "ai:error":
      if messages[index].text.isEmpty { messages[index].text = event["message"].string; messages[index].error = true }
      else { messages[index].incomplete = true; messages[index].result["warning"] = event["message"] }
      busy = false; progress = ""
    default: break
    }
  }
  func fail(_ error: Error, request: String) {
    guard busy, request == requestID else { return }
    receive(["type":"ai:error","profileId":.string(profileID),"requestId":.string(request),
             "message":.string(error.localizedDescription),"code":.string((error as? ServiceError)?.code ?? "AI")])
  }
}

struct NativeServiceButtonStyle: ButtonStyle {
  var palette: NativeSpacePalette
  var prominent = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size:11,weight:.medium)).padding(.horizontal,9).padding(.vertical,7)
      .foregroundStyle(prominent ? (palette.dark ? Color.black.opacity(0.85) : .white) : palette.ink)
      .background(prominent ? palette.accent.opacity(configuration.isPressed ? 0.8 : 1) : palette.ink.opacity(configuration.isPressed ? 0.13 : 0.06),
                  in:RoundedRectangle(cornerRadius:7))
      .contentShape(RoundedRectangle(cornerRadius:7))
  }
}

struct NativeAIView: View {
  @ObservedObject var model: NativeServicesModel
  let palette: NativeSpacePalette
  var body: some View { NativeAIConversationView(model:model,conversation:model.aiConversation,palette:palette) }
}

private struct NativeAIConversationView: View {
  @ObservedObject var model: NativeServicesModel
  @ObservedObject var conversation: NativeAIConversationState
  let palette: NativeSpacePalette
  @State private var connections = false
  @State private var reviewing = false
  @State private var changingContext = false
  @State private var candidates = Set<String>()
  @State private var reviewContext = "tabs"
  private var privateMode: Bool { model.ai["private"].bool }
  private var configured: Bool { model.ai["configured"].bool }
  private var stale: Bool { conversation.grants.contains { grant in !model.contextTabs.contains(where: { $0.id == grant.id && $0.url == grant.url && $0.profileID == grant.profileID }) } }
  private var locked: Bool { conversation.busy || changingContext }
  private var pages: [NativeAIContextTab] { model.contextTabs.filter { $0.profileID == model.ai["profileId"].string && $0.isReadable && safeURL($0.url) != nil } }
  var body: some View {
    VStack(spacing:0) {
      ScrollViewReader { reader in
        ScrollView {
          VStack(alignment:.leading,spacing:22) {
            if !conversation.savedQuestions.isEmpty { savedQuestions }
            if conversation.messages.isEmpty { welcome }
            ForEach(conversation.messages) { message in messageView(message) }
            if conversation.busy {
              HStack(spacing:7) { ProgressView().controlSize(.mini); Text(conversation.progress).font(.system(size:11)) }
                .foregroundStyle(palette.muted).accessibilityLabel(conversation.progress)
            }
            Color.clear.frame(height:1).id("end")
          }.padding(16)
        }.scrollIndicators(.hidden)
          .onChange(of:conversation.messages.count) { _,_ in withAnimation(.easeOut(duration:0.16)) { reader.scrollTo("end",anchor:.bottom) } }
      }
      if !privateMode { composer }
    }.foregroundStyle(palette.ink).tint(palette.accent).font(.system(size:12))
      .sheet(isPresented:$connections) {
        VStack(alignment:.leading,spacing:16) {
          HStack { Text("AI providers").font(.system(size:16,weight:.semibold)); Spacer(); Button("Done") { connections = false } }
          ScrollView { NativeAIConnectionView(model:model,palette:palette) }
        }.padding(20).frame(width:400,height:580).background(palette.chrome)
      }
      .sheet(isPresented:$reviewing) { contextReview }
      .onAppear { conversation.activate(profileID:model.ai["profileId"].string,isPrivate:privateMode) }
      .onChange(of:model.ai["profileId"]) { _,value in
        conversation.activate(profileID:value.string,isPrivate:privateMode); reviewing = false; connections = false
      }
      .onChange(of:conversation.pendingReview,initial:true) { _,value in
        guard let value else { return }; reviewContext = value; candidates = Set(conversation.grants.map(\.id)); reviewing = true; conversation.pendingReview = nil
      }
  }
  private var welcome: some View {
    VStack(spacing:12) {
      Image(systemName:privateMode ? "lock.shield" : "sparkles").font(.system(size:27)).foregroundStyle(palette.accent)
      Text(privateMode ? "Private session" : "Understand what you’re browsing").font(.system(size:15,weight:.semibold))
      Text(privateMode ? "AI is unavailable in private browsing." : "Choose a starting point and review your question and context before sending.")
        .foregroundStyle(palette.muted).multilineTextAlignment(.center).font(.system(size:11)).lineSpacing(4)
      if !privateMode {
        VStack(spacing:2) {
          intent("Summarize page","doc.text","summarize")
          intent("Explain page","sparkles","explain")
          intent("Compare tabs","rectangle.split.2x1","compare")
          intent(model.ai["researchSupported"] == false ? "Start a chat" : "Research a topic","magnifyingglass","research")
        }.padding(.vertical,2)
        Text("These actions prepare a question. Nothing is shared until you send.").font(.system(size:10)).foregroundStyle(palette.muted).multilineTextAlignment(.center)
      }
    }.frame(maxWidth:.infinity).padding(.top,24)
  }
  private func intent(_ title: String,_ icon: String,_ action: String) -> some View {
    Button { prepare(action) } label: {
      HStack(spacing:9) { Image(systemName:icon).frame(width:16); Text(title); Spacer(); Image(systemName:"arrow.right").font(.system(size:11)) }
        .padding(9).contentShape(RoundedRectangle(cornerRadius:7))
    }.buttonStyle(.plain).disabled(locked).foregroundStyle(palette.ink)
  }
  private var savedQuestions: some View {
    DisclosureGroup("Saved questions (\(conversation.savedQuestions.count))") {
      VStack(alignment:.leading,spacing:10) {
        ForEach(conversation.savedQuestions,id:\.self) { question in
          Text(question).font(.system(size:12))
          HStack {
            Button("Review") {
              let previous = conversation.draft
              conversation.savedQuestions.removeAll { $0 == question }; conversation.draft = question
              if !previous.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && previous != question { conversation.savedQuestions.append(previous) }
            }.disabled(locked)
            Button("Discard") { conversation.savedQuestions.removeAll { $0 == question } }
          }.buttonStyle(NativeServiceButtonStyle(palette:palette))
        }
      }.padding(.top,9)
    }.font(.system(size:11)).foregroundStyle(palette.muted)
  }
  private func messageView(_ message: NativeAIMessage) -> some View {
    VStack(alignment:.leading,spacing:9) {
      Text(message.role == "user" ? "You" : message.error ? "Couldn’t finish" : "Zacro")
        .font(.system(size:10,weight:.semibold)).foregroundStyle(palette.accent)
      if message.role == "user" {
        Label(message.request["contextTabs"].array.isEmpty ? (model.ai["researchSupported"] == false ? "Chat · no page text" : "Web research · no page text") : message.request["contextTabs"].array.map { $0["title"].string }.joined(separator:" · "),systemImage:message.request["contextTabs"].array.isEmpty ? "globe" : "doc.text")
          .font(.system(size:10)).foregroundStyle(palette.muted)
        Text(message.text).textSelection(.enabled).lineSpacing(5).frame(maxWidth:.infinity,alignment:.leading).padding(12)
          .background(palette.accent.opacity(0.075),in:UnevenRoundedRectangle(topLeadingRadius:12,bottomLeadingRadius:12,bottomTrailingRadius:3,topTrailingRadius:12))
      } else {
        Text(attributed(message)).textSelection(.enabled).lineSpacing(6).foregroundStyle(message.error ? Color.red : palette.ink)
          .environment(\.openURL,OpenURLAction { url in
            if url.scheme == "zacro-source", let index = Int(url.lastPathComponent), message.result["citations"].array.indices.contains(index) {
              openSource(message.result["citations"].array[index]); return .handled
            }
            guard safeURL(url.absoluteString) != nil else { return .discarded }
            openSource(["url":.string(url.absoluteString)]); return .handled
          })
      }
      if !message.result["warning"].string.isEmpty { Text(message.result["warning"].string).font(.system(size:10)).foregroundStyle(palette.muted) }
      if !message.result["sharedTabs"].array.isEmpty {
        Text("Read: " + message.result["sharedTabs"].array.map { ($0["title"].string.isEmpty ? $0["url"].string : $0["title"].string) + ($0["truncated"].bool ? " (partial text)" : "") + ($0["pdf"].bool ? " · PDF text" : "") }.joined(separator:", "))
          .font(.system(size:10)).foregroundStyle(palette.muted)
      }
      ForEach(Array(message.result["unreadable"].array.enumerated()),id:\.offset) { _,entry in
        Text("Couldn’t read: \(entry["title"].string) — \(entry["reason"].string)").font(.system(size:10)).foregroundStyle(palette.muted)
      }
      ForEach(Array(message.result["sources"].array.enumerated()),id:\.offset) { index,source in
        Button { openSource(source) } label: {
          HStack(spacing:8) { Text("\(index+1)").foregroundStyle(palette.accent); Text(source["title"].string.isEmpty ? source["url"].string : source["title"].string).lineLimit(1); Spacer(); Image(systemName:"arrow.up.right") }
            .font(.system(size:10)).padding(10).frame(maxWidth:.infinity).background(palette.card.opacity(0.55),in:RoundedRectangle(cornerRadius:9))
        }.buttonStyle(.plain).help(source["url"].string)
      }
      HStack(spacing:4) {
        if message.role == "user" { Button("Edit question") { review(message) }.disabled(locked) }
        if message.role == "assistant" && !message.text.isEmpty && !message.error && !message.incomplete && !conversation.busy {
          Button("Copy answer") {
            let sources = message.result["sources"].array.enumerated().map { index,source in
              "\(index+1). \(source["title"].string) — \(source["url"].string)"
            }.joined(separator:"\n")
            let text = [message.text,message.result["warning"].string,sources.isEmpty ? "" : "Sources\n" + sources].filter { !$0.isEmpty }.joined(separator:"\n\n")
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string)
          }
        }
        if message.error || message.incomplete {
          Button("Retry question") { if let user = conversation.messages.first(where: { $0.role == "user" && $0.requestID == message.requestID }) { review(user,retry:true) } }.disabled(locked)
        }
      }.buttonStyle(NativeServiceButtonStyle(palette:palette))
    }
  }
  private var composer: some View {
    VStack(alignment:.leading,spacing:9) {
      if !configured {
        HStack { Text("Connect to send your question.").font(.system(size:10)).foregroundStyle(palette.muted); Spacer(); Button("Connect AI") { connections = true }.buttonStyle(NativeServiceButtonStyle(palette:palette)) }
      }
      if !conversation.sources.isEmpty && !conversation.busy {
        Button { action("ai:open-sources") } label: { Label("Open sources",systemImage:"arrow.up.right.square").frame(maxWidth:.infinity) }
          .buttonStyle(NativeServiceButtonStyle(palette:palette)).keyboardShortcut(.return,modifiers:.command)
      }
      HStack(spacing:5) {
        Image(systemName:"checkmark.shield").foregroundStyle(palette.muted)
        Picker("Content to share",selection:Binding(get:{ conversation.context },set:{ value in
          if value == "research" { changeContext("research",grants:[]) }
          else { reviewContext = value; candidates = Set(conversation.grants.map(\.id)); reviewing = true }
        })) {
          Text(model.ai["researchSupported"] == false ? "Chat · no page sharing" : "Web research · no page sharing").tag("research")
          Text("One page").tag("page"); Text("Selected tabs").tag("tabs")
        }.labelsHidden().controlSize(.small).disabled(locked)
        if conversation.context != "research" {
          Button { reviewContext = conversation.context; candidates = Set(conversation.grants.map(\.id)); reviewing = true } label: { Image(systemName:"plus") }.buttonStyle(.plain).help("Choose pages").disabled(locked)
          Button { changeContext("research",grants:[]) } label: { Image(systemName:"xmark") }.buttonStyle(.plain).help("Clear shared context and conversation").disabled(locked)
        }
      }.font(.system(size:10))
      if !conversation.grants.isEmpty {
        ScrollView {
          VStack(spacing:5) {
            ForEach(conversation.grants) { page in
              HStack(spacing:6) {
                VStack(alignment:.leading,spacing:2) { Text(page.title).lineLimit(1); Text(URL(string:page.url)?.host ?? page.url).font(.system(size:10)).foregroundStyle(palette.muted).lineLimit(1) }
                Spacer()
                Button { changeContext(conversation.context,grants:conversation.grants.filter { $0.id != page.id }) } label: { Image(systemName:"xmark").font(.system(size:9)) }.buttonStyle(.plain).disabled(locked).help("Remove \(page.title) from context")
              }.font(.system(size:11)).padding(7).background(palette.card.opacity(0.55),in:RoundedRectangle(cornerRadius:7)).help(page.url)
            }
          }
        }.frame(maxHeight:min(145,CGFloat(conversation.grants.count)*45)).scrollIndicators(.hidden)
        Text("On send, readable page or PDF text goes to \(model.ai["providerName"].string). Forms and passwords are excluded.").font(.system(size:10)).foregroundStyle(palette.muted)
      } else {
        Text(model.ai["researchSupported"] == false ? "No web search on this connection. No open-page text is shared." : "Searches the web for supporting sources. No open-page text is shared.").font(.system(size:10)).foregroundStyle(palette.muted)
      }
      if stale {
        HStack { Text("A selected page changed or closed.").font(.system(size:10)); Button("Review again") { reviewContext = conversation.context; candidates = Set(conversation.grants.map(\.id)); reviewing = true }.buttonStyle(.plain) }.foregroundStyle(.red)
      }
      HStack(alignment:.bottom,spacing:5) {
        NativeAIComposer(text:$conversation.draft,placeholder:conversation.messages.isEmpty ? "Ask a question…" : "Ask a follow-up…",color:NSColor(palette.ink),send:submit)
          .frame(minHeight:55,maxHeight:100)
          .overlay(alignment:.topLeading) {
            if conversation.draft.isEmpty { Text(conversation.messages.isEmpty ? "Ask a question…" : "Ask a follow-up…").font(.system(size:12)).foregroundStyle(palette.muted).padding(.leading,8).padding(.top,5).allowsHitTesting(false) }
          }
        Button {
          if conversation.busy { action("ai:cancel") } else { submit() }
        } label: { Image(systemName:conversation.busy ? "stop.fill" : "arrow.up").font(.system(size:12,weight:.semibold)).frame(width:22,height:22) }
          .buttonStyle(NativeServiceButtonStyle(palette:palette,prominent:true))
          .disabled(!conversation.busy && (!configured || locked || stale || conversation.draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty))
          .accessibilityLabel(conversation.busy ? "Stop response" : "Send question")
      }.padding(6).background(palette.card.opacity(0.7),in:RoundedRectangle(cornerRadius:9))
      if !conversation.notice.isEmpty { Text(conversation.notice).font(.system(size:10)).foregroundStyle(palette.muted) }
      Text(configured ? "Enter to send · Shift + Enter for a new line. Check sources." : "Connect AI to send · Shift + Enter for a new line.").font(.system(size:10)).foregroundStyle(palette.muted)
    }.padding(14).background(palette.chrome.opacity(0.18))
  }
  private var contextReview: some View {
    VStack(alignment:.leading,spacing:14) {
      Text(reviewContext == "page" ? "Review page sharing" : "Review selected pages").font(.system(size:16,weight:.semibold))
      Text("Choose up to six pages. These exact addresses and their readable text will be shared only when you send a question.").font(.system(size:12)).foregroundStyle(palette.muted)
      ScrollView {
        VStack(spacing:8) {
          ForEach(pages) { page in
            Toggle(isOn:Binding(get:{ candidates.contains(page.id) },set:{ chosen in
              if chosen { if reviewContext == "page" { candidates = [page.id] } else if candidates.count < 6 { candidates.insert(page.id) } }
              else { candidates.remove(page.id) }
            })) {
              VStack(alignment:.leading,spacing:3) { Text(page.title).fontWeight(.medium); Text(page.url).font(.system(size:10)).foregroundStyle(palette.muted).textSelection(.enabled) }
            }.toggleStyle(.checkbox).padding(8).background(palette.card.opacity(0.5),in:RoundedRectangle(cornerRadius:8))
          }
          if pages.isEmpty { Text("Open a web page or text PDF first.").foregroundStyle(palette.muted) }
        }
      }
      HStack { Button("Cancel") { reviewing = false }; Spacer(); Button("Use selected pages") { changeContext(reviewContext,grants:pages.filter { candidates.contains($0.id) }); reviewing = false }.disabled(candidates.isEmpty) }
        .buttonStyle(NativeServiceButtonStyle(palette:palette))
    }.padding(20).frame(width:460,height:420).background(palette.chrome).foregroundStyle(palette.ink)
  }
  private func prepare(_ intent: String) {
    let prompts = [
      "summarize":"Summarize this page in five concise points. Highlight the main conclusion, useful details, and any important caveats. Cite the page.",
      "explain":"Explain the main ideas on this page in plain language. Define unfamiliar terms and distinguish what the page says from what it does not establish. Cite the page.",
      "compare":"Compare these pages. Organize the key similarities, differences, tradeoffs, and missing information in a concise table. Cite each page and do not guess.",
      "research":"Research "
    ]
    if conversation.draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { conversation.draft = prompts[intent] ?? "" }
    if intent == "research" { changeContext("research",grants:[]) }
    else {
      reviewContext = intent == "compare" ? "tabs" : "page"
      candidates = intent == "compare" ? [] : Set(pages.prefix(1).map(\.id)); reviewing = true
    }
  }
  private func changeContext(_ kind: String, grants: [NativeAIContextTab]) {
    guard !locked else { return }; changingContext = true
    Task {
      defer { changingContext = false }
      do { _ = try await model.aiAction("ai:reset"); conversation.reset(); conversation.context = grants.isEmpty ? "research" : kind; conversation.grants = grants }
      catch { conversation.notice = error.localizedDescription }
    }
  }
  private func review(_ message: NativeAIMessage, retry: Bool = false) {
    guard !locked else { return }
    let grants = message.request["contextTabs"].array.map { NativeAIContextTab(id:$0["id"].string,title:$0["title"].string,url:$0["url"].string,profileID:conversation.profileID) }
    guard grants.allSatisfy({ grant in pages.contains(where: { $0.id == grant.id && $0.url == grant.url }) }) else {
      conversation.notice = "Those pages changed or closed. Review the context before asking again."; return
    }
    if !retry && !conversation.draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && conversation.draft != message.text {
      conversation.notice = "Your unfinished question was kept. Clear it before editing an earlier question."; return
    }
    let context = grants.isEmpty ? "research" : grants.count == 1 ? "page" : "tabs", profile = conversation.profileID
    changingContext = true
    Task {
      defer { changingContext = false }
      do {
        if !retry || conversation.context != context || conversation.grants != grants { _ = try await model.aiAction("ai:reset") }
        guard conversation.profileID == profile else { return }
        conversation.grants = grants; conversation.context = context; changingContext = false
        if retry { submitQuestion(message.text) } else { conversation.draft = message.text }
      } catch { conversation.notice = error.localizedDescription }
    }
  }
  private func submit() { submitQuestion(conversation.draft) }
  private func submitQuestion(_ value: String) {
    let question = value.trimmingCharacters(in:.whitespacesAndNewlines)
    guard !question.isEmpty, !locked, !stale, configured, !privateMode else { return }
    let request: ServiceJSON = ["question":.string(question),"requestId":.string(UUID().uuidString),
      "tabIds":.array(conversation.grants.map { .string($0.id) }),
      "contextTabs":.array(conversation.grants.map { ["id":.string($0.id),"url":.string($0.url),"title":.string($0.title)] })]
    conversation.begin(question:question,request:request)
    Task { do { let answer = try await model.aiAction("ai:ask",payload:request); conversation.receive(answer) } catch { conversation.fail(error,request:request["requestId"].string) } }
  }
  private func action(_ name: String) { Task { do { _ = try await model.aiAction(name) } catch { conversation.notice = error.localizedDescription } } }
  private func openSource(_ source: ServiceJSON) { Task { do { _ = try await model.aiAction("ai:open-source",payload:source) } catch { conversation.notice = error.localizedDescription } } }
  private func safeURL(_ value: String) -> URL? {
    guard let url = URL(string:value), ["https","http"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { return nil }; return url
  }
  private func attributed(_ message: NativeAIMessage) -> AttributedString {
    func formatted(_ value: String) -> AttributedString {
      var result = (try? AttributedString(markdown:value,options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
      for run in result.runs { if let link = run.link, safeURL(link.absoluteString) == nil { result[run.range].link = nil } }
      return result
    }
    let text = message.text as NSString, citations = message.result["citations"].array
    var result = AttributedString(), cursor = 0
    for (index,citation) in citations.enumerated().sorted(by:{ $0.element["end"].int < $1.element["end"].int }) {
      let start = citation["start"].int, end = citation["end"].int
      guard start >= cursor, end >= start, end <= text.length, safeURL(citation["url"].string) != nil else { continue }
      let marker = text.substring(with:NSRange(location:start,length:end-start))
      let replacement = marker.range(of:#"^\[\d+:\d+\]$"#,options:.regularExpression) != nil
      result += formatted(text.substring(with:NSRange(location:cursor,length:(replacement ? start : end)-cursor)))
      var link = AttributedString(" [\(index+1)]"); link.link = URL(string:"zacro-source://citation/\(index)"); result += link; cursor = end
    }
    result += formatted(text.substring(from:cursor)); return result
  }
}

private struct NativeAIComposer: NSViewRepresentable {
  @Binding var text: String
  var placeholder: String
  var color: NSColor
  var send: () -> Void
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView(), editor = NSTextView()
    editor.isRichText = false; editor.drawsBackground = false; editor.font = .systemFont(ofSize:12)
    editor.textContainerInset = NSSize(width:3,height:5); editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
    editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
    editor.delegate = context.coordinator; editor.setAccessibilityLabel("Ask Zacro")
    scroll.documentView = editor; scroll.drawsBackground = false; scroll.hasVerticalScroller = false
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.owner = self
    guard let editor = scroll.documentView as? NSTextView else { return }
    if editor.string != text { editor.string = text }
    editor.textColor = color; editor.setAccessibilityHelp(placeholder)
  }
  final class Coordinator: NSObject, NSTextViewDelegate {
    var owner: NativeAIComposer
    init(_ owner: NativeAIComposer) { self.owner = owner }
    func textDidChange(_ notification: Notification) {
      guard let view = notification.object as? NSTextView else { return }
      if view.string.utf16.count > 8000 { view.string = String(decoding:view.string.utf16.prefix(8000),as:UTF16.self) }
      owner.text = view.string
    }
    func textView(_ textView: NSTextView,doCommandBy commandSelector: Selector) -> Bool {
      if commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText(), NSEvent.modifierFlags.intersection([.shift,.option]).isEmpty { owner.send(); return true }
      return false
    }
  }
}

struct NativeAIConnectionView: View {
  @ObservedObject var model: NativeServicesModel
  let palette: NativeSpacePalette
  @State private var key = ""
  @State private var endpoint = ""
  @State private var selectedModel = ""
  @State private var storage = "encrypted"
  @State private var busy = false
  @State private var error = ""
  @State private var notice = ""
  private var provider: String { model.ai["provider"].string.isEmpty ? "codex" : model.ai["provider"].string }
  private var api: Bool { !["codex","claude-code"].contains(provider) }
  private var connected: Bool { model.ai["configured"].bool }
  private var pending: Bool { model.ai["loginPending"].bool }
  var body: some View {
    VStack(alignment:.leading,spacing:12) {
      if model.ai["private"].bool { Text("AI is unavailable in private browsing.").foregroundStyle(palette.muted) }
      else {
        Picker("Provider",selection:Binding(get:{ provider },set:{ value in perform("ai:configure",payload:["provider":.string(value)]) })) {
          ForEach(NativeAIProvider.allCases,id:\.rawValue) { provider in Text(provider.name).tag(provider.rawValue) }
        }.disabled(busy || model.ai["busy"].bool)
        HStack(spacing:7) {
          Circle().fill(connected ? palette.accent : palette.muted.opacity(0.35)).frame(width:6,height:6)
          Text(connected ? (api ? "Key saved" : model.ai["account"]["email"].string.isEmpty ? "Signed in" : model.ai["account"]["email"].string) : pending ? "Waiting for sign-in…" : "Not connected")
        }.font(.system(size:11))
        if !error.isEmpty || !model.ai["error"].string.isEmpty { Text(error.isEmpty ? model.ai["error"].string : error).font(.system(size:11)).foregroundStyle(.red).textSelection(.enabled) }
        if !notice.isEmpty { Text(notice).font(.system(size:11)).foregroundStyle(palette.muted) }
        if api { apiFields } else { subscriptionFields }
      }
    }.font(.system(size:12)).foregroundStyle(palette.ink).tint(palette.accent)
      .task { populate(); perform("ai:status",payload:["refresh":true]) }
      .onChange(of:model.ai["provider"]) { _,_ in key = ""; populate() }
      .onChange(of:model.ai["profileId"]) { _,_ in key = ""; error = ""; notice = ""; populate() }
      .onChange(of:model.ai["configured"]) { _,_ in populate() }
      .task(id:pending) {
        guard pending else { return }
        while !Task.isCancelled {
          try? await Task.sleep(for:.seconds(1)); if Task.isCancelled { return }
          _ = try? await model.aiAction("ai:status",payload:["refresh":true])
          if !model.ai["loginPending"].bool { return }
        }
      }
  }
  private var apiFields: some View {
    VStack(alignment:.leading,spacing:11) {
      field("API key") { SecureField(connected ? "Leave blank to keep saved key" : "Paste an API key",text:$key) }
      if provider == "compatible" { field("Base URL") { TextField("https://example.com/v1",text:$endpoint) } }
      field("Model") { TextField("Model ID",text:$selectedModel) }
      Picker("Keep key",selection:$storage) { Text("Encrypted on this device").tag("encrypted"); Text("This session only").tag("session") }
      HStack {
        Button("Save connection") {
          var payload: ServiceJSON = ["provider":.string(provider),"model":.string(selectedModel),"storage":.string(storage)]
          if !key.isEmpty { payload["apiKey"] = .string(key) }
          if provider == "compatible" { payload["baseUrl"] = .string(endpoint) }
          perform("ai:configure",payload:payload,message:"Connection saved."); key = ""
        }.buttonStyle(NativeServiceButtonStyle(palette:palette,prominent:true)).disabled(busy)
        if connected { Button("Test connection") { perform("ai:test-connection") }.buttonStyle(NativeServiceButtonStyle(palette:palette)).disabled(busy) }
      }
      if connected { Button("Remove key") { perform("ai:disconnect") }.buttonStyle(NativeServiceButtonStyle(palette:palette)).disabled(busy) }
      Text("Uses your provider’s API billing." + (storage == "session" ? " This key is cleared when Zacro quits." : " Keys are protected by macOS Keychain."))
        .font(.system(size:10)).foregroundStyle(palette.muted)
      if provider == "compatible" { Text("Keys stay with their endpoint. Localhost can run without a key.").font(.system(size:10)).foregroundStyle(palette.muted) }
    }
  }
  private var subscriptionFields: some View {
    VStack(alignment:.leading,spacing:11) {
      if provider == "codex" {
        Picker("Keep sign-in",selection:Binding(get:{ model.ai["credentialStorage"] == "session" ? "session" : "keyring" },set:{ perform("ai:configure",payload:["authStorage":.string($0)]) })) {
          Text("Operating system keychain").tag("keyring"); Text("This session only").tag("session")
        }.disabled(busy || pending || model.ai["busy"].bool)
        Text("Changing storage ends the current sign-in.").font(.system(size:10)).foregroundStyle(palette.muted)
      }
      if !model.ai["storageNotice"].string.isEmpty { Text(model.ai["storageNotice"].string).font(.system(size:10)).foregroundStyle(palette.muted) }
      HStack {
        if connected { Button("Sign out") { perform("ai:disconnect") } }
        else if pending { Button("Cancel sign-in") { perform("ai:login-cancel") } }
        else if model.ai["available"] == false && provider == "claude-code" { Button("Install Claude Code") { perform("ai:install") } }
        else { Button(provider == "codex" ? "Sign in with ChatGPT" : "Sign in with Claude") { perform("ai:login") }.disabled(model.ai["available"] == false) }
        if connected { Button("Test connection") { perform("ai:test-connection") } }
      }.buttonStyle(NativeServiceButtonStyle(palette:palette)).disabled(busy)
      if provider == "codex" && !connected && !pending && model.ai["credentialStorage"] != "session" {
        Button("Use only for this session") {
          busy = true; Task {
            defer { busy = false }
            do { _ = try await model.aiAction("ai:configure",payload:["authStorage":"session"]); _ = try await model.aiAction("ai:login") }
            catch { self.error = error.localizedDescription }
          }
        }.buttonStyle(.plain).font(.system(size:11)).foregroundStyle(palette.accent)
      }
      Text(provider == "codex" ? "Uses your Codex subscription and its usage limits. No API key required." : "Uses your Claude subscription through Claude Code.").font(.system(size:10)).foregroundStyle(palette.muted)
      if connected && !model.ai["models"].array.isEmpty {
        Picker("Model",selection:$selectedModel) {
          ForEach(model.ai["models"].array,id:\.text) { item in Text(item["name"].string.isEmpty ? item["id"].string : item["name"].string).tag(item["id"].string) }
        }
        Button("Use model") { perform("ai:configure",payload:["model":.string(selectedModel)]) }.buttonStyle(NativeServiceButtonStyle(palette:palette)).disabled(busy)
      }
    }
  }
  private func field<Content: View>(_ label: String,@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment:.leading,spacing:5) { Text(label).font(.system(size:11)); content().textFieldStyle(.plain).padding(8).background(palette.card.opacity(0.55),in:RoundedRectangle(cornerRadius:7)) }
  }
  private func populate() {
    endpoint = model.ai["baseUrl"].string; selectedModel = model.ai["model"].string
    if selectedModel.isEmpty { selectedModel = model.ai["models"].array.first(where: { $0["isDefault"].bool })?["id"].string ?? "" }
    storage = model.ai["credentialStorage"] == "session" ? "session" : "encrypted"
  }
  private func perform(_ action: String,payload: ServiceJSON = [:],message: String = "") {
    guard !busy else { return }; busy = true; error = ""; notice = ""
    Task {
      defer { busy = false }
      do { let result = try await model.aiAction(action,payload:payload); notice = result["message"].string.isEmpty ? message : result["message"].string; populate() }
      catch { self.error = error.localizedDescription }
    }
  }
}
