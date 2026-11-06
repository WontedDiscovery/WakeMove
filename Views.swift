import SwiftUI
import AudioToolbox

// MARK: - Liquid Glass 輔助(iOS 26+ 用 Liquid Glass,舊版退回 Material)
extension View {
    @ViewBuilder func glassCard(_ radius: CGFloat = 24) -> some View {
        if #available(iOS 26, *) { self.glassEffect(.regular, in: .rect(cornerRadius: radius)) }
        else { self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius)) }
    }
    @ViewBuilder func glassCircle() -> some View {
        if #available(iOS 26, *) { self.glassEffect(.regular.interactive(), in: .circle) }
        else { self.background(.ultraThinMaterial, in: Circle()) }
    }
    @ViewBuilder func glassProminentButton() -> some View {
        if #available(iOS 26, *) { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.borderedProminent) }
    }
    @ViewBuilder func glassSecondaryButton() -> some View {
        if #available(iOS 26, *) { self.buttonStyle(.glass) } else { self.buttonStyle(.bordered) }
    }
}

struct Backdrop: View {
    @Environment(\.colorScheme) private var cs
    var body: some View {
        LinearGradient(
            colors: cs == .dark ? [Color.indigo.opacity(0.7), Color.black]
                                : [Color.orange.opacity(0.55), Color.pink.opacity(0.4), Color.purple.opacity(0.5)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        .ignoresSafeArea()
    }
}

private let dayLabels: [(String, Int)] = [("一", 2), ("二", 3), ("三", 4), ("四", 5), ("五", 6), ("六", 7), ("日", 1)]
private func daysText(_ d: Set<Int>) -> String {
    if d.isEmpty { return "只響一次" }
    if d.count == 7 { return "每天" }
    return "週" + dayLabels.filter { d.contains($0.1) }.map { $0.0 }.joined()
}

// MARK: - 根畫面
struct ContentView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        TabView {
            HomeView().tabItem { Label("首頁", systemImage: "alarm") }
            StatsView().tabItem { Label("統計", systemImage: "chart.bar") }
            SettingsView().tabItem { Label("設定", systemImage: "gearshape") }
        }
        .fullScreenCover(item: $store.ringing) { r in RingingView(r: r) }
    }
}

// MARK: - 首頁
struct HomeView: View {
    @EnvironmentObject var store: Store
    @State private var editing: Alarm?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                Backdrop()
                ScrollView {
                    VStack(spacing: 14) {
                        summary
                        if store.s.alarms.isEmpty {
                            Text("還沒有鬧鐘,點右下角 ＋ 新增").foregroundStyle(.secondary).padding(.top, 40)
                        }
                        ForEach(store.s.alarms) { card($0) }
                    }
                    .padding()
                    .padding(.bottom, 80)
                }
                Button { editing = Alarm() } label: {
                    Image(systemName: "plus").font(.title2.bold()).frame(width: 60, height: 60).glassCircle()
                }
                .buttonStyle(.plain).foregroundStyle(.primary).padding(24)
            }
            .navigationTitle("醒動鬧鐘")
            .sheet(item: $editing) { EditView(alarm: $0) }
        }
    }

    private var summary: some View {
        HStack {
            Label("連續 \(store.s.streak) 天", systemImage: "flame.fill").foregroundStyle(.orange)
            Spacer()
            Text("Lv.\(Rules.levelOf(store.s.points)) · \(store.s.points) 分").foregroundStyle(.secondary)
        }
        .font(.headline).padding().glassCard()
    }

    private func card(_ a: Alarm) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(a.timeText).font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("\(a.exercise.title) × \(a.target) · \(daysText(a.repeatDays))")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { a.enabled },
                                     set: { v in var x = a; x.enabled = v; store.upsert(x) }))
                .labelsHidden()
        }
        .padding().glassCard().opacity(a.enabled ? 1 : 0.6)
        .contentShape(Rectangle())
        .onTapGesture { editing = a }
    }
}

// MARK: - 新增 / 編輯鬧鐘
struct EditView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var alarm: Alarm
    @State private var time: Date
    @State private var confirmDelete = false

    init(alarm: Alarm) {
        _alarm = State(initialValue: alarm)
        var c = DateComponents(); c.hour = alarm.hour; c.minute = alarm.minute
        _time = State(initialValue: Calendar.current.date(from: c) ?? Date())
    }

    private var exists: Bool { store.s.alarms.contains { $0.id == alarm.id } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("時間", selection: $time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel).labelsHidden().frame(maxWidth: .infinity)
                }
                Section("重複") {
                    HStack {
                        ForEach(dayLabels, id: \.1) { label, wd in
                            let on = alarm.repeatDays.contains(wd)
                            Button {
                                if on { alarm.repeatDays.remove(wd) } else { alarm.repeatDays.insert(wd) }
                            } label: {
                                Text(label).frame(width: 34, height: 34)
                                    .background(Circle().fill(on ? Color.accentColor : Color.gray.opacity(0.2)))
                                    .foregroundStyle(on ? Color.white : Color.primary)
                            }
                            .buttonStyle(.plain)
                            if wd != 1 { Spacer(minLength: 0) }
                        }
                    }
                }
                Section("甦醒動作") {
                    Picker("動作", selection: $alarm.exercise) {
                        ForEach(Exercise.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    Stepper("目標次數:\(alarm.target)", value: $alarm.target, in: 5...50, step: 5)
                    Toggle("貪睡懲罰(每貪睡一次 +5 下)", isOn: $alarm.snoozePenalty)
                }
                if exists {
                    Section { Button("刪除鬧鐘", role: .destructive) { confirmDelete = true } }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Backdrop())
            .navigationTitle(exists ? "編輯鬧鐘" : "新增鬧鐘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
                        alarm.hour = c.hour ?? 7; alarm.minute = c.minute ?? 0; alarm.enabled = true
                        store.upsert(alarm); dismiss()
                    }
                }
            }
            .confirmationDialog("確定刪除這個鬧鐘?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("刪除", role: .destructive) { store.delete(alarm.id); dismiss() }
            }
        }
    }
}

