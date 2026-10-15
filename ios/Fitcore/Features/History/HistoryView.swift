import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var filter: HistoryFilter = .all
    @State private var showingRhythm = false

    private var records: [TrainingReview] { store.history.sorted { $0.date > $1.date } }
    private var monthRecords: [TrainingReview] {
        records.filter { Calendar.current.isDate($0.date, equalTo: Date(), toGranularity: .month) }
    }
    private var filteredRecords: [TrainingReview] { records.filter { filter.includes($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            HStack(spacing: 9) {
                statistic("本月训练", value: "\(monthRecords.count)") {
                    Button { showingRhythm = true } label: {
                        Image(systemName: "chart.bar.fill")
                            .font(.caption).padding(8)
                            .background(FitcoreTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                    }
                    .accessibilityLabel("查看训练节奏图表")
                }
                statistic("累计分钟", value: "\(monthRecords.reduce(0) { $0 + $1.durationMinutes })") { EmptyView() }
                statistic("最长连续", value: "\(longestStreak) 天") { EmptyView() }
            }
            Picker("训练类型", selection: $filter) {
                ForEach(HistoryFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if filteredRecords.isEmpty {
                emptyState
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 11) {
                        ForEach(filteredRecords) { review in
                            Button { store.selectReview(review) } label: {
                                HistoryRecordRow(review: review)
                            }
                            .buttonStyle(.plain)
                        }
                        Text("已显示全部 \(filteredRecords.count) 次训练")
                            .font(.caption).foregroundStyle(FitcoreTheme.muted).padding(.top, 8)
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.horizontal, 20).padding(.top, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(FitcoreTheme.canvas)
        .foregroundStyle(FitcoreTheme.ink)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingRhythm) { TrainingRhythmSheet(records: records) }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("FITCORE · TRAINING LOG").font(.system(size: 10, weight: .bold)).tracking(1.2)
                    .foregroundStyle(FitcoreTheme.muted)
                Text("历史记录").font(.system(size: 28, weight: .bold))
            }
            Spacer()
            Text(Date().formatted(.dateTime.month(.wide)))
                .font(.subheadline).foregroundStyle(FitcoreTheme.muted)
        }
    }

    private func statistic<Accessory: View>(_ title: String, value: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 2) {
                Text(value).font(.system(size: 24, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                accessory()
            }
            Text(title).font(.caption).foregroundStyle(FitcoreTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 11).padding(.vertical, 14)
        .frame(minHeight: 85)
        .background(.white, in: RoundedRectangle(cornerRadius: 18))
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 32, weight: .light)).foregroundStyle(FitcoreTheme.accent)
                .frame(width: 72, height: 72)
                .background(FitcoreTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 23))
            Text(records.isEmpty ? "每次进步，都值得留下" : "还没有这类训练")
                .font(.headline)
            Text(records.isEmpty ? "完成一次训练，在 AI 分析中保存后，记录就会出现在这里。" : "试试其他分类，或记录一次新的训练。")
                .font(.subheadline).foregroundStyle(FitcoreTheme.muted)
                .multilineTextAlignment(.center).lineSpacing(4)
            if records.isEmpty {
                Button("去记录今天的训练") { store.selectedTab = .today }
                    .buttonStyle(PrimaryButtonStyle())
            } else {
                Button("查看全部训练") { filter = .all }.font(.subheadline.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity).padding(24)
        .background(.white, in: RoundedRectangle(cornerRadius: 24))
        .padding(.top, 10)
    }

    private var longestStreak: Int {
        let calendar = Calendar.current
        let days = Set(records.map { calendar.startOfDay(for: $0.date) }).sorted()
        var longest = 0, current = 0
        var previous: Date?
        for date in days {
            if let previous, calendar.dateComponents([.day], from: previous, to: date).day == 1 {
                current += 1
            } else { current = 1 }
            longest = max(longest, current)
            previous = date
        }
        return longest
    }
}

private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all = "全部训练", strength = "力量", cardio = "有氧", recovery = "恢复"
    var id: Self { self }

    func includes(_ review: TrainingReview) -> Bool {
        switch self {
        case .all: return true
        case .strength: return review.events.contains { $0.type == .set }
        case .cardio: return review.events.contains { $0.type == .warmup }
        case .recovery: return review.events.contains { $0.type == .stretch }
        }
    }
}

private struct HistoryRecordRow: View {
    let review: TrainingReview

