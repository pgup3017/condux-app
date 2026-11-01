import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
        } detail: {
            // 시스템 inspector 는 창이 좁으면 왼쪽 목록까지 밀어내므로 오른쪽 칸 안에 직접 둡니다.
            HStack(spacing: 0) {
                ConversationView().frame(maxWidth: .infinity)
                if model.showInspector {
                    Divider()
                    EventLogView().frame(width: 300).transition(.move(edge: .trailing))
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.showInspector)
        }
        .onAppear { model.showInspector = false }
        .navigationTitle(tr(model.selectedConversation?.title ?? "새 대화"))
        .navigationSubtitle(model.selectedConversation?.provider.displayName ?? "")
        .toolbar {
            ToolbarItem {
                Button { model.showInspector.toggle() } label: { Label(tr("이벤트 로그"), systemImage: "list.bullet.rectangle") }
                    .help(tr("AI 와 주고받은 원문 기록 보기"))
            }
            ToolbarItem {
                Button { model.toggleAppearance() } label: {
                    Label(model.isDarkAppearance ? tr("밝은 화면으로") : tr("어두운 화면으로"),
                          systemImage: model.isDarkAppearance ? "sun.max" : "moon")
                }
                .help(model.isDarkAppearance ? tr("밝은 화면으로") : tr("어두운 화면으로"))
            }
            ToolbarItem {
                Button { model.showConnections = true } label: { Label(tr("연결 관리"), systemImage: "slider.horizontal.3") }
                    .help(tr("연결 관리: 로그인, API 키, 작업 폴더, MCP 도구"))
            }
        }
        .sheet(isPresented: $model.showSettings) { SettingsSheet() }
        .sheet(isPresented: $model.showConnections) { ConnectionsSheet() }
    }
}

/// 연결 관리 창의 MCP 서버 칸 (구독판). 로그인은 터미널 명령을 복사해 사용자가 직접 합니다.
struct MCPServersBox: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            VStack(alignment: .leading, spacing: 6) {
                Label(model.mcpServers.isEmpty ? tr("MCP 서버 없음") : tr("MCP 서버 \(model.enabledMCPServers.count)개 켜짐"),
                      systemImage: "puzzlepiece.extension")
                    .foregroundStyle(model.enabledMCPServers.isEmpty ? .secondary : ConduxTheme.blue)
                ForEach(model.mcpServers) { server in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Toggle("", isOn: Binding(get: { server.enabled }, set: { model.setMCPServer(id: server.id, enabled: $0) }))
                                .labelsHidden().toggleStyle(.checkbox).controlSize(.mini)
                            Text(server.name).font(.caption.bold()).foregroundStyle(ConduxTheme.textPrimary)
                            Text(tr(model.mcpStatusText(for: server))).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Menu {
                                Toggle(tr("도구 자동 허용 (승인 없이)"), isOn: Binding(get: { server.autoAllow }, set: { model.setMCPServer(id: server.id, autoAllow: $0) }))
                                if server.loginCommands != nil { Button(tr("로그인 명령 복사")) { model.copyMCPLoginCommands(id: server.id) } }
                                Divider()
                                Button(tr("삭제"), role: .destructive) { model.removeMCPServer(id: server.id) }
                            } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        }
                        Text(server.locationText).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        if !server.note.isEmpty { Text(tr(server.note)).foregroundStyle(.secondary).lineLimit(3) }
                    }
                    .help(server.locationText)
                }
                HStack {
                    Menu(tr("추가")) {
                        ForEach(MCPServer.presets, id: \.name) { preset in
                            Button(preset.name + " · " + (preset.transport == .http ? preset.url : tr("로컬 명령"))) { model.addMCPServer(preset) }
                                .disabled(model.mcpServers.contains { $0.name == preset.name })
                        }
                        Divider()
                        Button(tr("직접 입력…")) { model.showMCPAddSheet = true }
                    }
                    .fixedSize()
                }
                .controlSize(.small)
                Text(tr("켜면 다음 전송부터 Claude 에서, ‘다시 연결’ 후 Codex 에서 씁니다. 로그인은 터미널에서 한 번."))
                    .foregroundStyle(.secondary).lineLimit(2)
            }
            .font(.caption)
        }
        .sheet(isPresented: $model.showMCPAddSheet) { MCPAddSheet() }
    }
}