// MARK: - 統計
struct StatsView: View {
    @EnvironmentObject var store: Store
    private var lv: Int { Rules.levelOf(store.s.points) }
    private var range: (Int, Int) { Rules.levelRange(lv) }
    private var rate: Int {
        let t = store.s.records.count
        return t == 0 ? 0 : store.s.records.filter { $0.result == .success }.count * 100 / t
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop()
                ScrollView {
                    VStack(spacing: 14) {
                        HStack(spacing: 12) {
                            stat("連續天數", "\(store.s.streak)")
                            stat("積分", "\(store.s.points)")
                            stat("等級", "Lv.\(lv)")
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: Double(max(0, store.s.points - range.0)),
                                         total: Double(range.1 - range.0))
                            Text("距離下一級還差 \(range.1 - store.s.points) 分 · 完成率 \(rate)%")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding().glassCard()
                        ForEach(store.s.records.prefix(30)) { row($0) }
                        if store.s.records.isEmpty {
                            Text("還沒有起床紀錄").foregroundStyle(.secondary).padding(.top, 30)
                        }
                    }.padding()
                }
            }
            .navigationTitle("統計")
        }
    }

    private func stat(_ t: String, _ v: String) -> some View {
        VStack { Text(v).font(.title.bold()); Text(t).font(.caption).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity).padding(.vertical, 14).glassCard(20)
    }

    private func row(_ r: WakeRecord) -> some View {
        let icon = r.result == .success ? "checkmark.circle.fill" : (r.result == .failed ? "xmark.circle.fill" : "minus.circle.fill")
        let color: Color = r.result == .success ? .green : (r.result == .failed ? .red : .gray)
        return HStack {
            Image(systemName: icon).foregroundStyle(color).font(.title3)
            VStack(alignment: .leading) {
                Text(r.date.formatted(date: .abbreviated, time: .shortened))
                Text("完成 \(r.done)/\(r.target) · 貪睡 \(r.snoozeCount) 次").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("+\(r.points)").foregroundStyle(.secondary)
        }
        .padding().glassCard(18)
    }
}

// MARK: - 設定
struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section("鬧鐘") {
                    Toggle("一般關閉模式", isOn: $store.s.allowNormalClose)
                    Text("開啟後響鈴頁會出現「一般關閉」,不運動也能關鬧鐘,但該次記為未完成、連續天數歸零。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("權限") {
                    Button("開啟系統設定(相機 / 通知)") {
                        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                    }
                }
                Section("測試") {
                    Button("立即測試響鈴與動作偵測(不計入紀錄)") { store.testRing() }
                }
                Section("隱私") {
                    Text("鏡頭影像只在手機上即時處理,不上傳、不儲存。所有資料目前只存在這支手機。")
                        .font(.footnote)
                }
                Section { Button("清除所有資料", role: .destructive) { confirmReset = true } }
            }
            .scrollContentBackground(.hidden)
            .background(Backdrop())
            .navigationTitle("設定")
            .confirmationDialog("會刪除所有鬧鐘與紀錄,確定嗎?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("全部清除", role: .destructive) { store.resetAll() }
            }
        }
    }
}

// MARK: - 響鈴 / 動作偵測頁
struct RingingView: View {
    @EnvironmentObject var store: Store
    let r: Ringing
    @StateObject private var cam = CameraModel()
    @State private var detecting = false
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var remain: Int { max(0, Int(r.deadline.timeIntervalSince(now))) }

    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 16) {
                Text(String(format: "%d:%02d", remain / 60, remain % 60))
                    .font(.system(size: 56, weight: .bold, design: .rounded)).monospacedDigit()
                Text("\(r.alarm.exercise.title) × \(r.target)").font(.title2.bold())
                if detecting {
                    ZStack(alignment: .bottom) {
                        CameraPreview(session: cam.session).clipShape(RoundedRectangle(cornerRadius: 28))
                        VStack(spacing: 4) {
                            Text("\(cam.count) / \(r.target)").font(.system(size: 44, weight: .bold, design: .rounded))
                            if !cam.hint.isEmpty { Text(cam.hint).font(.callout) }
                        }
                        .padding(.horizontal, 28).padding(.vertical, 10).glassCard().padding()
                    }
                } else {
                    Spacer()
                    Image(systemName: r.alarm.exercise.icon).font(.system(size: 90))
                    Text("完成動作才算成功起床").foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        detecting = true
                        cam.start(r.alarm.exercise, target: r.target)
                    } label: {
                        Text("開始動作").font(.title3.bold()).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .glassProminentButton()
                }
                HStack(spacing: 12) {
                    if r.snoozeCount < 2 {
                        Button("貪睡 5 分鐘") { cam.stop(); store.snooze(r) }.glassSecondaryButton()
                    }
                    if store.s.allowNormalClose {
                        Button("一般關閉") { cam.stop(); store.finish(r, .normalClose, done: cam.count) }
                            .glassSecondaryButton()
                    }
                }
            }
            .padding()
        }
        .onReceive(tick) { t in
            now = t
            AudioServicesPlaySystemSound(1005)
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            if t >= r.deadline { cam.stop(); store.finish(r, .failed, done: cam.count) }
        }
        .onChange(of: cam.done) { _, d in
            if d { cam.stop(); store.finish(r, .success, done: r.target) }
        }
        .onDisappear { cam.stop() }
    }
}
