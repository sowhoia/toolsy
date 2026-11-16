import Foundation
import Testing
@testable import ToolsyEngine
import ToolsyShared

/// The store shows a mod in the user's language and tells the mod's commands which language that is.
@MainActor @Suite struct LocalizedModTests {
    private static let timer = manifest(name: "Timer", #"""
        "summary": "Counts down",
        "commands": {"tick": {"shell": ". ./tick.sh"}},
        "ui": [{"type": "button", "label": "Start", "command": "tick"}],
        "widgets": [{"id": "left", "value": "{{left}} left"}],
        "localizations": {"ru": {"Timer": "Таймер", "Counts down": "Отсчёт времени", "Start": "Старт", "{{left}} left": "Осталось {{left}}"}}
        """#)
    /// Logs the locale the command was told, or `none`.
    private static let scripts = ["tick.sh": logLine + #"; log "${TOOLSY_LOCALE-none}""#]

    private func label(of control: ModControl?) -> String? {
        if case .button(let button) = control?.kind { button.label } else { nil }
    }

    @Test func aModIsShownInTheFirstLanguageItHasATableFor() async throws {
        try await withHarness(languages: ["de-DE", "ru-RU", "en"]) { harness in
            let source = try writeMod(Self.timer, scripts: Self.scripts, in: harness.temporary)
            let prepared = try await harness.store.prepareInstall(from: source)
            #expect(prepared.manifest.name == "Таймер", "the confirmation names the mod as the list will")

            let mod = try await harness.store.commitInstall(prepared)
            #expect(mod.manifest.name == "Таймер")
            #expect(mod.manifest.summary == "Отсчёт времени")
            #expect(label(of: mod.manifest.ui.first) == "Старт")
            mod.setValue(.number(5), for: "left")
            #expect(mod.render(mod.manifest.widgets[0].value) == "Осталось 5", "a template is translated, then rendered")

            await mod.run("tick")
            #expect(harness.log() == ["de-de"], "commands are told the user's first language, whatever the mod translates")

            await harness.relaunch()
            #expect(try harness.mod().manifest.name == "Таймер", "a mod loaded at launch is translated too")
        }
    }

    @Test func withoutATableForTheUsersLanguagesTheModKeepsItsOwnText() async throws {
        try await withHarness(languages: ["fr-CA"]) { harness in
            let mod = try await harness.install(Self.timer, scripts: Self.scripts)
            #expect(mod.manifest.name == "Timer")
            #expect(label(of: mod.manifest.ui.first) == "Start")
            await mod.run("tick")
            #expect(harness.log() == ["fr-ca"])
        }
    }

    @Test func withoutLanguagesCommandsAreToldNoLocale() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(Self.timer, scripts: Self.scripts)
            #expect(mod.manifest.name == "Timer")
            await mod.run("tick")
            #expect(harness.log() == ["none"])
        }
    }

    @Test func aTranslatedModStillSavesItsSettingsUnderTheSameKeys() async throws {
        try await withHarness(languages: ["ru"]) { harness in
            let mod = try await harness.install(manifest(#"""
                "settings": {"minutes": 5},
                "ui": [{"type": "stepper", "label": "Minutes", "bind": "minutes", "min": 1, "max": 60}],
                "localizations": {"ru": {"Minutes": "Минуты", "Demo": "Демо"}}
                """#))
            #expect(mod.manifest.name == "Демо")
            mod.setValue(.number(25), for: "minutes")
            await harness.relaunch()
            #expect(try harness.mod().state["minutes"] == .number(25))
        }
    }
}
