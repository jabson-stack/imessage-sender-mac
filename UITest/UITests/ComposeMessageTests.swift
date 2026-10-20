import AppKit
import XCTest

/// Writes a new message in Messages on this Mac. NUMBERS (comma-separated,
/// taken by iMessageCollectorMac from the Mobelio API) are tried as recipients.
/// A number goes in the To field and must keep the
/// conversation an iMessage; one that would turn it into a text message
/// (SMS/RCS) is removed again. Every number that has iMessage gets BODY in its own conversation;
/// Send is tapped only when SEND=1 (with SEND=0 each message is written, then
/// the run goes on to the next number; the last one written is left ready in Messages).
/// If the compose view is dismissed in Messages meanwhile, a new one is opened
/// with the same recipients and the run goes on.
/// With SEND_LATER_FROM and SEND_LATER_TO (seconds since 1970), each message is
/// scheduled with Edit → Send Later… at a random minute between them.
/// LOOKUP (seconds, default 4) is how long a number gets to turn into an
/// iMessage before it counts as a text-message number.
/// After MISS_LIMIT (default 20) numbers in a row without iMessage the
/// lookups are taken to have gone stale (Apple throttles them, and Messages
/// remembers the wrong answers): Messages and its iMessage services are
/// restarted and the search goes on with new numbers.
/// If iMessage is signed out (at the start or after a restart), the test signs
/// in with APPLE_ID (email) and APPLE_PASSWORD.
/// Messages on the Mac is a Catalyst app, so the compose view uses the same
/// accessibility names as on iOS: TextField "To:" and the message field
/// "messageBodyField", whose placeholder ("iMessage" or "Text Message…") says
/// which service the conversation uses.
/// Lines printed with a "[bot] " prefix show up in iMessageCollectorMac's log.
final class ComposeMessageTests: XCTestCase {
    private let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var body: String { env["BODY"] ?? "" }
    private var lookupTimeout: TimeInterval { Double(env["LOOKUP"] ?? "") ?? 4 }
    /// The numbers in the To field right now, to put back if the compose
    /// view goes away.
    private var recipients: [String] = []
    private var appleID: String { env["APPLE_ID"] ?? "" }
    private var applePassword: String { env["APPLE_PASSWORD"] ?? "" }
    /// How many numbers in a row without iMessage trigger restarting Messages.
    private var missStreakLimit: Int { max(Int(env["MISS_LIMIT"] ?? "") ?? 20, 1) }
    /// When to schedule messages with Send Later; nil = send now.
    private var sendLaterRange: ClosedRange<Date>? {
        guard let from = Double(env["SEND_LATER_FROM"] ?? ""), let to = Double(env["SEND_LATER_TO"] ?? ""), to >= from else { return nil }
        return Date(timeIntervalSince1970: from)...Date(timeIntervalSince1970: to)
    }

    override func setUp() {
        continueAfterFailure = false
    }

    /// Also runs when XCTest itself stops the test (e.g. an element query fails).
    override func tearDown() {
        if composeIsOpen, !draftLeftReady { clearCompose() }
    }

    /// Tap Send is off and the compose view holds the last message written:
    /// it stays in Messages after the run.
    private var draftLeftReady = false

