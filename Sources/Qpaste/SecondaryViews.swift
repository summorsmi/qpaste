import SwiftUI
import AppKit
import ServiceManagement
import ApplicationServices
import QpasteCore

struct SnippetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState<SnippetDraft> var draft: SnippetDraft
    var save: (SnippetDraft) -> Void
    @FocusState private var nameFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: "text.badge.plus").foregroundStyle(Palette.accent)
                Text(draft.entryID == nil ? "保存为文本片段" : "编辑文本片段").font(.system(size: 19, weight: .semibold))
            }
            Text("给常用内容起个名字，下次搜索即可找到。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("名称").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                TextField("例如：邮箱签名、常用回复", text: $draft.name).textFieldStyle(.roundedBorder).focused($nameFocused)
                    .accessibilityLabel("片段名称")
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("内容")
                    Spacer()
                    Text("\(draft.body.count) 字符").foregroundStyle(.tertiary)
                }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                TextEditor(text: $draft.body).font(.system(size: 13)).padding(8)
                    .frame(height: 220).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
                    .accessibilityLabel("片段内容")
            }
            HStack {
                Text("文本片段会一直保留").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存片段") { save(draft); dismiss() }.buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.body.isEmpty)
            }
        }.padding(28).frame(width: 520).tint(Palette.accent)
            .onAppear { nameFocused = true }
    }
}

