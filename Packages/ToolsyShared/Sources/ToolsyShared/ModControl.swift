import Foundation

/// One element of a mod's `ui` tree. In JSON it is a flat object discriminated by `type`.
public struct ModControl: Decodable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case section(Section)
        case row(Row)
        case toggle(Toggle)
        case slider(Slider)
        case stepper(Stepper)
        case picker(Picker)
        case input(Input)
        case button(Button)
        case value(Value)
        case text(Text)
        case gauge(Gauge)
        case chart(Chart)
        case list(List)
        case divider
    }

    public var kind: Kind
    /// Expression; the control is shown only while it is truthy.
    public var when: String?
    /// Expression; the control is inert while it is truthy.
    public var disabled: String?

    private enum CodingKeys: String, CodingKey {
        case type, when, disabled
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        when = try container.decodeIfPresent(String.self, forKey: .when)
        disabled = try container.decodeIfPresent(String.self, forKey: .disabled)
        switch type {
        case "section": kind = .section(try Section(from: decoder))
        case "row": kind = .row(try Row(from: decoder))
        case "toggle": kind = .toggle(try Toggle(from: decoder))
        case "slider": kind = .slider(try Slider(from: decoder))
        case "stepper": kind = .stepper(try Stepper(from: decoder))
        case "picker": kind = .picker(try Picker(from: decoder))
        case "input": kind = .input(try Input(from: decoder))
        case "button": kind = .button(try Button(from: decoder))
        case "value": kind = .value(try Value(from: decoder))
        case "text": kind = .text(try Text(from: decoder))
        case "gauge": kind = .gauge(try Gauge(from: decoder))
        case "chart": kind = .chart(try Chart(from: decoder))
        case "list": kind = .list(try List(from: decoder))
        case "divider": kind = .divider
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "unknown control type \"\(type)\""
            )
        }
    }
}

// Text properties documented as "template" may contain `{{key}}` / `{{key|filter}}` placeholders.
extension ModControl {
    /// A titled group of controls.
    public struct Section: Decodable, Sendable, Equatable {
        /// Template.
        public var title: String?
        /// Template.
        public var footer: String?
        public var children: [ModControl]
    }

    /// Leaf controls laid out side by side with equal widths.
    public struct Row: Decodable, Sendable, Equatable {
        public var children: [ModControl]
    }

    public struct Toggle: Decodable, Sendable, Equatable {
        /// Template.
        public var label: String
        public var icon: String?
        public var bind: String
        /// Runs after the value changed.
        public var command: String?
    }

    public struct Slider: Decodable, Sendable, Equatable {
        /// Template.
        public var label: String
        public var icon: String?
        public var bind: String
        public var min: Double
        public var max: Double
        public var step: Double?
        /// Suffix shown after the value, e.g. `%` or ` ms`.
        public var unit: String?
        public var command: String?
        /// Run `command` while dragging instead of once on release.
        public var live: Bool

        private enum CodingKeys: String, CodingKey {
            case label, icon, bind, min, max, step, unit, command, live
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            label = try container.decode(String.self, forKey: .label)
            icon = try container.decodeIfPresent(String.self, forKey: .icon)
            bind = try container.decode(String.self, forKey: .bind)
            min = try container.decode(Double.self, forKey: .min)
            max = try container.decode(Double.self, forKey: .max)
            step = try container.decodeIfPresent(Double.self, forKey: .step)
            unit = try container.decodeIfPresent(String.self, forKey: .unit)
            command = try container.decodeIfPresent(String.self, forKey: .command)
            live = try container.decodeIfPresent(Bool.self, forKey: .live) ?? false
        }
    }

    public struct Stepper: Decodable, Sendable, Equatable {
        /// Template.
        public var label: String
        public var icon: String?
        public var bind: String
        public var min: Double?
        public var max: Double?
        public var step: Double
        public var unit: String?
        public var command: String?

        private enum CodingKeys: String, CodingKey {
            case label, icon, bind, min, max, step, unit, command
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            label = try container.decode(String.self, forKey: .label)
            icon = try container.decodeIfPresent(String.self, forKey: .icon)
            bind = try container.decode(String.self, forKey: .bind)
            min = try container.decodeIfPresent(Double.self, forKey: .min)
            max = try container.decodeIfPresent(Double.self, forKey: .max)
            step = try container.decodeIfPresent(Double.self, forKey: .step) ?? 1
            unit = try container.decodeIfPresent(String.self, forKey: .unit)
            command = try container.decodeIfPresent(String.self, forKey: .command)
        }
    }

    public struct Picker: Decodable, Sendable, Equatable {
        public enum Style: String, Decodable, Sendable {
            case segmented, menu
        }

        public struct Option: Decodable, Sendable, Equatable {
            /// String, number or boolean stored under the bound key.
            public var value: JSONValue
            public var label: String
            public var icon: String?

            private enum CodingKeys: String, CodingKey {
                case value, label, icon
            }

            /// Accepts `{"value": …, "label": …}` or a bare string that is both value and label.
            public init(from decoder: any Decoder) throws {
                if let shorthand = try? decoder.singleValueContainer().decode(String.self) {
                    value = .string(shorthand)
                    label = shorthand
                    return
                }
                let container = try decoder.container(keyedBy: CodingKeys.self)
                value = try container.decode(JSONValue.self, forKey: .value)
                label = try container.decodeIfPresent(String.self, forKey: .label) ?? value.text
                icon = try container.decodeIfPresent(String.self, forKey: .icon)
            }
        }

        /// Template.
        public var label: String?
        public var icon: String?
        public var bind: String
        public var options: [Option]
        /// Unset: segmented for up to four options, a menu beyond that.
        public var style: Style?
        public var command: String?
    }

