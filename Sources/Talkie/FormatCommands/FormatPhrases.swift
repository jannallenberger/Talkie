import Foundation

/// The built-in phrases of "format while you dictate", in every transcription
/// language the app offers (Settings ▸ Languages: English, German, French, Spanish,
/// Italian, Portuguese, Dutch, Japanese, Korean, Chinese). A command span is matched
/// against ALL of them plus the user's own synonyms, whatever language the dictation
/// is in — so an English command works inside a German dictation and the reverse.
///
/// The first phrase of a language is the one shown in the UI in that language; the
/// rest are accepted variants. Every phrase must normalise to something unique to its
/// command (`FormatPhraseTableTests` checks).
enum FormatPhrases {
    /// Language codes with a phrase table, in display order.
    static let languages = ["en", "de", "fr", "es", "it", "pt", "nl", "ja", "ko", "zh"]

    /// The phrase-table language for a locale or UI language id ("pt-BR" → "pt",
    /// "zh-Hans" → "zh"); nil when there is no table for it.
    static func language(of identifier: String?) -> String? {
        guard let identifier else { return nil }
        let code = String(identifier.lowercased().prefix { $0.isLetter })
        return languages.contains(code) ? code : nil
    }

    // swiftlint:disable function_body_length
    static func phrases(_ preset: FormatPreset, language: String) -> [String] {
        switch (preset, language) {
        // MARK: Bullet list
        case (.bulletList, "en"): return ["bullet points", "bullet list", "bullets", "as a list", "list", "bullet point list", "bullet point", "bulletpoints", "points", "dot points", "unordered list"]
        case (.bulletList, "de"): return ["in Stichpunkten", "Stichpunkte", "als Liste", "Aufzählung", "Aufzählungszeichen", "Spiegelstriche", "Punkte", "Bulletpoints", "Spiegelstrichliste", "Aufzählungsliste", "Stichpunktliste", "Stichpunkt", "Liste machen", "Auflistung"]
        case (.bulletList, "fr"): return ["liste à puces", "puces", "en liste"]
        case (.bulletList, "es"): return ["con viñetas", "viñetas", "lista"]
        case (.bulletList, "it"): return ["elenco puntato", "punti elenco", "elenco"]
        case (.bulletList, "pt"): return ["com marcadores", "marcadores", "em lista"]
        case (.bulletList, "nl"): return ["opsommingstekens", "opsomming", "als lijst", "lijst"]
        case (.bulletList, "ja"): return ["箇条書き", "リスト"]
        case (.bulletList, "ko"): return ["글머리 기호", "목록"]
        case (.bulletList, "zh"): return ["项目符号", "列表"]
        // MARK: Numbered list
        case (.numberedList, "en"): return ["numbered list", "numbered", "numbers", "numbered points", "number list", "ordered list", "numbered items"]
        case (.numberedList, "de"): return ["nummerierte Liste", "nummeriert", "Nummerierung", "durchnummeriert", "Nummernliste", "nummerierte Aufzählung", "nummerierte Punkte", "durchnummerierte Liste", "Nummern"]
        case (.numberedList, "fr"): return ["liste numérotée", "numérotée", "numéroté"]
        case (.numberedList, "es"): return ["lista numerada", "numerada"]
        case (.numberedList, "it"): return ["elenco numerato", "numerato"]
        case (.numberedList, "pt"): return ["lista numerada", "numerada"]
        case (.numberedList, "nl"): return ["genummerde lijst", "genummerd"]
        case (.numberedList, "ja"): return ["番号付きリスト", "番号付き"]
        case (.numberedList, "ko"): return ["번호 목록", "번호 매기기"]
        case (.numberedList, "zh"): return ["编号列表", "编号"]
        // MARK: To-do list
        case (.todoList, "en"): return ["to-do list", "todo list", "checklist", "to-dos", "tasks", "to do list", "to do", "task list", "checkboxes", "check list"]
        case (.todoList, "de"): return ["als To-do-Liste", "To-do-Liste", "Aufgabenliste", "Checkliste", "Aufgaben", "To-dos", "Todo-Liste", "Todo", "Aufgabe", "Abhakliste", "Checkboxen", "Erledigungsliste"]
        case (.todoList, "fr"): return ["liste de tâches", "tâches", "liste à cocher"]
        case (.todoList, "es"): return ["lista de tareas", "tareas", "pendientes"]
        case (.todoList, "it"): return ["lista di cose da fare", "elenco attività", "attività"]
        case (.todoList, "pt"): return ["lista de tarefas", "tarefas", "pendências"]
        case (.todoList, "nl"): return ["takenlijst", "to-do-lijst", "afvinklijst"]
        case (.todoList, "ja"): return ["ToDoリスト", "チェックリスト", "やることリスト"]
        case (.todoList, "ko"): return ["할 일 목록", "체크리스트"]
        case (.todoList, "zh"): return ["待办清单", "待办事项", "清单"]
        // MARK: ALL CAPS
        case (.allCaps, "en"): return ["all caps", "caps lock", "capslock", "caps", "uppercase", "capital letters", "capitals", "all capitals", "all uppercase", "upper case", "big letters", "all upper case"]
        case (.allCaps, "de"): return ["alles groß", "Großbuchstaben", "Großschreibung", "Capslock", "Feststelltaste", "alles in Großbuchstaben", "Versalien", "alles groß geschrieben", "großgeschrieben", "Caps", "komplett groß", "in Großbuchstaben"]
        case (.allCaps, "fr"): return ["en majuscules", "majuscules", "tout en majuscules"]
        case (.allCaps, "es"): return ["en mayúsculas", "mayúsculas", "todo en mayúsculas"]
        case (.allCaps, "it"): return ["tutto maiuscolo", "maiuscolo", "in maiuscolo"]
        case (.allCaps, "pt"): return ["em maiúsculas", "maiúsculas", "caixa alta"]
        case (.allCaps, "nl"): return ["hoofdletters", "alles hoofdletters", "alles groot"]
        case (.allCaps, "ja"): return ["大文字", "全部大文字"]
        case (.allCaps, "ko"): return ["대문자", "모두 대문자"]
        case (.allCaps, "zh"): return ["大写", "全部大写"]
        // MARK: lowercase
        case (.lowercase, "en"): return ["all lowercase", "lowercase", "lower case", "small letters", "all lower case", "lowercase letters", "lower", "no caps", "all small"]
        case (.lowercase, "de"): return ["alles klein", "Kleinbuchstaben", "Kleinschreibung", "alles in Kleinbuchstaben", "kleingeschrieben", "alles klein geschrieben", "komplett klein", "in Kleinbuchstaben", "keine Großbuchstaben"]
        case (.lowercase, "fr"): return ["en minuscules", "minuscules", "tout en minuscules"]
        case (.lowercase, "es"): return ["en minúsculas", "minúsculas", "todo en minúsculas"]
        case (.lowercase, "it"): return ["tutto minuscolo", "minuscolo", "in minuscolo"]
        case (.lowercase, "pt"): return ["em minúsculas", "minúsculas", "caixa baixa"]
        case (.lowercase, "nl"): return ["kleine letters", "alles kleine letters"]
        case (.lowercase, "ja"): return ["小文字", "全部小文字"]
        case (.lowercase, "ko"): return ["소문자", "모두 소문자"]
        case (.lowercase, "zh"): return ["小写", "全部小写"]
        // MARK: Quotes
        case (.quotes, "en"): return ["in quotes", "quotation marks", "quotes", "quote", "with quotes", "in double quotes", "speech marks", "inverted commas", "quotation"]
        case (.quotes, "de"): return ["in Anführungszeichen", "Anführungszeichen", "in Gänsefüßchen", "Gänsefüßchen", "als Zitat", "Zitat", "in Anführungsstrichen", "Anführungsstriche", "zitieren", "wörtliche Rede", "Zitatzeichen"]
        case (.quotes, "fr"): return ["entre guillemets", "guillemets", "citation"]
        case (.quotes, "es"): return ["entre comillas", "comillas", "cita"]
        case (.quotes, "it"): return ["tra virgolette", "virgolette", "citazione"]
        case (.quotes, "pt"): return ["entre aspas", "aspas", "citação"]
        case (.quotes, "nl"): return ["tussen aanhalingstekens", "aanhalingstekens", "citaat"]
        case (.quotes, "ja"): return ["かぎかっこ", "引用符", "引用"]
        case (.quotes, "ko"): return ["따옴표", "인용 부호"]
        case (.quotes, "zh"): return ["引号", "加引号"]
        // MARK: Parentheses
        case (.parentheses, "en"): return ["in parentheses", "parentheses", "brackets", "in brackets", "round brackets", "in round brackets", "parenthesis", "bracket"]
        case (.parentheses, "de"): return ["in Klammern", "Klammern", "Klammer", "in Klammer", "runde Klammern", "in runden Klammern", "eingeklammert"]
        case (.parentheses, "fr"): return ["entre parenthèses", "parenthèses"]
        case (.parentheses, "es"): return ["entre paréntesis", "paréntesis"]
        case (.parentheses, "it"): return ["tra parentesi", "parentesi"]
        case (.parentheses, "pt"): return ["entre parênteses", "parênteses"]
        case (.parentheses, "nl"): return ["tussen haakjes", "haakjes"]
        case (.parentheses, "ja"): return ["丸かっこ", "括弧"]
        case (.parentheses, "ko"): return ["괄호", "괄호 안에"]
        case (.parentheses, "zh"): return ["括号", "加括号"]
        // MARK: Heading
        case (.heading, "en"): return ["as a heading", "heading", "headline", "title", "as a title", "as heading", "header", "as a header", "section title"]
        case (.heading, "de"): return ["als Überschrift", "Überschrift", "Titel", "als Titel", "Headline", "Header", "als Header", "Schlagzeile"]
        case (.heading, "fr"): return ["en titre", "titre"]
        case (.heading, "es"): return ["como título", "título", "encabezado"]
        case (.heading, "it"): return ["come titolo", "titolo", "intestazione"]
        case (.heading, "pt"): return ["como título", "cabeçalho"]
        case (.heading, "nl"): return ["als kop", "kop", "kopje"]
        case (.heading, "ja"): return ["見出し", "タイトル"]
        case (.heading, "ko"): return ["제목", "제목으로"]
        case (.heading, "zh"): return ["标题", "作为标题"]
        // MARK: Verbatim / code
        case (.verbatim, "en"): return ["verbatim", "as code", "code", "word for word", "literally", "exactly", "unchanged", "code block", "raw", "exactly as said"]
        case (.verbatim, "de"): return ["wörtlich", "als Code", "Code", "unverändert", "Wort für Wort", "exakt", "genauso", "im Wortlaut", "Codeblock", "Quelltext", "wortwörtlich"]
        case (.verbatim, "fr"): return ["mot pour mot", "tel quel", "en code"]
        case (.verbatim, "es"): return ["al pie de la letra", "textual", "código"]
        case (.verbatim, "it"): return ["alla lettera", "letterale", "codice"]
        case (.verbatim, "pt"): return ["ao pé da letra", "literal", "código"]
        case (.verbatim, "nl"): return ["letterlijk", "als code"]
        case (.verbatim, "ja"): return ["そのまま", "コード"]
        case (.verbatim, "ko"): return ["그대로", "코드"]
        case (.verbatim, "zh"): return ["原样", "代码"]
        // MARK: E-mail
        case (.email, "en"): return ["as an email", "email", "e-mail", "as a mail", "as e-mail", "email format", "e mail", "email message"]
        case (.email, "de"): return ["als E-Mail", "E-Mail", "als Mail", "Mail", "Email", "als Email", "Mailformat", "E-Mail-Format", "per E-Mail"]
        case (.email, "fr"): return ["en e-mail", "courriel", "en mail"]
        case (.email, "es"): return ["como correo", "correo", "correo electrónico"]
        case (.email, "it"): return ["come email", "posta elettronica"]
        case (.email, "pt"): return ["como e-mail", "correio eletrônico"]
        case (.email, "nl"): return ["als e-mail", "als mail"]
        case (.email, "ja"): return ["メール", "メールで"]
        case (.email, "ko"): return ["이메일", "메일"]
        case (.email, "zh"): return ["邮件", "电子邮件"]
        // MARK: Formal
        case (.formal, "en"): return ["formal", "formally", "more formal", "professional", "formal tone", "more formally", "polite", "business style", "official"]
        case (.formal, "de"): return ["formell", "förmlich", "professionell", "Sie-Form", "höflich", "geschäftlich", "offiziell", "formeller", "förmlicher"]
        case (.formal, "fr"): return ["formel", "plus formel", "soutenu"]
        case (.formal, "es"): return ["más formal", "formalmente"]
        case (.formal, "it"): return ["formale", "più formale"]
        case (.formal, "pt"): return ["mais formal", "formalmente"]
        case (.formal, "nl"): return ["formeel", "zakelijk"]
        case (.formal, "ja"): return ["丁寧に", "フォーマル"]
        case (.formal, "ko"): return ["격식체", "공손하게"]
        case (.formal, "zh"): return ["正式", "更正式"]
        // MARK: Shorter
        case (.shorter, "en"): return ["shorter", "shorten", "make it shorter", "concise", "short", "make shorter", "condense", "more concise", "briefer", "tighter", "trim it"]
        case (.shorter, "de"): return ["kürzer", "kürzen", "kurz und knapp", "knapper", "kurz", "gekürzt", "kompakter", "prägnant", "kürzere Version"]
        case (.shorter, "fr"): return ["plus court", "raccourcir"]
        case (.shorter, "es"): return ["más corto", "acortar"]
        case (.shorter, "it"): return ["più corto", "accorcia"]
        case (.shorter, "pt"): return ["mais curto", "encurtar"]
        case (.shorter, "nl"): return ["korter", "inkorten"]
        case (.shorter, "ja"): return ["短く", "簡潔に"]
        case (.shorter, "ko"): return ["짧게", "간단하게"]
        case (.shorter, "zh"): return ["简短", "缩短"]
        // MARK: Translate to English
        case (.translateToEnglish, "en"): return ["in English", "English", "translate to English", "into English", "to English", "in English please", "English version"]
        case (.translateToEnglish, "de"): return ["auf Englisch", "ins Englische", "Englisch", "übersetze ins Englische", "nach Englisch", "in Englisch", "englische Version", "auf Englisch übersetzen"]
        case (.translateToEnglish, "fr"): return ["en anglais", "anglais", "traduire en anglais"]
        case (.translateToEnglish, "es"): return ["en inglés", "inglés", "traducir al inglés"]
        case (.translateToEnglish, "it"): return ["in inglese", "inglese", "traduci in inglese"]
        case (.translateToEnglish, "pt"): return ["em inglês", "traduzir para inglês"]
        case (.translateToEnglish, "nl"): return ["in het Engels", "Engels", "vertaal naar het Engels"]
        case (.translateToEnglish, "ja"): return ["英語で", "英語に翻訳"]
        case (.translateToEnglish, "ko"): return ["영어로", "영어로 번역"]
        case (.translateToEnglish, "zh"): return ["翻译成英文", "用英语", "英文"]
        // MARK: Translate to German
        case (.translateToGerman, "en"): return ["in German", "German", "translate to German", "into German", "to German", "German version"]
        case (.translateToGerman, "de"): return ["auf Deutsch", "ins Deutsche", "Deutsch", "übersetze ins Deutsche", "nach Deutsch", "in Deutsch", "deutsche Version", "auf Deutsch übersetzen"]
        case (.translateToGerman, "fr"): return ["en allemand", "allemand", "traduire en allemand"]
        case (.translateToGerman, "es"): return ["en alemán", "alemán", "traducir al alemán"]
        case (.translateToGerman, "it"): return ["in tedesco", "tedesco", "traduci in tedesco"]
        case (.translateToGerman, "pt"): return ["em alemão", "traduzir para alemão"]
        case (.translateToGerman, "nl"): return ["in het Duits", "Duits", "vertaal naar het Duits"]
        case (.translateToGerman, "ja"): return ["ドイツ語で", "ドイツ語に翻訳"]
        case (.translateToGerman, "ko"): return ["독일어로", "독일어로 번역"]
        case (.translateToGerman, "zh"): return ["翻译成德文", "用德语", "德文"]
        default: return []
        }
    }
    // swiftlint:enable function_body_length

    /// "Back to normal text", per language.
    static func endPhrases(language: String) -> [String] {
        switch language {
        case "en": return ["normal", "end", "plain text", "stop", "done", "off"]
        case "de": return ["normal", "Ende", "normaler Text", "Stopp", "Schluss", "fertig", "aus"]
        case "fr": return ["normal", "fin", "texte normal", "terminé"]
        case "es": return ["normal", "fin", "texto normal", "terminar"]
        case "it": return ["normale", "fine", "testo normale", "basta"]
        case "pt": return ["normal", "fim", "texto normal", "parar"]
        case "nl": return ["normaal", "einde", "gewone tekst", "klaar"]
        case "ja": return ["普通", "通常", "終わり"]
        case "ko": return ["보통", "끝", "일반 텍스트"]
        case "zh": return ["正常", "结束", "普通文本"]
        default: return []
        }
    }

    /// Every built-in phrase of `preset`, all languages.
    static func allPhrases(_ preset: FormatPreset) -> [String] {
        languages.flatMap { phrases(preset, language: $0) }
    }

    static var allEndPhrases: [String] { languages.flatMap { endPhrases(language: $0) } }
}