struct MCPAddSheet: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var transport: MCPServer.Transport = .http
    @State private var url = ""
    @State private var command = ""
    @State private var autoAllow = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("MCP 서버 직접 입력")).font(.headline)
            TextField(tr("이름 (영문·숫자·-·_)"), text: $name)
            Picker(tr("종류"), selection: $transport) {
                Text(tr("원격 (HTTP)")).tag(MCPServer.Transport.http)
                Text(tr("로컬 명령 (stdio)")).tag(MCPServer.Transport.stdio)
            }
            .pickerStyle(.segmented)
            if transport == .http {
                TextField("https://… /mcp", text: $url)
            } else {
                TextField(tr("명령과 인수 (예: npx -y some-mcp-server)"), text: $command)
            }
            Toggle(tr("도구 자동 허용 (승인 없이)"), isOn: $autoAllow)
            Text(tr("원격 서버 로그인은 추가 후 ‘로그인 명령 복사’로 터미널에서 합니다.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(tr("취소")) { model.showMCPAddSheet = false }
                Button(tr("추가")) {
                    let parts = command.split(separator: " ").map(String.init)
                    model.addMCPServer(MCPServer(name: name.trimmingCharacters(in: .whitespaces), transport: transport,
                                                 url: url.trimmingCharacters(in: .whitespaces),
                                                 command: parts.first ?? "", args: Array(parts.dropFirst()), autoAllow: autoAllow))
                    if model.mcpServers.contains(where: { $0.name == name.trimmingCharacters(in: .whitespaces) }) { model.showMCPAddSheet = false }
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || (transport == .http ? url.isEmpty : command.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// 승인 카드 본문: `- `/`+ ` 로 시작하는 줄을 빨강·초록으로, `$ ` 명령 줄은 굵게 보여줍니다.
struct DiffTextView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.caption.monospaced())
                    .foregroundStyle(color(for: line))
                    .fontWeight(line.hasPrefix("$ ") ? .semibold : .regular)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(for: line))
            }
        }
        .textSelection(.enabled)
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+ ") || line.hasPrefix("+\t") { return ConduxTheme.diffAdd }
        if line.hasPrefix("- ") || line.hasPrefix("-\t") { return ConduxTheme.diffRemove }
        if line.hasPrefix("# ") { return .secondary }
        return ConduxTheme.textPrimary
    }

    private func background(for line: String) -> Color {
        if line.hasPrefix("+ ") || line.hasPrefix("+\t") { return Color.green.opacity(0.10) }
        if line.hasPrefix("- ") || line.hasPrefix("-\t") { return Color.red.opacity(0.10) }
        return .clear
    }
}

/// 도움말 ▸ 빠른 안내. 네트워크 없이 앱 안에서 보는 사용법 요약.
struct QuickGuideSheet: View {
    @Environment(AppModel.self) private var model

