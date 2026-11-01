import AppKit
import SwiftUI

// Figma ‘Condux UI 개편’ 시안(https://www.figma.com/design/aLLsfnGuIc8bKcFBf7xlgI)을 옮긴 화면입니다.
// 왼쪽은 대화 목록, 오른쪽은 대화. 연결은 ‘연결 관리’ 창으로, 대화 조작은 입력창 안으로 모았습니다.

// MARK: 왼쪽: 대화 목록

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 22, height: 22)
                Text("Condux").font(.system(size: 15, weight: .bold)).foregroundStyle(ConduxTheme.textPrimary)
            }
            .padding(.horizontal, 4).padding(.top, 4).padding(.bottom, 4)

            newConversationButton
            searchField

            Text(tr("최근 대화")).font(.system(size: 11, weight: .medium)).foregroundStyle(ConduxTheme.textTertiary)
                .padding(.horizontal, 10).padding(.top, 8)
            if model.progress.isBusy {
                Text(tr("답변이 끝나면 다른 대화로 이동할 수 있습니다."))
                    .font(.caption2).foregroundStyle(ConduxTheme.textTertiary).padding(.horizontal, 10)
            }
            conversationList
            connectionFooter
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
        .background(ConduxTheme.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
    }

    private var newConversationButton: some View {
        HStack(spacing: 0) {
            Button { model.startFreshConversation() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                    Text(tr("새 대화")).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("⌘N").font(.system(size: 11)).opacity(0.8)
                }
                .padding(.leading, 12).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("새 대화 화면으로 갑니다. 첫 메시지를 보낼 때 대화가 만들어집니다."))
            Menu {
                ForEach(model.startableProviders, id: \.self) { provider in
                    Button(provider.displayName + tr(" 로 새 대화")) { model.startFreshConversation(provider: provider) }
                }
                if model.startableProviders.isEmpty {
                    Button(tr("연결 관리 열기…")) { model.showConnections = true }
                }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 10)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(tr("어떤 AI 로 시작할지 고릅니다"))
        }
        .foregroundStyle(.white)
        .background(ConduxTheme.blue, in: RoundedRectangle(cornerRadius: 8))
        .opacity(model.progress.isBusy ? 0.5 : 1)
        .disabled(model.progress.isBusy)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(ConduxTheme.textTertiary)
            TextField(tr("대화 검색"), text: Binding(get: { model.searchText }, set: { model.searchText = $0 }))
                .textFieldStyle(.plain).font(.system(size: 12))
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(ConduxTheme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private var conversationList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(model.filteredConversations) { conversation in
                    ConversationRow(conversation: conversation)
                        .contextMenu { contextMenu(for: conversation) }
                }
            }
        }
        .scrollIndicators(.never)
        .confirmationDialog(tr("이 대화를 목록에서 제거할까요?"),
                            isPresented: Binding(get: { model.deleteTargetID != nil }, set: { if !$0 { model.deleteTargetID = nil } }),
                            titleVisibility: .visible) {
            Button(tr("제거"), role: .destructive) {
                if let id = model.deleteTargetID { model.deleteConversation(id) }
                model.deleteTargetID = nil
            }
            Button(tr("취소"), role: .cancel) { model.deleteTargetID = nil }
        } message: {
            Text(tr("앱의 로컬 기록에서만 지웁니다. Codex 서버 기록과 Claude Code 세션 파일은 남고, 받은 파일·첨부 복사본 폴더도 지우지 않습니다."))
        }
        .alert(tr("대화 이름 바꾸기"), isPresented: Binding(get: { model.renameTargetID != nil }, set: { if !$0 { model.renameTargetID = nil } })) {
            TextField(tr("제목"), text: Binding(get: { model.renameDraft }, set: { model.renameDraft = $0 }))
            Button(tr("저장")) { model.commitRename() }
            Button(tr("취소"), role: .cancel) { model.renameTargetID = nil }
        }
    }

    @ViewBuilder
    private func contextMenu(for conversation: StoredConversation) -> some View {
        Button(tr("이름 바꾸기…")) { model.beginRename(conversation.id) }
        Button(tr("마크다운으로 내보내기…")) { model.exportConversationMarkdown(conversation.id) }
        if conversation.provider == .claude, !AppModel.isAppStoreBuild {
            if conversation.hasWorkspace {
                Button(tr("작업 폴더 해제")) { model.setConversationWorkspace(conversation.id, path: nil) }.disabled(model.progress.isBusy)
            } else {
                Button(tr("작업 폴더 연결…")) { model.chooseWorkspace(forConversation: conversation.id) }.disabled(model.progress.isBusy)
            }
        }
        Divider()
        Button(tr("목록에서 제거…")) { model.confirmDelete(conversation.id) }.disabled(model.progress.isBusy)
    }

    /// 맨 아래 연결 상태. 누르면 연결 관리 창이 열립니다.
    private var connectionFooter: some View {
        Button { model.showConnections = true } label: {
            HStack(spacing: 8) {
                if !AppModel.isAppStoreBuild {
                    statusDot("Codex", on: model.connection.isConnected && model.isLoggedIn)
                    statusDot("Claude", on: model.claudeAuth.isLoggedIn)
                }
                statusDot(tr("키 \(model.apiKeyCount)"), on: model.apiKeyCount > 0)
                Spacer()
                Image(systemName: "slider.horizontal.3").font(.system(size: 12)).foregroundStyle(ConduxTheme.textSecondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(ConduxTheme.surface, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr("연결 관리 열기: 로그인, API 키, 작업 폴더, MCP 도구"))
    }

    private func statusDot(_ label: String, on: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(on ? ConduxTheme.ok : ConduxTheme.off).frame(width: 7, height: 7)
            Text(tr(label)).font(.system(size: 11)).foregroundStyle(ConduxTheme.textSecondary).lineLimit(1)
        }
    }
}

/// 대화 목록의 한 줄. 시스템 목록의 선택 상자가 생기지 않게 직접 그립니다.
struct ConversationRow: View {
    @Environment(AppModel.self) private var model
    let conversation: StoredConversation
    @State private var isHovered = false

    private var isSelected: Bool { conversation.id == model.selectedID }

    var body: some View {
        Button { model.select(conversation.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title == "새 대화" ? tr("새 대화") : conversation.title)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                    .foregroundStyle(ConduxTheme.textPrimary)
                HStack(spacing: 4) {
                    if conversation.hasWorkspace {
                        Image(systemName: "folder.fill").font(.system(size: 9))
                    }
                    Text("\(conversation.provider.displayName) · \(conversation.updatedAt.formatted(.relative(presentation: .named).locale(Tr.locale)))")
                        .font(.system(size: 11)).lineLimit(1)
                }
                .foregroundStyle(ConduxTheme.textTertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? ConduxTheme.selected : (isHovered ? ConduxTheme.surface : Color.clear),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
    }
}

// MARK: 오른쪽: 대화

struct ConversationView: View {
    @Environment(AppModel.self) private var model

    private var showsStart: Bool { model.selectedID == nil || model.entries.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            if let notice = model.notice {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(ConduxTheme.blue)
                    Text(tr(notice)).font(.system(size: 12)).textSelection(.enabled)
                    Spacer()
                    Button { model.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(ConduxTheme.surface)
            }
            if showsStart {
                StartView()
            } else {
                messages
                VStack(spacing: 6) {
                    StatusLine()
                    ComposerView().frame(maxWidth: 760)
                }
                .padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 12)
            }
        }
        .background(ConduxTheme.canvas)
        // 대화 화면 어디에 놓아도 첨부됩니다.
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.progress.isBusy else { return false }
            Task {
                guard await model.ensureConversation() else { return }
                model.addAttachments(urls: urls)
            }
            return true
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(model.entries) { entry in
                        EntryRow(entry: entry, assistantName: model.selectedProvider.displayName).id(entry.id)
                    }
                }
                .font(.system(size: 14))
                .frame(maxWidth: 720)
                .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 16)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.entries.last?.text) { _, _ in scrollToEnd(proxy) }
            .onChange(of: model.entries.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: model.selectedID) { _, _ in scrollToEnd(proxy) }
            .onAppear { scrollToEnd(proxy) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if let last = model.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
    }
}

