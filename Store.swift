import SwiftUI
import UserNotifications

struct Snapshot: Codable {
    var alarms: [Alarm] = []
    var records: [WakeRecord] = []
    var streak = 0
    var points = 0
    var allowNormalClose = false
    var snoozes: [Snooze] = []
    var handled: [String] = []
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()
    @Published var s: Snapshot { didSet { persist() } }
    @Published var ringing: Ringing?
    private let key = "wakemove.v1"

    init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let v = try? JSONDecoder().decode(Snapshot.self, from: d) { s = v } else { s = Snapshot() }
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: key) }
    }

    // MARK: 鬧鐘 CRUD
    func upsert(_ a: Alarm) {
        if let i = s.alarms.firstIndex(where: { $0.id == a.id }) { s.alarms[i] = a } else { s.alarms.append(a) }
        s.alarms.sort { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
        reschedule()
    }
    func delete(_ id: UUID) { s.alarms.removeAll { $0.id == id }; reschedule() }
    func resetAll() { s = Snapshot(); ringing = nil; reschedule() }

    // MARK: 排程:每次響鈴連發 6 則通知(每 30 秒),撐滿 3 分鐘窗口
    func reschedule() {
        let c = UNUserNotificationCenter.current()
        c.removeAllPendingNotificationRequests()
        let now = Date(), cal = Calendar.current
        s.snoozes.removeAll { $0.at <= now }
        var occ: [(Alarm, Date, Int)] = []
        for a in s.alarms where a.enabled {
            for d in 0..<8 {
                guard let day = cal.date(byAdding: .day, value: d, to: now),
                      let t = cal.date(bySettingHour: a.hour, minute: a.minute, second: 0, of: day),
                      t > now else { continue }
                if a.repeatDays.isEmpty || a.repeatDays.contains(cal.component(.weekday, from: t)) {
                    occ.append((a, t, 0))
                    if a.repeatDays.isEmpty { break }
                }
            }
        }
        for sn in s.snoozes {
            if let a = s.alarms.first(where: { $0.id == sn.alarmID }) { occ.append((a, sn.at, sn.count)) }
        }
        occ.sort { $0.1 < $1.1 }
        for (a, t, sc) in occ.prefix(10) {   // iOS 最多 64 則待發通知 → 最近 10 次響鈴
            let target = Rules.targetWithPenalty(a.target, sc, a.snoozePenalty)
            for i in 0..<6 {
                let fire = t.addingTimeInterval(Double(i) * 30)
                let content = UNMutableNotificationContent()
                content.title = "⏰ 起床運動時間!"
                content.body = "點開 App:\(a.exercise.title) × \(target),3 分鐘內完成"
                content.sound = .default
                content.userInfo = ["alarm": a.id.uuidString, "start": t.timeIntervalSince1970, "sc": sc]
                let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire)
                let trig = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                c.add(UNNotificationRequest(identifier: "\(a.id)|\(Int(t.timeIntervalSince1970))|\(i)",
                                            content: content, trigger: trig))
            }
        }
    }

    // MARK: 響鈴流程
    func handleRing(_ info: [AnyHashable: Any]) {
        guard let idStr = info["alarm"] as? String, let id = UUID(uuidString: idStr),
              let t = info["start"] as? Double,
              let alarm = s.alarms.first(where: { $0.id == id }) else { return }
        let r = Ringing(alarm: alarm, start: Date(timeIntervalSince1970: t), snoozeCount: info["sc"] as? Int ?? 0)
        if s.handled.contains(r.id) || ringing?.id == r.id { return }
        if Date() > r.deadline { finish(r, .failed, done: 0) }       // 沒開 App,逾時補記失敗
        else if ringing == nil { ringing = r }
    }

    func syncDelivered() {
        UNUserNotificationCenter.current().getDeliveredNotifications { list in
            let infos = list.map { $0.request.content.userInfo }
            Task { @MainActor in
                for i in infos { self.handleRing(i) }
                UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                self.reschedule()
            }
        }
    }

    func snooze(_ r: Ringing) {
        guard r.snoozeCount < 2 else { return }
        s.handled.append(r.id)
        s.snoozes.append(Snooze(alarmID: r.alarm.id, at: Date().addingTimeInterval(300), count: r.snoozeCount + 1))
        ringing = nil
        reschedule()
    }

    func finish(_ r: Ringing, _ result: WakeResult, done: Int) {
        guard !s.handled.contains(r.id) else { return }
        s.handled.append(r.id)
        if s.handled.count > 200 { s.handled.removeFirst(100) }
        if ringing?.id == r.id { ringing = nil }
        if !r.isTest {
            let newStreak = Rules.nextStreak(s.streak, result)
            let gain = Rules.pointsFor(result, r.snoozeCount, newStreak)
            s.streak = newStreak
            s.points += gain
            s.records.insert(WakeRecord(result: result, snoozeCount: r.snoozeCount, target: r.target,
                                        done: done, points: gain), at: 0)
            if r.alarm.repeatDays.isEmpty, let i = s.alarms.firstIndex(where: { $0.id == r.alarm.id }) {
                s.alarms[i].enabled = false
            }
        }
        reschedule()
    }

    func testRing() {
        ringing = Ringing(alarm: s.alarms.first ?? Alarm(), start: Date(), snoozeCount: 0, isTest: true)
    }
}
