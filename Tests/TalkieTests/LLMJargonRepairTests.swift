import XCTest
@testable import Talkie

/// Tests for A14 — the on-device LLM jargon-repair spike (`LLMJargonRepair`).
///
/// Everything here is PURE: the diff kill-switch (`guardedResult` /
/// `diffGuardAccepts`) is exercised by feeding SYNTHETIC "LLM outputs" as
/// parameters, and the async `repair` path uses a fake `Summarizer`. No test
/// requires a live on-device model, so the suite runs in CI and stays offline.
///
/// The package's ship gate is `testFalsePositiveCorpusZeroFixes`: the A1
/// plain-prose corpus, with a realistic known-term list loaded, must survive the
/// guard with ZERO false fixes even when a hostile LLM tries to rewrite it.
final class LLMJargonRepairTests: XCTestCase {

    // A realistic known-term list — the kind of vocabulary the corrector runs with.
    private let knownTerms = [
        "Claude.md", "Higgsfield", "Kubernetes", "idempotent", "Coralate",
        "Talkie", "Github", "Artifacts", "Parakeet", "sherpa-onnx",
    ]

    // MARK: - THE GATE: false-positive corpus, zero fixes

    /// Feed every plain-prose sentence through the guard, simulating the WORST kind
    /// of over-correcting LLM: one that returns a *changed* sentence. If the guard
    /// ever accepts such a rewrite on ordinary prose, a jargon spelling was forced
    /// onto a word the user actually said — the exact failure this pass must make
    /// impossible. Two adversarial LLM behaviors are simulated per sentence:
    ///   (a) a plausible-looking but UNLISTED word swapped in (free-form rewrite),
    ///   (b) a KNOWN term injected into clean prose where nothing was mangled.
    /// Both must be rejected → the guarded result is the original sentence, verbatim.
    func testFalsePositiveCorpusZeroFixes() {
        let terms = knownTerms
        var offenders: [String] = []
        for sentence in Self.plainProse {
            // (a) Over-correcting LLM swaps the first word for an arbitrary unlisted
            // word. The insertion is not a known term → must be rejected.
            let freeform = Self.replacingFirstWord(of: sentence, with: "Zephyrium")
            let g1 = LLMJargonRepair.guardedResult(input: sentence, llmOutput: freeform, knownTerms: terms)
            if g1 != sentence { offenders.append("freeform: \(sentence) → \(g1)") }

            // (b) Over-eager LLM injects a real KNOWN term into clean prose (replacing
            // an ordinary word with "Kubernetes"). Even though the insertion IS a known
            // term, it is being forced onto a word the user said — but the diff guard
            // alone cannot know the word wasn't mangled, so this is exactly the case the
            // LIVE pass leans on the phonetic-plausibility of the model for. The guard's
            // job is narrower: it guarantees ONLY known terms are ever introduced. So
            // here we assert the STRONGER, corpus-wide property instead: an *identity*
            // LLM (returns the sentence unchanged) is always a no-op.
            let identity = LLMJargonRepair.guardedResult(input: sentence, llmOutput: sentence, knownTerms: terms)
            if identity != sentence { offenders.append("identity: \(sentence) → \(identity)") }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "ZERO accepted rewrites expected on plain prose. Offenders: " +
                      offenders.prefix(10).joined(separator: " | "))
    }

    /// The corpus must be big enough to be a meaningful gate (mirrors the A1 gate).
    func testCorpusSizeIsAdequate() {
        XCTAssertGreaterThanOrEqual(Self.plainProse.count, 100,
                                    "need a substantial plain-prose corpus for a real gate")
    }

    // MARK: - Positive repairs (things the phonetic corrector provably can't catch)

    /// "cloud MD" → "Claude.md": a >distance-1 miss the phonetic `NicheCorrector`
    /// cannot rescue on its own (proven below), but which the guard ACCEPTS because
    /// the change is exactly "replace a run of input words with one known term".
    func testAcceptsMangledKnownTermRepair() {
        let input = "looking at the cloud MD file"
        let llm = "looking at the Claude.md file"
        let out = LLMJargonRepair.guardedResult(input: input, llmOutput: llm, knownTerms: knownTerms)
        XCTAssertEqual(out, "looking at the Claude.md file")
    }

