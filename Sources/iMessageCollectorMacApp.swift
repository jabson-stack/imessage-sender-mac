import AppKit
import Security
import SwiftUI

@main
struct iMessageCollectorMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("iMessageCollectorMac") {
            ContentView()
                .frame(minWidth: 560, minHeight: 400)
        }
        .windowResizability(.contentSize)
    }
}

/// Quitting iMessageCollectorMac must take its xcodebuild session down with it, or the
/// orphaned session keeps driving Messages.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        Runner.active?.terminateCurrentProcess()
    }
}

// MARK: - Paths

enum iMessageCollectorMacPaths {
    /// The iMessageCollectorMac folder; iMessageCollectorMac.app is built into iMessageCollectorMac/build.
    static let root = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
    static let testProject = root.appendingPathComponent("UITest/UITest.xcodeproj")
    static let derivedData = root.appendingPathComponent("build/DerivedData")
}

// MARK: - UI

struct ContentView: View {
    /// The Apple developer team that signs the UI test runner (Personal Team).
    @AppStorage("teamID") private var teamID = "U6GX266ND3"
    @AppStorage("body") private var messageBody = "https://apps.apple.com/ge/app/mobelio-game/id6781200469"
    @AppStorage("tapSend") private var tapSend = true
    /// The country whose numbers are taken from Mobelio, e.g. "US" or "GE".
    @AppStorage("countryCode") private var countryCode = "US"
    /// How many numbers (1–500) to take from Mobelio and message.
    @AppStorage("numberCount") private var numberCount = 3
    /// How long a number gets to turn into an iMessage before it counts as a
    /// text-message number. Every miss costs this much time.
    @AppStorage("lookupSeconds") private var lookupSeconds = 4.0
    /// The Apple ID (email) Messages is signed in with if iMessage is signed out.
    @AppStorage("appleID") private var appleID = ""
    /// Kept in the Keychain, not in the app's preferences.
    @State private var applePassword = Keychain.applePassword
    /// How many numbers in a row without iMessage before Messages is restarted.
    @AppStorage("missLimit") private var missLimit = 20
    /// Schedule each message with Messages' Send Later, at a random time from–to.
    @AppStorage("sendLater") private var sendLater = false
    /// Seconds since 1970 (AppStorage can't keep a Date).
    @AppStorage("sendLaterFrom") private var sendLaterFrom = Date().addingTimeInterval(3600).timeIntervalSince1970
    @AppStorage("sendLaterTo") private var sendLaterTo = Date().addingTimeInterval(86400).timeIntervalSince1970
    @StateObject private var runner = Runner()