/// 대화가 비어 있을 때: 가운데 입력창과 예시 질문.
struct StartView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let provider = model.composerProvider
        let hasWorkspace = model.composerHasWorkspace
        ScrollView {
            VStack(spacing: 14) {
                Text(tr("무엇을 해 드릴까요?")).font(.system(size: 26, weight: .bold)).foregroundStyle(ConduxTheme.textPrimary)
                Text(hasWorkspace
                     ? tr("AI 가 폴더 안 파일을 읽고, 고치거나 명령을 실행할 때는 먼저 허용을 묻습니다.")
                     : (provider == .localLLM ? tr("이 Mac 에서 글로만 대화합니다. 짧은 질문이나 요약할 글을 입력해 주세요.")
                        : tr("짧게 물어봐도 됩니다. 사진·PDF 를 붙이면 그걸 보고 답합니다.")))
                    .font(.system(size: 13)).foregroundStyle(ConduxTheme.textSecondary).multilineTextAlignment(.center)
                ComposerView()
                VStack(spacing: 0) {
                    ForEach(FriendlyText.examplePrompts(provider: provider, hasWorkspace: hasWorkspace), id: \.self) { prompt in
                        Button { model.draft = prompt } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "text.bubble").font(.system(size: 12)).foregroundStyle(ConduxTheme.textTertiary)
                                Text(prompt).font(.system(size: 13)).foregroundStyle(ConduxTheme.textSecondary).multilineTextAlignment(.leading)
                                Spacer()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                GettingStartedBox()
                Text(provider == .localLLM ? tr("Enter 보내기 · Shift+Enter 줄바꿈") : FriendlyText.composerHint)
                    .font(.caption2).foregroundStyle(ConduxTheme.textTertiary)
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 28).padding(.vertical, 40)
            .frame(maxWidth: .infinity, minHeight: 620)
        }
        .defaultScrollAnchor(.center)
    }
}