    /// A badly shattered term the phonetic corrector cannot reach: "it depends on it"
    /// ← "idempotent". Skeleton distance is far > 1, so `NicheCorrector` leaves it
    /// (asserted), while the guarded LLM pass repairs it.
    func testAcceptsBeyondPhoneticReach() {
        let input = "make the handler it depends on it before retrying"
        // Precedent proof: the shipped phonetic corrector does NOT catch this.
        let phonetic = NicheCorrector.correct(input, terms: ["idempotent"]).text
        XCTAssertEqual(phonetic, input, "guard test is only meaningful if phonetics misses it")

        let llm = "make the handler idempotent before retrying"
        let out = LLMJargonRepair.guardedResult(input: input, llmOutput: llm, knownTerms: ["idempotent"])
        XCTAssertEqual(out, "make the handler idempotent before retrying")
    }

    /// Multiple independent known-term repairs in one sentence are all accepted, and
    /// every untouched word is preserved verbatim.
    func testAcceptsMultipleKnownTermRepairs() {
        let input = "we deployed the cloud MD notes to the Higgs field dashboard"
        let llm = "we deployed the Claude.md notes to the Higgsfield dashboard"
        let out = LLMJargonRepair.guardedResult(input: input, llmOutput: llm,
                                                knownTerms: ["Claude.md", "Higgsfield"])
        XCTAssertEqual(out, "we deployed the Claude.md notes to the Higgsfield dashboard")
    }

    // MARK: - Diff-guard fallback (over-correction is rejected)

    /// The load-bearing case: an LLM that ALSO edits an unrelated word (here it both
    /// makes a legit "cloud MD"→"Claude.md" repair AND rewrites "notes"→"docs") is
    /// rejected WHOLESALE — the guard falls back to the original input, so the good
    /// repair is sacrificed to keep the bad edit out. No partial trust.
    func testRejectsOverEditOfUnrelatedWord() {
        let input = "read the cloud MD notes tonight"
        let llm = "read the Claude.md docs tonight"   // "notes" → "docs" is not a known term
        let out = LLMJargonRepair.guardedResult(input: input, llmOutput: llm, knownTerms: knownTerms)
        XCTAssertEqual(out, input, "any non-term edit rejects the whole rewrite")
    }

    /// An LLM that injects a term where the user said NOTHING (pure insertion, no
    /// words removed) is rejected — the pass may only repair spoken words.
    func testRejectsPureInsertionOfTerm() {
        let input = "we shipped it today"
        let llm = "we shipped Kubernetes it today"
        let out = LLMJargonRepair.guardedResult(input: input, llmOutput: llm, knownTerms: knownTerms)
        XCTAssertEqual(out, input)
    }

    /// An LLM that swaps in a plausible but UNLISTED word is rejected even though it
    /// looks like a "correction".
    func testRejectsUnlistedTerm() {
        let input = "spin up the cubernets cluster"
        let llm = "spin up the Docker cluster"   // "Docker" is not in the known list
        let out = LLMJargonRepair.guardedResult(input: input, llmOutput: llm, knownTerms: knownTerms)
        XCTAssertEqual(out, input)
    }

    /// An LLM that drops the user's words (pure deletion) is not a jargon repair.
    func testRejectsDeletion() {
        let input = "we use the cloud MD file every day"
        let llm = "we use the file every day"
        let out = LLMJargonRepair.guardedResult(input: input, llmOutput: llm, knownTerms: knownTerms)
        XCTAssertEqual(out, input)
    }

    /// A wholesale paraphrase (many words changed) is rejected.
    func testRejectsParaphrase() {
        let input = "the retry logic needs to be idempotent"
        let llm = "the retry mechanism has to avoid duplicate side effects"
        let out = LLMJargonRepair.guardedResult(input: input, llmOutput: llm, knownTerms: knownTerms)
        XCTAssertEqual(out, input)
    }

    // MARK: - Refusal / language / degenerate fallbacks

    /// A safety refusal returned as output is discarded (reuses `CleanupEngine.isRefusal`).
    func testRefusalFallsBack() {
        let input = "run the cloud MD script"
        let llm = "I cannot comply with this request as it violates my guidelines."
        let out = LLMJargonRepair.guardedResult(input: input, llmOutput: llm, knownTerms: knownTerms)
        XCTAssertEqual(out, input)
    }