    private func date(_ seconds: Binding<Double>) -> Binding<Date> {
        Binding { Date(timeIntervalSince1970: seconds.wrappedValue) }
            set: { seconds.wrappedValue = $0.timeIntervalSince1970 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField("Signing team ID", text: $teamID)
                LabeledContent("Country code") {
                    HStack {
                        TextField("Country code", text: $countryCode)
                            .labelsHidden()
                            .frame(width: 60)
                        Text("whose numbers are taken from Mobelio, e.g. US or GE")
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Next count") {
                    HStack {
                        TextField("Next count", value: $numberCount, format: .number)
                            .labelsHidden()
                            .frame(width: 60)
                        Text("numbers (1–500) per batch from Mobelio; the next batch is taken when one is done, until Stop")
                            .foregroundStyle(.secondary)
                    }
                }
                TextField("Message", text: $messageBody)
                Toggle("Tap Send (otherwise the first message is left ready in Messages)", isOn: $tapSend)
                Toggle("Send later (Messages sends each one at a random time from–to)", isOn: $sendLater)
                if sendLater {
                    DatePicker("From", selection: date($sendLaterFrom), in: Date()...)
                    DatePicker("To", selection: date($sendLaterTo), in: Date()...Date().addingTimeInterval(Message.sendLaterLimit))
                }
                LabeledContent("Lookup wait") {
                    HStack {
                        TextField("Lookup wait", value: $lookupSeconds, format: .number)
                            .labelsHidden()
                            .frame(width: 60)
                        Text("seconds for a number to show iMessage; every miss costs this long (the log says how long hits took)")
                            .foregroundStyle(.secondary)
                    }
                }
                TextField("Apple ID", text: $appleID, prompt: Text("email signed in to iMessage"))
                SecureField("Password", text: $applePassword)
                LabeledContent("Miss limit") {
                    HStack {
                        TextField("Miss limit", value: $missLimit, format: .number)
                            .labelsHidden()
                            .frame(width: 60)
                        Text("numbers in a row without iMessage before Messages is restarted")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Button { start() } label: {
                    Label(runner.isRunning ? "Running batches until Stop…"
                          : tapSend ? "Send iMessage" : "Write iMessage (don't send)",
                          systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(runner.isRunning || !(1...500).contains(numberCount) || missLimit < 1)

                if runner.isRunning {
                    Button(role: .destructive) { runner.stop() } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .controlSize(.large)
                }
            }

            ScrollView {
                Text(runner.log)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding()
        .task {
            if CommandLine.arguments.contains("--run") { start() }
        }
    }

    private func start() {
        Keychain.applePassword = applePassword
        runner.run(teamID: teamID.trimmingCharacters(in: .whitespaces),
                   message: Message(body: messageBody, send: tapSend,
                                    countryCode: countryCode.trimmingCharacters(in: .whitespaces),
                                    count: numberCount,
                                    lookupSeconds: max(lookupSeconds, 1),
                                    appleID: appleID.trimmingCharacters(in: .whitespaces),
                                    applePassword: applePassword,
                                    missLimit: missLimit,
                                    sendLater: sendLater
                                        ? Date(timeIntervalSince1970: sendLaterFrom)...Date(timeIntervalSince1970: max(sendLaterTo, sendLaterFrom))
                                        : nil))
    }
}

struct Message {
    let body: String
    let send: Bool
    /// The country whose numbers are taken from Mobelio.
    let countryCode: String
    /// How many numbers (1–500) to take from Mobelio and message.
    let count: Int
    /// How long to wait for a number to show iMessage.
    let lookupSeconds: Double
    /// Signed in to iMessage with if it is signed out; empty = never.
    let appleID: String
    let applePassword: String
    /// Numbers in a row without iMessage before restarting Messages.
    let missLimit: Int
    /// Each message is scheduled with Send Later at a random time in this range; nil = sent now.
    let sendLater: ClosedRange<Date>?

    /// Messages schedules up to 14 days ahead.
    static let sendLaterLimit: TimeInterval = 14 * 86400
}

/// The Apple ID password, as a generic password in the login keychain.
enum Keychain {
    private static let item: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "ge.space.iMessageCollectorMac",
        kSecAttrAccount as String: "Apple ID password",
    ]

    static var applePassword: String {
        get {
            var query = item
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        set {
            guard newValue != applePassword else { return }
            SecItemDelete(item as CFDictionary)
            guard !newValue.isEmpty else { return }
            var add = item
            add[kSecValueData as String] = Data(newValue.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

struct AutomationError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MARK: - Runner

@MainActor
final class Runner: ObservableObject {
    @Published var log = ""
    @Published var isRunning = false

    /// The runner of the run in progress, for the app delegate.
    static weak var active: Runner?

    private var stopRequested = false
    private var currentProcess: Process?

    private let api = MobelioAPI()
    /// Set once the API refuses the login: retrying would lock the account (5 failures in 15 minutes).
    private var loginRefused: String?

    func run(teamID: String, message: Message) {
        isRunning = true
        stopRequested = false
        log = ""
        Self.active = self
        Task {
            do {
                guard !teamID.isEmpty else { throw AutomationError("Enter the signing team ID") }
                guard teamID.count == 10, teamID.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else {
                    throw AutomationError("The signing team ID \"\(teamID)\" isn't 10 capital letters and digits: copy it from Xcode → Settings → Accounts (e.g. 4WS8VKQEGB)")
                }
                guard !message.body.isEmpty else { throw AutomationError("Enter the message") }
                guard !message.countryCode.isEmpty else { throw AutomationError("Enter the country code") }
                guard (1...500).contains(message.count) else { throw AutomationError("Enter how many numbers to take from Mobelio (1–500)") }
                guard message.missLimit >= 1 else { throw AutomationError("Enter a miss limit of at least 1") }
                if let range = message.sendLater {
                    guard range.upperBound > Date().addingTimeInterval(120) else { throw AutomationError("The Send later range is over: pick a To in the future") }
                    guard range.upperBound <= Date().addingTimeInterval(Message.sendLaterLimit) else {
                        throw AutomationError("Messages can only schedule up to 14 days ahead: pick an earlier To")
                    }
                }
                guard message.appleID.isEmpty == message.applePassword.isEmpty else {
                    throw AutomationError("Enter both the Apple ID and its password (or leave both empty to never sign in)")
                }
                try checkMessagesApp()
                try await buildTest(teamID: teamID)
                // Taken only once the test is built: numbers handed out aren't handed out again.
                // One batch after another, until Stop or the country's list runs out.
                var batch = 0
                while !stopRequested {
                    let numbers = try await nextNumbers(countryCode: message.countryCode, count: message.count)
                    guard !numbers.isEmpty else {
                        append("Mobelio has no \(message.countryCode) numbers left")
                        break
                    }
                    batch += 1
                    append("Batch \(batch):")
                    try await writeMessage(message, to: numbers, teamID: teamID)
                }
                append(stopRequested ? "⏹ Stopped" : "✅ Done")
            } catch {
                append(stopRequested ? "⏹ Stopped" : "❌ \(error.localizedDescription)")
            }
            isRunning = false
        }
    }

    func stop() {
        guard isRunning, !stopRequested else { return }
        stopRequested = true
        append("⏹ Stopping…")
        terminateCurrentProcess()
    }

    func terminateCurrentProcess() {
        guard let process = currentProcess, process.isRunning else { return }
        process.terminate()
        // Give xcodebuild a moment to take its test runner down with it.
        for _ in 0..<20 where process.isRunning { Thread.sleep(forTimeInterval: 0.1) }
    }

    // MARK: Steps

    private func checkMessagesApp() throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.MobileSMS") else {
            throw AutomationError("Messages is not installed on this Mac")
        }
        append("Messages: \(url.path) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    /// Builds and signs the UI test once, so the run only installs and runs it.
    private func buildTest(teamID: String) async throws {
        guard FileManager.default.fileExists(atPath: iMessageCollectorMacPaths.testProject.path) else {
            throw AutomationError("UI test project not found at \(iMessageCollectorMacPaths.testProject.path)")
        }
        append("Building the UI test…")
        try await xcodebuild("build-for-testing", teamID: teamID)
    }

    /// Takes the country's next numbers with POST /v1/phone-numbers/next.
    /// Empty when the country's list has run out.
    private func nextNumbers(countryCode: String, count: Int) async throws -> [String] {
        append("Taking \(count) \(countryCode) number(s) from Mobelio…")
        let numbers: [String]
        do {
            numbers = try await withMobelioSession { try await self.api.nextPhoneNumbers(countryCode: countryCode, count: count) }
        } catch let error as AutomationError {
            throw error
        } catch {
            throw AutomationError("Couldn't take numbers from Mobelio: \(describe(error))")
        }
        if !numbers.isEmpty, numbers.count < count { append("   Mobelio only had \(numbers.count) \(countryCode) number(s) left") }
        return numbers
    }

    /// Runs the UI test that writes the message in Messages to the numbers
    /// that have iMessage and, if asked, taps Send.
    private func writeMessage(_ message: Message, to numbers: [String], teamID: String) async throws {
        append("Messaging \(numbers.count) number(s)…")
        // xcodebuild hands TEST_RUNNER_-prefixed variables to the test, without the prefix.
        try await xcodebuild("test-without-building", teamID: teamID, environment: [
            "TEST_RUNNER_BODY": message.body,
            "TEST_RUNNER_SEND": message.send ? "1" : "0",
            "TEST_RUNNER_NUMBERS": numbers.joined(separator: ","),
            "TEST_RUNNER_LOOKUP": String(message.lookupSeconds),
            "TEST_RUNNER_APPLE_ID": message.appleID,
            "TEST_RUNNER_APPLE_PASSWORD": message.applePassword,
            "TEST_RUNNER_MISS_LIMIT": String(message.missLimit),
            // Seconds since 1970; empty = send now.
            "TEST_RUNNER_SEND_LATER_FROM": message.sendLater.map { String(Int($0.lowerBound.timeIntervalSince1970)) } ?? "",
            "TEST_RUNNER_SEND_LATER_TO": message.sendLater.map { String(Int($0.upperBound.timeIntervalSince1970)) } ?? "",
        ])
    }

    private func xcodebuild(_ action: String, teamID: String, environment: [String: String] = [:]) async throws {
        let result = try await shell(
            "xcodebuild", action, "-project", iMessageCollectorMacPaths.testProject.path, "-scheme", "UITest",
            "-destination", "platform=macOS", "-derivedDataPath", iMessageCollectorMacPaths.derivedData.path,
            "-allowProvisioningUpdates", "-collect-test-diagnostics", "never",
            "DEVELOPMENT_TEAM=\(teamID)",
            environment: environment
        ) { line in
            if line.hasPrefix("[bot] ") { self.append("   " + line.dropFirst(6)) }
        }
        guard result.status == 0 else {
            // The test said why it stopped; that line is already in the log.
            if let reason = result.output.split(separator: "\n").last(where: { $0.hasPrefix("[bot] ❌ ") }) {
                throw AutomationError(String(reason.dropFirst("[bot] ❌ ".count)))
            }
            if result.output.contains("No Accounts: Add a new account") {
                throw AutomationError("Xcode has no Apple account, so the test can't be signed: open Xcode → Settings → Accounts, add the Apple ID of team \(teamID), then run again")
            }
            if result.output.contains("Timed out waiting for automation session")
                || result.output.contains("automation session")
                || result.output.contains("Accessibility")
                || result.output.contains("not authorized") {
                throw AutomationError("macOS did not let the test runner control Messages: open System Settings → Privacy & Security → Accessibility, enable iMessageCollectorMacUITests-Runner (and Xcode Helper if it is listed), then run again")
            }
            let failure = result.output.split(separator: "\n").last { $0.contains("error:") }
                .map { $0.split(separator: ":").suffix(2).joined(separator: ":") } ?? String(result.output.suffix(500))
            throw AutomationError("UI test failed: \(failure)")
        }
    }

    // MARK: Helpers

    /// Logs in with MobelioCredentials when there is no session (or it has ended), then makes the call.
    private func withMobelioSession<T>(_ call: () async throws -> T) async throws -> T {
        if !(await api.isLoggedIn) { try await logIn() }
        do {
            return try await call()
        } catch MobelioError.sessionExpired {
            try await logIn()
            return try await call()
        }
    }

    private func logIn() async throws {
        if let loginRefused { throw AutomationError(loginRefused) }
        do {
            try await api.login(username: MobelioCredentials.username, password: MobelioCredentials.password)
        } catch MobelioError.invalidCredentials {
            loginRefused = "the API refused the login in MobelioCredentials.swift; fix it and restart the app"
            throw AutomationError(loginRefused!)
        }
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case MobelioError.tooManyAttempts(let seconds): "too many failed logins, try again in \(seconds / 60) min"
        case MobelioError.api(let status, let code): "API error \(status) \(code)"
        case let error as MobelioError: "\(error)"
        default: error.localizedDescription
        }
    }

    private func append(_ line: String) {
        log += line + "\n"
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private func shell(_ args: String..., environment: [String: String] = [:],
                       onLine: (String) -> Void = { _ in }) async throws -> (status: Int32, output: String) {
        try await shell(args, environment: environment, onLine: onLine)
    }

    /// Runs a command, streaming each output line to `onLine`, and returns its
    /// exit status and full output. `trackProcess` makes it the process Stop kills.
    private func shell(_ args: [String], environment: [String: String] = [:], trackProcess: Bool = true,
                       onLine: (String) -> Void = { _ in }) async throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // Helpers xcodebuild leaves running keep the pipe open after it exits,
        // so stop reading shortly after it is gone.
        let reader = pipe.fileHandleForReading
        process.terminationHandler = { _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { try? reader.close() }
        }
        try process.run()
        if trackProcess { currentProcess = process }
        defer { if trackProcess { currentProcess = nil } }

        var output = ""
        do {
            for try await line in reader.bytes.lines {
                output += line + "\n"
                onLine(line)
            }
        } catch {
            // The pipe was closed under the reader: the process has ended.
        }
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}
