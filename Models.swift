import Foundation

enum Exercise: String, Codable, CaseIterable, Identifiable {
    case jumpingJack, raiseHands, squat
    var id: String { rawValue }
    var title: String {
        switch self {
        case .jumpingJack: return "開合跳"
        case .raiseHands: return "舉手"
        case .squat: return "深蹲"
        }
    }
    var icon: String {
        switch self {
        case .jumpingJack: return "figure.jumprope"
        case .raiseHands: return "figure.arms.open"
        case .squat: return "figure.strengthtraining.functional"
        }
    }
}

struct Alarm: Codable, Identifiable, Equatable {
    var id = UUID()
    var hour = 7
    var minute = 0
    var repeatDays: Set<Int> = []   // Calendar weekday: 1=日 2=一 ... 7=六;空=只響一次
    var exercise: Exercise = .jumpingJack
    var target = 20
    var snoozePenalty = true
    var enabled = true
    var timeText: String { String(format: "%02d:%02d", hour, minute) }
}

enum WakeResult: String, Codable { case success, failed, normalClose }

struct WakeRecord: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var result: WakeResult
    var snoozeCount: Int
    var target: Int
    var done: Int
    var points: Int
}

struct Snooze: Codable { var alarmID: UUID; var at: Date; var count: Int }

struct Ringing: Identifiable, Equatable {
    var alarm: Alarm
    var start: Date
    var snoozeCount: Int
    var isTest = false
    var id: String { "\(alarm.id)|\(Int(start.timeIntervalSince1970))" }
    var deadline: Date { start.addingTimeInterval(Rules.ringWindow) }   // 響鈴起算 3 分鐘
    var target: Int { Rules.targetWithPenalty(alarm.target, snoozeCount, alarm.snoozePenalty) }
}

/// 規格書第 11 章、22.7 的規則(純函式)
enum Rules {
    static let ringWindow: TimeInterval = 180
    static let thresholds = [0, 100, 250, 450, 700]

    static func levelOf(_ p: Int) -> Int {
        if p >= 700 { return 5 + (p - 700) / 300 }
        var lv = 1
        for i in 1..<thresholds.count where p >= thresholds[i] { lv = i + 1 }
        return lv
    }
    static func levelRange(_ lv: Int) -> (Int, Int) {
        lv >= 5 ? (700 + (lv - 5) * 300, 700 + (lv - 4) * 300) : (thresholds[lv - 1], thresholds[lv])
    }
    static func pointsFor(_ r: WakeResult, _ snoozes: Int, _ newStreak: Int) -> Int {
        guard r == .success else { return 0 }
        var p = snoozes > 0 ? 5 : 10
        if newStreak > 0 && newStreak % 7 == 0 { p += 20 }
        return p
    }
    static func nextStreak(_ cur: Int, _ r: WakeResult) -> Int { r == .success ? cur + 1 : 0 }
    static func targetWithPenalty(_ base: Int, _ snoozes: Int, _ on: Bool) -> Int {
        on ? min(50, max(base, base + 5 * snoozes)) : base
    }
}