/// 입력창 위 한 줄: 진행 상태, 승인 대기, 비용.
struct StatusLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            if model.progress.isBusy {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(dotColor).frame(width: 7, height: 7)
            }
            Text(tr(model.relay?.isActive == true ? (model.relay?.statusText ?? "") : model.progress.phase))
                .lineLimit(1)
            if model.hasPendingApproval {
                Text(tr("· 승인을 기다리는 중")).foregroundStyle(ConduxTheme.warn)
            }
            if let started = model.progress.startedAt, model.progress.isBusy {
                Text("·")
                Text(started, style: .timer).monospacedDigit()
            }
            if !model.apiCostSummary.isEmpty {
                Text("· " + tr(model.apiCostSummary))
                    .lineLimit(1)
                    .foregroundStyle(model.apiBudgetExhausted ? ConduxTheme.warn : ConduxTheme.textTertiary)
                    .help(tr("공식 요율표로 계산한 추정치라 실제 청구와 다를 수 있습니다"))
                if model.apiBudgetExhausted {
                    Button(tr("예산 +$1")) { model.raiseAPIBudget() }.controlSize(.mini)
                }
            }
            if model.selectedProvider == .claude, !model.claudeUsageSummary.isEmpty {
                Text("· " + tr(model.claudeUsageSummary))
                    .lineLimit(1)
            }
            if model.selectedConversation != nil, model.selectedProvider != .localLLM {
                UsageChip()
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(ConduxTheme.textTertiary)
    }

    private var dotColor: Color {
        switch model.progress.state {
        case .completed: return ConduxTheme.ok
        case .failed: return .red
        case .interrupted: return ConduxTheme.warn
        default: return ConduxTheme.off
        }
    }
}

/// 상태 줄의 사용량 버튼. 누르면 컨텍스트와 사용량을 자세히 보여줍니다.
struct UsageChip: View {
    @Environment(AppModel.self) private var model
    @State private var isOpen = false

