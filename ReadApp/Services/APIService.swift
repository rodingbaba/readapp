import Foundation
import Combine
import UIKit
import JavaScriptCore

private actor ChapterContentCacheStore {
    struct ManifestEntry: Codable {
        let fileName: String
        var lastAccessTime: TimeInterval
    }
    
    private let maxDiskEntries = 300
    private let expirationInterval: TimeInterval = 7 * 24 * 60 * 60
    private let memoryCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 120
        return cache
    }()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let manifestURL: URL
    
    private var manifest: [String: ManifestEntry] = [:]
    private var isPrepared = false
    
    init() {
        let fm = FileManager.default
        let root = fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        self.cacheDirectory = root.appendingPathComponent("ReadAppChapterContentCache", isDirectory: true)
        self.manifestURL = cacheDirectory.appendingPathComponent("manifest.json")
    }
    
    func get(for key: String) -> String? {
        if let memoryValue = memoryCache.object(forKey: key as NSString) {
            return memoryValue as String
        }
        
        ensurePrepared()
        
        guard let entry = manifest[key] else {
            return nil
        }
        
        if isExpired(entry) {
            removeEntry(for: key, entry: entry)
            saveManifest()
            return nil
        }
        
        let fileURL = cacheDirectory.appendingPathComponent(entry.fileName)
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else {
            manifest.removeValue(forKey: key)
            saveManifest()
            return nil
        }
        
        memoryCache.setObject(content as NSString, forKey: key as NSString)
        manifest[key]?.lastAccessTime = Date().timeIntervalSince1970
        saveManifest()
        return content
    }
    
    func set(_ content: String, for key: String) {
        ensurePrepared()
        
        memoryCache.setObject(content as NSString, forKey: key as NSString)
        
        guard let data = content.data(using: .utf8) else {
            return
        }
        
        let fileName = "\(stableHash(key)).txt"
        let fileURL = cacheDirectory.appendingPathComponent(fileName)
        
        do {
            try data.write(to: fileURL, options: .atomic)
            manifest[key] = ManifestEntry(fileName: fileName, lastAccessTime: Date().timeIntervalSince1970)
            cleanupExpiredAndOverflow()
            saveManifest()
        } catch {
            LogManager.shared.log("写入章节缓存失败: \(error)", category: "缓存错误")
        }
    }
    
    func removeAll() {
        ensurePrepared()
        
        memoryCache.removeAllObjects()
        manifest.removeAll()
        
        do {
            if fileManager.fileExists(atPath: cacheDirectory.path) {
                try fileManager.removeItem(at: cacheDirectory)
            }
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            saveManifest()
        } catch {
            LogManager.shared.log("清理章节缓存失败: \(error)", category: "缓存错误")
        }
    }
    
    private func ensurePrepared() {
        guard !isPrepared else {
            return
        }
        
        isPrepared = true
        
        do {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            if let data = try? Data(contentsOf: manifestURL),
               let decoded = try? JSONDecoder().decode([String: ManifestEntry].self, from: data) {
                manifest = decoded
            }
            cleanupExpiredAndOverflow()
            saveManifest()
        } catch {
            LogManager.shared.log("初始化章节缓存失败: \(error)", category: "缓存错误")
        }
    }
    
    private func isExpired(_ entry: ManifestEntry) -> Bool {
        Date().timeIntervalSince1970 - entry.lastAccessTime > expirationInterval
    }
    
    private func cleanupExpiredAndOverflow() {
        let now = Date().timeIntervalSince1970
        
        let expired = manifest.filter { now - $0.value.lastAccessTime > expirationInterval }
        for (key, entry) in expired {
            removeEntry(for: key, entry: entry)
        }
        
        if manifest.count > maxDiskEntries {
            let sorted = manifest.sorted { $0.value.lastAccessTime < $1.value.lastAccessTime }
            let overflowCount = manifest.count - maxDiskEntries
            for (key, entry) in sorted.prefix(overflowCount) {
                removeEntry(for: key, entry: entry)
            }
        }
    }
    
    private func removeEntry(for key: String, entry: ManifestEntry) {
        let fileURL = cacheDirectory.appendingPathComponent(entry.fileName)
        try? fileManager.removeItem(at: fileURL)
        manifest.removeValue(forKey: key)
    }
    
    private func saveManifest() {
        guard let data = try? JSONEncoder().encode(manifest) else {
            return
        }
        try? data.write(to: manifestURL, options: .atomic)
    }
    
    private func stableHash(_ text: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }
}

