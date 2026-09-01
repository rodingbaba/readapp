import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var apiService: APIService
    @StateObject private var preferences = UserPreferences.shared
    @Environment(\.dismiss) var dismiss
    
    @State private var showTTSSelection = false
    @State private var selectedTTSName = ""
    @State private var showLogoutAlert = false
    @State private var showShareSheet = false
    @State private var logFileURL: URL?
    @State private var showClearLogsAlert = false
    @State private var showClearCacheAlert = false
    
    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(UIColor.systemBackground),
                        Color.blue.opacity(0.05),
                        Color(UIColor.systemBackground)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                Form {
                    Section(header: Text("用户信息")) {
                    HStack {
                        Text("用户名")
                        Spacer()
                        Text(preferences.username)
                            .foregroundColor(.secondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("服务器")
                            Spacer()
                            Text(preferences.serverURL)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    
                    Button(action: { showLogoutAlert = true }) {
                        HStack {
                            Spacer()
                            Text("退出登录")
                                .foregroundColor(.red)
                            Spacer()
                        }
                    }
                }
                
                Section(header: Text("阅读设置")) {
                    HStack {
                        Text("字体大小")
                        Spacer()
                        Text("\(Int(preferences.fontSize))")
                    }
                    Slider(value: $preferences.fontSize, in: 12...30, step: 1)
                    
                    HStack {
                        Text("行间距")
                        Spacer()
                        Text("\(Int(preferences.lineSpacing))")
                    }
                    Slider(value: $preferences.lineSpacing, in: 4...20, step: 2)
                    
                    Toggle("正文净化", isOn: $preferences.useReplaceRuleSanitization)
                    Text("启用轻阅读替换净化规则（默认开启）")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("无极滚动阅读", isOn: $preferences.infiniteScrollReadingEnabled)
                    Text("开启后，普通阅读会自动拼接后续章节并随滚动自动切章；默认关闭")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section(header: Text("听书设置")) {
                    Button(action: { showTTSSelection = true }) {
                        HStack {
                            Text("TTS 引擎")
                                .foregroundColor(.primary)
                            Spacer()
                            if preferences.selectedTTSId.isEmpty {
                                Text("未选择")
                                    .foregroundColor(.orange)
                            } else {
                                Text(selectedTTSName.isEmpty ? "已选择" : selectedTTSName)
                                    .foregroundColor(.secondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if !preferences.selectedTTSId.isEmpty {
                        let currentTTSId = preferences.selectedTTSId
                        
                        let speechRateBinding = Binding<Double>(
                            get: { preferences.getSpeechRate(for: currentTTSId) },
                            set: { preferences.setSpeechRate($0, for: currentTTSId) }
                        )
                        let preloadCountBinding = Binding<Int>(
                            get: { preferences.getPreloadCount(for: currentTTSId) },
                            set: { preferences.setPreloadCount($0, for: currentTTSId) }
                        )
                        let gapBinding = Binding<Double>(
                            get: { preferences.getGapReduction(for: currentTTSId) },
                            set: { preferences.setGapReduction($0, for: currentTTSId) }
                        )
                        
                        HStack {
                            Text("语速 (当前引擎)")
                            Spacer()
                            Text(String(format: "%.1fx", speechRateBinding.wrappedValue))
                        }
                        Slider(value: speechRateBinding, in: 0.5...3.0, step: 0.1)
                        
                        Text("语速范围: 0.5x - 3.0x (默认 1.0x)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Stepper(value: preloadCountBinding, in: 0...6) {
                            HStack {
                                Text("预载段数 (当前引擎)")
                                Spacer()
                                Text("\(preloadCountBinding.wrappedValue) 段")
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Text("提前下载接下来的音频段，范围 0-6 段（默认 3 段）")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack {
                            Text("减少段落间隔 (当前引擎)")
                            Spacer()
                            Text(String(format: "%.1f 秒", gapBinding.wrappedValue))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: gapBinding, in: 0.0...1.0, step: 0.1)
                        Text("如果当前发音人在段落末尾带有静音，可增加此值来提前切入下一段，实现无缝衔接")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Section(header: Text("书架设置")) {
                    Toggle("最近阅读排序", isOn: $preferences.bookshelfSortByRecent)
                    Text("开启后按最后阅读时间排序，关闭则按加入书架时间排序")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section(header: Text("调试工具")) {
                    HStack {
                        Text("日志记录")
                        Spacer()
                        Text("\(LogManager.shared.getLogCount()) 条")
                            .foregroundColor(.secondary)
                    }
                    
                    Button(action: exportLogs) {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("导出日志")
                            Spacer()
                        }
                        .foregroundColor(.blue)
                    }
                    
                    Button(action: { showClearLogsAlert = true }) {
                        HStack {
                            Image(systemName: "trash")
                            Text("清空日志")
                            Spacer()
                        }
                        .foregroundColor(.red)
                    }
                    
                    Button(action: { showClearCacheAlert = true }) {
                        HStack {
                            Image(systemName: "trash.circle")
                            Text("清除本地缓存")
                            Spacer()
                        }
                        .foregroundColor(.orange)
                    }
                }
                
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 4) {
                            Text("服务器地址示例: http://192.168.1.100:8080")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("使用后端 HttpTTS 引擎进行朗读")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                        Spacer()
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showTTSSelection) {
                TTSSelectionView()
                    .environmentObject(apiService)
            }
            .alert("退出登录", isPresented: $showLogoutAlert) {
                Button("取消", role: .cancel) { }
                Button("退出", role: .destructive) {
                    handleLogout()
                }
            } message: {
                Text("确定要退出登录吗？")
            }
            .alert("清空日志", isPresented: $showClearLogsAlert) {
                Button("取消", role: .cancel) { }
                Button("清空", role: .destructive) {
                    LogManager.shared.clearLogs()
                }
            } message: {
                Text("确定要清空所有日志吗？")
            }
            .alert("清除本地缓存", isPresented: $showClearCacheAlert) {
                Button("取消", role: .cancel) { }
                Button("清除", role: .destructive) {
                    apiService.clearLocalCache()
                }
            } message: {
                Text("确定要清除所有本地章节内容缓存吗？")
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = logFileURL {
                    ShareSheet(items: [url])
                }
            }
            .task {
                await loadTTSName()
            }
            .onChange(of: preferences.selectedTTSId) { _ in
                Task {
                    await loadTTSName()
                }
            }
            .hideScrollBackground()
            }
        }
    }
    
    private func handleLogout() {
        preferences.logout()
        dismiss()
    }
    
    private func exportLogs() {
        if let url = LogManager.shared.exportLogs() {
            logFileURL = url
            showShareSheet = true
            LogManager.shared.log("导出日志文件: \(url.lastPathComponent)", category: "系统")
        }
    }
    
    private func loadTTSName() async {
        guard !preferences.selectedTTSId.isEmpty else {
            selectedTTSName = ""
            return
        }
        
        do {
            let ttsList = try await apiService.fetchTTSList()
            if let tts = ttsList.first(where: { $0.id == preferences.selectedTTSId }) {
                selectedTTSName = tts.name
            }
        } catch {
            print("加载 TTS 名称失败: \(error)")
        }
    }
}

// MARK: - 分享视图
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
    }
}