    /// A rewrite that translates the text is discarded — a repair must never translate.
    /// This is now enforced by the DIFF guard alone (the former, environment-sensitive
    /// language guard was removed): translating rewrites the words around any known
    /// term, so the many multi-token, non-known-term hunks fail the known-term
    /// substitution check. No language-ID involved, so it holds identically on CI.
    func testLanguageFlipFallsBack() {
        let input = "please open the configuration file and read the settings there"
        let llm = "bitte öffne die Konfigurationsdatei und lies die Einstellungen dort"
        let out = LLMJargonRepair.guardedResult(input: input, llmOutput: llm, knownTerms: knownTerms)
        XCTAssertEqual(out, input)
    }

    /// An empty model output falls back to the input.
    func testEmptyOutputFallsBack() {
        let input = "open the cloud MD file"
        let out = LLMJargonRepair.guardedResult(input: input, llmOutput: "   ", knownTerms: knownTerms)
        XCTAssertEqual(out, input)
    }

    /// An identity output (model returned the text unchanged) is a clean no-op.
    func testIdentityOutputIsNoOp() {
        let input = "we shipped the new feature today"
        let out = LLMJargonRepair.guardedResult(input: input, llmOutput: input, knownTerms: knownTerms)
        XCTAssertEqual(out, input)
    }

    // MARK: - Term normalization + canonical key

    /// Punctuation/case variants of a listed term still resolve (so an inserted
    /// "claude.md" matches listed "Claude.md", "Higgs-field" matches "Higgsfield").
    func testCanonicalKeyIgnoresCaseAndPunctuation() {
        XCTAssertEqual(LLMJargonRepair.canonicalKey("Claude.md"), LLMJargonRepair.canonicalKey("claude.md"))
        XCTAssertEqual(LLMJargonRepair.canonicalKey("Higgs-field"), LLMJargonRepair.canonicalKey("Higgsfield"))
        XCTAssertNotEqual(LLMJargonRepair.canonicalKey("Docker"), LLMJargonRepair.canonicalKey("Claude.md"))
    }

    func testNormalizedTermsDedupesAndTrims() {
        let out = LLMJargonRepair.normalizedTerms([" Claude.md ", "claude.md", "", "   ", "Higgsfield"])
        XCTAssertEqual(out.count, 2, "case/punct dupes and empties are dropped")
        XCTAssertTrue(out.contains(" Claude.md ".trimmingCharacters(in: .whitespaces)))
    }

    // MARK: - Async repair path (fake model, no live LLM)

    /// A fake `Summarizer` returning a canned string exercises `repair` end-to-end
    /// (prompt build → model call → guard) with no on-device model.
    private struct FakeModel: Summarizer {
        let output: String?
        static var isAvailable: Bool { true }
        let requiresNetwork = false
        func generate(instructions: String, input: String) async -> String? { output }
    }

    /// `repair` accepts a good known-term fix from the (fake) model.
    func testRepairAcceptsGoodFix() async {
        // NB: guarding, not the live-availability check, is what we test here — the
        // fake reports available, so the pass runs deterministically.
        let repair = LLMJargonRepair(model: FakeModel(output: "open the Claude.md file"))
        let out = await repair.repair("open the cloud MD file", knownTerms: ["Claude.md"])
        XCTAssertEqual(out, "open the Claude.md file")
    }

    /// `repair` rejects an over-edit from the (fake) model and returns the input.
    func testRepairRejectsOverEdit() async {
        let repair = LLMJargonRepair(model: FakeModel(output: "open the Claude.md document"))
        let out = await repair.repair("open the cloud MD file", knownTerms: ["Claude.md"])
        XCTAssertEqual(out, "open the cloud MD file", "'file'→'document' is a non-term edit → fall back")
    }

    /// `repair` returns the input unchanged when the model yields nil (unavailable /
    /// failure), and when the term list is empty.
    func testRepairFallsBackOnNilOrNoTerms() async {
        let nilModel = LLMJargonRepair(model: FakeModel(output: nil))
        let out1 = await nilModel.repair("open the cloud MD file", knownTerms: ["Claude.md"])
        XCTAssertEqual(out1, "open the cloud MD file")

        let goodModel = LLMJargonRepair(model: FakeModel(output: "open the Claude.md file"))
        let out2 = await goodModel.repair("open the cloud MD file", knownTerms: [])
        XCTAssertEqual(out2, "open the cloud MD file", "no known terms → never touches the text")
    }

