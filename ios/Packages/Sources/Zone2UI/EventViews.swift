import SwiftUI
import Zone2Kit

extension PlanEvent {
    /// "3 мая 2027", "начало июня 2027", "май 2027", "лето 2028", "2029" — as precise as the date is.
    func dateLabel(today: LocalDate? = nil) -> String {
        let year = String(dateFrom.iso.prefix(4))
        let month = Int(dateFrom.iso.dropFirst(5).prefix(2)) ?? 1
        let day = Int(dateFrom.iso.suffix(2)) ?? 1
        switch datePrecision {
        case "year":
            return year
        case "season":
            let season: String = switch month {
            case 3...5: L("spring")
            case 6...8: L("summer")
            case 9...11: L("autumn")
            default: L("winter")
            }
            return "\(season) \(year)"
        case "month":
            return "\(Self.standaloneMonth.string(from: dateFrom.utcDate)) \(year)"
        case "month_part":
            let monthOf = Self.monthOf.string(from: dateFrom.utcDate)
            let part: String = day <= 10 ? L("early \(monthOf)") : day <= 20 ? L("mid \(monthOf)") : L("late \(monthOf)")
            return "\(part) \(year)"
        default:
            let thisYear = today.map { $0.iso.prefix(4) == dateFrom.iso.prefix(4) } ?? false
            return thisYear ? dateFrom.formatted(.dateTime.day().month(.wide))
                : dateFrom.formatted(.dateTime.day().month(.wide).year())
        }
    }

    /// The stand-alone month name ("май", not "мая"); the year is appended without "г.".
    private static let standaloneMonth: DateFormatter = monthFormatter("LLLL")
    /// The month as in "начало июня" (genitive in Russian).
    private static let monthOf: DateFormatter = monthFormatter("MMMM")

    private static func monthFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }

    /// "вс, 22 августа 2027 · 08:00 (Barnaul)" — the full date for the race screen.
    var fullDateLabel: String {
        guard datePrecision == "day" else { return dateLabel() }
        var s = dateFrom.formatted(.dateTime.weekday(.abbreviated).day().month(.wide).year())
        if let startTime {
            s += " · \(startTime)"
            if let tz = timezone?.split(separator: "/").last {
                s += " (\(tz.replacingOccurrences(of: "_", with: " ")))"
            }
        }
        return s
    }

    var statusTitle: String? {
        switch status {
        case "registered": L("Registered")
        case "planned": L("Planned")
        case "idea": L("Idea")
        case "done": L("Finished")
        case "dnf": L("DNF")
        case "cancelled": L("Cancelled")
        default: nil
        }
    }

    var statusColor: Color {
        switch status {
        case "registered", "done": .green
        case "dnf": .orange
        default: .secondary
        }
    }
}

/// One race in a list: name, priority, date as precise as it is; on the right the countdown
/// (exact date ahead) or the result / status (history).
struct EventRow: View {
    let event: PlanEvent
    let today: LocalDate

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "flag.checkered").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.name).font(.subheadline.weight(.medium))
                    if let p = event.priority, !event.isClosed { Chip(text: p, color: .brand) }
                }
                Text(event.dateLabel(today: today)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if event.isConfirmed && event.isUpcoming(today: today) {
                Text("\(today.days(until: event.dateFrom)) d", bundle: .module).font(.headline.monospacedDigit())
            } else if let t = event.result?.timeSec {
                Text(Formats.clock(t)).font(.subheadline.monospacedDigit())
            } else if event.isClosed, let status = event.statusTitle {
                Chip(text: status, color: event.statusColor)
            }
        }
        .padding(.vertical, 2)
    }
}

/// All races (Profile → Races): ahead (planned/registered, by date, countdown for exact dates),
/// ideas, and history (finished, DNF, cancelled or simply past) newest first.
public struct RacesView: View {
    let store: LocalStore
    @State private var events: [PlanEvent] = []
    @State private var today: LocalDate?

    public init(store: LocalStore) { self.store = store }

    public var body: some View {
        let today = today ?? LocalDate.today(in: .current)
        let byDate = { (a: PlanEvent, b: PlanEvent) in (a.sortDate, a.name) < (b.sortDate, b.name) }
        let ahead = events.filter { $0.isOn && $0.isUpcoming(today: today) }.sorted(by: byDate)
        let ideas = events.filter { $0.status == "idea" && $0.isUpcoming(today: today) }.sorted(by: byDate)
        let past = events.filter { $0.isClosed || ($0.isOn && !$0.isUpcoming(today: today)) }
            .sorted(by: byDate).reversed()
        List {
            section(L("Ahead"), ahead, today)
            section(L("Ideas"), ideas, today)
            section(L("Past"), Array(past), today)
        }
        .overlay {
            if events.isEmpty { ContentUnavailableView(L("No races yet"), systemImage: "flag.checkered") }
        }
        .navigationTitle(L("Races"))
        .task {
            do {
                for try await e in store.observeEvents() { events = e }
            } catch {}
        }
        .task {
            do {
                for try await s in store.observe(pastDays: 0, futureDays: 0) { self.today = s.today }
            } catch {}
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [PlanEvent], _ today: LocalDate) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { e in
                    NavigationLink { EventView(event: e) } label: { EventRow(event: e, today: today) }
                }
            }
        }
    }
}

/// A race, offline (docs/07-ios-app.md §3.5a): date and start time, goal, the coach's notes with
/// tables and check lists, linked notebook pages. Read-only: changes go through the coach.
public struct EventView: View {
    let event: PlanEvent
    @Environment(\.planContext) private var context
    @State private var pages: [NotebookPage] = []

    public init(event: PlanEvent) { self.event = event }

    public var body: some View {
        let today = LocalDate.today(in: .current)
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(event.fullDateLabel).font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        if let status = event.statusTitle {
                            Chip(text: status, color: event.statusColor)
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: Space.l) {
                        if event.isConfirmed && event.isUpcoming(today: today) {
                            let days = today.days(until: event.dateFrom)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(verbatim: "\(days)")
                                    .font(.system(size: 56, weight: .bold).monospacedDigit())
                                    .foregroundStyle(Color.brand.gradient)
                                Text("days to go", bundle: .module).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        if let d = event.distanceM {
                            let p = Formats.distanceParts(d)
                            StatTile(label: L("Distance"), value: p.value, unit: p.unit, size: 28)
                        }
                        if let t = event.result?.timeSec {
                            StatTile(label: L("Time"), value: Formats.clock(t), size: 28)
                        }
                    }
                    if let goal = event.goal { MarkdownText(goal, style: .compact) }
                    if let text = event.dateText {
                        Label(text, systemImage: "calendar.badge.clock").font(.caption).foregroundStyle(.secondary)
                    }
                    if let raw = event.url, let url = URL(string: raw) {
                        Link(destination: url) {
                            Label(L("Race website"), systemImage: "safari").font(.subheadline)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            if let notes = event.notes, !notes.isEmpty {
                Section(L("Notes")) { MarkdownText(notes) }
            }
            let linked = (event.notebookRefs ?? []).compactMap { ref in pages.first { $0.slug == ref } }
            if !linked.isEmpty {
                Section(L("Notebook")) {
                    ForEach(linked) { page in
                        NavigationLink { NotebookPageView(page: page) } label: {
                            Label(page.title, systemImage: "doc.text")
                        }
                    }
                }
            }
        }
        .navigationTitle(event.name)
        .inlineTitle()
        .task {
            guard let store = context?.store, !(event.notebookRefs ?? []).isEmpty else { return }
            do {
                for try await p in store.observeNotebook() { pages = p }
            } catch {}
        }
    }
}