    private var sections: [(String, String)] {
        var list: [(String, String)] = [
            (tr("새 대화"), tr("왼쪽 위 ‘새 대화’(⌘N)를 누르고 가운데 입력창에 씁니다. 어떤 AI 로 시작할지는 입력창 오른쪽에서 고릅니다. 보내기는 Enter, 중단은 ⌘. 입니다.")),
            (tr("첨부"), tr("입력창의 + 버튼(⌘⇧A)이나 드래그 앤 드롭으로 PNG·JPEG·PDF·ZIP 을 붙입니다. 사진은 말풍선에서 바로 보입니다.")),
            (tr("받은 파일"), tr("AI 가 돌려준 파일은 대화에 항목으로 나타나고 열기·Finder에서 보기·저장이 됩니다. 이미지는 미리보기가 뜹니다.")),
            (tr("자동 릴레이"), tr("지시를 쓰고 입력창의 ‘릴레이’ ▸ ‘이 내용으로 릴레이 시작’을 누르면 현재 대화의 AI 가 만들고, 검토자(API)가 확인해 고칠 점을 자동으로 돌려줍니다. 최대 횟수와 작업 예산 안에서만 돕니다.")),
            (tr("API 예산"), tr("API 대화는 대화마다 작업 예산(기본 $1, 추정치)이 있고 입력창 위에 표시됩니다. 다 쓰면 전송이 막힙니다. ‘예산 +$1’로만 올립니다. 구독 대화는 비용을 지어내지 않고 사용률만 보여줍니다.")),
            (tr("정리"), tr("왼쪽 검색창으로 대화를 찾고, 오른쪽 클릭으로 이름 바꾸기·마크다운 내보내기(⌘⇧E)·제거를 합니다.")),
        ]
        if !AppModel.isAppStoreBuild {
            list.insert((tr("작업 폴더"), tr("새 대화 화면 입력창의 ‘폴더’ 칩이나 연결 관리에서 폴더를 고르면 그 뒤 만드는 대화가 그 폴더에서 일합니다. 파일 수정과 명령 실행은 승인 카드에서 허용해야 실행되고, 파일 변경은 되돌릴 수 있습니다. 입력창의 폴더 칩을 누르면 빌드를 돌리고 오류를 AI 에게 보낼 수 있습니다.")), at: 2)
            list.append((tr("MCP 서버"), tr("왼쪽 아래 연결 상태 ▸ 연결 관리의 ‘도구 (MCP)’에서 Figma·Mobbin·Xcode 프리셋을 켭니다. 원격 서버 로그인은 ‘로그인 명령 복사’로 받은 명령을 터미널에서 한 번 실행합니다.")))
            list.append((tr("로그인"), tr("Codex 는 ‘브라우저로 로그인’, Claude 구독은 터미널에서 claude auth login. 앱은 토큰을 읽거나 저장하지 않습니다.")))
        }
        return list
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(tr("Condux 빠른 안내")).font(.title3.bold())
                Spacer()
                Button(tr("닫기")) { model.showQuickGuide = false }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(sections, id: \.0) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.0).font(.headline)
                            Text(section.1).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Link(tr("지원 페이지와 개인정보 처리방침 열기"), destination: URL(string: "https://pgup3017.github.io/condux-site/")!)
                        .padding(.top, 6)
                }
                .padding(20)
            }
        }
        .frame(width: 560, height: 520)
    }
}

struct EntryRow: View {
    @Environment(AppModel.self) private var model
    let entry: ChatEntry
    var assistantName = "Codex"