class APIService: ObservableObject {
    static let shared = APIService()
    static let apiVersion = 5
    
    @Published var books: [Book] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    // 章节内容缓存（内存 + 磁盘）
    private let chapterCache = ChapterContentCacheStore()
    
    // 并发去重，避免同章节重复请求
    private var inFlightChapterTasks: [String: Task<String, Error>] = [:]
    private let inFlightLock = NSLock()
    
    var baseURL: String {
        var serverURL = UserPreferences.shared.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if serverURL.isEmpty {
            return "http://127.0.0.1:8080/reader3"
        }
        // 去除尾部的 / 或 /#/
        while serverURL.hasSuffix("/") || serverURL.hasSuffix("/#") {
            if serverURL.hasSuffix("/#") {
                serverURL = String(serverURL.dropLast(2))
            } else if serverURL.hasSuffix("/") {
                serverURL = String(serverURL.dropLast(1))
            }
        }
        if !serverURL.lowercased().hasPrefix("http://") && !serverURL.lowercased().hasPrefix("https://") {
            serverURL = "http://" + serverURL
        }
        if serverURL.hasSuffix("/reader3") {
            return serverURL
        }
        return "\(serverURL)/reader3"
    }
    
    private var accessToken: String {
        UserPreferences.shared.accessToken
    }
    
    private init() {}
    
    // MARK: - 请求与重试
    /// 通用请求
    private func requestWithFailback(
        endpoint: String,
        method: String = "GET",
        queryItems: [URLQueryItem]? = nil,
        body: Data? = nil,
        headers: [String: String]? = nil,
        timeoutInterval: TimeInterval = 15
    ) async throws -> (Data, HTTPURLResponse) {
        let requestURL = "\(baseURL)/\(endpoint)"

        do {
            return try await performRequest(
                urlString: requestURL,
                method: method,
                queryItems: queryItems,
                body: body,
                headers: headers,
                timeoutInterval: timeoutInterval
            )
        } catch let requestError as NSError {
            // 对可恢复网络错误做一次快速重试
            if shouldRetrySameServer(error: requestError) {
                LogManager.shared.log("请求失败，重试一次: \(requestError.localizedDescription)", category: "网络")
                return try await performRequest(
                    urlString: requestURL,
                    method: method,
                    queryItems: queryItems,
                    body: body,
                    headers: headers,
                    timeoutInterval: timeoutInterval
                )
            }
            throw requestError
        }
    }
    
