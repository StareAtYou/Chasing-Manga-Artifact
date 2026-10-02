import SwiftUI
import MangaCore
struct SettingsView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    var body: some View { @Bindable var app = app
        Form { Section("外观") { Picker("主题", selection: $app.settings.theme) { Text("跟随系统").tag(AppTheme.system); Text("浅色").tag(AppTheme.light); Text("深色").tag(AppTheme.dark) }.onChange(of: app.settings.theme) { _, _ in Task { await app.saveSettings() } } }
            Section("更新提醒") { Toggle("新章节通知", isOn: Binding(get: { app.settings.notifications }, set: { enabled in Task { if enabled { await app.perform { app.settings.notifications = try await app.notificationService.requestPermission(); await app.saveSettings() } } else { app.settings.notifications = false; await app.saveSettings() } } })); Text("关闭通知或拒绝权限时，更新列表仍可使用。").font(.caption).foregroundStyle(.secondary) }
            Section("本地存储") { Text("自动缓存上限 256 MB · 解码缓存上限 64 MB"); Button("清理自动缓存") { Task { await app.perform { try await app.images.files.clearCache(); await app.images.handleMemoryPressure() } } }; Text("清理缓存会保留已下载章节。").font(.caption).foregroundStyle(.secondary) }
            Section { Text("macOS 和 iOS 各自保存在本机，不提供账户或同步。").font(.caption).foregroundStyle(.secondary) }
        }.formStyle(.grouped).navigationTitle("设置").toolbar { Button("完成") { dismiss() } }.frame(minWidth: 320) }
}
