import Foundation

/// Main entry point for the Adaptive Conversion OS SDK.
///
/// Setup (AppDelegate or @main):
///   ACO.configure(projectId: "your-project-id", sdkKey: "your-sdk-key")
///
/// Trigger a flow:
///   if let flow = await ACO.shared.flow(type: .onboarding) {
///       let vc = ACOFlowViewController(flow: flow, onComplete: { ... })
///       present(vc, animated: true)
///   }
public final class ACO {

    // MARK: - Singleton

    public static let shared = ACO()
    private init() {}

    // MARK: - Configuration

    private var config: ACOConfig?
    private var cachedConfig: SDKConfig?
    private var fetchTask: Task<SDKConfig?, Never>?
    private var userAttributes: [String: Any] = [:]

    public static func configure(
        projectId: String,
        sdkKey: String,
        userId: String = "anonymous",
        apiBaseURL: String = "https://adaptive-conversion-os-ruddy.vercel.app",
        debug: Bool = false
    ) {
        shared.config = ACOConfig(
            projectId: projectId,
            sdkKey: sdkKey,
            userId: userId,
            apiBaseURL: apiBaseURL,
            debug: debug
        )
        // Prefetch in background
        Task { await shared.fetchSDKConfig() }
    }

    // MARK: - Flow access

    /// Returns the active published flow for the given type, or nil if none published.
    public func flow(type flowType: FlowType) async -> ACOFlow? {
        let config = await fetchSDKConfig()
        return config?.flows.first(where: { $0.type == flowType.rawValue })
    }

    /// Returns a flow by its ID.
    public func flow(id flowId: String) async -> ACOFlow? {
        let config = await fetchSDKConfig()
        return config?.flows.first(where: { $0.id == flowId })
    }

    // MARK: - Fetching

    @discardableResult
    private func fetchSDKConfig() async -> SDKConfig? {
        guard let cfg = config else {
            log("ACO not configured. Call ACO.configure() first.")
            return cachedConfig
        }

        if let cached = cachedConfig { return cached }

        var components = URLComponents(string: "\(cfg.apiBaseURL)/api/sdk/\(cfg.projectId)")!
        components.queryItems = [
            URLQueryItem(name: "userId", value: cfg.userId),
            URLQueryItem(name: "platform", value: "ios"),
            URLQueryItem(name: "appVersion", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"),
        ]

        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue(cfg.sdkKey, forHTTPHeaderField: "x-sdk-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                log("SDK config fetch failed: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            let sdkConfig = try JSONDecoder().decode(SDKConfig.self, from: data)
            cachedConfig = sdkConfig
            log("Fetched \(sdkConfig.flows.count) active flows")
            return sdkConfig
        } catch {
            log("SDK config error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Event tracking

    public func track(event: ACOEvent) {
        guard let cfg = config else { return }
        Task {
            var request = URLRequest(url: URL(string: "\(cfg.apiBaseURL)/api/sdk/\(cfg.projectId)")!)
            request.httpMethod = "POST"
            request.setValue(cfg.sdkKey, forHTTPHeaderField: "x-sdk-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(["events": [event]])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    public func trackScreenView(screenId: String, flowId: String) {
        track(event: ACOEvent(
            eventType: "screen_view",
            eventName: "screen_viewed",
            flowId: flowId,
            screenId: screenId
        ))
    }

    public func trackFlowComplete(flowId: String) {
        track(event: ACOEvent(
            eventType: "flow_complete",
            eventName: "flow_completed",
            flowId: flowId
        ))
    }

    // MARK: - Identity

    /// Associate the current user and set attributes. Call after sign-in.
    ///
    /// ```swift
    /// ACO.identify(userId: user.id, attributes: ["plan": "free", "source": "tiktok"])
    /// ```
    public static func identify(userId: String, attributes: [String: Any] = [:]) {
        shared.config = shared.config.map { config in
            ACOConfig(
                projectId: config.projectId,
                sdkKey: config.sdkKey,
                userId: userId,
                apiBaseURL: config.apiBaseURL,
                debug: config.debug
            )
        }
        shared.userAttributes.merge(attributes) { _, new in new }
        // Invalidate cache so next fetch picks up the new userId
        shared.cachedConfig = nil
    }

    /// Merge additional attributes into the current user profile without
    /// resetting the user identity.
    ///
    /// ```swift
    /// ACO.setUserAttributes(["plan": "pro", "trialing": true])
    /// ```
    public static func setUserAttributes(_ attributes: [String: Any]) {
        shared.userAttributes.merge(attributes) { _, new in new }
    }

    /// The user's current subscription status. Set this after verifying a
    /// purchase so personalization rules can target subscribers.
    ///
    /// ```swift
    /// ACO.shared.subscriptionStatus = .active(productId: "com.app.pro_monthly")
    /// ```
    public var subscriptionStatus: ACOSubscriptionStatus = .unknown

    // MARK: - Reset

    /// Clear user identity and attributes on sign-out.
    public static func reset() {
        shared.config = shared.config.map { config in
            ACOConfig(
                projectId: config.projectId,
                sdkKey: config.sdkKey,
                userId: "anonymous",
                apiBaseURL: config.apiBaseURL,
                debug: config.debug
            )
        }
        shared.userAttributes = [:]
        shared.subscriptionStatus = .unknown
        shared.cachedConfig = nil
    }

    // MARK: - Utilities

    private func log(_ message: String) {
        if config?.debug == true {
            print("[ACO] \(message)")
        }
    }
}

// MARK: - Config

struct ACOConfig {
    let projectId: String
    let sdkKey: String
    let userId: String
    let apiBaseURL: String
    let debug: Bool
}

// MARK: - Flow type enum

public enum FlowType: String {
    case onboarding
    case paywall
    case survey
    case upsell
    case custom
}
