// The hand-checked sample project (see the test checklist, page 10): 15 rows small enough to check by hand.

import Foundation

public func samplePumpStation() -> Session {
    let s = Session(newProject(name: "Sample - Pump station", startDate: "2026-10-05"))
    s.run("cal") { p, _ in
        var c = p.calendars[0]
        c.exceptions = [CalException(from: "2026-11-09", to: "2026-11-09", working: false, name: "Example holiday")]
        return try upsertCalendar(&p, c)
    }
    func add(_ name: String, _ level: Int, _ days: Double? = nil, _ preds: [Pred] = [], constraint: Constraint? = nil) -> Int {
        s.run("add") { p, _ in
            insertTask(&p, p.tasks.count, level: level, name: name, durationDays: days) { t in
                t.preds = preds
                if let c = constraint { t.constraint = c }
            }.uid
        }.value!
    }
    func P(_ uid: Int, _ type: String = "FS", _ v: Double = 0, _ u: String = "d") -> Pred { Pred(uid: uid, type: type, lag: Lag(v: v, u: u)) }
    _ = add("Site works", 1)                                                                       // 1
    let mob = add("Mobilise", 2, 3)                                                                 // 2
    let exc = add("Excavate", 2, 5, [P(mob)])                                                       // 3
    let fnd = add("Foundations", 2, 4, [P(exc, "FS", 2)])                                           // 4
    let stl = add("Steel erection", 2, 6, [P(fnd, "SS", 2)])                                        // 5
    let pip = add("Piping", 2, 5, [P(stl, "FF")])                                                   // 6
    _ = add("Equipment", 1)                                                                         // 7
    let ord = add("Order pump", 2, 2)                                                               // 8
    let man = add("Manufacture pump", 2, 15, [P(ord)])                                              // 9
    let del = add("Deliver pump", 2, 5, [P(man)])                                                   // 10
    let ins = add("Install pump", 2, 3, [P(del), P(fnd)])                                           // 11
    _ = add("Commissioning and handover", 1)                                                        // 12
    let per = add("Permit inspection", 2, 2, constraint: Constraint(type: "SNET", date: "2026-10-26")) // 13
    let com = add("Commissioning", 2, 4, [P(ins), P(pip), P(per)])                                 // 14
    _ = add("Handover", 2, 0, [P(com)])                                                             // 15
    return s
}
