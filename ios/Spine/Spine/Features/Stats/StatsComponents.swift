import Charts
import SwiftUI

struct SWStatsSlice: Identifiable {
    let id: String
    let title: String
    let value: Int
    let color: Color
}

struct SWStatsDonutChart: View {
    let slices: [SWStatsSlice]
    let centerTitle: String

    @State private var selectedAngle: Int?

    private var visibleSlices: [SWStatsSlice] {
        slices.filter { $0.value > 0 }
    }

    private var selectedSlice: SWStatsSlice? {
        guard let selectedAngle else { return nil }
        var upperBound = 0
        for slice in visibleSlices {
            upperBound += slice.value
            if selectedAngle <= upperBound {
                return slice
            }
        }
        return nil
    }

    private var total: Int {
        visibleSlices.reduce(0) { $0 + $1.value }
    }

    var body: some View {
        Chart(visibleSlices) { slice in
            let isSelected = selectedSlice?.id == slice.id
            SectorMark(
                angle: .value("Count", slice.value),
                innerRadius: .ratio(0.68),
                outerRadius: .ratio(isSelected ? 1 : 0.92),
                angularInset: 1.5
            )
            .cornerRadius(5)
            .foregroundStyle(slice.color)
            .opacity(selectedSlice == nil || isSelected ? 1 : 0.28)
        }
        .chartLegend(.hidden)
        .chartAngleSelection(value: $selectedAngle)
        .chartBackground { proxy in
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    let frame = geometry[plotFrame]
                    VStack(spacing: 2) {
                        Text((selectedSlice?.value ?? total).formatted())
                            .font(.system(size: 25, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .monospacedDigit()

                        Text(selectedSlice?.title ?? centerTitle)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .animation(.snappy(duration: 0.22), value: selectedSlice?.id)
        .onChange(of: visibleSlices.map(\.id)) { _, _ in
            selectedAngle = nil
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(centerTitle)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        visibleSlices
            .map { "\($0.title), \($0.value)" }
            .joined(separator: "; ")
    }
}

struct SWStatsRatingPoint: Identifiable {
    let rating: Double
    let count: Int

    var id: Double { rating }
}

struct SWStatsRatingChart: View {
    let points: [SWStatsRatingPoint]
    let average: Double?
    let tint: Color

    var body: some View {
        Chart {
            ForEach(points) { point in
                BarMark(
                    x: .value("Rating", point.rating),
                    y: .value("Count", point.count),
                    width: .ratio(0.76)
                )
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .foregroundStyle(
                    LinearGradient(
                        colors: [tint.opacity(0.58), tint],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                )
            }

            if let average {
                RuleMark(x: .value("Average", average))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("AVG \(average.formatted(.number.precision(.fractionLength(1))))")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(.white.opacity(0.62))
                    }
            }
        }
        .chartXScale(domain: 0...10)
        .chartXAxis {
            AxisMarks(values: [0, 2, 4, 6, 8, 10]) { value in
                AxisGridLine().foregroundStyle(.clear)
                AxisTick().foregroundStyle(.white.opacity(0.18))
                AxisValueLabel {
                    if let rating = value.as(Int.self) {
                        Text(String(rating))
                            .foregroundStyle(.white.opacity(0.42))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(.white.opacity(0.055))
                AxisValueLabel {
                    if let count = value.as(Int.self) {
                        Text(count.formatted())
                            .foregroundStyle(.white.opacity(0.36))
                    }
                }
            }
        }
        .accessibilityChartDescriptor(StatsRatingChartDescriptor(points: points, average: average))
    }
}

private struct StatsRatingChartDescriptor: AXChartDescriptorRepresentable {
    let points: [SWStatsRatingPoint]
    let average: Double?

    func makeChartDescriptor() -> AXChartDescriptor {
        let xAxis = AXNumericDataAxisDescriptor(
            title: "Rating",
            range: 0...10,
            gridlinePositions: [0, 2, 4, 6, 8, 10]
        ) { value in
            value.formatted(.number.precision(.fractionLength(0...1)))
        }
        let maximum = Double(max(1, points.map(\.count).max() ?? 1))
        let yAxis = AXNumericDataAxisDescriptor(
            title: "Titles",
            range: 0...maximum,
            gridlinePositions: []
        ) { value in
            Int(value).formatted()
        }
        let series = AXDataSeriesDescriptor(
            name: average.map { "Ratings, average \($0.formatted(.number.precision(.fractionLength(1))))" } ?? "Ratings",
            isContinuous: false,
            dataPoints: points.map {
                AXDataPoint(x: $0.rating, y: Double($0.count), label: "\($0.rating) out of 10")
            }
        )
        return AXChartDescriptor(
            title: "Rating distribution",
            summary: nil,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series]
        )
    }
}

struct SWStatsActivityPoint: Identifiable {
    let date: Date
    let count: Int

    var id: Date { date }
}

struct SWStatsActivityHeatmap: View {
    private struct Week: Identifiable {
        let startDate: Date
        let days: [SWStatsActivityPoint]

        var id: Date { startDate }
    }

    let points: [SWStatsActivityPoint]
    let tint: Color
    let startDate: Date?
    let endDate: Date?

    private let cellSize: CGFloat = 11
    private let spacing: CGFloat = 3

    private var weeks: [Week] {
        guard let firstDate = startDate ?? points.map(\.date).min(),
              let lastDate = endDate ?? points.map(\.date).max() else { return [] }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let firstDay = calendar.startOfDay(for: firstDate)
        let lastDay = calendar.startOfDay(for: lastDate)
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: firstDay) else { return [] }
        let alignedStart = interval.start
        let counts = Dictionary(
            points.map { (calendar.startOfDay(for: $0.date), $0.count) },
            uniquingKeysWith: +
        )

        var allDays: [SWStatsActivityPoint] = []
        var cursor = alignedStart
        repeat {
            allDays.append(SWStatsActivityPoint(date: cursor, count: counts[cursor] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        } while cursor <= lastDay || allDays.count % 7 != 0

        return stride(from: 0, to: allDays.count, by: 7).map { offset in
            let days = Array(allDays[offset..<min(offset + 7, allDays.count)])
            return Week(startDate: days[0].date, days: days)
        }
    }

    private var maximumCount: Int {
        max(1, points.map(\.count).max() ?? 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: spacing) {
                        ForEach(weeks) { week in
                            VStack(spacing: spacing) {
                                ForEach(week.days) { day in
                                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                        .fill(color(for: day.count))
                                        .frame(width: cellSize, height: cellSize)
                                        .accessibilityHidden(true)
                                }
                            }
                            .id(week.id)
                        }
                    }
                    .padding(.horizontal, 1)
                }
                .onAppear {
                    guard let lastWeek = weeks.last else { return }
                    proxy.scrollTo(lastWeek.id, anchor: .trailing)
                }
                .onChange(of: weeks.last?.id) { _, lastID in
                    guard let lastID else { return }
                    proxy.scrollTo(lastID, anchor: .trailing)
                }
            }

            HStack(spacing: 5) {
                Text("LESS")
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(level == 0 ? Color.white.opacity(0.055) : tint.opacity(0.18 + Double(level) * 0.19))
                        .frame(width: 9, height: 9)
                }
                Text("MORE")
            }
            .font(.system(size: 8, weight: .black))
            .foregroundStyle(.white.opacity(0.32))
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Activity history")
        .accessibilityValue("\(activeDays) active days and \(totalActivity) logged activities")
    }

    private var activeDays: Int {
        points.filter { $0.count > 0 }.count
    }

    private var totalActivity: Int {
        points.reduce(0) { $0 + $1.count }
    }

    private func color(for count: Int) -> Color {
        guard count > 0 else { return .white.opacity(0.055) }
        let ratio = Double(count) / Double(maximumCount)
        switch ratio {
        case ..<0.26: return tint.opacity(0.34)
        case ..<0.51: return tint.opacity(0.54)
        case ..<0.76: return tint.opacity(0.76)
        default: return tint
        }
    }
}

struct SWStatsYearPoint: Identifiable {
    let year: Int
    let count: Int

    var id: Int { year }
}

struct SWStatsYearChart: View {
    let points: [SWStatsYearPoint]
    let tint: Color

    private var sortedPoints: [SWStatsYearPoint] {
        points.sorted { $0.year < $1.year }
    }

    private var initialYear: Int {
        max((sortedPoints.last?.year ?? Calendar.current.component(.year, from: Date())) - 10, sortedPoints.first?.year ?? 0)
    }

    var body: some View {
        Chart(sortedPoints) { point in
            BarMark(
                x: .value("Release year", point.year),
                y: .value("Titles", point.count),
                width: .ratio(0.72)
            )
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .foregroundStyle(tint.gradient)
        }
        .chartScrollableAxes(sortedPoints.count > 12 ? .horizontal : [])
        .chartXVisibleDomain(length: min(12, max(1, sortedPoints.count)))
        .chartScrollPosition(initialX: initialYear)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(.clear)
                AxisTick().foregroundStyle(.white.opacity(0.16))
                AxisValueLabel {
                    if let year = value.as(Int.self) {
                        Text(String(year))
                            .foregroundStyle(.white.opacity(0.42))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(.white.opacity(0.055))
                AxisValueLabel {
                    if let count = value.as(Int.self) {
                        Text(count.formatted())
                            .foregroundStyle(.white.opacity(0.36))
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Titles by release year")
        .accessibilityValue(sortedPoints.map { "\($0.year), \($0.count)" }.joined(separator: "; "))
    }
}

struct SWStatsRankedBarItem: Identifiable {
    let id: String
    let title: String
    let value: Int
}

struct SWStatsRankedBars: View {
    let items: [SWStatsRankedBarItem]
    let tint: Color

    private var maximumValue: Int {
        max(1, items.map(\.value).max() ?? 1)
    }

    var body: some View {
        VStack(spacing: 7) {
            ForEach(items) { item in
                GeometryReader { proxy in
                    let progress = CGFloat(item.value) / CGFloat(maximumValue)
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.white.opacity(0.045))

                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(tint.opacity(0.28))
                            .frame(width: max(6, proxy.size.width * progress))

                        HStack(spacing: 8) {
                            Text(item.title)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(item.value.formatted())
                                .monospacedDigit()
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.74))
                        .padding(.horizontal, 9)
                    }
                }
                .frame(height: 28)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.title)
                .accessibilityValue(item.value.formatted())
            }
        }
    }
}
