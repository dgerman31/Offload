import Foundation

/// Why a capture couldn't be sorted.
///
/// Capture is Gemini-only. There used to be an on-device fallback, and it was worse than having
/// none: a small model silently standing in for a frontier one produced captures that were
/// quietly, invisibly dumber — "I left my jacket in school" landing as those literal words
/// instead of "Retrieve jacket from school" — with nothing anywhere saying the good model never
/// ran. The user couldn't tell a bad day for the AI from a bad app.
///
/// So when Gemini can't run, nothing is invented and nothing is saved half-understood. The words
/// stay in the capture box, this says exactly what happened, and the retry is the user's to make.
enum ExtractionUnavailable: Error, Equatable {
    /// No API key has been entered yet.
    case noKey
    /// Private mode is on, which forbids any cloud call.
    case privateMode
    /// This minute's or today's request allowance is spent.
    case overBudget
    /// The request never left the device — almost always no network.
    case offline(String)
    /// Google answered, but with an error.
    case failed(String)
    /// The call was abandoned because the user navigated away mid-capture. Not a failure, and
    /// deliberately not something to interrupt anyone about — see `isSilent`.
    case cancelled

    /// Should this interrupt the user? A cancelled call is one they caused by leaving; saying
    /// "the AI couldn't reach Google" about their own navigation would be noise, not diagnosis.
    var isSilent: Bool { self == .cancelled }

    /// What the popup says. Each one names what happened and what to do about it, and every
    /// recoverable case promises the words are still there — because they are, sitting in the
    /// capture box behind the alert.
    var message: String {
        switch self {
        case .noKey:
            return "Offload needs a Gemini API key to sort captures. Add one in Settings, then try again — your words are still here."
        case .privateMode:
            return "Private mode keeps everything on this device, so captures can't be sorted. Turn it off in Settings to use the AI — your words are still here."
        case .overBudget:
            return "You've used this period's AI allowance. Your words are still here — try again in a little while."
        case .offline:
            return "Offload couldn't reach the AI. Check your connection and try again — your words are still here."
        case .failed(let detail):
            return "The AI couldn't sort this capture. \(detail) Your words are still here — try again."
        case .cancelled:
            return "Capture cancelled."
        }
    }

    /// A short, safe-to-log label. Never carries Google's message text or the capture's words.
    var kind: String {
        switch self {
        case .noKey:       return "noKey"
        case .privateMode: return "privateMode"
        case .overBudget:  return "overBudget"
        case .offline:     return "offline"
        case .failed:      return "failed"
        case .cancelled:   return "cancelled"
        }
    }
}

extension ExtractionUnavailable: LocalizedError {
    /// Callers that can't present the alert — Siri's intents, the retry sweep — surface this
    /// instead of inventing a task from words nothing understood.
    var errorDescription: String? { message }
}
