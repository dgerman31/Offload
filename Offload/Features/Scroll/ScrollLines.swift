import Foundation

/// What the app actually says to you while you're scrolling.
///
/// The tone is the feature. A guilt-trip gets silenced within two days — you don't keep a thing
/// on your phone that talks to you like that — and a neutral "12 minutes elapsed" is wallpaper you
/// stop seeing by Thursday. So these are written to be on your side and slightly funny, and to get
/// shorter and flatter as the ladder climbs, because at ten minutes the joke is over and the only
/// useful message is a short one.
///
/// One rule holds throughout: **never shame, always offer the exit.** Half of these end by pointing
/// out that stopping right now costs nothing, because that happens to be true and it's the single
/// most useful thing anyone can be told at minute nine.
enum ScrollLines {

    /// What a line can talk about.
    struct Context: Equatable, Sendable {
        var minutes: Int
        var cards: Int
        /// What you left open, when the app could work it out. Lines that need one are skipped
        /// when it can't — a nudge naming "your task" in the abstract is worse than one that
        /// doesn't try.
        var task: String?
    }

    /// A title, a body, and whether the body needs a task name to make sense.
    ///
    /// Format strings rather than closures so the bank stays a plain `Sendable` value that can be
    /// checked in a test — every placeholder is verified to resolve, which is how you avoid
    /// shipping a notification that literally reads "{task} is waiting".
    struct Line: Equatable, Sendable {
        var title: String
        var body: String
        var needsTask = false
    }

    static func bank(for beat: ScrollGuard.Beat) -> [Line] {
        switch beat {
        case .nudge:      return nudges
        case .push:       return pushes
        case .cost:       return costs
        case .relentless: return relentless
        }
    }

    /// Two minutes. Light, brief, and the only warning that's purely friendly.
    static let nudges: [Line] = [
        .init(title: "Still you in there?",
              body: "Two minutes of scrolling is genuinely fine. Three is where it starts lying about how long it's been."),
        .init(title: "Just checking",
              body: "You've been here {mins} minutes. Did you mean to be?"),
        .init(title: "Small thing",
              body: "The feed has no ending. That isn't a bug, it's the product."),
        .init(title: "Two minutes in",
              body: "Still a coffee break. Let's keep it one."),
        .init(title: "Heads up",
              body: "Nothing's wrong yet — this is just the part where you'd normally stop noticing."),
        .init(title: "Hello",
              body: "You're allowed this. Pick a number in your head before the next one loads."),
        .init(title: "Noted",
              body: "{mins} minutes. Consider this the gentle one."),
        .init(title: "Quick one",
              body: "The next ten minutes are the ones that vanish. Now you know they're coming.")
    ]

    /// Four to six minutes. Names what you put down, because the thing you lose in a feed is the
    /// memory that you were doing something else.
    static let pushes: [Line] = [
        .init(title: "{task} is still open",
              body: "{mins} minutes here. It's still there, and it's still yours.", needsTask: true),
        .init(title: "Where were you?",
              body: "{mins} minutes. You started today wanting to do {task}.", needsTask: true),
        .init(title: "{mins} minutes",
              body: "This is the stretch you won't remember spending. Noticing it now."),
        .init(title: "Come back",
              body: "{mins} minutes. Nothing in here is going to be better than the thing you put down."),
        .init(title: "Still going",
              body: "{mins} minutes in. Honestly — are you enjoying this, or just not stopping?"),
        .init(title: "Checkpoint",
              body: "You opened this to rest for a second. {mins} minutes isn't rest, it's drift."),
        .init(title: "One question",
              body: "{mins} minutes. Put the phone down right now and the day is still completely fine."),
        .init(title: "{mins} minutes",
              body: "It will hand you another one forever. That's the entire trick.")
    ]

    /// Six to ten. The same minutes, priced in the only currency that means anything to you.
    static let costs: [Line] = [
        .init(title: "{mins} minutes ≈ {cards} cards",
              body: "That's the trade you just made. It might genuinely be worth it — but decide it, don't drift into it."),
        .init(title: "The bill",
              body: "{mins} minutes here is about {cards} cards. Tomorrow-you is picking that up."),
        .init(title: "{cards} cards",
              body: "That's what {mins} minutes bought. Has any of it been worth {cards} cards?"),
        .init(title: "Exchange rate",
              body: "{mins} minutes, {cards} cards. Stopping now costs you nothing further."),
        .init(title: "Worth it?",
              body: "{mins} minutes ≈ {cards} cards. Serious question, not a telling-off."),
        .init(title: "Priced up",
              body: "{cards} cards' worth of scrolling. The good news is the meter stops the moment you close it."),
        .init(title: "{mins} minutes gone",
              body: "About {cards} cards. {task} is where they were going.", needsTask: true),
        .init(title: "Maths",
              body: "{mins} minutes = roughly {cards} cards you now owe. Close it and you owe nothing.")
    ]

    /// Ten minutes and past. Short, flat, frequent. No jokes left.
    static let relentless: [Line] = [
        .init(title: "Put it down.", body: "{mins} minutes."),
        .init(title: "Still here.", body: "{mins} minutes. You're not choosing this any more."),
        .init(title: "Hey.", body: "This is the algorithm winning. It is very good at this. Close it."),
        .init(title: "{mins} minutes", body: "You won't remember one of these tomorrow."),
        .init(title: "Enough.", body: "Twenty seconds of willpower. That's the whole ask."),
        .init(title: "Stop.", body: "{mins} minutes. Nothing good is coming."),
        .init(title: "Come on.", body: "{mins} minutes. You already know. Close the app."),
        .init(title: "Last one.", body: "Put it down and the day restarts right now.")
    ]

    /// The line for the nth interruption of a session.
    ///
    /// Walks the bank rather than picking at random, so a single session never repeats itself, and
    /// starts at a different place each day so the same three lines don't become furniture. Lines
    /// needing a task are dropped when there isn't one, which is why the filtering happens before
    /// the indexing and not after.
    static func line(for beat: ScrollGuard.Beat, index: Int, context: Context, daySeed: Int = 0) -> Line {
        let available = bank(for: beat).filter { !$0.needsTask || context.task != nil }
        // Every bank has task-free lines in it, so this is unreachable — but a crash on an empty
        // collection at minute nine of a doomscroll would be a memorable way to find out otherwise.
        guard !available.isEmpty else {
            return Line(title: "Still scrolling", body: "\(context.minutes) minutes.")
        }
        let offset = ((index + daySeed) % available.count + available.count) % available.count
        let line = available[offset]
        return Line(title: fill(line.title, context), body: fill(line.body, context), needsTask: false)
    }

    /// Substitute the placeholders. Anything unresolved is stripped rather than shown: a
    /// notification reading "{task} is waiting" is worse than one that's slightly generic.
    static func fill(_ text: String, _ context: Context) -> String {
        var result = text
            .replacingOccurrences(of: "{mins}", with: "\(context.minutes)")
            .replacingOccurrences(of: "{cards}", with: "\(context.cards)")
        if let task = context.task, !task.isEmpty {
            result = result.replacingOccurrences(of: "{task}", with: task)
        } else {
            result = result.replacingOccurrences(of: "{task}", with: "what you were doing")
        }
        return result
    }

    /// A stable per-day rotation offset, so the bank doesn't start from the same line every day.
    static func daySeed(_ now: Date = Date(), calendar: Calendar = .current) -> Int {
        calendar.ordinality(of: .day, in: .era, for: now) ?? 0
    }
}