    func testSendMessage() {
        let numbers = (env["NUMBERS"] ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !numbers.isEmpty else { fail("No numbers given (NUMBERS)") }
        guard !body.isEmpty else { fail("No message body given") }

        // activate(), not launch(), so Messages isn't restarted under the user.
        messages.activate()
        guard messages.wait(for: .runningForeground, timeout: 15) else {
            fail("Messages did not come to the foreground: is it set up and signed in on this Mac?")
        }
        signInIfSignedOut()
        openFreshCompose()
        send(to: numbers)
    }

    // MARK: Send mode

    /// Each number with iMessage gets the message in its own conversation.
    private func send(to numbers: [String]) {
        print("[bot] Messaging \(numbers.count) number(s): \(numbers.joined(separator: ", ")); each one with iMessage gets the message in its own conversation")
        var hits = 0
        var missStreak = 0
        let sending = env["SEND"] == "1"
        for (index, number) in numbers.enumerated() {
            // Tap Send is off: the message written to the last hit is cleared only
            // now that there is another number to try.
            if draftLeftReady {
                openFreshCompose()
                draftLeftReady = false
            }
            if addIfIMessage(number) {
                hits += 1
                missStreak = 0
                writeAndSend(to: number)
                if sending {
                    openFreshCompose()
                } else {
                    draftLeftReady = true
                    if index + 1 < numbers.count { print("[bot] Tap Send is off; going on to the next number") }
                }
            } else {
                missStreak += 1
                if missStreak >= missStreakLimit, index + 1 < numbers.count {
                    print("[bot] \(missStreak) numbers in a row with no iMessage; the lookups may have gone stale, restarting Messages")
                    restartMessages()
                    missStreak = 0
                }
            }
            print("[bot] \(index + 1) of \(numbers.count) tried, \(hits) with iMessage")
        }
        if !draftLeftReady { clearCompose() }
        // Not a failure: iMessageCollectorMac goes on with the next batch.
        if hits == 0 { print("[bot] None of these numbers can receive iMessage") }
    }

    /// Adds `number` to the To field and keeps it only if the conversation is iMessage.
    private func addIfIMessage(_ number: String) -> Bool {
        switch lookUp([number]) {
        case .iMessage:
            print("[bot] \(number): iMessage ✓")
            return true
        case .text(let kind):
            print("[bot] \(number): no iMessage (\(kind)); removing it")
            removeLastRecipient()
            return false
        }
    }

    private func writeAndSend(to number: String) {
        ensureCompose()
        let field = bodyField
        focus(field)
        // Pasting is independent of the keyboard layout; typing a link on a
        // Georgian input source would lose its Latin letters.
        paste(body, into: field)
        var typed = (field.value as? String) ?? ""
        if !shows(body, in: typed) {
            print("[bot] Pasting gave \"\(typed)\"; typing the message instead")
            selectAll(in: field)
            field.typeText(body)
            typed = (field.value as? String) ?? ""
        }
        guard shows(body, in: typed) else {
            fail("Message text came out as \"\(typed)\": characters were dropped (switch the input source to ABC / English)")
        }
        print("[bot] Message written to \(number)")

        if let range = sendLaterRange {
            // Checked now: the Send Later bar replaces the field's "iMessage" placeholder.
            guard service() == .iMessage else { fail("Conversation is no longer iMessage; not scheduling") }
            scheduleSendLater(in: range)
        }

        guard env["SEND"] == "1" else {
            print("[bot] Not sending (Tap Send is off); the message is ready in Messages")
            return
        }
        guard sendLaterRange != nil || service() == .iMessage else { fail("Conversation is no longer iMessage; not sending") }
        let send = messages.buttons.matching(NSPredicate(format: "identifier == 'sendButton' OR label == 'Send'")).firstMatch
        if send.waitForExistence(timeout: 3) {
            send.click()
        } else {
            // Return sends in Messages on the Mac, but only from the message
            // field (after Send Later the focus is still on its time picker),
            // and only Return: Send Later ignores the keypad's Enter.
            focus(field)
            field.typeKey(.return, modifierFlags: [])
        }
        // After the send the compose view turns into the conversation: the To
        // field goes away (or at least the message field is empty again).
        XCTAssertTrue(waitUntil(timeout: 15) { !self.composeIsOpen || ((self.bodyField.value as? String) ?? "").isEmpty },
                      "Message did not leave the compose view")
        recipients = []
        print(sendLaterRange == nil ? "[bot] Sent as iMessage to \(number)" : "[bot] Scheduled as iMessage to \(number)")
    }

    // MARK: Send Later

    /// Edit → Send Later… puts a bar above the message field with two date
    /// pickers: the date (day and month, in the order of the Mac's region) and
    /// the time (hour and minute, plus AM/PM on a 12-hour clock).
    private var sendLaterPickers: XCUIElementQuery { messages.datePickers }

    private var sendLaterClose: XCUIElement {
        messages.buttons.matching(NSPredicate(format: "identifier == 'xmark' AND label == 'Close'")).firstMatch
    }

    /// Opens the Send Later bar and sets it to a random minute in `range`, at
    /// least 2 minutes from now (the range may have begun while the run went on)
    /// and within the 14 days Messages schedules ahead.
    private func scheduleSendLater(in range: ClosedRange<Date>) {
        let earliest = max(range.lowerBound, Date().addingTimeInterval(120))
        let latest = min(range.upperBound, Date().addingTimeInterval(14 * 86400 - 600))
        guard earliest <= latest else { fail("The Send later range is over: it ended \(range.upperBound.formatted())") }
        let seconds = Double.random(in: earliest.timeIntervalSince1970...latest.timeIntervalSince1970)
        let date = Date(timeIntervalSince1970: (seconds / 60).rounded(.down) * 60)

        if sendLaterPickers.count < 2 {
            let edit = messages.menuBars.menuBarItems["Edit"]
            edit.click()
            let item = edit.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Send Later'")).firstMatch
            guard item.waitForExistence(timeout: 3), item.isEnabled else {
                messages.typeKey(.escape, modifierFlags: [])
                fail("Edit → Send Later… is not available in Messages")
            }
            item.click()
            guard waitUntil(timeout: 5, { self.sendLaterPickers.count >= 2 }) else {
                dumpWindow()
                fail("Send Later did not show its date and time")
            }
        }

        let parts = Calendar.current.dateComponents([.day, .month, .hour, .minute], from: date)
        let (day, month, hour24, minute) = (parts.day!, parts.month!, parts.hour!, parts.minute!)
        let order = DateFormatter.dateFormat(fromTemplate: "dM", options: 0, locale: .current) ?? "d/M"
        let dayFirst = (order.firstIndex(of: "d") ?? order.startIndex) < (order.firstIndex(of: "M") ?? order.endIndex)
        let dateFields = sendLaterPickers.element(boundBy: 0).textFields
        let timeFields = sendLaterPickers.element(boundBy: 1).textFields
        let twelveHour = timeFields.count >= 3
        let entries = [
            (dateFields.element(boundBy: dayFirst ? 1 : 0), month),
            (dateFields.element(boundBy: dayFirst ? 0 : 1), day),
            (timeFields.element(boundBy: 0), twelveHour ? (hour24 % 12 == 0 ? 12 : hour24 % 12) : hour24),
            (timeFields.element(boundBy: 1), minute),
        ]
        func shown() -> [Int?] { entries.map { Int(($0.0.value as? String) ?? "") } }
        // Messages pulls a date outside the next 14 days back in (and a 31st
        // into a shorter month), so a field typed early can be changed by a
        // later one: go over them again until they all hold.
        for _ in 0..<3 where shown() != entries.map({ Optional($0.1) }) {
            for (field, value) in entries {
                field.click()
                // Typed into Messages, not the field: clicking a date field
                // opens a calendar popover that hides the field from queries,
                // while the keyboard focus stays on it.
                messages.typeText(String(format: "%02d", value))
                // Escape closes the calendar and keeps what was typed.
                if messages.dialogs.firstMatch.exists { messages.typeKey(.escape, modifierFlags: []) }
            }
            if twelveHour {
                timeFields.element(boundBy: 2).click()
                messages.typeText(hour24 < 12 ? "A" : "P")
            }
            // Tab commits the last field (Return would send the message).
            messages.typeKey(.tab, modifierFlags: [])
        }

        // Never send at a time other than the one picked.
        guard shown() == entries.map({ Optional($0.1) }) else {
            dumpWindow()
            fail("Send Later shows \(shown().map { $0.map(String.init) ?? "?" }) instead of \(entries.map(\.1)) (month, day, hour, minute)")
        }
        print("[bot] Send Later set to \(date.formatted(date: .abbreviated, time: .shortened))")
    }

    // MARK: iMessage check

    private enum Service: Equatable {
        case iMessage
        case text(String)
    }

    /// The message field's placeholder says which service the conversation
    /// uses: "iMessage", or "Text Message" / "Text Message • RCS". nil when
    /// the compose view is gone.
    private func service() -> Service? {
        guard composeIsOpen else { return nil }
        let placeholder = bodyField.placeholderValue ?? ""
        return placeholder == "iMessage" ? .iMessage : .text(placeholder.isEmpty ? "unknown" : placeholder)
    }

    /// Messages looks the number up after it's added, so give it `lookupTimeout`
    /// to turn into an iMessage before calling it a text message. A miss always
    /// costs the whole timeout: the field says "Text Message" from the start.
    private func waitForService() -> Service? {
        let started = Date()
        _ = waitUntil(timeout: lookupTimeout) {
            let service = self.service()
            return service == nil || service == .iMessage
        }
        let result = service()
        if result == .iMessage {
            print("[bot] iMessage showed up after \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        }
        return result
    }

    /// Puts `numbers` in the To field and waits for Messages to look them up.
    /// If the compose view goes away meanwhile, they are tried again on a new one.
    private func lookUp(_ numbers: [String]) -> Service {
        for _ in 0..<3 {
            enterRecipients(numbers)
            if let service = waitForService() { return service }
            print("[bot] The compose view went away during the lookup; trying \(numbers.joined(separator: ", ")) again")
            recipients.removeLast(numbers.count)
        }
        fail("The compose view keeps closing")
    }

    /// Each number ends with a return, so it becomes its own token.
    private func enterRecipients(_ numbers: [String]) {
        ensureCompose()
        let field = toField
        focus(field)
        for number in numbers {
            field.typeText(number)
            field.typeKey(.enter, modifierFlags: [])
        }
        recipients += numbers
    }

    /// The first delete selects the last recipient, the second removes it.
    private func removeLastRecipient() {
        ensureCompose()
        let field = toField
        focus(field)
        field.typeKey(.delete, modifierFlags: [])
        field.typeKey(.delete, modifierFlags: [])
        _ = recipients.popLast()
    }

    // MARK: Compose view

    private var window: XCUIElement { messages.windows.firstMatch }

    /// The recipients field of a new message. Only shown while the message has
    /// no conversation yet, so it doubles as "the compose view is open".
    private var toField: XCUIElement {
        messages.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %d OR elementType == %d OR elementType == %d) AND (identifier == 'To:' OR placeholderValue == 'To:' OR label == 'To:' OR title == 'To:')",
            XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue,
            XCUIElement.ElementType.searchField.rawValue)).firstMatch
    }