    private func shouldRetrySameServer(error: NSError) -> Bool {
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorTimedOut,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotFindHost:
                return true
            default:
                return false
            }
        }
        return false
    }
    
    /// 执行实际的网络请求
    private func performRequest(
        urlString: String,
        method: String,
        queryItems: [URLQueryItem]?,
        body: Data?,
        headers: [String: String]?,
        timeoutInterval: TimeInterval
    ) async throws -> (Data, HTTPURLResponse) {
        guard var components = URLComponents(string: urlString) else {
            throw NSError(domain: "APIService", code: 400, userInfo: [NSLocalizedDescriptionKey: "无效的URL: \(urlString)"])
        }

        if let queryItems = queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw NSError(domain: "APIService", code: 400, userInfo: [NSLocalizedDescriptionKey: "无法构建URL"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeoutInterval

        if let body = body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        if let headers = headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: "无效的响应类型"])
        }

        return (data, httpResponse)
    }
    
    // MARK: - 登录
    private struct LoginRequestBody: Codable {
        let username: String
        let password: String
        let isLogin: Bool
    }
    
    func testServerConnection() async throws {
        let body = try JSONEncoder().encode(LoginRequestBody(username: "test", password: "test", isLogin: true))
        _ = try await requestWithFailback(endpoint: "login", method: "POST", body: body, timeoutInterval: 10)
    }
    
    func login(username: String, password: String) async throws -> String {
        let loginBody = LoginRequestBody(username: username, password: password, isLogin: true)
        let bodyData = try JSONEncoder().encode(loginBody)
        
        do {
            let (data, httpResponse) = try await requestWithFailback(
                endpoint: "login",
                method: "POST",
                body: bodyData,
                timeoutInterval: 15
            )
            
            LogManager.shared.log("HTTP 状态码: \(httpResponse.statusCode)", category: "网络")
            
            if httpResponse.statusCode != 200 {
                let responseText = String(data: data, encoding: .utf8) ?? "无法解析响应"
                let error = "服务器错误(状态码: \(httpResponse.statusCode)): \(responseText)"
                LogManager.shared.log(error, category: "网络错误")
                throw NSError(domain: "APIService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: error])
            }
            
            let apiResponse = try JSONDecoder().decode(APIResponse<LoginResponse>.self, from: data)
            
            if apiResponse.isSuccess, let loginData = apiResponse.data {
                LogManager.shared.log("登录成功", category: "网络")
                return loginData.accessToken
            } else {
                let error = apiResponse.errorMsg ?? "登录失败"
                LogManager.shared.log("登录失败: \(error)", category: "网络错误")
                throw NSError(domain: "APIService", code: 401, userInfo: [NSLocalizedDescriptionKey: error])
            }
        } catch let error as NSError {
            // 检查是否是网络连接错误
            if error.domain == NSURLErrorDomain {
                var errorMsg = "网络连接失败: "
                switch error.code {
                case NSURLErrorTimedOut:
                    errorMsg += "请求超时，请检查服务器地址"
                case NSURLErrorCannotConnectToHost:
                    errorMsg += "无法连接到服务器，请检查服务器地址"
                case NSURLErrorNetworkConnectionLost:
                    errorMsg += "网络连接已断开"
                case NSURLErrorNotConnectedToInternet:
                    errorMsg += "设备未连接到互联网"
                default:
                    errorMsg += error.localizedDescription
                }
                LogManager.shared.log(errorMsg, category: "网络错误")
                throw NSError(domain: "APIService", code: error.code, userInfo: [NSLocalizedDescriptionKey: errorMsg])
            }
            throw error
        }
    }
    
    // MARK: - 获取用户信息
    func getUserInfo() async throws -> UserInfo {
        let queryItems = [
            URLQueryItem(name: "accessToken", value: accessToken)
        ]
        let (data, httpResponse) = try await requestWithFailback(endpoint: "getUserInfo", queryItems: queryItems)
        
        guard httpResponse.statusCode == 200 else {
            throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: "服务器错误"])
        }
        
        struct UserInfoData: Codable {
            let userInfo: UserInfo
        }
        
        let apiResponse = try JSONDecoder().decode(APIResponse<UserInfoData>.self, from: data)
        
        if apiResponse.isSuccess, let userInfoData = apiResponse.data {
            return userInfoData.userInfo
        } else {
            throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: apiResponse.errorMsg ?? "获取用户信息失败"])
        }
    }
    
    // MARK: - 获取书架列表
    func fetchBookshelf() async throws {
        guard !accessToken.isEmpty else {
            throw NSError(domain: "APIService", code: 401, userInfo: [NSLocalizedDescriptionKey: "请先登录"])
        }
        
        let queryItems = [
            URLQueryItem(name: "accessToken", value: accessToken),
            URLQueryItem(name: "version", value: "1.0.0")
        ]
        
        let (data, httpResponse) = try await requestWithFailback(endpoint: "getBookshelf", queryItems: queryItems)
        
        guard httpResponse.statusCode == 200 else {
            throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: "服务器错误"])
        }
        
        let apiResponse = try JSONDecoder().decode(APIResponse<[Book]>.self, from: data)
        
        if apiResponse.isSuccess, let books = apiResponse.data {
            await MainActor.run {
                self.books = books
            }
        } else {
            throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: apiResponse.errorMsg ?? "获取书架失败"])
        }
    }
    
    // MARK: - 获取章节列表
    func fetchChapterList(bookUrl: String, bookSourceUrl: String?) async throws -> [BookChapter] {
        var queryItems = [
            URLQueryItem(name: "accessToken", value: accessToken),
            URLQueryItem(name: "url", value: bookUrl)
        ]
        
        if let bookSourceUrl = bookSourceUrl {
            queryItems.append(URLQueryItem(name: "bookSourceUrl", value: bookSourceUrl))
        }
        
        let (data, httpResponse) = try await requestWithFailback(endpoint: "getChapterList", queryItems: queryItems)
        
        guard httpResponse.statusCode == 200 else {
            throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: "服务器错误"])
        }
        
        let apiResponse = try JSONDecoder().decode(APIResponse<[BookChapter]>.self, from: data)
        
        if apiResponse.isSuccess, let chapters = apiResponse.data {
            return chapters
        } else {
            throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: apiResponse.errorMsg ?? "获取章节列表失败"])
        }
    }
    
    // MARK: - 获取章节内容
    func fetchChapterContent(bookUrl: String, bookSourceUrl: String?, index: Int, bookName: String? = nil) async throws -> String {
        let useSanitization = UserPreferences.shared.useReplaceRuleSanitization
        let cacheKey = buildChapterCacheKey(
            bookUrl: bookUrl,
            bookSourceUrl: bookSourceUrl,
            index: index,
            useReplaceRuleSanitization: useSanitization
        )
        
        if let cachedContent = await chapterCache.get(for: cacheKey) {
            return cachedContent
        }
        
        let (task, isNewTask) = taskForChapterContent(cacheKey: cacheKey) {
            Task<String, Error> { [weak self] in
                guard let self = self else {
                    throw NSError(domain: "APIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "服务已释放"])
                }
                
                if let cachedContent = await self.chapterCache.get(for: cacheKey) {
                    return cachedContent
                }
                
                var queryItems = [
                    URLQueryItem(name: "accessToken", value: self.accessToken),
                    URLQueryItem(name: "url", value: bookUrl),
                    URLQueryItem(name: "index", value: "\(index)"),
                    URLQueryItem(name: "type", value: "0")
                ]
                
                if let bookSourceUrl = bookSourceUrl {
                    queryItems.append(URLQueryItem(name: "bookSourceUrl", value: bookSourceUrl))
                }
                
                let endpoint = "getBookContent"
                
                let (data, httpResponse) = try await self.requestWithFailback(endpoint: endpoint, queryItems: queryItems)
                
                guard httpResponse.statusCode == 200 else {
                    throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: "服务器错误"])
                }
                
                let apiResponse = try JSONDecoder().decode(APIResponse<String>.self, from: data)
                
                if apiResponse.isSuccess, let content = apiResponse.data {
                    await self.chapterCache.set(content, for: cacheKey)
                    return content
                } else {
                    throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: apiResponse.errorMsg ?? "获取章节内容失败"])
                }
            }
        }
        
        if isNewTask {
            do {
                defer { removeInFlightTask(for: cacheKey) }
                return try await task.value
            }
        } else {
            return try await task.value
        }
    }
    
    // MARK: - 批量预载章节内容
    func preloadChapterContents(bookUrl: String, bookSourceUrl: String?, indices: [Int], bookName: String? = nil) async {
        let uniqueIndices = Array(Set(indices)).sorted()
        guard !uniqueIndices.isEmpty else {
            return
        }
        
        await withTaskGroup(of: Void.self) { group in
            for index in uniqueIndices {
                group.addTask { [weak self] in
                    guard let self = self else { return }
                    do {
                        _ = try await self.fetchChapterContent(bookUrl: bookUrl, bookSourceUrl: bookSourceUrl, index: index, bookName: bookName)
                    } catch {
                        LogManager.shared.log("章节预载失败 - index: \(index), error: \(error.localizedDescription)", category: "缓存")
                    }
                }
            }
        }
    }
    
    // MARK: - 保存阅读进度
    func saveBookProgress(bookUrl: String, index: Int, pos: Double, title: String?) async throws {
        var queryItems = [
            URLQueryItem(name: "accessToken", value: accessToken),
            URLQueryItem(name: "url", value: bookUrl),
            URLQueryItem(name: "bookUrl", value: bookUrl),
            URLQueryItem(name: "index", value: "\(index)"),
            URLQueryItem(name: "position", value: "\(Int(pos))")
        ]
        
        if let title = title {
            queryItems.append(URLQueryItem(name: "title", value: title))
        }
        
        let (data, _) = try await requestWithFailback(endpoint: "saveBookProgress", method: "POST", queryItems: queryItems)
        
        let apiResponse = try JSONDecoder().decode(APIResponse<String>.self, from: data)
        
        if !apiResponse.isSuccess {
            print("保存进度失败: \(apiResponse.errorMsg ?? "未知错误")")
        }
    }
    
    private var cachedTTSList: [HttpTTS]?
    
    // MARK: - 获取 TTS 引擎列表
    func fetchTTSList(forceRefresh: Bool = false) async throws -> [HttpTTS] {
        if !forceRefresh, let cached = cachedTTSList {
            return cached
        }
        
        guard !accessToken.isEmpty else {
            throw NSError(domain: "APIService", code: 401, userInfo: [NSLocalizedDescriptionKey: "请先登录"])
        }
        
        let queryItems = [
            URLQueryItem(name: "accessToken", value: accessToken)
        ]
        
        let (data, httpResponse) = try await requestWithFailback(endpoint: "getSpeechConfig", queryItems: queryItems)
        
        guard httpResponse.statusCode == 200 else {
            throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: "服务器错误"])
        }
        
        struct SpeechConfigData: Codable {
            let provider: String?
            let httpTtsEngines: [HttpTTS]?
            let httpTtsActiveId: String?
            
            // Allow arbitrary other fields
            private enum CodingKeys: String, CodingKey {
                case provider, httpTtsEngines, httpTtsActiveId
            }
        }
        
        struct SpeechConfigResponse: Codable {
            let isSuccess: Bool
            let errorMsg: String?
            let data: SpeechConfigData?
        }
        
        do {
            let apiResponse = try JSONDecoder().decode(SpeechConfigResponse.self, from: data)
            
            if apiResponse.isSuccess, let configData = apiResponse.data, let ttsList = configData.httpTtsEngines {
                self.cachedTTSList = ttsList
                
                // 可选：如果用户未选择TTS，自动使用后端的 httpTtsActiveId
                if UserPreferences.shared.selectedTTSId.isEmpty, let activeId = configData.httpTtsActiveId, !activeId.isEmpty {
                    DispatchQueue.main.async {
                        UserPreferences.shared.selectedTTSId = activeId
                    }
                }
                
                return ttsList
            } else {
                self.cachedTTSList = []
                return []
            }
        } catch {
            let responseStr = String(data: data, encoding: .utf8) ?? ""
            let prefix = String(responseStr.prefix(200))
            throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: "解析失败: \(error.localizedDescription) \n数据片段: \(prefix)"])
        }
    }
    
    // MARK: - 获取默认 TTS
    func fetchDefaultTTS() async throws -> String {
        return ""
    }
    
    // MARK: - 构建 TTS 音频 URL (内部使用)
    private func evaluateHttpTtsTemplate(_ template: String, speakText: String, speakSpeed: Int) -> String {
        let regex = try! NSRegularExpression(pattern: "\\{\\{([\\s\\S]+?)\\}\\}")
        let nsString = template as NSString
        var result = template
        
        let matches = regex.matches(in: template, options: [], range: NSRange(location: 0, length: nsString.length))
        guard !matches.isEmpty else { return template }
        
        guard let context = JSContext() else { return template }
        context.setObject(speakText, forKeyedSubscript: "speakText" as NSString)
        context.setObject(speakSpeed, forKeyedSubscript: "speakSpeed" as NSString)
        
        let javaMock = JSValue(newObjectIn: context)!
        let encodeURI: @convention(block) (String) -> String = { str in
            return str.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? str
        }
        javaMock.setObject(encodeURI, forKeyedSubscript: "encodeURI" as NSString)
        context.setObject(javaMock, forKeyedSubscript: "java" as NSString)
        
        for match in matches.reversed() {
            let range = match.range(at: 1)
            let exp = nsString.substring(with: range)
            
            if let jsResult = context.evaluateScript(exp), !jsResult.isUndefined, !jsResult.isNull {
                let evalString = jsResult.toString() ?? ""
                let fullRange = match.range
                result = (result as NSString).replacingCharacters(in: fullRange, with: evalString)
            } else {
                let fullRange = match.range
                result = (result as NSString).replacingCharacters(in: fullRange, with: "")
            }
        }
        
        return result
    }
    
    struct HttpTtsRequestOptions {
        var method: String
        var headers: [String: String]?
        var body: Any?
    }
    
    private func parseHttpTtsTemplate(_ template: String) -> (url: String, options: HttpTtsRequestOptions) {
        let pattern = "^(.*?)(\\s*,\\s*(\\{.*\\}))$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return (template.trimmingCharacters(in: .whitespaces), HttpTtsRequestOptions(method: "GET"))
        }
        
        let nsString = template as NSString
        let matches = regex.matches(in: template, options: [], range: NSRange(location: 0, length: nsString.length))
        
        if let match = matches.first {
            let url = nsString.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let jsonStr = nsString.substring(with: match.range(at: 3))
            
            if let data = jsonStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                
                let method = (json["method"] as? String) ?? "GET"
                var headers: [String: String]? = nil
                if let h = json["headers"] as? [String: Any] {
                    headers = h.mapValues { "\($0)" }
                } else if let h = json["headers"] as? [String: String] {
                    headers = h
                }
                
                return (url, HttpTtsRequestOptions(method: method, headers: headers, body: json["body"]))
            }
        }
        return (template.trimmingCharacters(in: .whitespaces), HttpTtsRequestOptions(method: "GET"))
    }
    
    // MARK: - 获取 TTS 音频数据
    func fetchTTSAudioData(ttsId: String, text: String, speechRate: Double, timeoutInterval: TimeInterval = 20) async throws -> Data {
        let ttsList = try await fetchTTSList()
        guard let tts = ttsList.first(where: { $0.id == ttsId }) else {
            throw NSError(domain: "APIService", code: 404, userInfo: [NSLocalizedDescriptionKey: "未找到指定的TTS引擎配置"])
        }
        
        let mappedSpeed = max(0, min(100, Int(round(speechRate * 50))))
        let evaluatedTemplate = evaluateHttpTtsTemplate(tts.url, speakText: text, speakSpeed: mappedSpeed)
        
        let parsed = parseHttpTtsTemplate(evaluatedTemplate)
        
        guard let url = URL(string: parsed.url) else {
            throw NSError(domain: "APIService", code: 400, userInfo: [NSLocalizedDescriptionKey: "TTS URL 解析失败: \(parsed.url)"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = parsed.options.method
        request.timeoutInterval = timeoutInterval
        
        if let headers = parsed.options.headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        
        if let body = parsed.options.body {
            if let bodyDict = body as? [String: Any] {
                request.httpBody = try? JSONSerialization.data(withJSONObject: bodyDict)
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            } else if let bodyStr = body as? String {
                request.httpBody = bodyStr.data(using: .utf8)
            }
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: "无效的TTS响应"])
        }
        
        if !(200...299).contains(httpResponse.statusCode) {
            let errorText = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw NSError(domain: "APIService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "TTS 请求失败 (\(httpResponse.statusCode)): \(errorText)"])
        }
        
        return data
    }
    
    // MARK: - 清除本地缓存
    func clearLocalCache() {
        clearAllInFlightChapterTasks()
        Task {
            await chapterCache.removeAll()
        }
    }
    
    // MARK: - 清除所有远程缓存
    func clearAllRemoteCache() async throws {
        // reader-next 暂不支持清空全部远程缓存，这里仅执行本地清理
        clearLocalCache()
    }
    
    private func buildChapterCacheKey(bookUrl: String, bookSourceUrl: String?, index: Int, useReplaceRuleSanitization: Bool) -> String {
        "\(bookUrl)|\(bookSourceUrl ?? "default")|\(index)|san:\(useReplaceRuleSanitization ? 1 : 0)"
    }
    
    private func taskForChapterContent(cacheKey: String, create: () -> Task<String, Error>) -> (Task<String, Error>, Bool) {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        
        if let existing = inFlightChapterTasks[cacheKey] {
            return (existing, false)
        }
        
        let task = create()
        inFlightChapterTasks[cacheKey] = task
        return (task, true)
    }
    
    private func removeInFlightTask(for key: String) {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        inFlightChapterTasks.removeValue(forKey: key)
    }
    
    private func clearAllInFlightChapterTasks() {
        inFlightLock.lock()
        let tasks = Array(inFlightChapterTasks.values)
        inFlightChapterTasks.removeAll()
        inFlightLock.unlock()
        
        tasks.forEach { $0.cancel() }
    }
}
