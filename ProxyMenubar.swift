// ProxyMenubar.swift
// Build: bash build.sh
// Run:   open ProxyMenubar.app

import AppKit
import Foundation
import UserNotifications

// MARK: - Tunnel Manager

private let proxyHost = "gitlab"

enum TunnelState { case idle, releasing, connecting, connected }

final class TunnelManager {
    private var process: Process?
    private var pipe: Pipe?
    private let lock = NSLock()
    private var logBuffer: [String] = []
    private let logBufferMax = 500
    private var _state: TunnelState = .idle

    var state: TunnelState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    var onUnexpectedDisconnect: (() -> Void)?
    var onStateChanged: ((TunnelState) -> Void)?

    var isConnected: Bool { state == .connected }

    func logs() -> String {
        lock.lock(); defer { lock.unlock() }
        return logBuffer.joined(separator: "\n")
    }

    // Kill any orphaned ssh process holding port 1080 (e.g. left over from previous app run)
    func killOrphanedTunnel() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "lsof -ti :1080 | xargs kill -9 2>/dev/null || true"]
        try? task.run()
        task.waitUntilExit()
    }

    // Async connect — calls back on main thread with optional error string
    func connect(completion: @escaping (String?) -> Void) {
        if isConnected { disconnect() }

        // Go to releasing state, kill orphan async, then proceed
        lock.lock(); _state = .releasing; lock.unlock()
        onStateChanged?(.releasing)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // Keep killing + waiting until port is free, up to 10s total
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if self.isPortFree() { break }
                self.killOrphanedTunnel()
                Thread.sleep(forTimeInterval: 0.5)
            }

            guard self.isPortFree() else {
                self.lock.lock(); self._state = .idle; self.lock.unlock()
                DispatchQueue.main.async {
                    self.onStateChanged?(.idle)
                    completion("Port 1080 could not be released. Please wait and try again.")
                }
                return
            }

            if let err = self.launchSSH() {
                self.lock.lock(); self._state = .idle; self.lock.unlock()
                DispatchQueue.main.async {
                    self.onStateChanged?(.idle)
                    completion(err)
                }
            } else {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    private func launchSSH() -> String? {

        let stderr = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = ["-D", "1080", "-N", "-v", proxyHost]
        proc.standardError = stderr
        proc.standardOutput = FileHandle.nullDevice

        // Full PATH so ProxyCommand (aws ssm ...) resolves from Finder launch
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/usr/local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin",
                          "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let current = env["PATH"] ?? ""
        let merged = (extraPaths + current.split(separator: ":").map(String.init))
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        env["PATH"] = merged.joined(separator: ":")
        proc.environment = env

        lock.lock()
        logBuffer.removeAll()
        lock.unlock()

        // Event-driven stderr reading — fires whenever data is available
        stderr.fileHandleForReading.readabilityHandler = { [weak self] fh in
            guard let self else { return }
            let data = fh.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
            self.lock.lock()
            self.logBuffer.append(contentsOf: lines)
            if self.logBuffer.count > self.logBufferMax {
                self.logBuffer.removeFirst(self.logBuffer.count - self.logBufferMax)
            }
            self.lock.unlock()
        }

        proc.terminationHandler = { [weak self] p in
            guard let self else { return }
            p.standardError.flatMap { $0 as? Pipe }?.fileHandleForReading.readabilityHandler = nil
            self.lock.lock()
            let wasActive = self.process === p
            if wasActive { self.process = nil; self.pipe = nil; self._state = .idle }
            self.lock.unlock()
            if wasActive {
                DispatchQueue.main.async { self.onStateChanged?(.idle) }
                self.onUnexpectedDisconnect?()
            }
        }

        do { try proc.run() } catch {
            return "Failed to launch ssh: \(error.localizedDescription)"
        }

        lock.lock()
        process = proc
        pipe = stderr
        _state = .connecting
        lock.unlock()

        onStateChanged?(.connecting)

        // Poll until port 1080 accepts connections, then flip to connected
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if !proc.isRunning { break }
                if self.isPort1080Reachable() {
                    self.lock.lock()
                    let stillOurs = self.process === proc
                    if stillOurs { self._state = .connected }
                    self.lock.unlock()
                    if stillOurs {
                        DispatchQueue.main.async { self.onStateChanged?(.connected) }
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 0.3)
            }
        }

        return nil
    }

    // Try to bind port 1080 — succeeds only if nothing is listening
    private func isPortFree() -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return true }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(1080)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        close(sock)
        return bound == 0
    }

    // Try to connect to port 1080 — succeeds once SSH SOCKS proxy is accepting
    private func isPort1080Reachable() -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(1080)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        close(sock)
        return result == 0
    }

    func disconnect() {
        lock.lock()
        let proc = process
        let p = pipe
        process = nil
        pipe = nil
        _state = .idle
        lock.unlock()

        onStateChanged?(.idle)

        p?.fileHandleForReading.readabilityHandler = nil
        guard let proc, proc.isRunning else { return }

        proc.terminate()

        // Wait up to 2s for process to actually release port 1080
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            proc.waitUntilExit()
            sem.signal()
        }
        if sem.wait(timeout: .now() + 2) == .timedOut {
            proc.interrupt()
            proc.waitUntilExit()
        }
    }
}


