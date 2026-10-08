import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let intervalKey = "refreshInterval"
    private static let intervals: [(title: String, seconds: TimeInterval)] = [
        ("10 saniye", 10), ("30 saniye", 30), ("1 dakika", 60), ("5 dakika", 300),
    ]

    private let service = RateService()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?
    private var isFetching = false
    private var snapshot: Snapshot?
    /// Last known gold quote, kept when a refresh comes back without one.
    private var gold: Rate?
    private var lastError = false

    private let usdItem = NSMenuItem()
    private let eurItem = NSMenuItem()
    private let goldItem = NSMenuItem()
    private let infoItem = NSMenuItem()
    private let loginItem = NSMenuItem(title: "Oturum açılışında başlat", action: #selector(toggleLoginItem), keyEquivalent: "")
    private var intervalItems: [NSMenuItem] = []

    private let priceFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.numberStyle = .decimal
        return formatter
    }()

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private var interval: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: Self.intervalKey)
        return Self.intervals.contains { $0.seconds == stored } ? stored : 30
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        statusItem.button?.title = "$ …  € …  Au …"
        buildMenu()
        render()
        scheduleTimer()
        refresh()

        // Refresh right away after the Mac wakes up instead of showing stale rates.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for item in [usdItem, eurItem, goldItem, infoItem] {
            item.isEnabled = false
            menu.addItem(item)
            if item === goldItem { menu.addItem(.separator()) }
        }
        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Şimdi yenile", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let intervalMenu = NSMenu()
        for (index, option) in Self.intervals.enumerated() {
            let item = NSMenuItem(title: option.title, action: #selector(selectInterval(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            intervalMenu.addItem(item)
            intervalItems.append(item)
        }
        let intervalParent = NSMenuItem(title: "Yenileme sıklığı", action: nil, keyEquivalent: "")
        intervalParent.submenu = intervalMenu
        menu.addItem(intervalParent)

        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Çıkış", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = interval * 0.1
        // .common keeps the timer firing while the menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func refresh() {
        guard !isFetching else { return }
        isFetching = true
        Task {
            do {
                let fetched = try await service.fetch()
                snapshot = fetched
                gold = fetched.gold ?? gold
                lastError = false
            } catch {
                lastError = true
            }
            isFetching = false
            render()
        }
    }

    @objc private func selectInterval(_ sender: NSMenuItem) {
        UserDefaults.standard.set(Self.intervals[sender.tag].seconds, forKey: Self.intervalKey)
        scheduleTimer()
        render()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Oturum açılışı ayarı değiştirilemedi"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        render()
    }

    private func price(_ value: Double, digits: Int) -> String {
        priceFormatter.minimumFractionDigits = digits
        priceFormatter.maximumFractionDigits = digits
        return priceFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func detail(_ label: String, _ rate: Rate, digits: Int = 4) -> String {
        var text = "\(label)   \(price(rate.price, digits: digits)) ₺"
        if let change = rate.changePercent {
            let arrow = change > 0 ? "▲" : (change < 0 ? "▼" : "•")
            text += "   \(arrow) %\(price(abs(change), digits: 2))"
        }
        return text
    }

    private func render() {
        if let snapshot {
            var title = "$ \(price(snapshot.usd.price, digits: 2))  € \(price(snapshot.eur.price, digits: 2))"
            if let gold { title += "  Au \(price(gold.price, digits: 0))" }
            statusItem.button?.title = title
            usdItem.title = detail("Dolar (USD/TRY)", snapshot.usd)
            eurItem.title = detail("Euro (EUR/TRY)", snapshot.eur)
            goldItem.title = gold.map { detail("Gram altın", $0, digits: 2) } ?? "Gram altın   —"
            let time = timeFormatter.string(from: snapshot.fetchedAt)
            infoItem.title = lastError
                ? "Bağlantı hatası — son başarılı güncelleme \(time)"
                : "Son güncelleme \(time) · \(snapshot.source)"
        } else {
            usdItem.title = "Dolar (USD/TRY)   —"
            eurItem.title = "Euro (EUR/TRY)   —"
            goldItem.title = "Gram altın   —"
            infoItem.title = lastError ? "Kur alınamadı, tekrar denenecek" : "Kurlar alınıyor…"
            if lastError { statusItem.button?.title = "$ —  € —  Au —" }
        }

        for (index, item) in intervalItems.enumerated() {
            item.state = Self.intervals[index].seconds == interval ? .on : .off
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}