    /// A single-line text field. The value is committed on Return or when focus leaves.
    public struct Input: Decodable, Sendable, Equatable {
        /// Template.
        public var label: String?
        public var icon: String?
        public var bind: String
        public var placeholder: String?
        /// Runs after a commit.
        public var command: String?
    }

    public struct Button: Decodable, Sendable, Equatable {
        public enum Style: String, Decodable, Sendable {
            case normal, prominent, destructive
        }

        /// Template.
        public var label: String
        public var icon: String?
        /// Command to run. A button has either this or `open`.
        public var command: String?
        /// `http(s)` URL to open in the browser.
        public var open: String?
        /// Passed to the command as its value.
        public var value: JSONValue?
        public var style: Style
        /// Question asked before the command runs.
        public var confirm: String?

        private enum CodingKeys: String, CodingKey {
            case label, icon, command, open, value, style, confirm
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            label = try container.decode(String.self, forKey: .label)
            icon = try container.decodeIfPresent(String.self, forKey: .icon)
            command = try container.decodeIfPresent(String.self, forKey: .command)
            open = try container.decodeIfPresent(String.self, forKey: .open)
            value = try container.decodeIfPresent(JSONValue.self, forKey: .value)
            style = try container.decodeIfPresent(Style.self, forKey: .style) ?? .normal
            confirm = try container.decodeIfPresent(String.self, forKey: .confirm)
        }
    }

    /// A read-only "label: value" line.
    public struct Value: Decodable, Sendable, Equatable {
        /// Template.
        public var label: String
        /// Template.
        public var value: String
        public var icon: String?
        /// Template resolving to a colour or level name.
        public var tint: String?
        /// Clicking copies the value.
        public var copyable: Bool

        private enum CodingKeys: String, CodingKey {
            case label, value, icon, tint, copyable
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            label = try container.decode(String.self, forKey: .label)
            value = try container.decode(String.self, forKey: .value)
            icon = try container.decodeIfPresent(String.self, forKey: .icon)
            tint = try container.decodeIfPresent(String.self, forKey: .tint)
            copyable = try container.decodeIfPresent(Bool.self, forKey: .copyable) ?? false
        }
    }

    /// Free-standing text.
    public struct Text: Decodable, Sendable, Equatable {
        public enum Style: String, Decodable, Sendable {
            case body, caption, title, mono
        }

        /// Template.
        public var text: String
        public var style: Style
        /// Template resolving to a colour or level name.
        public var tint: String?

        private enum CodingKeys: String, CodingKey {
            case text, style, tint
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decode(String.self, forKey: .text)
            style = try container.decodeIfPresent(Style.self, forKey: .style) ?? .body
            tint = try container.decodeIfPresent(String.self, forKey: .tint)
        }
    }

    /// A number shown against a range.
    public struct Gauge: Decodable, Sendable, Equatable {
        public enum Style: String, Decodable, Sendable {
            case bar, ring
        }

        /// Template.
        public var label: String
        public var icon: String?
        public var bind: String
        public var min: Double
        public var max: Double
        public var unit: String?
        public var style: Style
        /// Template resolving to a colour or level name.
        public var tint: String?

        private enum CodingKeys: String, CodingKey {
            case label, icon, bind, min, max, unit, style, tint
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            label = try container.decode(String.self, forKey: .label)
            icon = try container.decodeIfPresent(String.self, forKey: .icon)
            bind = try container.decode(String.self, forKey: .bind)
            min = try container.decodeIfPresent(Double.self, forKey: .min) ?? 0
            max = try container.decodeIfPresent(Double.self, forKey: .max) ?? 100
            unit = try container.decodeIfPresent(String.self, forKey: .unit)
            style = try container.decodeIfPresent(Style.self, forKey: .style) ?? .bar
            tint = try container.decodeIfPresent(String.self, forKey: .tint)
        }
    }

    /// Plots one or more numeric state keys over time.
    public struct Chart: Decodable, Sendable, Equatable {
        public enum Style: String, Decodable, Sendable {
            case line, area, bar
        }

        public struct Series: Decodable, Sendable, Equatable {
            /// A number (the host records its history) or an array of numbers (plotted as is).
            public var bind: String
            public var label: String?
            public var tint: String?
        }

        public static let defaultPoints = 60

        /// Template.
        public var label: String?
        public var series: [Series]
        public var style: Style
        /// How many samples of history to keep and show.
        public var points: Int
        /// Fixed lower bound of the value axis; fitted to the data when unset.
        public var min: Double?
        /// Fixed upper bound of the value axis; fitted to the data when unset.
        public var max: Double?
        public var unit: String?

        private enum CodingKeys: String, CodingKey {
            case label, series, style, points, min, max, unit
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            label = try container.decodeIfPresent(String.self, forKey: .label)
            series = try container.decode([Series].self, forKey: .series)
            style = try container.decodeIfPresent(Style.self, forKey: .style) ?? .line
            points = try container.decodeIfPresent(Int.self, forKey: .points) ?? Self.defaultPoints
            min = try container.decodeIfPresent(Double.self, forKey: .min)
            max = try container.decodeIfPresent(Double.self, forKey: .max)
            unit = try container.decodeIfPresent(String.self, forKey: .unit)
        }
    }

    /// Rows read from a state array; see `ModListItem`.
    public struct List: Decodable, Sendable, Equatable {
        public var bind: String
        /// Runs when a row is clicked, with the row's `id` as the value.
        public var command: String?
        /// Shown while the array is empty.
        public var empty: String?
        /// Maximum number of rows shown.
        public var limit: Int?
    }
}