    private var bodyField: XCUIElement {
        messages.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'messageBodyField' OR ((elementType == %d OR elementType == %d) AND (placeholderValue == 'iMessage' OR placeholderValue BEGINSWITH 'Text Message' OR placeholderValue BEGINSWITH 'SMS' OR placeholderValue BEGINSWITH 'RCS'))",
            XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue)).firstMatch
    }

    private var composeIsOpen: Bool { toField.exists }

    /// Starts from an empty compose view: one that's already open is emptied
    /// (dropping its draft), otherwise a new one is opened.
    private func openFreshCompose() {
        if toField.waitForExistence(timeout: 2) {
            print("[bot] Emptying the compose view that was already open")
            clearCompose()
            recipients = []
            return
        }
        openCompose()
    }

    /// Everything happens on the compose view, and Messages can drop it under
    /// the bot: another conversation is clicked, the window is closed… Then a
    /// new one is opened and the recipients that were in the To field are put back.
    private func ensureCompose() {
        guard !composeIsOpen else { return }
        print("[bot] The compose view was dismissed; opening a new one")
        messages.activate()
        guard messages.wait(for: .runningForeground, timeout: 15) else { fail("Messages did not come to the foreground") }
        // Messages was only in the background: the compose view is still there.
        guard !toField.waitForExistence(timeout: 2) else { return }
        let lost = recipients
        openCompose()
        guard !lost.isEmpty else { return }
        enterRecipients(lost)
        _ = waitForService()
        print("[bot] Put back \(lost.joined(separator: ", "))")
    }

    /// Opens New Message: ⌘N, or File → New Message if that didn't take.
    private func openCompose() {
        messages.activate()
        if !window.waitForExistence(timeout: 5) {
            // Messages is running without a window: File → New Message opens one.
            print("[bot] Messages has no window open; opening one")
        }
        messages.typeKey("n", modifierFlags: .command)
        if !toField.waitForExistence(timeout: 5) {
            let menu = messages.menuBars.menuBarItems["File"]
            if menu.waitForExistence(timeout: 3) {
                menu.click()
                let item = messages.menuBars.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'New Message' OR title BEGINSWITH 'New iMessage'")).firstMatch
                if item.waitForExistence(timeout: 3) { item.click() }
            }
        }
        guard toField.waitForExistence(timeout: 10) else {
            dumpWindow()
            fail("New Message did not open (no To field found)")
        }
        guard bodyField.waitForExistence(timeout: 10) else {
            dumpWindow()
            fail("New Message has no message field (see the lines above for what Messages shows)")
        }
        recipients = []
        print("[bot] New Message opened")
    }

    /// Empties the compose view (recipients and text) rather than closing it:
    /// an empty New Message disappears by itself when another conversation is
    /// selected, and the next run can reuse it.
    private func clearCompose() {
        guard composeIsOpen else { recipients = []; return }
        // The Send Later bar hides which service the next number gets.
        if sendLaterClose.exists {
            sendLaterClose.click()
            _ = waitUntil(timeout: 3) { !self.sendLaterClose.exists }
        }
        let to = toField
        focus(to)
        // A couple of extra deletes in case a token wasn't ours; they do nothing on an empty field.
        for _ in 0..<(recipients.count + 2) {
            to.typeKey(.delete, modifierFlags: [])
            to.typeKey(.delete, modifierFlags: [])
        }
        recipients = []
        let field = bodyField
        if field.exists, !((field.value as? String) ?? "").isEmpty {
            focus(field)
            selectAll(in: field)
            field.typeKey(.delete, modifierFlags: [])
        }
    }

    // MARK: Keyboard

    /// One click doesn't always move the keyboard focus to a field (Messages
    /// may still be busy looking a number up), and typeText then fails with
    /// "Neither element nor any descendant has keyboard focus": click until it has it.
    private func focus(_ field: XCUIElement) {
        for _ in 0..<5 {
            field.click()
            if waitUntil(timeout: 2, { (field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false }) { return }
        }
        fail("The keyboard focus would not move to the \(field.label.isEmpty ? field.placeholderValue ?? "" : field.label) field")
    }

    /// Messages turns a pasted link into a rich-link attachment, which the
    /// field's value shows as U+FFFC, so the text is checked without its links.
    private func shows(_ text: String, in value: String) -> Bool {
        if value.contains(text) { return true }
        guard value.contains("\u{FFFC}") else { return false }
        let withoutLinks = text.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.contains(withoutLinks)
    }

    private func selectAll(in field: XCUIElement) {
        field.typeKey("a", modifierFlags: .command)
    }

    /// Puts `text` on the pasteboard, pastes it into `field` and restores what
    /// was on the pasteboard before. A `concealed` text (a password) is marked
    /// so clipboard managers don't keep it; its field's value can't be checked.
    private func paste(_ text: String, into field: XCUIElement, concealed: Bool = false) {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        if concealed {
            pasteboard.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
                                     NSPasteboard.PasteboardType("org.nspasteboard.TransientType")], owner: nil)
        }
        pasteboard.setString(text, forType: .string)
        field.typeKey("v", modifierFlags: .command)
        if concealed {
            Thread.sleep(forTimeInterval: 0.5)
        } else {
            _ = waitUntil(timeout: 3) { ((field.value as? String) ?? "").contains(text) }
        }
        pasteboard.clearContents()
        if let previous { pasteboard.setString(previous, forType: .string) }
    }

    // MARK: Restart

    /// Quits Messages and the services behind its lookups, then opens it again
    /// on a fresh compose view. imagent and identityservicesd keep the answers
    /// already looked up and Apple's throttling of new lookups; launchd starts
    /// them again when Messages needs them.
    private func restartMessages() {
        if composeIsOpen { clearCompose() }
        messages.terminate()
        // imagent only starts again together with Messages: killed while
        // Messages is still running, it stays down and every lookup comes
        // back as a text message. (The sandboxed test runner can't list
        // processes, so whether it came back can't be checked afterwards.)
        if messages.wait(for: .notRunning, timeout: 15) {
            for daemon in ["imagent", "identityservicesd"] { killall(daemon) }
            Thread.sleep(forTimeInterval: 3)
        } else {
            print("[bot] Messages did not quit; restarting it without its iMessage services")
        }
        messages.activate()
        guard messages.wait(for: .runningForeground, timeout: 30) else {
            fail("Messages did not start again after the restart")
        }
        print("[bot] Messages restarted")
        signInIfSignedOut()
        openFreshCompose()
    }

    private func killall(_ process: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = [process]
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                print("[bot] Could not restart \(process) (killall exited with \(task.terminationStatus))")
            }
        } catch {
            print("[bot] Could not restart \(process): \(error.localizedDescription)")
        }
    }

    // MARK: iMessage sign-in

    /// Messages shows the "Sign in to iMessage" window when iMessage is
    /// signed out; sign in before anything else.
    private func signInIfSignedOut() {
        guard waitUntil(timeout: 3, { self.signInFormIsOpen }) else { return }
        guard !appleID.isEmpty, !applePassword.isEmpty else {
            fail("iMessage is signed out: enter the Apple ID and password in iMessageCollectorMac, then run again")
        }
        print("[bot] iMessage is signed out; signing in")
        signIn()
        closeSettings()
    }

    private static let iMessageTabPredicate = NSPredicate(format: "label == 'iMessage' OR title == 'iMessage' OR identifier == 'iMessage'")

    /// The Settings window: the one whose toolbar has the iMessage tab.
    private var settingsWindow: XCUIElement {
        messages.windows.containing(Self.iMessageTabPredicate).firstMatch
    }

    private func button(_ titles: [String], in element: XCUIElement) -> XCUIElement {
        element.descendants(matching: .button).matching(NSPredicate(
            format: "label IN %@ OR title IN %@ OR identifier IN %@", titles, titles, titles)).firstMatch
    }

    /// "Email or Phone Number" on the "Sign in to iMessage with your Apple
    /// Account" form, which Messages shows in a window of its own.
    private static let appleIDFieldPredicate = NSPredicate(
        format: "elementType IN %@ AND (placeholderValue CONTAINS[c] 'mail' OR placeholderValue CONTAINS[c] 'Apple' OR label CONTAINS[c] 'mail' OR label CONTAINS[c] 'Apple' OR identifier CONTAINS[c] 'Apple')",
        [XCUIElement.ElementType.textField, .textView, .comboBox].map(\.rawValue))

    /// The sign-in form's window (or sheet), wherever Messages put it.
    private var signInWindow: XCUIElement {
        let form = NSPredicate(format: "elementType == %d", XCUIElement.ElementType.secureTextField.rawValue)
        let either = NSCompoundPredicate(orPredicateWithSubpredicates: [Self.appleIDFieldPredicate, form])
        let window = messages.windows.containing(either).firstMatch
        return window.exists ? window : messages.sheets.containing(either).firstMatch
    }

    private var appleIDField: XCUIElement {
        messages.descendants(matching: .any).matching(Self.appleIDFieldPredicate).firstMatch
    }

    private var passwordField: XCUIElement { messages.secureTextFields.firstMatch }

    private var signInFormIsOpen: Bool { appleIDField.exists || passwordField.exists }

    /// Fills in "Email or Phone Number", Sign In, then the password, Sign In,
    /// and waits for the sign-in window to go away. A two-factor code has to be
    /// entered on the Mac by hand; the test waits for it.
    private func signIn() {
        if appleIDField.exists, !passwordField.exists {
            let idField = appleIDField
            focus(idField)
            selectAll(in: idField)
            paste(appleID, into: idField)
            if (idField.value as? String) != appleID {
                selectAll(in: idField)
                idField.typeText(appleID)
            }
            print("[bot] Entered \(appleID)")
            // Sign In stays disabled until the field has text.
            clickSignIn(orEnterIn: idField)
        }

        guard passwordField.waitForExistence(timeout: 20) else {
            dumpWindow(signInWindow)
            fail("Messages did not ask for the Apple ID password")
        }
        let password = passwordField
        focus(password)
        selectAll(in: password)
        paste(applePassword, into: password, concealed: true)
        clickSignIn(orEnterIn: password)
        print("[bot] Signing in to iMessage as \(appleID)…")

        // Messages may answer "An unknown error occurred."; Sign In again then.
        for attempt in 1...Self.signInRetries {
            if waitUntil(timeout: 20, { !self.signInFormIsOpen || self.signInError.exists }), signInError.exists {
                print("[bot] Messages says \"\(signInError.label.isEmpty ? (signInError.value as? String ?? "") : signInError.label)\"; signing in again (\(attempt) of \(Self.signInRetries))")
                clickSignIn(orEnterIn: passwordField)
                // The old error stays up until Messages has taken the new attempt.
                _ = waitUntil(timeout: 5) { !self.signInError.exists }
            } else {
                break
            }
        }
        if signInFormIsOpen {
            print("[bot] Still not signed in: if Messages asks for a verification code or shows an error, deal with it on this Mac (waiting up to 3 minutes)")
            guard waitUntil(timeout: 180, { !self.signInFormIsOpen }) else {
                dumpWindow(signInWindow)
                fail("Could not sign in to iMessage as \(appleID)")
            }
        }
        print("[bot] Signed in to iMessage as \(appleID)")
    }

    private static let signInRetries = 10

    /// The red error line of the sign-in window, e.g. "An unknown error occurred."
    private var signInError: XCUIElement {
        signInWindow.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] 'error' OR value CONTAINS[c] 'error' OR label CONTAINS[c] 'incorrect' OR value CONTAINS[c] 'incorrect'")).firstMatch
    }

    /// Clicks the sign-in window's Sign In (or Next / Continue) once it is
    /// enabled, or presses Return in `field` if there is none. Waits 3 s first:
    /// clicked right after the field is filled, Messages fails with
    /// "An unknown error occurred."
    private func clickSignIn(orEnterIn field: XCUIElement) {
        Thread.sleep(forTimeInterval: 3)
        let signIn = button(["Sign In", "Next", "Continue"], in: signInWindow)
        if signIn.exists, waitUntil(timeout: 5, { signIn.isEnabled }) {
            signIn.click()
        } else {
            field.typeKey(.enter, modifierFlags: [])
        }
    }

    private func closeSettings() {
        let window = settingsWindow
        guard window.exists else { return }
        let close = window.buttons[XCUIIdentifierCloseWindow]
        if close.exists { close.click() } else { messages.typeKey("w", modifierFlags: .command) }
        _ = waitUntil(timeout: 5) { !self.settingsWindow.exists }
    }

    // MARK: Helpers

    /// Prints the text fields, text views and buttons Messages shows, for
    /// finding the right names when the compose view isn't recognised.
    private func dumpWindow(_ shown: XCUIElement? = nil) {
        let lines = (shown ?? window).debugDescription.split(separator: "\n")
            .filter { $0.contains("TextField") || $0.contains("TextView") || $0.contains("Button") || $0.contains("placeholder") }
        print("[bot] Messages shows:")
        for line in lines.prefix(80) { print("[bot]    " + line.trimmingCharacters(in: .whitespaces)) }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return condition()
    }

    private func fail(_ message: String) -> Never {
        print("[bot] ❌ \(message)")
        // Don't leave a half-written message in Messages.
        if composeIsOpen { clearCompose() }
        XCTFail(message)
        fatalError(message)
    }
}