// MARK: - Log Window

final class LogWindowController: NSWindowController, NSWindowDelegate {
    private var textView: NSTextView!
    private let tunnel: TunnelManager
    private var timer: Timer?

    init(tunnel: TunnelManager) {
        self.tunnel = tunnel
        let win = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 720, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Proxy Logs"
        win.isReleasedWhenClosed = false
        super.init(window: win)
        win.delegate = self
        setupTextView()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupTextView() {
        guard let contentView = window?.contentView else { return }
        let bounds = contentView.bounds

        let scroll = NSScrollView(frame: bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder

        // NSTextView must be created via NSScrollView helper to wire up correctly
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.backgroundColor = NSColor(white: 0.08, alpha: 1)
        tv.textColor = .systemGreen
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true

        scroll.documentView = tv
        contentView.addSubview(scroll)
        textView = tv
    }

    func show() {
        if window?.isVisible == true {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        refresh()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func refresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.isVisible == true else { return }
            let text = self.tunnel.logs()
            let display = text.isEmpty ? "(no logs yet — connect first)" : text
            self.textView.string = display
            self.textView.scrollToEndOfDocument(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let tunnel = TunnelManager()
    private var logWindowController: LogWindowController?
    private var toggleItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }

        tunnel.onStateChanged = { [weak self] _ in
            DispatchQueue.main.async { self?.updateMenuState() }
        }

        tunnel.onUnexpectedDisconnect = { [weak self] in
            DispatchQueue.main.async {
                self?.updateMenuState()
                let content = UNMutableNotificationContent()
                content.title = "Proxy Menubar"
                content.body = "Connection was lost"
                let req = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content, trigger: nil)
                UNUserNotificationCenter.current().add(req)
            }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🔌"
        buildMenu()
    }

    // MARK: Menu

    private func buildMenu() {
        let menu = NSMenu()

        // Status line (non-clickable)
        let statusItem = NSMenuItem(title: "Status: Disconnected", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        statusItem.tag = 100
        menu.addItem(statusItem)

        menu.addItem(.separator())

        // Single toggle item
        toggleItem = NSMenuItem(title: "Enable Proxy", action: #selector(toggleProxy), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let logs = NSMenuItem(title: "Show Logs", action: #selector(showLogsClicked), keyEquivalent: "l")
        logs.target = self
        menu.addItem(logs)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        self.statusItem.menu = menu
        updateMenuState()
    }

    private func updateMenuState() {
        guard let menu = statusItem.menu else { return }

        switch tunnel.state {
        case .idle:
            statusItem.button?.title = "🔌"
            menu.item(withTag: 100)?.title = "Status: Disconnected"
            toggleItem.title = "Enable Proxy"
            toggleItem.isEnabled = true
        case .releasing:
            statusItem.button?.title = "⚪"
            menu.item(withTag: 100)?.title = "Releasing port… try again shortly"
            toggleItem.title = "Releasing port…"
            toggleItem.isEnabled = false
        case .connecting:
            statusItem.button?.title = "⚪"
            menu.item(withTag: 100)?.title = "Connecting…"
            toggleItem.title = "Connecting…"
            toggleItem.isEnabled = false
        case .connected:
            statusItem.button?.title = "🟢"
            menu.item(withTag: 100)?.title = "Connected → \(proxyHost)"
            toggleItem.title = "Disable Proxy"
            toggleItem.isEnabled = true
        }
    }

    // MARK: Actions

    @objc private func toggleProxy() {
        switch tunnel.state {
        case .releasing, .connecting:
            return  // ignore clicks while busy
        case .connected:
            tunnel.disconnect()
            updateMenuState()
        case .idle:
            tunnel.connect { [weak self] err in
                guard let self else { return }
                if let err {
                    let alert = NSAlert()
                    alert.messageText = "Connection Failed"
                    alert.informativeText = err
                    alert.runModal()
                }
                self.updateMenuState()
            }
            updateMenuState()  // shows ⚪ releasing/connecting immediately
        }
    }

    @objc private func showLogsClicked() {
        if logWindowController == nil {
            logWindowController = LogWindowController(tunnel: tunnel)
        }
        logWindowController?.show()
    }

    @objc private func quitClicked() {
        // disconnect() already waits for SSH to exit — port is free before app terminates
        tunnel.disconnect()
        // Kill any remaining orphan just in case (e.g. connecting state on quit)
        tunnel.killOrphanedTunnel()
        NSApp.terminate(nil)
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