struct SettingsView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @ViewState<Bool> private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @ViewState<String?> private var loginError = nil
    @ViewState<Bool> private var confirmClear = false
    @ViewState<Bool> private var includeFavorites = false
    @ViewState<Bool> private var accessibilityEnabled = AXIsProcessTrusted()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("让 Qpaste 顺手一点").font(.system(size: 21, weight: .semibold))
                    Text("简单设置，然后继续专注。 ").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12)).padding(7) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("关闭设置").keyboardShortcut(.cancelAction)
            }.padding(26)
            Form {
                Section("显示") {
                    Toggle("精简模式", isOn: $settings.isCompact)
                }
                Section("使用习惯") {
                    Picker("呼出快捷键", selection: $settings.shortcut) {
                        ForEach(ShortcutChoice.allCases) { Text($0.label).tag($0) }
                    }
                    if settings.shortcut == .doubleCommand {
                        Text("连续单独轻按 Command 两次即可呼出或收起，组合键不会触发。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if let error = store.shortcutError { Text(error).font(.caption).foregroundStyle(.orange) }
                    Toggle("登录 Mac 时启动", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                    if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
                    Toggle("暂停记录剪贴板", isOn: $settings.isPaused)
                }
                Section("历史记录") {
                    Picker("最多保留", selection: $settings.maximumCount) {
                        Text("100 条").tag(100)
                        Text("300 条").tag(300)
                        Text("500 条").tag(500)
                        Text("1000 条").tag(1000)
                        Text("不限").tag(0)
                    }.onChange(of: settings.maximumCount) { _, _ in store.applyRetention() }
                    Picker("自动清理", selection: $settings.retentionDays) {
                        Text("7 天前的记录").tag(7)
                        Text("30 天前的记录").tag(30)
                        Text("90 天前的记录").tag(90)
                        Text("不按时间清理").tag(0)
                    }.onChange(of: settings.retentionDays) { _, _ in store.applyRetention() }
                    capacityUsage
                    Text("普通历史达到条数、时间或容量任一限制时自动清理；“不限”只取消条数限制。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("收藏和文本片段不会自动清理，也不占用普通历史的 5 GB 额度。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Section("直接粘贴") {
                    HStack {
                        Label(accessibilityEnabled ? "辅助功能权限已开启" : "需要辅助功能权限", systemImage: accessibilityEnabled ? "checkmark.circle.fill" : "keyboard")
                            .foregroundStyle(accessibilityEnabled ? Color.green : Color.primary)
                        Spacer()
                        Button("系统设置") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                    Text("授权后，按回车即可粘贴回刚才的应用。复制和手动 ⌘V 无需授权。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Section("本机存储") {
                    HStack {
                        Text("\(store.historyCount) 条历史 · \(store.snippetCount) 个文本片段")
                        Spacer()
                        Button("打开存储位置") { NSWorkspace.shared.open(store.repository.directory) }
                    }
                    Text("内容仅存于这台 Mac；按你的偏好，带敏感标记的内容也会记录。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if let error = store.storageError { Text(error).font(.caption).foregroundStyle(.orange) }
                    HStack {
                        Toggle("同时清空收藏", isOn: $includeFavorites).toggleStyle(.checkbox)
                        Spacer()
                        Button("清空历史…", role: .destructive) { confirmClear = true }
                    }
                }
            }.formStyle(.grouped)
            HStack {
                Text("Qpaste 1.0").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button("退出 Qpaste") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.horizontal, 26).padding(.vertical, 14)
        }
        .frame(width: 560, height: 670).tint(Palette.accent)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityEnabled = AXIsProcessTrusted()
        }
        .alert("清空历史记录？", isPresented: $confirmClear) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { store.clearHistory(includeFavorites: includeFavorites) }
        } message: {
            Text(includeFavorites ? "历史和收藏会被删除，文本片段会保留。此操作无法撤销。" : "普通历史会被删除，收藏和文本片段会保留。此操作无法撤销。")
        }
    }

    private var capacityUsage: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("普通历史")
                Spacer()
                Text("\(capacityLabel(store.usage.historyBytes)) / \(capacityLabel(store.policy.maximumBytes))")
                    .monospacedDigit()
            }
            ProgressView(value: Double(store.usage.historyBytes), total: Double(store.policy.maximumBytes))
                .accessibilityLabel("普通历史容量使用情况")
            HStack {
                Text("收藏 \(capacityLabel(store.usage.favoriteBytes))")
                Spacer()
                Text("文本片段 \(capacityLabel(store.usage.snippetBytes))")
            }.foregroundStyle(.secondary)
            HStack {
                Text("内容合计")
                Spacer()
                Text(capacityLabel(store.usage.totalBytes)).monospacedDigit()
            }.foregroundStyle(.secondary)
            Text("按保存的内容大小统计，不含存储索引；文件仅计路径。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.font(.system(size: 11)).padding(.vertical, 4)
    }

    private func capacityLabel(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.includesActualByteCount = false
        formatter.zeroPadsFractionDigits = false
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = SMAppService.mainApp.status == .requiresApproval ? "请在系统设置的「登录项」中允许 Qpaste。" : nil
        } catch {
            loginError = "未能更新登录项。请先将 Qpaste 放进「应用程序」，再重试。"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

struct ImagePreview: View {
    let image: NSImage
    let entry: ClipboardEntry
    @Environment(\.dismiss) private var dismiss
    @ViewState<Double> private var zoom = 1.0
    private var baseSize: CGSize {
        let width = CGFloat(entry.imageWidth ?? 1)
        let height = CGFloat(entry.imageHeight ?? 1)
        let scale = min(700 / width, 470 / height, 1)
        return CGSize(width: width * scale, height: height * scale)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("图片预览", systemImage: "photo").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("适应窗口") { zoom = 1 }.buttonStyle(.plain).font(.system(size: 11))
                Slider(value: $zoom, in: 0.5...4).frame(width: 130).accessibilityLabel("图片缩放")
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: baseSize.width * zoom, height: baseSize.height * zoom)
                    .frame(minWidth: 760, minHeight: 490)
            }.background(Checkerboard())
            HStack {
                Text("\(entry.imageWidth ?? 0) × \(entry.imageHeight ?? 0) 像素")
                Spacer()
                Text("\(Int(zoom * 100))% 适应尺寸")
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(16)
        }.frame(width: 780, height: 620).tint(Palette.accent)
    }
}
