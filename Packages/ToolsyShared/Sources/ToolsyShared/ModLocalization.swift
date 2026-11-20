import Foundation

extension ModManifest {
    static let defaultLanguage = "en"
    static let maxLanguages = 20
    static let maxTranslations = 500

    /// Keys of `localizations`: a lowercase BCP 47 language, optionally with one more subtag (`pt-br`, `zh-hans`).
    public static func isValidLanguageCode(_ code: String) -> Bool {
        code.wholeMatch(of: /[a-z]{2,3}(?:-[a-z0-9]{2,8})?/) != nil
    }

    /// The first of `preferredLanguages` the mod has text in, the most specific match first (`pt-BR` finds
    /// `pt-br` before `pt`): that language as the user's system names it, and the table holding its text,
    /// or nil when it is the language the manifest itself is written in. Nil when the mod has text in none
    /// of them.
    func text(for preferredLanguages: [String]) -> (preferred: String, table: String?)? {
        for preferred in preferredLanguages {
            var subtags = preferred.lowercased().replacing("_", with: "-").split(separator: "-")
            while !subtags.isEmpty {
                let code = subtags.joined(separator: "-")
                if code == language { return (preferred, nil) }
                if localizations[code] != nil { return (preferred, code) }
                subtags.removeLast()
            }
        }
        return nil
    }

    /// The table `localized(for:)` uses. Nil when the user is shown the manifest as written: because a
    /// language they prefer more is the manifest's own, or because the mod has text in none of theirs.
    public func localizationCode(for preferredLanguages: [String]) -> String? {
        text(for: preferredLanguages)?.table
    }

    /// The language the mod is shown in, which its commands are told as `TOOLSY_LOCALE` so that what
    /// they report matches the page: the first of `preferredLanguages` the mod has text in, as the user's
    /// system names it (`ru-RU`), or the manifest's own language when it has text in none of them.
    public func shownLanguage(for preferredLanguages: [String]) -> String {
        text(for: preferredLanguages)?.preferred ?? language
    }

    /// A copy whose user-visible text is translated with the table `localizationCode(for:)` chooses; the
    /// manifest itself when it chooses none. Identifiers, commands, binds, icons, tints, expressions and
    /// `author` stay as they are. Templates are translated as whole strings, before they are rendered.
    public func localized(for preferredLanguages: [String]) -> ModManifest {
        guard let code = localizationCode(for: preferredLanguages), let table = localizations[code] else { return self }
        func translate(_ text: String) -> String { table[text] ?? text }
        var copy = self
        copy.name = translate(name)
        copy.summary = summary.map(translate)
        copy.ui = ui.map { $0.translated(with: translate) }
        copy.widgets = widgets.map { $0.translated(with: translate) }
        copy.quick = quick.map { $0.translated(with: translate) }
        return copy
    }
}

extension ModControl {
    /// The control with every user-visible text field passed through `translate`, children included.
    func translated(with translate: (String) -> String) -> ModControl {
        func list(_ controls: [ModControl]) -> [ModControl] { controls.map { $0.translated(with: translate) } }
        var copy = self
        copy.help = help.map(translate)
        switch kind {
        case .section(var section):
            section.title = section.title.map(translate)
            section.footer = section.footer.map(translate)
            section.children = list(section.children)
            copy.kind = .section(section)
        case .row(var row):
            row.children = list(row.children)
            copy.kind = .row(row)
        case .toggle(var toggle):
            toggle.label = translate(toggle.label)
            copy.kind = .toggle(toggle)
        case .slider(var slider):
            slider.label = translate(slider.label)
            slider.unit = slider.unit.map(translate)
            copy.kind = .slider(slider)
        case .stepper(var stepper):
            stepper.label = translate(stepper.label)
            stepper.unit = stepper.unit.map(translate)
            copy.kind = .stepper(stepper)
        case .picker(var picker):
            picker.label = picker.label.map(translate)
            for index in picker.options.indices {
                picker.options[index].label = translate(picker.options[index].label)
            }
            copy.kind = .picker(picker)
        case .input(var input):
            input.label = input.label.map(translate)
            input.placeholder = input.placeholder.map(translate)
            copy.kind = .input(input)
        case .button(var button):
            button.label = translate(button.label)
            button.copy = button.copy.map(translate)
            button.confirm = button.confirm.map(translate)
            copy.kind = .button(button)
        case .value(var value):
            value.label = translate(value.label)
            value.value = translate(value.value)
            copy.kind = .value(value)
        case .stat(var stat):
            stat.label = translate(stat.label)
            stat.value = translate(stat.value)
            copy.kind = .stat(stat)
        case .text(var text):
            text.text = translate(text.text)
            copy.kind = .text(text)
        case .gauge(var gauge):
            gauge.label = translate(gauge.label)
            gauge.unit = gauge.unit.map(translate)
            copy.kind = .gauge(gauge)
        case .chart(var chart):
            chart.label = chart.label.map(translate)
            chart.unit = chart.unit.map(translate)
            chart.series = chart.series.map { $0.translated(with: translate) }
            copy.kind = .chart(chart)
        case .list(var list):
            list.empty = list.empty.map(translate)
            copy.kind = .list(list)
        case .divider:
            break
        }
        return copy
    }
}

extension ModControl.Chart.Series {
    func translated(with translate: (String) -> String) -> Self {
        var copy = self
        copy.label = label.map(translate)
        return copy
    }
}

extension ModWidget {
    func translated(with translate: (String) -> String) -> ModWidget {
        var copy = self
        copy.title = title.map(translate)
        copy.value = translate(value)
        copy.chart?.series = chart?.series.map { $0.translated(with: translate) } ?? []
        copy.detail = detail.map { $0.translated(with: translate) }
        return copy
    }
}
