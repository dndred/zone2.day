import Foundation
import Testing
@testable import Zone2Kit

private func event(_ json: String) throws -> PlanEvent {
    try JSONDecoder().decode(PlanEvent.self, from: Data(json.utf8))
}

private func race(precision: String, from: String, to: String, status: String = "planned") throws -> PlanEvent {
    try event("""
    {"id":"e","name":"Race","sport":"run","status":"\(status)","datePrecision":"\(precision)",
     "dateFrom":"\(from)","dateTo":"\(to)"}
    """)
}

@Test func eventCarriesNotesAndRefs() throws {
    let e = try event("""
    {"id":"a3","name":"Altai3Race","sport":"triathlon","status":"registered","datePrecision":"day",
     "dateFrom":"2027-08-22","dateTo":"2027-08-22","startTime":"08:00","timezone":"Asia/Barnaul",
     "format":"olympic","url":"https://example.org/83","notebookRefs":["season","fuel"],
     "notes":"## Gear\\n- [ ] Wetsuit"}
    """)
    #expect(e.notes == "## Gear\n- [ ] Wetsuit")
    #expect(e.notebookRefs == ["season", "fuel"])
    #expect(e.startTime == "08:00" && e.timezone == "Asia/Barnaul")
    #expect(e.isOn && e.isConfirmed)
}

@Test func monthAndYearRacesStayUpcomingUntilTheyEnd() throws {
    let today = LocalDate("2027-05-20")!
    #expect(try race(precision: "month", from: "2027-05-01", to: "2027-05-31").isUpcoming(today: today))
    #expect(try !race(precision: "month", from: "2027-04-01", to: "2027-04-30").isUpcoming(today: today))
    #expect(try race(precision: "year", from: "2027-01-01", to: "2027-12-31").isUpcoming(today: today))
    #expect(try !race(precision: "day", from: "2027-05-03", to: "2027-05-03").isUpcoming(today: today))
    #expect(try race(precision: "day", from: "2027-05-20", to: "2027-05-20").isUpcoming(today: today))
    let month = try race(precision: "month", from: "2027-05-01", to: "2027-05-31")
    #expect(month.isOn && !month.isConfirmed)
    #expect(month.sortDate > (try race(precision: "day", from: "2027-05-03", to: "2027-05-03")).sortDate)
    #expect(try !race(precision: "day", from: "2027-08-22", to: "2027-08-22", status: "idea").isOn)
}

@Test func closedRacesAndResults() throws {
    let done = try event("""
    {"id":"p","name":"Parkrun","sport":"run","status":"done","datePrecision":"day",
     "dateFrom":"2027-05-03","dateTo":"2027-05-03","result":{"timeSec":12000,"place":12}}
    """)
    #expect(done.isClosed && !done.isOn)
    #expect(done.result?.timeSec == 12000 && done.result?.place == "12")
    // A season window stays ahead until it ends.
    #expect(try race(precision: "season", from: "2027-06-01", to: "2027-08-31").isUpcoming(today: LocalDate("2027-07-15")!))
}