    var body: some View {
        switch entry.kind {
        case .approval:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: entry.isPendingApproval ? "hand.raised.fill" : "hand.raised")
                        .foregroundStyle(entry.isPendingApproval ? .orange : .secondary)
                    Text(tr(FriendlyText.activityTitle(entry.title))).font(.callout.bold())
                    Spacer()
                    Text(tr(entry.status)).font(.caption).foregroundStyle(entry.status == "허용됨" ? ConduxTheme.blue : .secondary)
                }
                ScrollView(.horizontal) {
                    DiffTextView(text: entry.text.isEmpty ? tr("(내용 없음)") : entry.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
                if entry.isPendingApproval {
                    Text(FriendlyText.approvalHint(tool: String(entry.title.dropFirst("승인 요청 · ".count))))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(tr("허용")) { model.approve(entryID: entry.id) }.buttonStyle(.borderedProminent)
                        Button(tr("거부")) { model.deny(entryID: entry.id) }
                        Spacer()
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ConduxTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(entry.isPendingApproval ? ConduxTheme.warn : Color.clear, lineWidth: 1))
        case .user:
            HStack { Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(entry.text).textSelection(.enabled)
                    // 첨부한 사진은 말풍선 안에 미리보기 (클릭하면 열기)
                    let imagePaths = entry.attachmentPaths.filter { ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(($0 as NSString).pathExtension.lowercased()) }
                    if !imagePaths.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(imagePaths, id: \.self) { path in
                                if let image = NSImage(contentsOfFile: path) {
                                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 220, maxHeight: 160)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .onTapGesture { model.openReceivedFile(path: path) }
                                        .help((path as NSString).lastPathComponent)
                                }
                            }
                        }
                    }
                    if !entry.attachmentNames.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(entry.attachmentNames, id: \.self) { name in
                                Label(name, systemImage: "paperclip").font(.caption).lineLimit(1)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(ConduxTheme.blue.opacity(0.25), in: Capsule())
                            }
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(ConduxTheme.selected, in: RoundedRectangle(cornerRadius: 14))
            }
        case .file:
            VStack(alignment: .leading, spacing: 8) {
            if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff"].contains((entry.text as NSString).pathExtension.lowercased()),
               let image = NSImage(contentsOfFile: entry.text) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture { model.openReceivedFile(path: entry.text) }
            }
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.doc.fill").foregroundStyle(ConduxTheme.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("받은 파일 · \(entry.title)")).font(.callout.bold())
                    Text(entry.status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(tr("열기")) { model.openReceivedFile(path: entry.text) }.controlSize(.small)
                Button("Finder") { model.revealReceivedFile(path: entry.text) }.controlSize(.small)
                Button(tr("저장…")) { model.saveReceivedFile(path: entry.text) }.controlSize(.small)
            }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ConduxTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            .help(entry.text)
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text(assistantName).font(.system(size: 11, weight: .medium)).foregroundStyle(ConduxTheme.textTertiary)
                    if entry.isStreaming { ProgressView().controlSize(.mini) }
                }
                if entry.text.isEmpty { Text("…") } else { MarkdownView(text: entry.text) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .activity where entry.title.hasPrefix("생각 정리") && entry.text.isEmpty && !entry.isStreaming:
            EmptyView()
        case .activity:
            ActivityRow(entry: entry)
        case .error:
            Label(tr(entry.text), systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
    }
}

struct EventLogView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(tr("이벤트 로그")).font(.headline)
                Spacer()
                Button(tr("비우기")) { model.clearLog() }.controlSize(.small)
            }
            TextField(tr("필터 (예: turn/, item/, error)"), text: $filter).textFieldStyle(.roundedBorder)
            List(model.eventLog.filter { filter.isEmpty || $0.text.localizedCaseInsensitiveContains(filter) }) { line in
                HStack(alignment: .top, spacing: 6) {
                    Text(line.direction).font(.caption.monospaced().bold())
                        .foregroundStyle(line.direction == "!" ? .orange : .secondary)
                    Text(line.time, format: .dateTime.hour().minute().second()).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    Text(line.text).font(.caption2.monospaced()).lineLimit(6).textSelection(.enabled)
                }
            }
            .listStyle(.plain)
        }
        .padding(8)
    }
}

