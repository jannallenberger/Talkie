import SwiftUI

/// L3b — the "why it might be slow" detail page, reached from the Dashboard's
/// Dictation Speed card. Three parts, all drawn from data already on-device:
///
///   1. A per-stage WATERFALL of the steady-state medians (finalize → re-transcribe
///      → cleanup → insert) as proportional horizontal bars, so you can see which
///      stage dominates your typical dictation. The cold-start sample is shown as
///      its OWN labeled row and is NEVER folded into these medians.
///   2. ENVIRONMENT diagnostics — thermal, Low Power Mode, Apple-Intelligence
///      availability, memory pressure, and (only under pressure) the most
///      memory-hungry apps. Each row renders ONLY when its condition is actually
///      detected, so a healthy Mac shows an all-clear and nothing else.
///   3. A last-10 list of individual dictations with their totals and stage splits.
///
/// A Dashboard subpage (via `navigationDestination`), matching Plumage's shell.
struct SpeedDetailView: View {
    @ObservedObject var latency: LatencyStore
    @ObservedObject var pressure: SystemPressure

    private var stages: LatencyStore.StageMedians {
        latency.stageMedians(excludingColdStart: true, excludingOptimistic: true)
    }
    private var medianMs: Double? {
        latency.medianTotalMs(excludingColdStart: true, excludingOptimistic: true)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                header

                if medianMs == nil {
                    EmptyHint(icon: "gauge.with.dots.needle.33percent",
                              text: "Once you've dictated a few times, the per-stage breakdown shows up here.".loc)
                        .talkieCard()
                } else {
                    waterfallCard
                }

                environmentCard

                if !latency.recentSamples(1).isEmpty {
                    recentCard
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(LiveBackground(mood: .ambient))
        .scrollContentBackground(.hidden)
        .navigationTitle("Dictation speed")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dictation speed".loc)
                .font(.talkieDisplay(28))
                .foregroundStyle(Theme.ink)
            Text("Where the time goes between you stopping and your words landing — measured on this Mac, nothing shared.".loc)
                .font(.talkieHeading(13, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Waterfall

    private var waterfallCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Eyebrow(text: "Where the time goes")

            let s = stages
            WaterfallBar(label: "Finalize speech".loc, ms: s.finalizeMs, total: s.sumMs,
                         color: Theme.featherBlue)
            // Re-transcription only runs for multilingual dictation; when its median
            // is ~0 it still shows as a (near-empty) row so the set of stages is
            // stable and honest rather than appearing/vanishing.
            WaterfallBar(label: "Re-transcribe".loc, ms: s.reTxMs, total: s.sumMs,
                         color: Theme.featherPlum)
            WaterfallBar(label: "Clean up".loc, ms: s.cleanupMs, total: s.sumMs,
                         color: Theme.featherCoral)
            WaterfallBar(label: "Insert".loc, ms: s.insertMs, total: s.sumMs,
                         color: Theme.featherGold)

            if let cold = latency.coldStartSample {
                Divider().overlay(Theme.hairline).padding(.vertical, 2)
                ColdStartRow(record: cold)
            }
        }
        .talkieCard()
    }

    // MARK: - Environment diagnostics

    /// Every row here is conditional: a healthy Mac with Apple Intelligence on and
    /// no pressure shows only the all-clear line. Rows appear top-to-bottom in
    /// rough order of how often they matter.
    private var environmentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "What might be slowing things down")

            let rows = DiagnosticRow.detected(pressure: pressure)
            if rows.isEmpty {
                DiagnosticLine(
                    icon: "checkmark.circle.fill",
                    tint: Theme.featherGreen,
                    title: "Nothing's getting in the way".loc,
                    detail: "No thermal throttling, Low Power Mode, or memory pressure right now, and on-device cleanup is available.".loc
                )
            } else {
                ForEach(rows) { row in
                    DiagnosticLine(icon: row.icon, tint: row.tint,
                                   title: row.title, detail: row.detail)
                    if row.showsMemoryList {
                        MemoryHogList()
                    }
                }
            }
        }
        .talkieCard()
    }

    // MARK: - Recent list

    private var recentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Your last dictations")
            VStack(spacing: 0) {
                let rows = latency.recentSamples(10)
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, r in
                    if idx > 0 { Divider().overlay(Theme.hairline) }
                    RecentRow(record: r)
                }
            }
        }
        .talkieCard()
    }
}

// MARK: - Waterfall bar

/// One stage in the waterfall: a label, a proportional bar (its share of the four
/// stages' sum), and the median milliseconds for that stage. The proportion is
/// `ms / total`, clamped to [0, 1]; a zero total lays every bar out empty rather
/// than dividing by zero.
private struct WaterfallBar: View {
    let label: String
    let ms: Double
    let total: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(.talkieHeading(13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text(Self.millis(ms))
                    .font(.talkieHeading(12, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceSunken)
                    Capsule().fill(color)
                        .frame(width: max(2, geo.size.width * LatencyStore.StageMedians.proportion(ms: ms, total: total)))
                }
            }
            .frame(height: 7)
        }
    }

    /// A compact millisecond / second reading (e.g. "820 ms", "1.2 s").
    static func millis(_ ms: Double) -> String {
        if ms >= 1000 { return String(format: "%.1f s".loc, ms / 1000) }
        return String(format: "%.0f ms".loc, ms)
    }
}

/// The cold-start row: the first dictation after launch pays the on-device model
/// load, so it sits apart from the steady-state medians with an honest label.
private struct ColdStartRow: View {
    let record: LatencyStore.Record
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "thermometer.snowflake")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.featherBlue)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("First dictation after launch — model load".loc)
                    .font(.talkieHeading(13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text("Shown on its own — it isn't counted in the medians above.".loc)
                    .font(.talkieHeading(11, weight: .regular))
                    .foregroundStyle(Theme.inkTertiary)
            }
            Spacer(minLength: 8)
            Text(WaterfallBar.millis(record.totalMs))
                .font(.talkieHeading(13, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
                .monospacedDigit()
        }
    }
}

