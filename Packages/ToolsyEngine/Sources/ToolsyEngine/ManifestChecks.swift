import Foundation
import ToolsyShared

extension ModManifest {
    /// The install-time checks ToolsyShared leaves to the engine: every template and expression must parse.
    /// Messages name the control path in the style of `ManifestError`, e.g. `ui[2].children[0].when: …`.
    func validateTemplatesAndExpressions() throws(ManifestError) {
        try Self.check(ui, path: "ui")
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
    var allControls: [ModControl] {
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
    var children: [ModControl] {
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
        case .button(let button): [("label", button.label)]
        case .value(let value): [("label", value.label), ("value", value.value), ("tint", value.tint)]
        case .text(let text): [("text", text.text), ("tint", text.tint)]
        case .gauge(let gauge): [("label", gauge.label), ("tint", gauge.tint)]
        case .chart(let chart): [("label", chart.label)]
        case .row, .list, .divider: []
        }
        return fields.compactMap { field, template in template.map { (field, $0) } }
    }
}