/// Claude API(사용자 본인 API 키) 설정. 구독 연결과 별개이며 한도 소진 시 자동 전환하지 않습니다.
struct ClaudeAPISettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Claude API (본인 API 키, 구독과 별개)")).font(.headline)
            HStack {
                SecureField(tr("sk-ant-… (Anthropic 콘솔에서 만든 키)"), text: $model.claudeAPIKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.saveClaudeAPIKey() }
                Button(tr("키 저장")) { model.saveClaudeAPIKey() }
                    .disabled(model.claudeAPIKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                if model.claudeAPIKeyPresent { Button(tr("키 삭제")) { model.clearClaudeAPIKey() } }
            }
            HStack(spacing: 6) {
                Image(systemName: model.claudeAPIKeyPresent ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(model.claudeAPIKeyPresent ? ConduxTheme.blue : .orange)
                Text(model.claudeAPIKeyStatus.isEmpty
                     ? (model.claudeAPIKeyPresent ? tr("키 저장됨 · 이 앱 전용 키체인 항목에 보관") : tr("저장된 키 없음 · 키를 붙여 넣고 ‘키 저장’ 또는 아래 ‘저장’을 누르세요"))
                     : tr(model.claudeAPIKeyStatus))
            }
            .font(.caption)
            Text(tr("앱은 키를 화면에 다시 보여주지 않고, 파일이나 설정에 남기지 않습니다."))
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Picker(tr("API 모델"), selection: $model.claudeAPIModel) {
                    ForEach(AppModel.claudeAPIModelChoices, id: \.value) { choice in Text(tr(choice.label)).tag(choice.value) }
                    if !AppModel.claudeAPIModelChoices.contains(where: { $0.value == model.claudeAPIModel }) {
                        Text(tr("직접 입력: \(model.claudeAPIModel)")).tag(model.claudeAPIModel)
                    }
                }
                Picker(tr("노력 수준"), selection: $model.claudeAPIEffort) {
                    ForEach(AppModel.claudeEffortChoices, id: \.value) { choice in Text(tr(choice.label)).tag(choice.value) }
                }
            }
            .font(.caption)
            HStack {
                Text(tr("새 대화 작업 예산 (달러)")).font(.caption)
                TextField("1.00", value: $model.claudeAPIDefaultBudgetUSD, format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.roundedBorder).frame(width: 90)
                Stepper("", value: $model.claudeAPIDefaultBudgetUSD, in: 0.1...100, step: 0.5).labelsHidden()
            }
            Text(tr("예산은 대화마다 적용되는 추정 비용 상한입니다(Claude·OpenAI 공통). 재시도·검토·인계도 같은 예산에 합산되고, 다 쓰면 자동으로 올리지 않습니다. 추정치는 공식 요율표 기준이라 실제 청구와 다를 수 있습니다."))
                .font(.caption).foregroundStyle(.secondary)

            Divider()
            Text(tr("OpenAI API (본인 API 키)")).font(.headline)
            HStack {
                SecureField(tr("sk-… (OpenAI 플랫폼에서 만든 키)"), text: $model.openAIAPIKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.saveOpenAIAPIKey() }
                Button(tr("키 저장")) { model.saveOpenAIAPIKey() }
                    .disabled(model.openAIAPIKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                if model.openAIAPIKeyPresent { Button(tr("키 삭제")) { model.clearOpenAIAPIKey() } }
            }
            HStack(spacing: 6) {
                Image(systemName: model.openAIAPIKeyPresent ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(model.openAIAPIKeyPresent ? ConduxTheme.blue : .orange)
                Text(model.openAIAPIKeyStatus.isEmpty
                     ? (model.openAIAPIKeyPresent ? tr("키 저장됨 · 이 앱 전용 키체인 항목에 보관") : tr("저장된 키 없음 · 키를 붙여 넣고 ‘키 저장’ 또는 아래 ‘저장’을 누르세요"))
                     : tr(model.openAIAPIKeyStatus))
            }
            .font(.caption)
            HStack(spacing: 12) {
                Picker(tr("OpenAI 모델"), selection: $model.openAIAPIModel) {
                    ForEach(AppModel.openAIAPIModelChoices, id: \.value) { choice in Text(tr(choice.label)).tag(choice.value) }
                    if !AppModel.openAIAPIModelChoices.contains(where: { $0.value == model.openAIAPIModel }) {
                        Text(tr("직접 입력: \(model.openAIAPIModel)")).tag(model.openAIAPIModel)
                    }
                }
                Picker(tr("추론 수준"), selection: $model.openAIAPIEffort) {
                    ForEach(AppModel.openAIEffortChoices, id: \.value) { choice in Text(tr(choice.label)).tag(choice.value) }
                }
            }
            .font(.caption)
            Text(tr("OpenAI Responses API 로 직접 호출하고, 기록은 앱이 들고 다시 보냅니다(OpenAI 서버에 저장하지 않음). 요금은 OpenAI 에 직접 청구됩니다."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// 화살표뿐 아니라 제목 글자를 눌러도 열리는 접기 상자
struct TapDisclosure<Content: View>: View {
    let title: String
    var titleFont: Font = .caption
    var titleColor: Color = ConduxTheme.textPrimary
    @ViewBuilder let content: () -> Content
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded, content: content) {
            Button { withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() } } label: {
                Text(title).font(titleFont).foregroundStyle(titleColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(tr("Condux 설정")).font(.title2)
                Spacer()
                Text(tr("버전 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "개발 빌드")"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            // 입력칸 테두리가 스크롤 칸 경계에서 잘리지 않게 안쪽 여백을 두고, 바깥 정렬은 그대로 맞춥니다.
            ScrollView {
            VStack(alignment: .leading, spacing: 12) {
            Picker(tr("‘새 대화’ 기본 연결"), selection: Binding(get: { model.preferredNewConversationProvider?.rawValue ?? "" },
                                                        set: { model.preferredNewConversationProvider = Provider(rawValue: $0) })) {
                Text(tr("자동 (준비된 연결 중 먼저)")).tag("")
                ForEach(AppModel.isAppStoreBuild ? [Provider.claudeAPI, .openAIAPI] : [Provider.codex, .claude, .claudeAPI, .openAIAPI, .localLLM], id: \.rawValue) { provider in
                    Text(provider.displayName).tag(provider.rawValue)
                }
            }
            .font(.caption)
            Text(tr("⌘N 과 ‘새 대화’ 버튼에 적용됩니다. 로컬 AI를 고르면 모델 준비가 끝날 때까지 기다립니다. 다른 연결은 준비되지 않으면 자동 선택으로 돌아갑니다."))
                .font(.caption).foregroundStyle(.secondary)
            if !AppModel.isAppStoreBuild {
                LocalLLMSettingsSection()
                Divider()
            }
            TapDisclosure(title: tr("연결 상세 정보")) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codex: \(tr(model.connection.label))").textSelection(.enabled)
                    Text(tr("Codex 계정: \(tr(model.accountSummary))")).textSelection(.enabled)
                    Text("Claude: \(tr(model.claudeAuth.label))").textSelection(.enabled)
                    if !model.claudeAuth.version.isEmpty { Text(tr("Claude Code 버전: \(model.claudeAuth.version)")).textSelection(.enabled) }
                    if !model.claudeModelName.isEmpty { Text(tr("Claude 모델: \(model.claudeModelName)")).textSelection(.enabled) }
                    if !model.claudeUsageSummary.isEmpty { Text("Claude \(tr(model.claudeUsageSummary))").textSelection(.enabled) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)

            if !AppModel.isAppStoreBuild {
            Text(tr("codex 실행 파일 경로 (비우면 PATH 에서 자동으로 찾습니다. 예: /opt/homebrew/bin/codex)")).font(.caption)
            TextField("/opt/homebrew/bin/codex", text: $model.codexPathOverride).textFieldStyle(.roundedBorder)
            Text(tr("실험 모드: 읽기 전용 샌드박스를 사용하고 도구 승인 요청을 취소합니다. 읽기 명령이나 별도 도구까지 모두 차단하는 설정은 아닙니다."))
                .font(.caption).foregroundStyle(.secondary)

            Divider()
            Text(tr("claude 실행 파일 경로 (비우면 PATH 에서 자동으로 찾습니다. 예: ~/.local/bin/claude)")).font(.caption)
            TextField("/Users/me/.local/bin/claude", text: $model.claudePathOverride).textFieldStyle(.roundedBorder)
            HStack(spacing: 12) {
                Picker(tr("모델"), selection: $model.claudeModel) {
                    ForEach(AppModel.claudeModelChoices, id: \.value) { choice in Text(tr(choice.label)).tag(choice.value) }
                    if !AppModel.claudeModelChoices.contains(where: { $0.value == model.claudeModel }) {
                        Text(tr("직접 입력: \(model.claudeModel)")).tag(model.claudeModel)
                    }
                }
                Picker(tr("노력 수준"), selection: $model.claudeEffort) {
                    ForEach(AppModel.claudeEffortChoices, id: \.value) { choice in Text(tr(choice.label)).tag(choice.value) }
                    if !AppModel.claudeEffortChoices.contains(where: { $0.value == model.claudeEffort }) {
                        Text(tr("직접 입력: \(model.claudeEffort)")).tag(model.claudeEffort)
                    }
                }
            }
            .font(.caption)
            TextField(tr("모델 이름 직접 입력 (예: claude-sonnet-5-5). 비우면 위 선택을 따릅니다."), text: $model.claudeModel)
                .textFieldStyle(.roundedBorder).font(.caption)
            Text(tr("모델과 노력 수준은 다음 메시지부터 적용됩니다. 높은 모델·노력일수록 구독 한도를 더 빨리 씁니다."))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            } // !isAppStoreBuild
            ClaudeAPISettingsSection()
            if !AppModel.isAppStoreBuild {
                Text(tr("Claude 는 공식 Claude Code CLI 를 수정 없이 실행하고, 로그인은 터미널에서 `claude auth login` 으로 사용자가 직접 합니다. ") +
                     tr("앱은 토큰이나 인증 파일을 읽지 않고 `claude auth status` 로 상태만 확인합니다. 구독 요금제의 한도를 그대로 따르고, 한도가 끝나도 API 로 자동 전환하지 않습니다. ") +
                     tr("작업 폴더를 연결한 대화만 파일 도구를 씁니다."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            }
            .padding(.horizontal, -6)
            HStack {
                if !AppModel.isAppStoreBuild { Button(tr("로그인 명령 복사")) { model.copyClaudeLoginCommand() } }
                Spacer()
                Button(tr("닫기")) { model.commitPendingAPIKey(); dismiss() }
                Button(AppModel.isAppStoreBuild ? tr("저장") : tr("저장 후 다시 연결")) {
                    model.commitPendingAPIKey()
                    dismiss()
                    if !AppModel.isAppStoreBuild { Task { await model.startUp() } }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 700)
    }
}

struct LocalLLMSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDeletion = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("로컬 AI (MLX) · 시험 기능")).font(.headline)
            Text(tr("Apple Silicon Mac의 직접 설치판에서 사용합니다. API 키 없이 이 Mac에서 답변을 만듭니다."))
            Text(tr("Qwen3 1.7B · 약 1GB · 작은 시험용 모델입니다. 한국어·코딩 답변의 정확도는 낮을 수 있습니다. 대화는 총 8,000자까지, 긴 답변은 잘릴 수 있습니다."))
                .foregroundStyle(.secondary)
            if model.localLLMAvailable {
                Text(tr(model.localModelStatus)).textSelection(.enabled)
                if let fraction = model.localDownloadFraction {
                    ProgressView(value: fraction).controlSize(.small)
                }
                HStack {
                    if model.localModelDownloading {
                        Button(tr("다운로드 중단")) { model.cancelLocalModelDownload() }
                    } else if model.localModelReady {
                        Button(tr("로컬 새 대화")) {
                            Task {
                                await model.newConversation(provider: .localLLM)
                                if model.selectedProvider == .localLLM { model.commitPendingAPIKey(); model.showSettings = false }
                            }
                        }
                        Button(tr("모델 삭제…")) { confirmDeletion = true }
                    } else if model.localModelHasPartial {
                        Button(tr("이어서 받기")) { model.downloadLocalModel() }
                        Button(tr("받다 만 파일 지우기")) { model.deleteLocalModel() }
                    } else {
                        Button(tr("모델 다운로드 (약 1GB)")) { model.downloadLocalModel() }
                    }
                }
                .disabled(model.progress.isBusy)
                Text(tr("다운로드할 때만 Hugging Face에 연결합니다. 로컬 대화 내용은 모델 다운로드에 보내지 않습니다. 첨부·MCP·릴레이는 지원하지 않습니다."))
                    .foregroundStyle(.secondary)
            } else {
                Text(tr("이 빌드에서는 로컬 AI를 사용할 수 없습니다. Apple Silicon Mac의 직접 설치판이 필요합니다."))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Link(tr("모델 정보·라이선스"), destination: URL(string: "https://huggingface.co/\(LocalModelStore.modelID)")!)
                Link("MLX", destination: URL(string: "https://github.com/ml-explore/mlx-swift-lm")!)
            }
        }
        .font(.caption)
        .confirmationDialog(tr("모델 파일 약 1GB를 삭제합니다. 대화 기록은 남아 있습니다."), isPresented: $confirmDeletion) {
            Button(tr("모델 삭제"), role: .destructive) { model.deleteLocalModel() }
        }
    }
}