    var body: some View {
        let percent = model.selectedUsage.contextPercent ?? 0
        Button { isOpen.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                Text(tr(model.usageChipText))
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(percent >= 80 ? ConduxTheme.warn : ConduxTheme.textSecondary)
            .background(ConduxTheme.raised, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tr("이 대화의 컨텍스트와 사용량 보기"))
        .popover(isPresented: $isOpen, arrowEdge: .top) { UsageDetails().environment(model) }
    }
}

struct UsageDetails: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let usage = model.selectedUsage
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("사용량")).font(.system(size: 14, weight: .semibold))
            section(tr("컨텍스트"), note: tr("AI 가 이 대화에서 한 번에 기억하는 양입니다. 가득 차면 답이 실패하거나 앞부분을 잊을 수 있으니 새 대화를 시작하세요.")) {
                if let window = usage.contextWindow, let percent = usage.contextPercent {
                    ProgressView(value: Double(usage.contextTokens), total: Double(window))
                        .tint(percent >= 80 ? ConduxTheme.warn : ConduxTheme.blue)
                    value(tr("\(Self.number(usage.contextTokens)) / \(Self.number(window)) 토큰 (\(percent)%)"))
                } else if usage.contextTokens > 0 {
                    value(tr("\(Self.number(usage.contextTokens)) 토큰 · 이 모델의 한도는 알 수 없습니다"))
                } else {
                    value(tr("첫 답변이 끝나면 표시합니다."))
                }
            }
            if usage.hasData {
                section(tr("이 대화에서 주고받은 토큰"), note: tr("메시지를 보낼 때마다 앞선 대화도 함께 보내므로 보낸 토큰은 빠르게 늘어납니다.")) {
                    value(tr("보냄 \(Self.number(usage.totalInputTokens)) · 받음 \(Self.number(usage.totalOutputTokens))"))
                }
            }
            if !model.apiCostSummary.isEmpty {
                section(tr("비용"), note: tr("공식 요율표로 계산한 추정치라 실제 청구와 다를 수 있습니다")) {
                    value(tr(model.apiCostSummary))
                }
            }
            if model.selectedProvider == .claude || model.selectedProvider == .codex {
                section(tr("구독"), note: tr("구독은 달러 비용 대신 한도를 얼마나 썼는지만 표시합니다.")) {
                    value(model.subscriptionUsageSummary.isEmpty ? tr("메시지를 보내면 표시합니다.") : tr(model.subscriptionUsageSummary))
                }
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    private func section<Content: View>(_ title: String, note: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(ConduxTheme.textTertiary)
            content()
            Text(note).font(.system(size: 11)).foregroundStyle(ConduxTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func value(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(ConduxTheme.textPrimary).textSelection(.enabled)
    }

    private static func number(_ value: Int) -> String { value.formatted(.number.locale(Locale(identifier: "en_US"))) }
}

// MARK: 입력창

/// 입력창 안의 작은 버튼 모양.
struct ComposerChip: View {
    let icon: String
    let label: String
    var tint: Color = ConduxTheme.textSecondary

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(tint)
            Text(tr(label)).font(.system(size: 12, weight: .medium)).foregroundStyle(ConduxTheme.textPrimary).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(ConduxTheme.raised, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }
}

/// 입력창의 Shift+Enter(줄바꿈)와 ⌘V·Ctrl+V(이미지 붙여넣기). 입력칸이 시스템 편집기를 쓰기 때문에 키를 앱 안에서 먼저 받습니다.
@MainActor
enum ComposerKeyMonitor {
    static var pasteboard = NSPasteboard.general
    private static var monitor: Any?

    static func install(model: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] event in
            guard let model else { return event }
            return MainActor.assumeIsolated { handle(event, model: model) ? nil : event }
        }
    }

    private static func handle(_ event: NSEvent, model: AppModel) -> Bool {
        guard let window = event.window ?? NSApp.keyWindow, window.attachedSheet == nil, window.sheetParent == nil else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let editor = window.firstResponder as? NSTextView
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, flags == .shift, model.composerIsFocused, let editor {
            if editor.hasMarkedText() { editor.unmarkText() } // 조합 중인 한글을 먼저 확정합니다.
            editor.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        // V 자리의 키. 한글 입력 상태에서도 같은 키입니다.
        guard event.keyCode == 9, flags == .command || flags == .control else { return false }
        let editingElsewhere = editor != nil && !model.composerIsFocused
        guard !editingElsewhere else { return false }
        if ClipboardContent.isAttachable(pasteboard), !model.progress.isBusy {
            let source = pasteboard
            Task {
                guard await model.ensureConversation() else { return }
                model.pasteAttachments(from: source)
            }
            return true
        }
        if flags == .control, let editor { editor.paste(nil); return true }
        return false
    }
}

enum ClipboardContent {
    /// 첨부로 붙일 내용인지. 파일은 항상, 이미지는 글이 함께 없을 때만 그렇습니다(엑셀 복사처럼 글과 그림이 같이 있으면 글로 붙입니다).
    static func isAttachable(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        guard NSImage.canInit(with: pasteboard) else { return false }
        let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty || (text.lowercased().hasPrefix("http") && !text.contains(where: \.isWhitespace))
    }
}

struct ComposerView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var isFocused: Bool
    @State private var showRelay = false
    @State private var showFolder = false

    private var isLocal: Bool { model.composerProvider == .localLLM }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            if !model.pendingAttachments.isEmpty { attachments }
            TextField(model.composerHasWorkspace ? tr("무엇을 해 드릴까요?") : tr("무엇이든 물어보세요."),
                      text: $model.draft, axis: .vertical)
                .lineLimit(1...8)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($isFocused)
                .onChange(of: isFocused) { _, focused in model.composerIsFocused = focused }
                .onDisappear { model.composerIsFocused = false }
                .onSubmit { Task { await model.sendFromComposer() } }
            toolRow
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.top, 12).padding(.bottom, 10)
        .background(ConduxTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(ConduxTheme.borderStrong, lineWidth: 1))
        .task(id: model.selectedID) {
            isFocused = true // 대화를 고르면 바로 입력할 수 있게 합니다.
            await model.refreshBuildCommand()
        }
    }

    private var attachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.pendingAttachments) { attachment in
                    HStack(spacing: 4) {
                        if attachment.kind.isImage, let image = NSImage(contentsOfFile: attachment.path) {
                            Image(nsImage: image).resizable().scaledToFill().frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            Image(systemName: attachment.kind.systemImage).font(.caption)
                        }
                        Text(attachment.name).font(.caption).lineLimit(1)
                        Text(attachment.sizeText).font(.caption2).foregroundStyle(.secondary)
                        Button { model.removeAttachment(id: attachment.id) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(ConduxTheme.raised, in: RoundedRectangle(cornerRadius: 7))
                    .help(attachment.path)
                }
            }
        }
    }

    private var toolRow: some View {
        HStack(spacing: 6) {
            Button {
                Task {
                    guard await model.ensureConversation() else { return }
                    model.attachFiles()
                }
            } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(ConduxTheme.textSecondary)
                    .frame(width: 26, height: 24)
                    .background(ConduxTheme.raised, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(model.progress.isBusy || isLocal)
            .help(isLocal ? tr("시험용 로컬 AI 는 글로만 대화합니다.")
                  : tr("PNG·JPEG·PDF·ZIP 파일을 첨부합니다. 끌어다 놓거나, 복사한 스크린샷을 ⌘⇧V 로 붙여도 됩니다."))
            folderChip
            if !isLocal {
                Button { showRelay.toggle() } label: {
                    ComposerChip(icon: "arrow.triangle.2.circlepath", label: model.relayChipText,
                                 tint: model.relayIsActive ? ConduxTheme.warn : ConduxTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(FriendlyText.relayHint)
                .popover(isPresented: $showRelay, arrowEdge: .top) { RelayPopover() }
            }
            if let received = model.selectedConversation?.receivedFiles, !received.isEmpty {
                Button { model.revealReceivedFolder() } label: {
                    ComposerChip(icon: "arrow.down.doc", label: tr("받은 파일 \(received.count)"))
                }
                .buttonStyle(.plain).help(tr("받은 파일 폴더를 Finder 로 엽니다"))
            }
            Spacer(minLength: 8)
            providerChip
            sendButton
        }
    }

    @ViewBuilder
    private var folderChip: some View {
        if AppModel.isAppStoreBuild || isLocal || model.composerProvider.isDirectAPI {
            EmptyView()
        } else if let conversation = model.selectedConversation, !model.entries.isEmpty || conversation.hasWorkspace {
            if conversation.hasWorkspace {
                Button { showFolder.toggle() } label: {
                    ComposerChip(icon: "folder.fill", label: (conversation.workspacePath as NSString).lastPathComponent, tint: ConduxTheme.blue)
                }
                .buttonStyle(.plain)
                .help(conversation.workspacePath)
                .popover(isPresented: $showFolder, arrowEdge: .top) { FolderPopover() }
            } else if conversation.provider == .claude {
                Button { model.chooseWorkspace(forConversation: conversation.id) } label: {
                    ComposerChip(icon: "folder", label: tr("폴더 연결"))
                }
                .buttonStyle(.plain).disabled(model.progress.isBusy)
                .help(tr("이 대화에 프로젝트 폴더를 연결합니다. 다음 전송부터 파일을 읽고 고칠 수 있습니다."))
            }
        } else {
            Menu {
                Button(tr("폴더 선택…")) { model.chooseWorkspace() }
                if !model.workspacePath.isEmpty { Button(tr("폴더 해제")) { model.clearWorkspace() } }
            } label: {
                ComposerChip(icon: model.workspacePath.isEmpty ? "folder" : "folder.fill",
                             label: model.workspacePath.isEmpty ? tr("폴더 없음") : (model.workspacePath as NSString).lastPathComponent,
                             tint: model.workspacePath.isEmpty ? ConduxTheme.textSecondary : ConduxTheme.blue)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help(tr("AI 가 읽고 고칠 프로젝트 폴더. 새 대화에 적용됩니다."))
        }
    }

    @ViewBuilder
    private var providerChip: some View {
        if model.selectedID == nil {
            Menu {
                ForEach(model.startableProviders, id: \.self) { provider in
                    Button(provider.displayName) { model.startProvider = provider }
                }
                Divider()
                Button(tr("연결 관리 열기…")) { model.showConnections = true }
            } label: {
                ComposerChip(icon: "chevron.down", label: model.composerProvider.displayName)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help(tr("이번 대화에 쓸 AI 를 고릅니다"))
        } else {
            Button { model.showSettings = true } label: {
                ComposerChip(icon: "cpu", label: model.composerModelLabel)
            }
            .buttonStyle(.plain)
            .help(tr("모델을 바꾸려면 누르세요. 대화의 AI 연결은 바꿀 수 없습니다."))
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if model.progress.isBusy {
            Button { Task { await model.interrupt() } } label: {
                Image(systemName: "stop.fill").font(.system(size: 10)).foregroundStyle(ConduxTheme.textPrimary)
                    .frame(width: 28, height: 28).background(ConduxTheme.raised, in: Circle()).contentShape(Circle())
            }
            .buttonStyle(.plain).keyboardShortcut(".", modifiers: .command).help(tr("중단 (⌘.)"))
        } else {
            Button { Task { await model.sendFromComposer() } } label: {
                Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(model.composerCanSend ? Color.white : ConduxTheme.textTertiary)
                    .frame(width: 28, height: 28)
                    .background(model.composerCanSend ? ConduxTheme.blue : ConduxTheme.raised, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.composerCanSend)
            .help(tr("보내기 (Enter)"))
        }
    }
}

// MARK: 입력창 팝오버

struct RelayPopover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("자동 릴레이")).font(.system(size: 14, weight: .bold))
            Text(tr("한 AI 가 만들고 다른 AI 가 검토해 고칠 점을 돌려주는 걸 자동으로 반복합니다. 명령 실행은 직접 허용합니다."))
                .font(.system(size: 12)).foregroundStyle(ConduxTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if let state = model.relay, state.isActive {
                Text(tr(state.statusText)).font(.system(size: 12, weight: .medium)).foregroundStyle(ConduxTheme.warn)
                Button(tr("릴레이 중단")) { model.stopRelay() }
            } else if model.availableReviewers.isEmpty {
                Text(tr("검토자로 쓸 API 키가 필요합니다. 연결 관리에서 Claude API 나 OpenAI API 키를 넣어 주세요."))
                    .font(.system(size: 12)).foregroundStyle(ConduxTheme.warn).fixedSize(horizontal: false, vertical: true)
                Button(tr("연결 관리 열기")) { model.showConnections = true }
            } else {
                row(tr("검토자")) {
                    Picker("", selection: $model.relayReviewer) {
                        ForEach(model.availableReviewers, id: \.self) { provider in Text(provider.displayName).tag(provider) }
                    }
                    .labelsHidden().fixedSize()
                }
                row(tr("최대 횟수")) {
                    Stepper(tr("\(model.relayMaxRounds)회"), value: $model.relayMaxRounds, in: 1...5).fixedSize()
                }
                row(tr("파일 수정 자동 허용")) { Toggle("", isOn: $model.relayAutoApproveEdits).labelsHidden().toggleStyle(.switch).controlSize(.mini) }
                row(tr("자동 수정")) { Toggle("", isOn: $model.relayAutoFix).labelsHidden().toggleStyle(.switch).controlSize(.mini) }
                    .help(tr("끄면 검토 의견을 입력창에만 넣고 멈춥니다. 보내기를 누르면 수정 요청이 갑니다."))
                if model.composerHasWorkspace {
                    row(tr("빌드 자동 확인")) { Toggle("", isOn: $model.relayAutoBuild).labelsHidden().toggleStyle(.switch).controlSize(.mini) }
                        .help(tr("구현이 끝날 때마다 빌드하고, 실패하면 검토자 없이 오류를 바로 수정 요청합니다."))
                }
                Button {
                    Task { await model.startRelayFromComposer() }
                } label: {
                    Text(model.draft.trimmingCharacters(in: .whitespaces).isEmpty ? tr("먼저 입력창에 지시를 쓰세요") : tr("이 내용으로 릴레이 시작"))
                        .font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.draft.trimmingCharacters(in: .whitespaces).isEmpty || model.progress.isBusy)
                if let state = model.relay {
                    Text(tr(state.statusText)).font(.system(size: 11)).foregroundStyle(ConduxTheme.textTertiary).lineLimit(2)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(tr(label)).font(.system(size: 13))
            Spacer()
            content()
        }
    }
}

/// 작업 폴더 대화의 빌드·변경 파일.
struct FolderPopover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let conversation = model.selectedConversation
        let path = conversation?.workspacePath ?? ""
        VStack(alignment: .leading, spacing: 10) {
            Text((path as NSString).lastPathComponent).font(.system(size: 14, weight: .bold))
            Text(path).font(.system(size: 12)).foregroundStyle(ConduxTheme.textTertiary).lineLimit(2).textSelection(.enabled)
            HStack {
                Text(tr("파일 수정 자동 허용")).font(.system(size: 13))
                Spacer()
                Toggle("", isOn: $model.autoApproveEdits).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
            .help(tr("이 폴더 안의 파일 수정은 묻지 않고 허용합니다. 백업·되돌리기는 그대로이고 명령 실행은 항상 묻습니다."))
            Divider()
            Text(tr("빌드")).font(.system(size: 12, weight: .medium)).foregroundStyle(ConduxTheme.textSecondary)
            TextField(model.buildCommandDetecting ? tr("빌드 명령 찾는 중…") : tr("빌드 명령 (예: swift build)"), text: $model.buildCommandDraft)
                .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                .onSubmit { model.saveBuildCommand() }
                .disabled(model.buildRunning)
            HStack(spacing: 8) {
                if model.buildRunning {
                    ProgressView().controlSize(.small)
                    Button(tr("중단")) { model.cancelBuild() }
                } else {
                    Button(tr("빌드 실행")) { Task { await model.runBuild() } }
                        .disabled(model.buildCommandDraft.trimmingCharacters(in: .whitespaces).isEmpty || model.progress.isBusy)
                }
                if let result = model.lastBuildResult, !model.buildRunning {
                    Text(tr(result.statusText)).font(.system(size: 12))
                        .foregroundStyle(result.succeeded ? ConduxTheme.ok : ConduxTheme.warn).lineLimit(1)
                    if !result.succeeded {
                        Button(tr("오류를 AI에게 보내기")) { model.insertBuildErrorsIntoDraft() }.disabled(model.progress.isBusy)
                    }
                }
            }
            .controlSize(.small)
            if let records = conversation?.changeRecords, !records.isEmpty {
                Divider()
                Text(tr("변경된 파일 \(records.count)개")).font(.system(size: 12, weight: .medium)).foregroundStyle(ConduxTheme.textSecondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(records.reversed()) { record in
                            HStack(spacing: 8) {
                                Text((record.path as NSString).lastPathComponent).font(.system(size: 12)).lineLimit(1)
                                Spacer()
                                if record.reverted {
                                    Text(tr("되돌림")).font(.system(size: 11)).foregroundStyle(ConduxTheme.textTertiary)
                                } else {
                                    Button(tr("되돌리기")) { model.revert(changeRecordID: record.id) }
                                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(ConduxTheme.blue)
                                }
                            }
                            .help(record.path)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

// MARK: 시작하기

/// 처음 쓰는 사람을 위한 체크리스트. 할 일이 남았을 때만 보입니다.
struct GettingStartedBox: View {
    @Environment(AppModel.self) private var model

    private struct Step: Identifiable { let id: String; let done: Bool; let text: String; let action: (() -> Void)? }

    private var steps: [Step] {
        var list: [Step] = []
        if AppModel.isAppStoreBuild {
            list.append(Step(id: "key", done: model.apiKeyCount > 0,
                             text: tr("API 키 넣기 (Anthropic 또는 OpenAI 사이트에서 발급)"), action: { model.showConnections = true }))
        } else {
            list.append(Step(id: "login", done: model.connection.isConnected && model.isLoggedIn || model.claudeAuth.isLoggedIn || model.apiKeyCount > 0 || model.localModelReady,
                             text: tr("Codex·Claude 에 로그인하거나 API 키 넣기"), action: { model.showConnections = true }))
            list.append(Step(id: "folder", done: !model.workspacePath.isEmpty,
                             text: tr("AI 가 일할 프로젝트 폴더 고르기 (선택)"), action: { model.chooseWorkspace() }))
        }
        list.append(Step(id: "chat", done: !model.conversations.isEmpty, text: tr("위 입력창에 첫 질문 보내기"), action: nil))
        return list
    }

    var body: some View {
        let all = steps
        if all.contains(where: { !$0.done }) {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("시작하기 · \(all.filter(\.done).count)/\(all.count) 완료")).font(.system(size: 12, weight: .medium)).foregroundStyle(ConduxTheme.textSecondary)
                ForEach(all) { step in
                    HStack(spacing: 8) {
                        Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12)).foregroundStyle(step.done ? ConduxTheme.ok : ConduxTheme.textTertiary)
                        if let action = step.action, !step.done {
                            Button(step.text, action: action).buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(ConduxTheme.textPrimary)
                        } else {
                            Text(step.text).font(.system(size: 13)).foregroundStyle(step.done ? ConduxTheme.textTertiary : ConduxTheme.textPrimary)
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ConduxTheme.sidebar, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(ConduxTheme.borderSubtle, lineWidth: 1))
        }
    }
}

// MARK: 활동 항목

/// 도구 호출·생각 정리 같은 중간 과정. 접혀 있고 누르면 펼쳐집니다.
struct ActivityRow: View {
    @Environment(AppModel.self) private var model
    let entry: ChatEntry
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { withAnimation(.easeOut(duration: 0.12)) { isOpen.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(isOpen ? 90 : 0)).foregroundStyle(ConduxTheme.textTertiary)
                        if entry.changeRecordID != nil {
                            Image(systemName: "doc.badge.clock").font(.system(size: 11)).foregroundStyle(ConduxTheme.textTertiary)
                        }
                        Text(tr(FriendlyText.activityTitle(entry.title))).font(.system(size: 12)).foregroundStyle(ConduxTheme.textSecondary).lineLimit(1)
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let recordID = entry.changeRecordID, let record = model.changeRecord(id: recordID), !record.reverted {
                    Button(tr("되돌리기")) { model.revert(changeRecordID: recordID) }.controlSize(.mini)
                }
                Text(tr(entry.status)).font(.system(size: 11)).foregroundStyle(statusColor).lineLimit(1)
            }
            if isOpen {
                Text(entry.text.isEmpty ? tr("(내용 없음)") : entry.text)
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(ConduxTheme.textSecondary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ConduxTheme.sidebar, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var statusColor: Color {
        switch entry.status {
        case "승인", "성공": return ConduxTheme.ok
        case "수정 필요", "대기 중", "빌드 실패": return ConduxTheme.warn
        case "실패", "오류": return .red
        default: return ConduxTheme.textTertiary
        }
    }
}

// MARK: 연결 관리 창

struct ConnectionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(tr("연결 관리")).font(.system(size: 18, weight: .bold))
                Spacer()
                Button(tr("고급 설정…")) { showAdvanced = true }
                Button(tr("닫기")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(tr("AI 와 도구를 여기서 연결합니다. 하나만 연결해도 바로 쓸 수 있습니다."))
                        .font(.system(size: 13)).foregroundStyle(ConduxTheme.textSecondary)
                    recommendedCard
                    if !AppModel.isAppStoreBuild { subscriptionGroup }
                    apiGroup
                    if !AppModel.isAppStoreBuild {
                        macGroup
                        group(tr("도구 (MCP)")) {
                            MCPServersBox().padding(14)
                        }
                    }
                    if AppModel.isAppStoreBuild {
                        Text(tr("앱스토어판에는 구독 연결, 작업 폴더, MCP 도구(Figma·Mobbin·Xcode), 로컬 AI 가 없습니다. 이 기능은 직접 설치판에서 제공합니다. 앱스토어 샌드박스 안에서는 다른 앱을 조작할 수 없습니다."))
                            .font(.system(size: 12)).foregroundStyle(ConduxTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    group(tr("일반")) {
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle(isOn: Binding(get: { model.webSearchEnabled }, set: { model.webSearchEnabled = $0 })) {
                                Text(tr("웹 검색")).font(.system(size: 13, weight: .medium))
                            }
                            .toggleStyle(.switch).controlSize(.small)
                            Text(tr("API 대화에서 AI 가 웹을 검색하고 링크를 읽습니다. 검색 1회당 약 $0.01 과 결과 토큰 비용이 예산에 더해집니다."))
                                .font(.system(size: 11)).foregroundStyle(ConduxTheme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        Divider().padding(.leading, 14)
                        HStack {
                            Text(tr("언어")).font(.system(size: 13, weight: .medium))
                            Spacer()
                            Picker("", selection: Binding(get: { model.appLanguage }, set: { model.appLanguage = $0 })) {
                                ForEach(AppLanguage.allCases) { language in Text(language.label).tag(language) }
                            }
                            .labelsHidden().fixedSize()
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        Divider().padding(.leading, 14)
                        HStack {
                            Text(tr("화면")).font(.system(size: 13, weight: .medium))
                            Spacer()
                            Picker("", selection: Binding(get: { model.appAppearance }, set: { model.appAppearance = $0 })) {
                                ForEach(AppAppearance.allCases) { appearance in Text(appearance.label).tag(appearance) }
                            }
                            .labelsHidden().pickerStyle(.segmented).fixedSize()
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 20)
            }
        }
        .frame(width: 600, height: 680)
        .background(ConduxTheme.canvas)
        .sheet(isPresented: $showAdvanced) { SettingsSheet() }
    }

    /// 추천 설정: 처음 쓰는 사람에게 무난한 값을 버튼 하나로 맞춥니다. 키·로그인·폴더는 건드리지 않습니다.
    private var recommendedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(ConduxTheme.blue)
                Text(tr("추천 설정")).font(.system(size: 13, weight: .bold))
                Spacer()
                if model.usesRecommendedSettings {
                    Label(tr("추천 설정 사용 중"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(ConduxTheme.ok)
                } else {
                    Button(tr("추천 설정 적용")) { model.applyRecommendedSettings() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            Text(tr("처음이라면 이 설정이 무난합니다. 키·로그인·폴더는 바꾸지 않습니다."))
                .font(.system(size: 12)).foregroundStyle(ConduxTheme.textSecondary)
            TapDisclosure(title: tr("자세히 보기"), titleFont: .system(size: 12), titleColor: ConduxTheme.textSecondary) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(AppModel.recommendedSummary, id: \.0) { item in
                        HStack(alignment: .firstTextBaseline) {
                            Text(tr(item.0)).font(.system(size: 12)).foregroundStyle(ConduxTheme.textSecondary)
                            Spacer()
                            Text(tr(item.1)).font(.system(size: 12)).foregroundStyle(ConduxTheme.textPrimary).multilineTextAlignment(.trailing)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .background(ConduxTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ConduxTheme.blue.opacity(model.usesRecommendedSettings ? 0 : 0.5), lineWidth: 1))
    }

    private var subscriptionGroup: some View {
        group(tr("구독으로 쓰기")) {
            row("Codex", on: model.connection.isConnected && model.isLoggedIn,
                desc: model.connection.isConnected
                    ? (model.isLoggedIn ? FriendlyText.codexBoxHint + tr(" · 연결됨") : model.accountSummary)
                    : model.connection.label) {
                if model.connection.isConnected && !model.isLoggedIn {
                    Button(tr("브라우저로 로그인")) { Task { await model.startLogin() } }
                }
                Button(tr("다시 연결")) { Task { await model.connect() } }.disabled(model.progress.isBusy)
            }
            Divider().padding(.leading, 34)
            row("Claude", on: model.claudeAuth.isLoggedIn,
                desc: model.claudeAuth.isLoggedIn
                    ? (model.claudeUsageSummary.isEmpty ? FriendlyText.claudeBoxHint + tr(" · 로그인됨") : model.claudeUsageSummary)
                    : model.claudeAuth.label) {
                if !model.claudeAuth.isLoggedIn, model.claudeAuth != .checking {
                    Button(tr("로그인 명령 복사")) { model.copyClaudeLoginCommand() }
                }
                Button(tr("다시 확인")) { Task { await model.refreshClaudeAuth() } }.disabled(model.claudeAuth == .checking)
            }
        }
    }

    private var githubDescription: String {
        switch model.githubStatus {
        case .checking: return tr("확인 중…")
        case .missing: return tr("GitHub CLI(gh)가 없습니다. 명령을 복사해 설치하고 로그인하세요")
        case .loggedOut: return tr("로그인되어 있지 않습니다")
        case .loggedIn(let login): return tr("\(login) 로 로그인됨 · 폴더 대화에서 AI 가 승인을 받고 git·gh 를 씁니다")
        }
    }

    private var apiGroup: some View {
        group(tr("본인 키로 쓰기 · 쓴 만큼 청구")) {
            let budget = String(format: tr("새 대화 예산 $%.2f"), model.claudeAPIDefaultBudgetUSD)
            row("Claude API", on: model.claudeAPIKeyPresent,
                desc: model.claudeAPIKeyPresent ? tr("모델 \(model.claudeAPIModel) · \(budget)") : tr("키 없음 · Anthropic 사이트에서 발급")) {
                Button(model.claudeAPIKeyPresent ? tr("키 설정") : tr("키 넣기")) { showAdvanced = true }
            }
            Divider().padding(.leading, 34)
            row("OpenAI API", on: model.openAIAPIKeyPresent,
                desc: model.openAIAPIKeyPresent ? tr("모델 \(model.openAIAPIModel) · \(budget)") : tr("키 없음 · OpenAI 사이트에서 발급")) {
                Button(model.openAIAPIKeyPresent ? tr("키 설정") : tr("키 넣기")) { showAdvanced = true }
            }
        }
    }

    private var macGroup: some View {
        group(tr("이 Mac 에서")) {
            row(tr("작업 폴더"), on: !model.workspacePath.isEmpty,
                desc: model.workspacePath.isEmpty ? FriendlyText.workspaceBoxHint + tr(" · 없으면 글 대화만") : model.workspacePath) {
                Button(tr("폴더 선택…")) { model.chooseWorkspace() }
                if !model.workspacePath.isEmpty { Button(tr("해제")) { model.clearWorkspace() } }
            }
            Divider().padding(.leading, 34)
            row("GitHub", on: model.githubStatus.isLoggedIn, desc: githubDescription) {
                if model.githubStatus == .missing || model.githubStatus == .loggedOut {
                    Button(tr("로그인 명령 복사")) { model.copyGitHubSetupCommand() }
                }
                Button(tr("다시 확인")) { Task { await model.refreshGitHubStatus() } }.disabled(model.githubStatus == .checking)
            }
            Divider().padding(.leading, 34)
            row(tr("다른 프로그램 제어"), on: model.claudeAuth.isLoggedIn,
                desc: tr("Claude 가 명령으로 앱을 열고 조작합니다. 실행 전마다 승인합니다")) {
                Button(tr("제어 대화 시작")) {
                    model.startMacControlConversation()
                    if model.claudeAuth.isLoggedIn { model.showConnections = false }
                }
            }
            Divider().padding(.leading, 34)
            row(tr("로컬 AI (시험 기능)"), on: model.localModelReady, desc: model.localModelStatus) {
                Button(model.localModelReady ? tr("설정") : tr("모델 받기")) { showAdvanced = true }
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr(title)).font(.system(size: 11, weight: .medium)).foregroundStyle(ConduxTheme.textTertiary)
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ConduxTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func row<Actions: View>(_ name: String, on: Bool, desc: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 12) {
            Circle().fill(on ? ConduxTheme.ok : ConduxTheme.off).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(tr(name)).font(.system(size: 13, weight: .medium)).foregroundStyle(ConduxTheme.textPrimary)
                Text(tr(desc)).font(.system(size: 12)).foregroundStyle(ConduxTheme.textSecondary).lineLimit(2).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            actions().controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
}
