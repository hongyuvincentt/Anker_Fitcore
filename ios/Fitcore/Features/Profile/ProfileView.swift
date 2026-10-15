import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingGoals = false
    @State private var showingEnvironment = false
    @State private var bodyView = "front"
    @State private var selectedAction: String?
    @State private var selectedMuscleName: String?
    @State private var sourceActivity: RecordedActivity?
    @State private var activityPage = 0

    private var todayReviews: [TrainingReview] {
        store.history.filter { Calendar.current.isDateInToday($0.date) }.sorted { $0.date < $1.date }
    }
    private var calories: Int? {
        guard !todayReviews.isEmpty, todayReviews.allSatisfy({ $0.displayCalories != nil }) else { return nil }
        return todayReviews.compactMap(\.displayCalories).reduce(0, +)
    }
    private var minutes: Int { todayReviews.reduce(0) { $0 + $1.durationMinutes } }
    private var activities: [RecordedActivity] {
        // Each session retains its event order; adjacent sessions are not merged.
        todayReviews.flatMap { RecordedActivity.build(from: $0.events) }
    }
    private var activeMuscles: [String] {
        guard !todayReviews.isEmpty else { return [] }
        if let selected = activities.first(where: { $0.id == selectedAction }) { return selected.muscles }
        return Array(Set(activities.flatMap(\.muscles))).sorted()
    }
    private var muscleTitle: String {
        let names = activeMuscles.compactMap { ProfileMuscle.labels[$0] }
        return names.isEmpty ? (todayReviews.isEmpty ? "暂无今日训练" : "已记录动作 · 肌群待确认") : names.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            goalsCard
            bodyCard
                .frame(maxHeight: .infinity)
            Label(todayReviews.isEmpty ? "保存训练后，动作和肌群会显示在这里。" : "肌群依据训练记录生成，非传感器检测。", systemImage: "info.circle")
                .font(.system(size: 10)).foregroundStyle(FitcoreTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 12)
        .background(FitcoreTheme.canvas).foregroundStyle(FitcoreTheme.ink)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingGoals) { ProfileGoalSheet() }
        .sheet(isPresented: $showingEnvironment) { EnvironmentView() }
        .sheet(item: $sourceActivity) { activity in RecordedActivitySourceView(activity: activity) }
        .onChange(of: activities.map(\.id)) { _, ids in
            activityPage = 0
            if let selectedAction, !ids.contains(selectedAction) { self.selectedAction = nil }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("FITCORE · YOUR PROGRESS").font(.system(size: 10, weight: .bold)).tracking(1.1)
                    .foregroundStyle(FitcoreTheme.muted)
                Text("我的训练成效").font(.system(size: 28, weight: .bold))
            }
            Spacer(minLength: 8)
            Button { showingEnvironment = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .medium)).foregroundStyle(FitcoreTheme.accent)
                    .frame(width: 42, height: 42)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14))
            }
            .accessibilityLabel("打开开发环境设置")
        }
    }

    private var goalsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("今日目标").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("设置目标") { showingGoals = true }
                    .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 7)
                    .background(FitcoreTheme.accent.opacity(0.08), in: Capsule())
            }
            HStack(spacing: 16) {
                goalMeter("卡路里消耗", value: calories, goal: store.preferences.goalCalories, unit: "kcal")
                Rectangle().fill(FitcoreTheme.line).frame(width: 1, height: 78)
                goalMeter("运动时间", value: minutes, goal: store.preferences.goalMinutes, unit: "分钟")
            }
            if !todayReviews.isEmpty {
                Label(calories == nil ? "热量未估算，等待可靠来源。" : (todayReviews.allSatisfy(\.isSimulated) ? "模拟估算 · 演示数据" : "热量依据记录的估算来源，非传感器测量。"), systemImage: "info.circle")
                    .font(.system(size: 10)).foregroundStyle(FitcoreTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16).background(.white, in: RoundedRectangle(cornerRadius: 24))
    }

    private func goalMeter(_ title: String, value: Int?, goal: Int, unit: String) -> some View {
        let progress = min(1, Double(value ?? 0) / Double(max(1, goal)))
        return VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12)).foregroundStyle(FitcoreTheme.muted)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(todayReviews.isEmpty ? "—" : value.map(String.init) ?? "未估算")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(todayReviews.isEmpty || value == nil ? FitcoreTheme.muted : FitcoreTheme.accent)
                Text("/ \(goal) \(unit)").font(.system(size: 10)).foregroundStyle(FitcoreTheme.muted)
            }
            .lineLimit(1).minimumScaleFactor(0.75)
            GeometryReader { geometry in
                Capsule().fill(FitcoreTheme.accent.opacity(0.10))
                    .overlay(alignment: .leading) {
                        Capsule().fill(LinearGradient(colors: [Color(red: 0.44, green: 0.71, blue: 1), FitcoreTheme.accent], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geometry.size.width * progress)
                    }
            }
            .frame(height: 6)
            Text(todayReviews.isEmpty ? "保存训练后同步" : value.map { $0 >= goal ? "今日目标已达成" : "还差 \(goal - $0) \(unit)" } ?? "等待可靠估算来源")
                .font(.system(size: 10)).foregroundStyle(FitcoreTheme.muted)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bodyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("今日训练部位").font(.system(size: 17, weight: .semibold))
                    Text(selectedMuscleName.map { "\($0) · 肌群分布示意" } ?? muscleTitle)
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Text(activeMuscles.isEmpty ? (activities.isEmpty ? "等待记录" : "待确认") : "\(activeMuscles.count) 个部位")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .background(.white.opacity(0.09), in: Capsule())
            }
            HStack(spacing: 18) {
                HStack(spacing: 0) {
                    bodySwitch("男", selected: store.preferences.gender == "male") { setGender("male") }
                    bodySwitch("女", selected: store.preferences.gender == "female") { setGender("female") }
                }
                .background(.white.opacity(0.07), in: Capsule())
                HStack(spacing: 0) {
                    bodySwitch("正面", selected: bodyView == "front") { bodyView = "front" }
                    bodySwitch("背面", selected: bodyView == "back") { bodyView = "back" }
                }
                .background(.white.opacity(0.07), in: Capsule())
            }
            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 8) {
                        ProfileBodyFigure(gender: store.preferences.gender, isBack: bodyView == "back", active: Set(activeMuscles)) { muscle in
                            selectedMuscleName = ProfileMuscle.labels[muscle]
                        }
                        HStack(spacing: 5) {
                            Circle().fill(FitcoreTheme.lime).frame(width: 5, height: 5)
                            Text(todayReviews.isEmpty ? "等待训练数据" : "点击部位查看")
                                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .frame(width: geometry.size.width * 0.38)
                    timeline(height: geometry.size.height)
                }
            }
            if !activities.isEmpty {
                Button("查看今日全部已记录肌群 ›") {
                    selectMuscles(Array(Set(activities.flatMap(\.muscles))).sorted(), action: nil)
                }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(FitcoreTheme.lime)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(.white).padding(18)
        .background(LinearGradient(colors: [FitcoreTheme.deep, FitcoreTheme.navy], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 25))
    }

    private func timeline(height: CGFloat) -> some View {
        let pageSize = max(1, min(4, Int(max(0, height - 26) / 68)))
        let pageCount = max(1, (activities.count + pageSize - 1) / pageSize)
        let page = min(activityPage, pageCount - 1)
        let start = page * pageSize
        let visible = Array(activities.dropFirst(start).prefix(pageSize))
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                Text("训练顺序").font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                Spacer(minLength: 0)
                if pageCount > 1 {
                    Button { activityPage = max(0, page - 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(page == 0)
                    Text("\(page + 1)/\(pageCount)").font(.system(size: 10)).monospacedDigit()
                    Button { activityPage = min(pageCount - 1, page + 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(page == pageCount - 1)
                }
            }
            .font(.system(size: 11)).foregroundStyle(.white).frame(height: 19)
            if visible.isEmpty {
                Spacer(minLength: 0)
                Text("训练，从记录开始").font(.system(size: 14, weight: .semibold))
                Text("保存训练后，这里会按顺序显示动作和肌群。")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineSpacing(4)
                Spacer(minLength: 0)
            } else {
                ForEach(Array(visible.enumerated()), id: \.element.id) { offset, activity in
                    timelineRow(activity, number: start + offset + 1)
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func timelineRow(_ activity: RecordedActivity, number: Int) -> some View {
        let selected = selectedAction == activity.id
        return HStack(spacing: 7) {
            ZStack {
                Rectangle().fill(.white.opacity(0.13)).frame(width: 1)
                Text(String(format: "%02d", number))
                    .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .frame(width: 23, height: 23)
                    .foregroundStyle(selected ? FitcoreTheme.deep : .white)
                    .background(selected ? FitcoreTheme.lime : Color(red: 0.19, green: 0.36, blue: 0.55), in: Circle())
            }
            .frame(width: 23)
            HStack(spacing: 0) {
                Button { selectMuscles(activity.muscles, action: activity.id) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Image(systemName: activity.symbol).font(.system(size: 12))
                                .foregroundStyle(Color(red: 0.62, green: 0.83, blue: 1))
                            Text(activity.name).font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                        }
                        Text(activity.summary).font(.system(size: 10)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        Text(activity.muscleDescription).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.leading, 10).padding(.vertical, 7).contentShape(Rectangle())
                }
                .accessibilityLabel("\(activity.name)，\(activity.summary)，\(activity.muscleDescription)")
                .accessibilityAddTraits(selected ? .isSelected : [])
                Button { sourceActivity = activity } label: {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("查看\(activity.name)的明细与原话")
            }
            .buttonStyle(.plain)
            .background(selected ? FitcoreTheme.lime.opacity(0.09) : .white.opacity(0.07), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(selected ? FitcoreTheme.lime : .clear, lineWidth: 1))
        }
    }

    private func bodySwitch(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .foregroundStyle(selected ? .white : .white.opacity(0.55))
                .background(selected ? FitcoreTheme.accent : .clear, in: Capsule())
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func setGender(_ gender: String) {
        var preferences = store.preferences
        preferences.gender = gender
        store.updatePreferences(preferences)
    }

    private func selectMuscles(_ muscles: [String], action: String?) {
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedAction = action
            selectedMuscleName = nil
            var preferences = store.preferences
            preferences.selectedMuscles = muscles
            store.updatePreferences(preferences)
            if action != nil { bodyView = muscles.contains("back") ? "back" : "front" }
        }
    }
}

struct RecordedActivitySourceView: View {
    @Environment(\.dismiss) private var dismiss
    let activity: RecordedActivity

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("动作名称仅做已知同义词规范化。以下原话用于核对；缺失或未确认的重量、次数显示待补充。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("肌群：\(activity.muscleDescription)；依据动作映射，不是传感器检测。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(activity.events) { event in
                    Section {
                        Text(event.hasSourceEvidence ? event.sourceText : "缺少原话来源，待核对")
                            .font(.body).textSelection(.enabled)
                        if event.type == .set {
                            Text(event.setDescription).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if !event.feeling.isEmpty {
                            Text("记录感受：\(event.feeling)").font(.subheadline).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text(event.exercise)
                    }
                }
            }
            .navigationTitle(activity.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

private struct ProfileGoalSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var calories = 500
    @State private var minutes = 45

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("根据你的节奏调整目标，持续看见每一次进步。")
                        .foregroundStyle(FitcoreTheme.muted)
                }
                Section("每日目标") {
                    HStack {
                        Label("卡路里消耗", systemImage: "flame")
                        Spacer()
                        TextField("500", value: $calories, format: .number).keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing).frame(width: 70)
                        Text("kcal").foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("运动时间", systemImage: "timer")
                        Spacer()
                        TextField("45", value: $minutes, format: .number).keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing).frame(width: 70)
                        Text("分钟").foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("保存目标") {
                        var preferences = store.preferences
                        preferences.goalCalories = min(3000, max(100, calories))
                        preferences.goalMinutes = min(240, max(10, minutes))
                        store.updatePreferences(preferences)
                        dismiss()
                    }
                    .frame(maxWidth: .infinity).fontWeight(.semibold)
                } footer: {
                    Text("目标范围：100–3000 kcal，10–240 分钟。真实训练没有可靠热量来源时显示未估算。")
                }
            }
            .navigationTitle("设置今日目标").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("稍后设置") { dismiss() } } }
            .onAppear {
                calories = store.preferences.goalCalories
                minutes = store.preferences.goalMinutes
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}

private enum ProfileMuscle {
    static let labels = ["chest": "胸部", "shoulders": "肩部", "arms": "手臂", "back": "背部", "core": "核心", "legs": "腿部"]
}

private struct ProfileBodyFigure: View {
    let gender: String
    let isBack: Bool
    let active: Set<String>
    let onSelect: (String) -> Void

    private let skin = Color(red: 0.97, green: 0.70, blue: 0.56)
    private let shirt = Color(red: 0.15, green: 0.34, blue: 0.54)
    private let seam = Color(red: 0.34, green: 0.53, blue: 0.69)
    private var mirror: CGAffineTransform { CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 180, ty: 0) }

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / 180, geometry.size.height / 430)
            let transform = CGAffineTransform(scaleX: scale, y: scale)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    context.scaleBy(x: scale, y: scale)
                    drawBase(in: &context)
                }
                ForEach(regions) { region in
                    let shape = region.path.applying(transform)
                    shape.fill(active.contains(region.id) ? FitcoreTheme.lime : region.color)
                        .overlay(shape.stroke(active.contains(region.id) ? FitcoreTheme.lime.opacity(0.8) : seam.opacity(0.35), lineWidth: 0.5))
                        .contentShape(shape)
                        .onTapGesture { onSelect(region.id) }
                        .accessibilityLabel("\(ProfileMuscle.labels[region.id] ?? region.id)\(active.contains(region.id) ? "，已选中" : "")")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { onSelect(region.id) }
                }
                Canvas { context, _ in
                    context.scaleBy(x: scale, y: scale)
                    drawDetails(in: &context)
                }
                .allowsHitTesting(false)
            }
            .frame(width: 180 * scale, height: 430 * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func drawBase(in context: inout GraphicsContext) {
        func fill(_ path: Path, _ color: Color) {
            context.fill(path, with: .color(color))
            context.stroke(path, with: .color(color.opacity(0.7)), lineWidth: 0.7)
        }
        let leg = Path { p in
            p.move(to: CGPoint(x: 66, y: 218))
            p.addCurve(to: CGPoint(x: 65, y: 289), control1: CGPoint(x: 61, y: 247), control2: CGPoint(x: 60, y: 273))
            p.addCurve(to: CGPoint(x: 61, y: 326), control1: CGPoint(x: 69, y: 300), control2: CGPoint(x: 59, y: 312))
            p.addCurve(to: CGPoint(x: 64, y: 394), control1: CGPoint(x: 60, y: 350), control2: CGPoint(x: 68, y: 373))
            p.addLine(to: CGPoint(x: 80, y: 395))
            p.addCurve(to: CGPoint(x: 80, y: 327), control1: CGPoint(x: 80, y: 372), control2: CGPoint(x: 86, y: 347))
            p.addCurve(to: CGPoint(x: 84, y: 290), control1: CGPoint(x: 77, y: 311), control2: CGPoint(x: 81, y: 300))
            p.addCurve(to: CGPoint(x: 90, y: 226), control1: CGPoint(x: 90, y: 266), control2: CGPoint(x: 92, y: 242))
            p.closeSubpath()
        }
        fill(leg, skin); fill(leg.applying(mirror), skin)
        let arm = Path { p in
            p.move(to: CGPoint(x: 52, y: 74))
            p.addCurve(to: CGPoint(x: 40, y: 121), control1: CGPoint(x: 39, y: 78), control2: CGPoint(x: 38, y: 103))
            p.addCurve(to: CGPoint(x: 35, y: 154), control1: CGPoint(x: 42, y: 133), control2: CGPoint(x: 35, y: 142))
            p.addLine(to: CGPoint(x: 30, y: 196))
            p.addCurve(to: CGPoint(x: 27, y: 224), control1: CGPoint(x: 25, y: 205), control2: CGPoint(x: 24, y: 219))
            p.addQuadCurve(to: CGPoint(x: 36, y: 231), control: CGPoint(x: 30, y: 235))
            p.addLine(to: CGPoint(x: 39, y: 229))
            p.addLine(to: CGPoint(x: 34, y: 217))
            p.addQuadCurve(to: CGPoint(x: 39, y: 208), control: CGPoint(x: 34, y: 204))
            p.addLine(to: CGPoint(x: 43, y: 216))
            p.addQuadCurve(to: CGPoint(x: 47, y: 213), control: CGPoint(x: 47, y: 217))
            p.addLine(to: CGPoint(x: 43, y: 200))
            p.addCurve(to: CGPoint(x: 54, y: 155), control1: CGPoint(x: 44, y: 186), control2: CGPoint(x: 55, y: 169))
            p.addQuadCurve(to: CGPoint(x: 57, y: 128), control: CGPoint(x: 52, y: 141))
            p.addCurve(to: CGPoint(x: 65, y: 92), control1: CGPoint(x: 65, y: 117), control2: CGPoint(x: 67, y: 102))
            p.closeSubpath()
        }
        fill(arm, skin); fill(arm.applying(mirror), skin)
        fill(Path(roundedRect: CGRect(x: 81, y: 49, width: 18, height: 28), cornerRadius: 7), skin)
        fill(Path(ellipseIn: CGRect(x: 69, y: 19, width: 42, height: 47)), skin)
        fill(Path(ellipseIn: CGRect(x: 66, y: 35, width: 8, height: 13)), skin)
        fill(Path(ellipseIn: CGRect(x: 106, y: 35, width: 8, height: 13)), skin)
        let torso = Path { p in
            p.move(to: CGPoint(x: 79, y: 66))
            p.addQuadCurve(to: CGPoint(x: 101, y: 66), control: CGPoint(x: 90, y: 77))
            p.addLine(to: CGPoint(x: 123, y: 74))
            p.addQuadCurve(to: CGPoint(x: 119, y: 117), control: CGPoint(x: 130, y: 95))
            p.addQuadCurve(to: CGPoint(x: gender == "female" ? 108 : 115, y: 164), control: CGPoint(x: 113, y: 140))
            p.addLine(to: CGPoint(x: 116, y: 199))
            p.addQuadCurve(to: CGPoint(x: 64, y: 199), control: CGPoint(x: 90, y: 205))
            p.addLine(to: CGPoint(x: gender == "female" ? 72 : 65, y: 164))
            p.addQuadCurve(to: CGPoint(x: 61, y: 117), control: CGPoint(x: 67, y: 140))
            p.addQuadCurve(to: CGPoint(x: 57, y: 74), control: CGPoint(x: 50, y: 95))
            p.closeSubpath()
        }
        fill(torso, shirt)
        let shorts = Path { p in
            p.move(to: CGPoint(x: 65, y: 196))
            p.addQuadCurve(to: CGPoint(x: 115, y: 196), control: CGPoint(x: 90, y: 203))
            p.addLine(to: CGPoint(x: 120, y: 243))
            p.addQuadCurve(to: CGPoint(x: 96, y: 246), control: CGPoint(x: 109, y: 248))
            p.addLine(to: CGPoint(x: 90, y: 221))
            p.addLine(to: CGPoint(x: 84, y: 246))
            p.addQuadCurve(to: CGPoint(x: 60, y: 243), control: CGPoint(x: 71, y: 248))
            p.closeSubpath()
        }
        fill(shorts, Color(red: 0.12, green: 0.29, blue: 0.47))
        let shoe = Path { p in
            p.move(to: CGPoint(x: 64, y: 385))
            p.addLine(to: CGPoint(x: 79, y: 387))
            p.addLine(to: CGPoint(x: 85, y: 408))
            p.addQuadCurve(to: CGPoint(x: 50, y: 413), control: CGPoint(x: 77, y: 421))
            p.addQuadCurve(to: CGPoint(x: 49, y: 405), control: CGPoint(x: 46, y: 412))
            p.addLine(to: CGPoint(x: 60, y: 396))
            p.closeSubpath()
        }
        fill(shoe, Color(red: 0.83, green: 0.92, blue: 0.97)); fill(shoe.applying(mirror), Color(red: 0.83, green: 0.92, blue: 0.97))
        let hair = Path { p in
            p.move(to: CGPoint(x: 70, y: 41))
            p.addCurve(to: CGPoint(x: 75, y: 14), control1: CGPoint(x: 59, y: 23), control2: CGPoint(x: 69, y: 13))
            p.addCurve(to: CGPoint(x: 103, y: 12), control1: CGPoint(x: 80, y: 1), control2: CGPoint(x: 99, y: 2))
            p.addCurve(to: CGPoint(x: 110, y: 40), control1: CGPoint(x: 118, y: 11), control2: CGPoint(x: 117, y: 29))
            if isBack {
                p.addQuadCurve(to: CGPoint(x: 73, y: 53), control: CGPoint(x: 90, y: 70))
            } else {
                p.addLine(to: CGPoint(x: 104, y: 27))
                p.addQuadCurve(to: CGPoint(x: 87, y: 23), control: CGPoint(x: 100, y: 17))
                p.addQuadCurve(to: CGPoint(x: 73, y: 33), control: CGPoint(x: 80, y: 32))
            }
            p.closeSubpath()
        }
        fill(hair, Color(red: 0.10, green: 0.17, blue: 0.25))
        if gender == "female" {
            fill(Path(ellipseIn: CGRect(x: 106, y: 19, width: 15, height: 32)), Color(red: 0.10, green: 0.17, blue: 0.25))
        }
    }

    private func drawDetails(in context: inout GraphicsContext) {
        func line(_ points: [(CGFloat, CGFloat)], _ color: Color, width: CGFloat = 1) {
            context.stroke(polygon(points, closed: false), with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
        let skinShadow = Color(red: 0.75, green: 0.42, blue: 0.30).opacity(0.35)
        for flip in [false, true] {
            var side = context
            if flip { side.concatenate(mirror) }
            let knee = Path { p in
                p.move(to: CGPoint(x: 67, y: 287))
                p.addQuadCurve(to: CGPoint(x: 79, y: 295), control: CGPoint(x: 67, y: 299))
            }
            side.stroke(knee, with: .color(skinShadow), lineWidth: 1)
            side.stroke(polygon([(70, 308), (67, 332), (71, 371)], closed: false), with: .color(skinShadow), lineWidth: 1)
            side.stroke(polygon([(43, 122), (47, 137), (40, 179)], closed: false), with: .color(skinShadow), lineWidth: 1)
            for y in [395, 399, 403] {
                side.stroke(polygon([(62, CGFloat(y)), (75, CGFloat(y + 1))], closed: false), with: .color(seam), lineWidth: 1.1)
            }
            side.stroke(polygon([(51, 412), (65, 414), (82, 410)], closed: false), with: .color(.white), lineWidth: 2.8)
        }
        line([(67, 199), (90, 204), (113, 199)], seam.opacity(0.6))
        line([(65, 239), (81, 241)], seam.opacity(0.5))
        line([(99, 241), (115, 239)], seam.opacity(0.5))
        if isBack {
            line([(90, 80), (90, 176)], seam.opacity(0.7))
            line([(66, 87), (80, 116), (90, 122), (100, 116), (114, 87)], seam.opacity(0.5))
        } else {
            line([(90, 84), (90, 183)], seam.opacity(0.6))
            for y in [131, 147, 163, 180] {
                let path = Path { p in
                    p.move(to: CGPoint(x: 76, y: y))
                    p.addQuadCurve(to: CGPoint(x: 104, y: y), control: CGPoint(x: 90, y: y + 5))
                }
                context.stroke(path, with: .color(seam.opacity(0.45)), lineWidth: 0.9)
            }
            line([(76, 38), (82, 37)], FitcoreTheme.deep, width: 1.4)
            line([(98, 37), (104, 38)], FitcoreTheme.deep, width: 1.4)
            context.fill(Path(ellipseIn: CGRect(x: 78, y: 41, width: 2, height: 2.7)), with: .color(FitcoreTheme.deep))
            context.fill(Path(ellipseIn: CGRect(x: 100, y: 41, width: 2, height: 2.7)), with: .color(FitcoreTheme.deep))
            line([(90, 43), (88, 49), (92, 49)], skinShadow)
            let mouth = Path { p in
                p.move(to: CGPoint(x: 84, y: 54))
                p.addQuadCurve(to: CGPoint(x: 96, y: 54), control: CGPoint(x: 90, y: 58))
            }
            context.stroke(mouth, with: .color(skinShadow), lineWidth: 1)
        }
        let hairPart = Path { p in
            p.move(to: CGPoint(x: 72, y: 24))
            p.addQuadCurve(to: CGPoint(x: 99, y: 12), control: CGPoint(x: 88, y: 22))
        }
        context.stroke(hairPart, with: .color(seam.opacity(0.5)), lineWidth: 1.1)
    }

    private struct Region: Identifiable {
        let id: String
        let path: Path
        let color: Color
    }

    private func paired(_ path: Path) -> Path {
        var result = path
        result.addPath(path.applying(mirror))
        return result
    }

    private var regions: [Region] {
        let shoulder = Path { p in
            p.move(to: CGPoint(x: 61, y: 73))
            p.addCurve(to: CGPoint(x: 43, y: 106), control1: CGPoint(x: 45, y: 74), control2: CGPoint(x: 37, y: 92))
            p.addQuadCurve(to: CGPoint(x: 63, y: 97), control: CGPoint(x: 56, y: 110))
            p.addLine(to: CGPoint(x: 68, y: 79)); p.closeSubpath()
        }
        let arm = Path { p in
            p.move(to: CGPoint(x: 43, y: 108))
            p.addQuadCurve(to: CGPoint(x: 40, y: 155), control: CGPoint(x: 46, y: 128))
            p.addLine(to: CGPoint(x: 32, y: 199))
            p.addLine(to: CGPoint(x: 42, y: 201))
            p.addQuadCurve(to: CGPoint(x: 52, y: 155), control: CGPoint(x: 50, y: 179))
            p.addQuadCurve(to: CGPoint(x: 60, y: 104), control: CGPoint(x: 51, y: 132))
            p.closeSubpath()
        }
        let leg = Path { p in
            p.move(to: CGPoint(x: 64, y: 246)); p.addLine(to: CGPoint(x: 83, y: 247))
            p.addQuadCurve(to: CGPoint(x: 80, y: 291), control: CGPoint(x: 86, y: 270))
            p.addQuadCurve(to: CGPoint(x: 78, y: 334), control: CGPoint(x: 76, y: 313))
            p.addLine(to: CGPoint(x: 77, y: 384)); p.addLine(to: CGPoint(x: 67, y: 384))
            p.addQuadCurve(to: CGPoint(x: 63, y: 334), control: CGPoint(x: 66, y: 357))
            p.addQuadCurve(to: CGPoint(x: 65, y: 292), control: CGPoint(x: 61, y: 313))
            p.addQuadCurve(to: CGPoint(x: 64, y: 246), control: CGPoint(x: 61, y: 270)); p.closeSubpath()
        }
        var result = [
            Region(id: "shoulders", path: paired(shoulder), color: shirt),
            Region(id: "arms", path: paired(arm), color: skin.opacity(0.15)),
            Region(id: "legs", path: paired(leg), color: skin.opacity(0.15)),
        ]
        if isBack {
            let back = Path { p in
                p.move(to: CGPoint(x: 69, y: 82)); p.addLine(to: CGPoint(x: 111, y: 82))
                p.addQuadCurve(to: CGPoint(x: 113, y: 122), control: CGPoint(x: 120, y: 109))
                p.addLine(to: CGPoint(x: 106, y: 163)); p.addLine(to: CGPoint(x: 74, y: 163))
                p.addQuadCurve(to: CGPoint(x: 69, y: 82), control: CGPoint(x: 59, y: 110)); p.closeSubpath()
            }
            result.append(Region(id: "back", path: back, color: shirt.opacity(0.8)))
            result.append(Region(id: "core", path: polygon([(75, 166), (105, 166), (108, 191), (72, 191)]), color: shirt))
        } else {
            let chest = Path { p in
                p.move(to: CGPoint(x: 69, y: 82))
                p.addQuadCurve(to: CGPoint(x: 88, y: 87), control: CGPoint(x: 80, y: 84))
                p.addLine(to: CGPoint(x: 88, y: 113))
                p.addQuadCurve(to: CGPoint(x: 64, y: 114), control: CGPoint(x: 74, y: 125))
                p.addQuadCurve(to: CGPoint(x: 63, y: 100), control: CGPoint(x: 59, y: 108)); p.closeSubpath()
            }
            result.append(Region(id: "chest", path: paired(chest), color: Color(red: 0.18, green: 0.39, blue: 0.59)))
            let core = Path { p in
                p.move(to: CGPoint(x: 74, y: 124))
                p.addQuadCurve(to: CGPoint(x: 106, y: 124), control: CGPoint(x: 90, y: 118))
                p.addLine(to: CGPoint(x: 106, y: 183))
                p.addQuadCurve(to: CGPoint(x: 74, y: 183), control: CGPoint(x: 90, y: 195)); p.closeSubpath()
            }
            result.append(Region(id: "core", path: core, color: Color(red: 0.12, green: 0.29, blue: 0.46)))
        }
        return result
    }

    private func polygon(_ points: [(CGFloat, CGFloat)], closed: Bool = true) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: CGPoint(x: first.0, y: first.1))
            for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.0, y: point.1)) }
            if closed { path.closeSubpath() }
        }
    }
}
