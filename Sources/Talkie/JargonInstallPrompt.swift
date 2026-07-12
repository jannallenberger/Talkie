import SwiftUI
import AppKit

/// L16 — "Install my jargon" copy-prompt for the Dictionary page's export area.
///
/// A sibling of L9's Connect-to-Claude setup surface: instead of wiring the MCP up,
/// this hands the user a ready-made *prompt* they paste into Claude. A Claude session
/// with the `talkie` MCP connected then reads how the user actually talks to it —
/// their recurring proper nouns, product/project names, tools, people, and domain
/// terms — and suggests the ones Talkie would likely mis-hear back into the user's
/// dictionary through L15's teach-back write tools.
///
/// The prompt BODY is machine-directed English and is deliberately NOT localized
/// (same class as L9's JSON config and JobTitleEngine's model prompt) — it is read by
/// Claude, not the user. The surrounding UI chrome (labels, subtitle) IS localized via
/// `.loc`. The body must contain no URL literal — scripts/check-no-network.sh greps
/// Sources for the http/https scheme even inside comments — and it must never claim
/// Talkie auto-corrects everything: every tool call is QUEUED and the user confirms it
/// in Talkie with one tap plus an Undo.
enum JargonInstallPrompt {

    /// The English, machine-directed prompt the user copies and pastes into Claude.
    ///
    /// It instructs Claude to (a) use the `talkie` MCP, (b) look at how the user talks
    /// in this and recent sessions and call `get_dictionary` FIRST to avoid duplicates,
    /// (c) suggest genuinely-recurring terms Talkie would mis-hear via
    /// `add_vocabulary_term` / `add_replacement`, and fix or remove wrong entries with
    /// the management tools, and (d) understand that nothing is applied silently —
    /// every call is queued for the user to confirm in Talkie with a one-tap Undo.
    /// The etiquette wording mirrors docs/MCP_TEACH_BACK.md so it stays consistent with
    /// L9's setup prompt.
    static func body() -> String {
        """
        You have the `talkie` MCP connected. Talkie is my on-device dictation app; it \
        types what I say into whatever app I'm in. I want you to teach it to spell the \
        jargon I actually use so it stops mis-hearing my terms.

        Do this now, using only the `talkie` MCP tools:

        1. First call `get_dictionary` to see the vocabulary terms and spoken→written \
        replacement rules I already have. Never suggest something that is already there.

        2. Look at how I talk to you in THIS conversation and in our recent sessions — \
        the proper nouns, product and project names, tools, libraries, companies, \
        people, filenames, and domain terms I keep reaching for. You are reading your \
        own session context to infer my vocabulary; you are not asking Talkie for it. \
        Focus on the terms that recur, that are specific to me, and that ordinary \
        speech recognition would plausibly get wrong (novel names, capitalized \
        coinages, acronyms, `lowercase.dotted` filenames, non-English spellings).

        3. For each genuinely-recurring term that Talkie would likely mis-hear and that \
        is NOT already in my dictionary:
           - If it is a name, product, acronym, or coinage Talkie should learn to spell, \
        call `add_vocabulary_term` with the correct spelling.
           - If you know the specific WRONG thing recognition tends to produce for it \
        (for example it hears "get hub" when I mean "GitHub", or "higgs field" when \
        I mean "Higgsfield"), call `add_replacement` with `from` = the misheard form and \
        `to` = the correct spelling.

        4. If while reading `get_dictionary` you notice an existing entry that is clearly \
        wrong — a typo, a rule pointing at the wrong target, or a term I obviously never \
        use — fix it with `update_replacement`, or remove it with `remove_replacement` \
        or `remove_vocabulary_term`. Only touch an entry you are confident about.

        Etiquette — this matters:
        - Every one of these calls is only a SUGGESTION. Nothing changes my dictionary \
        directly. Talkie queues each call and shows me a pill with a one-tap Undo, and \
        it does NOT take effect until I confirm it. So you do not need to ask my \
        permission first — just make the call and tell me what you queued and why.
        - Do not spam it: one call per genuinely new or genuinely wrong term. Skip common \
        English words, skip anything already in the dictionary, and skip a term you are \
        only guessing at. A short, high-signal batch I can confirm at a glance is far \
        better than a long list of maybes.

        When you're done, give me a plain-language summary: the terms you suggested \
        adding, any rules you added, and anything you fixed or removed — so I know what \
        to confirm in Talkie.
        """
    }
}

/// The card that lives in the Dictionary page's export area. It offers a single
/// "Copy prompt" button that reuses the same copy-to-pasteboard + brief "Copied"
/// flash the MCP connector card uses (L9), so the interaction is identical across the
/// two Claude surfaces. The subtitle is honest: Claude *suggests* terms you confirm,
/// each with an Undo — it never silently auto-corrects anything.
struct InstallMyJargonCard: View {
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: "Install my jargon")
            Text("Let your AI agent teach Talkie your jargon. Paste this prompt into your AI agent (with the Talkie connector on) and it reads how you actually talk to it — your names, products, and terms — and suggests the ones Talkie would mis-hear. Every suggestion waits for your one-tap confirmation in Talkie, with an Undo. Your AI agent never changes your dictionary on its own.".loc)
                .font(.talkieHeading(13, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
            HStack {
                Button {
                    copyToPasteboard(JargonInstallPrompt.body())
                    flash($copied)
                } label: {
                    Label(copied ? "Copied".loc : "Copy prompt".loc,
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .tint(Theme.coral)
                Spacer()
            }
            Text("Needs the Talkie connector — set it up under Settings ▸ AI agent.".loc)
                .font(.talkieHeading(11.5, weight: .regular))
                .foregroundStyle(Theme.inkTertiary)
        }
        .talkieCard()
    }

    /// Same clipboard write the MCP connector card uses — no new mechanism.
    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Same "Copied" flash shape as MCPConnectorCard (1.4s, then reset).
    private func flash(_ flag: Binding<Bool>) {
        flag.wrappedValue = true
        Task { try? await Task.sleep(for: .seconds(1.4)); flag.wrappedValue = false }
    }
}