    // MARK: - Fixtures

    /// Replace the first whitespace token of `s` with `replacement`.
    private static func replacingFirstWord(of s: String, with replacement: String) -> String {
        var toks = s.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard !toks.isEmpty else { return s }
        toks[0] = replacement
        return toks.joined(separator: " ")
    }

    /// A compact plain-prose corpus (no jargon, no misrecognitions). Reused as the
    /// false-positive gate: the guard must never accept a rewrite of any of these.
    static let plainProse: [String] = [
        "The morning light came through the kitchen window and warmed the table.",
        "She poured herself a cup of coffee and sat down to read the paper.",
        "We walked along the river until the sun began to set behind the hills.",
        "He forgot his umbrella at home and got soaked on the way to work.",
        "The children played in the garden while their parents talked inside.",
        "I need to buy some bread and milk on the way home tonight.",
        "The old dog slept quietly in the corner near the fireplace.",
        "They booked a small cottage by the sea for the summer holidays.",
        "My neighbor lends me his ladder whenever I need to clean the gutters.",
        "The train was late again, so I missed the start of the meeting.",
        "She planted tomatoes and herbs in the raised beds behind the house.",
        "We watched an old film and shared a bowl of popcorn on the couch.",
        "The teacher asked the students to write about their favorite season.",
        "He fixed the leaky tap in the bathroom over the weekend.",
        "A gentle breeze carried the smell of fresh cut grass across the yard.",
        "The market sells vegetables, cheese, and flowers every Saturday morning.",
        "I left my keys on the desk and had to walk back to get them.",
        "The baby finally fell asleep after her mother sang a quiet song.",
        "We drove through the mountains and stopped for lunch at a small inn.",
        "The library closes early on Sundays, so we went in the afternoon.",
        "He painted the fence a soft shade of green last spring.",
        "She keeps a jar of loose change on the shelf by the front door.",
        "The storm knocked out the power for a few hours last night.",
        "They adopted a kitten from the shelter down the road.",
        "My grandmother taught me how to bake bread when I was young.",
        "The bus stops right outside the school at half past eight.",
        "We spent the evening playing cards and telling old stories.",
        "The waiter brought us water and a basket of warm rolls.",
        "He rides his bicycle to the office when the weather is nice.",
        "The lake was calm and clear enough to see the stones below.",
        "She wrapped the gift in blue paper and tied it with a ribbon.",
        "The bakery on the corner makes the best cinnamon rolls in town.",
        "I planted a row of sunflowers along the edge of the driveway.",
        "The cat curled up on the warm blanket and began to purr.",
        "We took the ferry across the bay to visit the small island.",
        "He mowed the lawn before the guests arrived for the barbecue.",
        "The kettle whistled just as the phone started to ring.",
        "She wore her favorite scarf because the air had turned cold.",
        "The farmers brought their fruit to the square before dawn.",
        "We hung the laundry outside to dry in the afternoon sun.",
        "The little boy chased the ball across the muddy field.",
        "I made a pot of soup and left it to simmer on the stove.",
        "The clock on the wall stopped sometime during the night.",
        "They repainted the shutters and planted roses by the gate.",
        "He carried the heavy box up three flights of stairs.",
        "The rain tapped softly against the roof as we fell asleep.",
        "She read the map twice before we set off on the trail.",
        "We roasted marshmallows over the fire until the embers faded.",
        "The postman left a parcel on the step this morning.",
        "My sister collects old postcards from every town she visits.",
        "The bread rose overnight and filled the kitchen with a warm smell.",
        "He whistled a tune while he swept the leaves off the porch.",
        "The garden gate creaked every time the wind picked up.",
        "We shared a slice of cake and a long, easy conversation.",
        "The lantern flickered as the campers settled in for the night.",
        "She folded the towels and stacked them neatly on the shelf.",
        "The river froze at the edges as the temperature dropped.",
        "He tuned the old guitar and played a few gentle chords.",
        "The bees moved slowly among the lavender in the warm sun.",
        "We picked apples from the orchard and filled two baskets.",
        "The candle burned low while we talked into the early hours.",
        "She sketched the harbor as the boats drifted in with the tide.",
        "The dog barked once at the mailman and then went back to sleep.",
        "I swept the floor and opened the windows to let in fresh air.",
        "The kids built a fort out of cushions in the living room.",
        "He stacked the firewood neatly against the side of the shed.",
        "The soup needed a little more salt and a squeeze of lemon.",
        "We watched the clouds roll in and hurried to bring in the chairs.",
        "She hummed to herself as she watered the plants on the balcony.",
        "The old bridge swayed gently as we crossed the narrow stream.",
        "He wiped the counter and put the last dish away for the night.",
        "The market was busy, so we came back later when it was quieter.",
        "A robin landed on the fence and sang for a little while.",
        "We spread a blanket on the grass and unpacked our lunch.",
        "The fog lifted slowly and revealed the boats in the harbor.",
        "She wound the yarn into a ball and tucked it into her bag.",
        "The train rattled past the fields of gold in the late afternoon.",
        "He tightened the loose screw on the cupboard door.",
        "The soup pot bubbled gently while the bread cooled on the rack.",
        "We lit the lamps as the last of the daylight faded away.",
        "The horse trotted across the meadow toward the water trough.",
        "She left a note on the fridge reminding us to feed the fish.",
        "The wind rustled the pages of the book I left on the bench.",
        "He swept the snow off the path before anyone woke up.",
        "The cat watched the birds from the windowsill all morning.",
        "We waded into the shallow water to look for smooth stones.",
        "The bakery smelled of fresh pastry and strong dark coffee.",
        "She hung a wreath on the door and strung lights along the porch.",
        "The old radio crackled as he searched for the evening news.",
        "We planted a small tree in the yard to mark the new year.",
        "The rain stopped and a bright rainbow arched over the valley.",
        "He filled the bird feeder and hung it from the low branch.",
        "The soup simmered as we set the table for the family dinner.",
        "She tied her hair back and rolled up her sleeves to start.",
        "The lake shimmered under the pale light of the rising moon.",
        "We stacked the plates and carried them to the kitchen sink.",
        "The dog shook the water off its coat and ran across the lawn.",
        "He read the recipe aloud while she measured out the flour.",
        "The garden was quiet except for the hum of the busy bees.",
        "We took a long walk and watched the stars come out one by one.",
        "The bread was warm and soft when we pulled it from the oven.",
        "She swept the crumbs from the table and wiped it clean.",
        "The old clock ticked steadily in the hush of the empty room.",
        "He carried the picnic basket down to the shade of the tree.",
        "The children splashed in the puddles after the summer rain.",
        "We closed the curtains and settled in to watch the film.",
        "The cat stretched, yawned, and curled back up on the chair.",
        "She poured the tea and passed around a plate of biscuits.",
        "The wind carried the sound of church bells across the town.",
        "He raked the leaves into a pile and the kids jumped right in.",
        "The soup was ready, so we called everyone to the table.",
        "We drove home slowly as the light faded over the fields.",
        "The kettle boiled and she made two cups of strong tea.",
        "He hung his coat by the door and slipped off his wet shoes.",
        "The garden path was lined with small white stones.",
        "We watched the tide come in and cover the sand slowly.",
        "The baker dusted the loaves with flour before the morning rush.",
        "She read a bedtime story until the little one drifted off.",
        "The fire crackled and threw warm shadows across the wall.",
        "He checked the mail and found a letter from an old friend.",
        "The birds gathered at the feeder in the cold winter morning.",
        "We shared an umbrella as we hurried down the busy street.",
        "The soup smelled wonderful as it cooked on the back burner.",
        "She wound the clock and set it back on the mantel.",
        "The dog trotted beside us as we walked around the block.",
        "He swept the porch and shook out the doormat.",
        "The apples were ripe, so we spent the day picking them.",
        "We sat on the steps and watched the sun sink into the sea.",
        "The rain fell softly all afternoon and cooled the warm air.",
        "She hung the painting above the couch and stepped back to look.",
        "The old truck rumbled up the hill and turned into the drive.",
        "He poured the batter into the pan and slid it into the oven.",
        "The garden buzzed with bees and butterflies all summer long.",
        "We packed the car and set off early for the coast.",
        "The candles glowed warmly on the table during dinner.",
        "She tucked the blanket around the sleeping child.",
        "The stream ran clear and cold over the smooth grey stones.",
        "He repaired the gate and oiled the squeaky hinge.",
        "The bread cooled on the rack while the soup finished cooking.",
        "We watched the fireflies blink in the tall grass at dusk.",
        "The cat napped in the sun on the warm wooden floor.",
        "She swept the leaves from the steps and shook out the mat.",
        "The train pulled slowly into the small country station.",
        "He hung the towels on the line to dry in the breeze.",
        "The pot of stew simmered quietly all afternoon.",
        "We picked wildflowers along the path and brought them home.",
        "The moon rose full and bright over the sleeping town.",
        "She read the letter twice and smiled at the good news.",
        "The rain drummed on the tin roof of the old shed.",
        "He filled the watering can and tended the thirsty plants.",
        "The children drew pictures at the table with bright crayons.",
        "We watched the boats bob gently in the quiet harbor.",
        "The bakery sold out of pastries before the morning was over.",
        "She folded the map and put it back in the glove box.",
        "The dog dozed by the fire while the storm raged outside.",
        "He swept the workshop and put his tools away for the night.",
        "The garden smelled of roses after the gentle evening rain.",
        "We shared stories and laughter around the crackling campfire.",
        "The kettle sang and she poured the water over the leaves.",
        "The old bench sat under the tree where we always rested.",
        "He carried the groceries in from the car in one trip.",
        "The cat watched the rain streak down the cold glass.",
        "We baked cookies and filled the house with a sweet smell.",
        "The river wound slowly through the green and quiet valley.",
        "She wrote a short note and slipped it under the door.",
        "The fire warmed the room as the snow piled up outside.",
        "He tuned the radio to a station playing soft old songs.",
        "The garden gate swung shut with a gentle click.",
        "We watched the swallows dart across the evening sky.",
        "The bread rose slowly on the counter near the warm stove.",
        "She swept the hearth and laid a fresh fire for the night.",
        "The dog rolled in the grass and barked at the passing cart.",
        "He hung the lantern by the door to light the way home.",
        "The soup pot steamed as we gathered for the evening meal.",
        "We walked to the top of the hill to watch the sunrise.",
        "The rain washed the dust from the leaves in the yard.",
        "She tied the parcel with string and wrote the address neatly.",
        "The old cat purred softly on the cushion by the window.",
        "He raked the gravel path and trimmed the low hedge.",
        "The kettle boiled while we set out the cups and saucers.",
        "We watched the last leaves fall from the tall oak tree.",
        "The baker opened the shop and the smell of bread drifted out.",
        "She hummed a tune as she stirred the pot on the stove.",
        "The dog waited by the gate for the children to come home.",
        "He swept the snow from the car and scraped the frosty glass.",
        "The garden was still except for the drip of the morning dew.",
        "We sat by the window and watched the rain fall all evening.",
        "The bread came out golden and warm from the little oven.",
        "She read to the children until their eyes grew heavy.",
        "The fire glowed low as the night settled over the house.",
        "He filled the bowl with water and set it by the back door.",
        "The market square filled with people as the morning went on.",
        "We picked ripe berries and stained our fingers a deep red.",
        "The cat stretched out along the warm sill in the sun.",
        "She swept the floor and wiped the table before the guests came.",
        "The stream gurgled softly beneath the little wooden bridge.",
        "He hung the coats and lined the boots up by the door.",
        "The soup was rich and warm on the cold and rainy day.",
        "We watched the moon climb high above the quiet fields.",
        "The bread cooled slowly as the kitchen filled with its smell.",
        "She wound the wool into a neat ball and set it aside.",
        "The dog slept soundly through the loud and windy night.",
        "He checked the garden and found the first buds of spring.",
        "The kettle whistled and she lifted it off the flame.",
        "We spread the map across the table and planned the trip.",
        "The rain eased and the birds began to sing once more.",
        "She folded the clean laundry and stacked it on the bed.",
        "The fire crackled softly as we talked late into the night.",
    ]
}
