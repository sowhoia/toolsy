import Foundation
import ToolsyShared

extension ModManifest {
    /// The install-time checks ToolsyShared leaves to the engine: every template, expression and value
    /// format must parse, in the manifest as written and in each of its translations. Messages name the path
    /// in the style of `ManifestError`, e.g. `ui[2].children[0].when: …`, `localizations.ru: widgets[0].value: …`.
    func validateTemplatesAndExpressions() throws(ManifestError) {
        try checkTemplatesAndExpressions()
        for code in localizations.keys.sorted() {
            do {
                try localized(for: [code]).checkTemplatesAndExpressions()
            } catch {
                throw ManifestError("localizations.\(code): \(error.message)")
            }
        }
    }

    private func checkTemplatesAndExpressions() throws(ManifestError) {
        try Self.check(ui, path: "ui")
        for (index, widget) in widgets.enumerated() {
            let path = "widgets[\(index)]"
            if let when = widget.when {
                try Self.located("\(path).when") { () throws(SyntaxError) in _ = try ModExpression(when) }
            }
            for (field, template) in [("title", widget.title), ("value", widget.value), ("tint", widget.tint)] {
                guard let template else { continue }
                try Self.located("\(path).\(field)") { () throws(SyntaxError) in _ = try ModTemplate(template) }
            }
            try Self.check(widget.detail, path: "\(path).detail")
        }
    }

    /// Checks that every `exec` program is a file of the mod with its executable bit set.
    func validatePrograms(in payload: ModPayload) throws(ManifestError) {
        for (name, command) in commands.sorted(by: { $0.key < $1.key }) {
            guard case .exec(let file) = command.program else { continue }
            guard payload.files[file] != nil else {
                throw ManifestError("commands.\(name): exec file \"\(file)\" is not part of the mod")
            }
            guard payload.executables.contains(file) else {
                throw ManifestError("commands.\(name): exec file \"\(file)\" is not executable (chmod +x)")
            }
        }
    }

    /// Every control of the page and of the widgets' details, depth first.
    public var allControls: [ModControl] {
        func flatten(_ controls: [ModControl]) -> [ModControl] {
            controls.flatMap { [$0] + flatten($0.children) }
        }
        return flatten(ui) + widgets.flatMap { flatten($0.detail) }
    }

    private static func check(_ controls: [ModControl], path: String) throws(ManifestError) {
        for (index, control) in controls.enumerated() {
            let path = "\(path)[\(index)]"
            if let when = control.when {
                try located("\(path).when") { () throws(SyntaxError) in _ = try ModExpression(when) }
            }
            if let disabled = control.disabled {
                try located("\(path).disabled") { () throws(SyntaxError) in _ = try ModExpression(disabled) }
            }
            for (field, template) in control.templateFields {
                try located("\(path).\(field)") { () throws(SyntaxError) in _ = try ModTemplate(template) }
            }
            if let format = control.valueFormat {
                try located("\(path).format") { () throws(SyntaxError) in _ = try ModValueFormat(format) }
            }
            try check(control.children, path: "\(path).children")
        }
    }

    private static func located(_ path: String, _ parse: () throws(SyntaxError) -> Void) throws(ManifestError) {
        do {
            try parse()
        } catch {
            throw ManifestError("\(path): \(error.message)")
        }
    }
}

extension ModControl {
    /// The controls inside a section or row; none for other controls.
    public var children: [ModControl] {
        switch kind {
        case .section(let section): section.children
        case .row(let row): row.children
        default: []
        }
    }

    /// The fields ToolsyShared documents as templates, by their JSON names.
    var templateFields: [(String, String)] {
        let fields: [(String, String?)] = switch kind {
        case .section(let section): [("title", section.title), ("footer", section.footer)]
        case .toggle(let toggle): [("label", toggle.label)]
        case .slider(let slider): [("label", slider.label)]
        case .stepper(let stepper): [("label", stepper.label)]
        case .picker(let picker): [("label", picker.label)]
        case .input(let input): [("label", input.label)]
        case .button(let button): [("label", button.label), ("copy", button.copy)]
        case .value(let value): [("label", value.label), ("value", value.value), ("tint", value.tint)]
        case .stat(let stat): [("label", stat.label), ("value", stat.value), ("tint", stat.tint)]
        case .text(let text): [("text", text.text), ("tint", text.tint)]
        case .gauge(let gauge): [("label", gauge.label), ("tint", gauge.tint)]
        case .chart(let chart): [("label", chart.label)]
        case .row, .list, .divider: []
        }
        return fields.compactMap { field, template in template.map { (field, $0) } }
    }

    /// The `format` of a gauge or chart: a filter chain applied to its readouts.
    var valueFormat: String? {
        switch kind {
        case .gauge(let gauge): gauge.format
        case .chart(let chart): chart.format
        default: nil
        }
    }
}
