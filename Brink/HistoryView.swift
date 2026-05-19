import SwiftUI

// MARK: - History View

struct HistoryView: View {
    @EnvironmentObject var vm: MotionViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var filterLevel: RiskLevel? = nil
    @State private var showClearConfirm = false

    private var filteredHistory: [AlertEvent] {
        guard let filter = filterLevel else { return vm.alertHistory }
        return vm.alertHistory.filter { $0.riskLevelEnum == filter }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.brinkBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    filterBar
                        .padding(.horizontal, BrinkSpacing.lg)
                        .padding(.top, BrinkSpacing.md)
                        .padding(.bottom, BrinkSpacing.md)

                    if vm.alertHistory.isEmpty {
                        emptyState
                    } else if filteredHistory.isEmpty {
                        filteredEmptyState
                    } else {
                        historyList
                    }
                }
            }
            .navigationTitle("Alert History")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.brinkBackground, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .font(BrinkFont.label(15))
                        .foregroundColor(.brinkTextSecondary)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if !vm.alertHistory.isEmpty {
                        Button {
                            showClearConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 15, weight: .light))
                                .foregroundColor(.brinkHigh)
                        }
                    }
                }
            }
            .preferredColorScheme(.dark)
            .confirmationDialog(
                "Clear all history?",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear History", role: .destructive) {
                    vm.clearHistory()
                    filterLevel = nil
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BrinkSpacing.sm) {
                FilterChip(
                    label: "All",
                    color: .brinkTextSecondary,
                    isSelected: filterLevel == nil,
                    count: vm.alertHistory.count,
                    onTap: { filterLevel = nil }
                )

                ForEach(RiskLevel.allCases.filter { $0 != .safe }, id: \.rawValue) { level in
                    let count = vm.alertHistory.filter { $0.riskLevelEnum == level }.count
                    if count > 0 {
                        FilterChip(
                            label: level.label,
                            color: level.primaryColor,
                            isSelected: filterLevel == level,
                            count: count,
                            onTap: { filterLevel = level }
                        )
                    }
                }
            }
        }
    }

    // MARK: - History List

    private var historyList: some View {
        ScrollView {
            LazyVStack(spacing: BrinkSpacing.sm) {
                ForEach(filteredHistory) { event in
                    HistoryRow(event: event)
                }
            }
            .padding(.horizontal, BrinkSpacing.lg)
            .padding(.bottom, BrinkSpacing.xl)
        }
    }

    // MARK: - Empty States

    private var emptyState: some View {
        VStack(spacing: BrinkSpacing.lg) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.brinkSafe.opacity(0.08))
                    .frame(width: 80, height: 80)

                Image(systemName: "clock.badge.checkmark")
                    .font(.system(size: 32, weight: .light))
                    .foregroundColor(.brinkSafe)
            }

            VStack(spacing: BrinkSpacing.sm) {
                Text("No alerts yet")
                    .font(BrinkFont.heading(18))
                    .foregroundColor(.brinkTextPrimary)

                Text("Brink has been watching. No risky situations detected so far.")
                    .font(BrinkFont.body(14))
                    .foregroundColor(.brinkTextSecondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()
            Spacer()
        }
        .padding(.horizontal, BrinkSpacing.xxl)
    }

    private var filteredEmptyState: some View {
        VStack(spacing: BrinkSpacing.md) {
            Spacer()

            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(.brinkTextTertiary)

            Text("No events at this level")
                .font(BrinkFont.body(15))
                .foregroundColor(.brinkTextSecondary)

            Spacer()
            Spacer()
        }
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let label: String
    let color: Color
    let isSelected: Bool
    let count: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Text(label)
                    .font(BrinkFont.label(12))
                    .foregroundColor(isSelected ? color : .brinkTextTertiary)

                Text("\(count)")
                    .font(BrinkFont.mono(10))
                    .foregroundColor(isSelected ? color.opacity(0.7) : .brinkTextTertiary)
            }
            .padding(.horizontal, BrinkSpacing.md)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(
                        isSelected
                        ? color.opacity(0.12)
                        : Color.brinkSurface
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                isSelected ? color.opacity(0.35) : Color.brinkBorder,
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - History Row

struct HistoryRow: View {
    let event: AlertEvent
    private var level: RiskLevel { event.riskLevelEnum }

    var body: some View {
        HStack(spacing: BrinkSpacing.md) {
            // Level indicator bar
            RoundedRectangle(cornerRadius: 2)
                .fill(level.primaryColor)
                .frame(width: 3, height: 52)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(level.label.uppercased())
                        .font(BrinkFont.mono(10))
                        .tracking(1.5)
                        .foregroundColor(level.primaryColor)

                    Spacer()

                    Text(event.timeAgo)
                        .font(BrinkFont.mono(11))
                        .foregroundColor(.brinkTextTertiary)
                }

                Text(event.context)
                    .font(BrinkFont.body(14))
                    .foregroundColor(.brinkTextPrimary)

                Text(formattedDate(event.date))
                    .font(BrinkFont.mono(11))
                    .foregroundColor(.brinkTextTertiary)
            }

            Spacer()
        }
        .padding(BrinkSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.brinkSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(level.primaryColor.opacity(0.15), lineWidth: 1)
                )
        )
    }

    private func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f.string(from: date)
    }
}

// MARK: - Preview

#Preview {
    let vm = MotionViewModel()
    let samples: [(RiskLevel, String)] = [
        (.high, "Edge tilt — fall risk detected"),
        (.medium, "Unstable position on surface"),
        (.high, "Grip instability detected"),
        (.low, "Minor motion detected"),
        (.medium, "Surface instability warning"),
    ]
    for (i, (level, ctx)) in samples.enumerated() {
        vm.alertHistory.append(
            AlertEvent(
                date: Date().addingTimeInterval(Double(-i * 3600)),
                riskLevel: level.rawValue,
                context: ctx,
                dismissed: true
            )
        )
    }

    return HistoryView().environmentObject(vm)
}