// MARK: - Diagnostic rows (only-when-detected)

/// A single environment diagnostic. `detected(pressure:)` returns the rows whose
/// condition actually holds right now — the list is empty on a healthy Mac. Each
/// row is pure presentation over a live system read; nothing here is persisted.
struct DiagnosticRow: Identifiable {
    let id: String
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    /// True only for the memory-pressure row, which is followed by the on-demand
    /// most-memory-hungry-apps list.
    var showsMemoryList: Bool = false

    /// Build the set of rows whose condition is detected, in display order. A row is
    /// added ONLY when its predicate is true, so a nominal Mac yields `[]`.
    @MainActor
    static func detected(pressure: SystemPressure) -> [DiagnosticRow] {
        var rows: [DiagnosticRow] = []

        // Thermal throttling — anything above nominal.
        if ProcessInfo.processInfo.thermalState != .nominal {
            rows.append(DiagnosticRow(
                id: "thermal",
                icon: "thermometer.sun.fill",
                tint: Theme.featherGold,
                title: "Your Mac is running warm".loc,
                detail: "macOS is throttling to manage heat, which can slow on-device speech and cleanup until it cools down.".loc
            ))
        }

        // Low Power Mode.
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            rows.append(DiagnosticRow(
                id: "lowPower",
                icon: "battery.25",
                tint: Theme.featherGold,
                title: "Low Power Mode is on".loc,
                detail: "Low Power Mode caps performance to save battery, so dictation may take a little longer than usual.".loc
            ))
        }

        // Apple Intelligence unavailable → cleanup runs without AI (never "slower").
        // Uses CleanupEngine's EXACT existing message so the copy stays in one place.
        if let message = CleanupEngine.unavailableMessage {
            rows.append(DiagnosticRow(
                id: "aiUnavailable",
                icon: "sparkles",
                tint: Theme.featherBlue,
                title: "Cleanup runs without AI right now".loc,
                detail: message
            ))
        }

        // Memory pressure — only after the OS has actually signalled it this session.
        if pressure.worstSeen > .normal {
            rows.append(DiagnosticRow(
                id: "memory",
                icon: "memorychip.fill",
                tint: Theme.featherGold,
                title: "Your Mac is low on memory".loc,
                detail: "macOS has reported memory pressure this session, which can slow everything down while it frees up space.".loc,
                showsMemoryList: true
            ))
        }

        return rows
    }
}

/// One rendered diagnostic line: a tinted glyph, a title, and a wrapping detail.
private struct DiagnosticLine: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.talkieHeading(14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(.talkieHeading(12, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The on-demand, never-stored list of the most memory-hungry regular apps, shown
/// only beneath the memory-pressure row. Read fresh at render via
/// `ProcessFootprint.topApps()`. The copy is pure information + disclosure and
/// makes NO claim that closing anything speeds Talkie up (honest-claims rule).
private struct MemoryHogList: View {
    // Read on demand at render; deliberately NOT persisted or cached.
    private var apps: [ProcessFootprint.Entry] { ProcessFootprint.topApps(limit: 5) }

    var body: some View {
        let entries = apps
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(entries) { entry in
                    HStack(spacing: 9) {
                        Group {
                            if let bundleID = entry.bundleID,
                               let icon = AppIconLookup.icon(forBundleID: bundleID) {
                                Image(nsImage: icon).resizable().scaledToFit()
                            } else {
                                Image(systemName: "app.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.inkTertiary)
                            }
                        }
                        .frame(width: 18, height: 18)
                        Text(entry.name)
                            .font(.talkieHeading(13, weight: .medium))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(ProcessFootprint.formatBytes(entry.footprintBytes))
                            .font(.talkieHeading(12, weight: .semibold))
                            .foregroundStyle(Theme.inkSecondary)
                            .monospacedDigit()
                    }
                }
                // VERBATIM disclosure copy — information only, no speedup promise.
                Text("These apps are using the most memory right now. Read on demand, never stored, never leaves this Mac.".loc)
                    .font(.talkieHeading(11, weight: .regular))
                    .foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .padding(.leading, 30)
            .padding(.top, 2)
        }
    }
}

// MARK: - Recent row

/// One dictation in the last-10 list: its total, a cold/optimistic tag when
/// relevant, and the four stage splits underneath.
private struct RecentRow: View {
    let record: LatencyStore.Record

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(WaterfallBar.millis(record.totalMs))
                    .font(.talkieHeading(14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .monospacedDigit()
                if record.coldStart { TagChip(text: "cold start".loc, tint: Theme.featherBlue) }
                if record.optimistic { TagChip(text: "optimistic".loc, tint: Theme.featherPlum) }
                Spacer()
                Text(String(format: "%d chars".loc, record.chars))
                    .font(.talkieHeading(11, weight: .regular))
                    .foregroundStyle(Theme.inkTertiary)
                    .monospacedDigit()
            }
            Text(stageSplit)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Theme.inkTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 9)
    }

    /// A compact "finalize · re-tx · cleanup · insert" split line in milliseconds.
    private var stageSplit: String {
        func ms(_ v: Double) -> String { String(format: "%.0f", v) }
        return "finalize \(ms(record.finalizeMs)) · re-tx \(ms(record.reTxMs)) · "
             + "cleanup \(ms(record.cleanupMs)) · insert \(ms(record.insertMs)) ms"
    }
}

/// A tiny tinted tag used inline in the recent list (cold start / optimistic).
private struct TagChip: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text)
            .font(.talkieHeading(10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}