    private var exercises: [String] {
        review.events.reduce(into: []) { result, event in
            if !result.contains(event.exercise) { result.append(event.exercise) }
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 3) {
                Text(review.date.formatted(.dateTime.day(.twoDigits)))
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text(review.date.formatted(.dateTime.month().weekday(.abbreviated)))
                    .font(.system(size: 9)).foregroundStyle(FitcoreTheme.muted)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 44)
            Rectangle().fill(FitcoreTheme.navy.opacity(0.08)).frame(width: 1, height: 52)
            VStack(alignment: .leading, spacing: 6) {
                Text(review.title).font(.subheadline.weight(.bold))
                Text("\(review.durationMinutes) 分钟 · \(review.events.count) 条记录")
                    .font(.caption).foregroundStyle(FitcoreTheme.muted)
                HStack(spacing: 4) {
                    ForEach(Array(exercises.prefix(2)), id: \.self) { exercise in
                        Text(exercise).font(.system(size: 10))
                            .lineLimit(1).padding(.horizontal, 6).padding(.vertical, 4)
                            .foregroundStyle(FitcoreTheme.accent)
                            .background(FitcoreTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                Text(review.isSimulated ? "模拟训练记录" : (review.isTextRecordSummary ? "文字训练记录" : "训练记录"))
                    .font(.system(size: 9)).foregroundStyle(FitcoreTheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 3) {
                Text("\(review.phaseCount)").font(.headline)
                Text("阶段").font(.system(size: 9))
            }
            .foregroundStyle(FitcoreTheme.navy).padding(9)
            .background(FitcoreTheme.limeSoft, in: RoundedRectangle(cornerRadius: 11))
        }
        .padding(14)
        .background(.white, in: RoundedRectangle(cornerRadius: 20))
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }
}

private struct TrainingRhythmSheet: View {
    enum Period: String, CaseIterable { case month = "本月", week = "本周", history = "近半年" }
    @Environment(\.dismiss) private var dismiss
    @State private var period: Period = .month
    let records: [TrainingReview]

    private var buckets: [(label: String, count: Int)] {
        let calendar = Calendar.current
        let now = Date()
        switch period {
        case .week:
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: now) else { return [] }
            return (0..<7).compactMap { offset in
                guard let date = calendar.date(byAdding: .day, value: offset, to: interval.start) else { return nil }
                return (date.formatted(.dateTime.weekday(.narrow)), records.filter { calendar.isDate($0.date, inSameDayAs: date) }.count)
            }
        case .month:
            guard let interval = calendar.dateInterval(of: .month, for: now),
                  let range = calendar.range(of: .day, in: .month, for: now) else { return [] }
            let count = Int(ceil(Double(range.count) / 7))
            return (0..<count).map { index in
                let total = records.filter {
                    interval.contains($0.date) && (calendar.component(.day, from: $0.date) - 1) / 7 == index
                }.count
                return ("第 \(index + 1) 周", total)
            }
        case .history:
            return (-5...0).compactMap { offset in
                guard let date = calendar.date(byAdding: .month, value: offset, to: now) else { return nil }
                return ("\(calendar.component(.month, from: date))月", records.filter { calendar.isDate($0.date, equalTo: date, toGranularity: .month) }.count)
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("FITCORE · TRAINING RHYTHM").font(.caption2.weight(.bold)).tracking(1)
                        .foregroundStyle(FitcoreTheme.accent)
                    Text("看见你的坚持").font(.title2.weight(.bold))
                    Text("已保存的训练，会逐渐组成你的节奏。")
                        .font(.subheadline).foregroundStyle(FitcoreTheme.muted)
                }
                Picker("图表周期", selection: $period) {
                    ForEach(Period.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(Array(buckets.enumerated()), id: \.offset) { _, bucket in
                        VStack(spacing: 9) {
                            Text("\(bucket.count)").font(.caption.weight(.semibold)).foregroundStyle(FitcoreTheme.accent)
                            RoundedRectangle(cornerRadius: 7)
                                .fill(bucket.count == 0 ? FitcoreTheme.accent.opacity(0.08) : FitcoreTheme.accent)
                                .frame(height: max(5, 125 * Double(bucket.count) / Double(max(1, buckets.map(\.count).max() ?? 1))))
                            Text(bucket.label).font(.system(size: 10)).foregroundStyle(FitcoreTheme.muted).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 180, alignment: .bottom).padding(20)
                .background(.white, in: RoundedRectangle(cornerRadius: 24))
                Text(buckets.reduce(0) { $0 + $1.count } == 0 ? "这个周期还没有保存的训练。每一次记录，都是起点。" : "\(period.rawValue)共保存 \(buckets.reduce(0) { $0 + $1.count }) 次训练。")
                    .font(.subheadline).foregroundStyle(FitcoreTheme.muted)
                Spacer(minLength: 0)
            }
            .padding(24).background(FitcoreTheme.canvas).foregroundStyle(FitcoreTheme.ink)
            .navigationTitle("训练节奏").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.large]).presentationDragIndicator(.visible)
    }
}
