import Foundation
import SwiftUI

/// A value that can live in UserDefaults.
///
/// A plist only accepts a handful of types, so enums are always stored by rawValue.
protocol StoredValue {
    static func read(from defaults: UserDefaults, key: String) -> Self?
    func write(to defaults: UserDefaults, key: String)
}

extension Bool: StoredValue {
    static func read(from d: UserDefaults, key: String) -> Bool? {
        d.object(forKey: key) == nil ? nil : d.bool(forKey: key)
    }
    func write(to d: UserDefaults, key: String) { d.set(self, forKey: key) }
}

extension Int: StoredValue {
    static func read(from d: UserDefaults, key: String) -> Int? {
        d.object(forKey: key) == nil ? nil : d.integer(forKey: key)
    }
    func write(to d: UserDefaults, key: String) { d.set(self, forKey: key) }
}

extension String: StoredValue {
    static func read(from d: UserDefaults, key: String) -> String? { d.string(forKey: key) }
    func write(to d: UserDefaults, key: String) { d.set(self, forKey: key) }
}

extension Array: StoredValue where Element == String {
    static func read(from d: UserDefaults, key: String) -> [String]? { d.stringArray(forKey: key) }
    func write(to d: UserDefaults, key: String) { d.set(self, forKey: key) }
}

extension StoredValue where Self: RawRepresentable, RawValue: StoredValue {
    static func read(from d: UserDefaults, key: String) -> Self? {
        RawValue.read(from: d, key: key).flatMap(Self.init(rawValue:))
    }
    func write(to d: UserDefaults, key: String) { rawValue.write(to: d, key: key) }
}

/// One setting. The value lives in UserDefaults; this only caches a copy, and on change it writes
/// to disk and tells the UI to redraw.
///
/// Every property used to be `@Published var x { didSet { d.set(x, forKey: "x") } }`: the same
/// three lines twenty times over, with key names written elsewhere, and a missing didSet meant a
/// setting that was never saved. Now the key name and default value sit on the property
/// declaration, and persisting and notifying are handled here in one place.
///
/// `$settings.property` still works as a Binding: the projected value comes from the subscript below.
@MainActor
@propertyWrapper
struct Stored<Value: StoredValue> {
    private let key: String
    private let fallback: Value
    private var cache: Value?

    init(wrappedValue: Value, _ key: String) {
        self.key = key
        self.fallback = wrappedValue
    }

    /// Only usable as a property of AppSettings (which it relies on to send notifications);
    /// accessing the value directly is a programming error
    @available(*, unavailable, message: "Only usable as a property of AppSettings")
    var wrappedValue: Value {
        get { fatalError() }
        set { fatalError() }
    }

    static subscript(
        _enclosingInstance instance: AppSettings,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<AppSettings, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<AppSettings, Self>
    ) -> Value {
        get { read(instance, storageKeyPath) }
        set { write(newValue, instance, storageKeyPath) }
    }

    /// What `$settings.property` gives you: a Binding that reads and writes this setting directly
    static subscript(
        _enclosingInstance instance: AppSettings,
        projected projectedKeyPath: KeyPath<AppSettings, Binding<Value>>,
        storage storageKeyPath: ReferenceWritableKeyPath<AppSettings, Self>
    ) -> Binding<Value> {
        Binding(
            get: { read(instance, storageKeyPath) },
            set: { write($0, instance, storageKeyPath) }
        )
    }

    @available(*, unavailable)
    var projectedValue: Binding<Value> { fatalError() }

    private static func read(_ instance: AppSettings,
                             _ path: ReferenceWritableKeyPath<AppSettings, Self>) -> Value {
        if let cached = instance[keyPath: path].cache { return cached }
        let wrapper = instance[keyPath: path]
        let value = Value.read(from: instance.defaults, key: wrapper.key) ?? wrapper.fallback
        instance[keyPath: path].cache = value
        return value
    }

    private static func write(_ value: Value, _ instance: AppSettings,
                              _ path: ReferenceWritableKeyPath<AppSettings, Self>) {
        let key = instance[keyPath: path].key
        instance.objectWillChange.send()
        instance[keyPath: path].cache = value
        value.write(to: instance.defaults, key: key)
        instance.didChange(key: key)
    }
}

// These enums in the settings are all stored by rawValue. The default RawRepresentable
// implementation above already handles reading and writing; this just declares that they can
// be stored.
extension PanelSize: StoredValue {}
extension PanelTextSize: StoredValue {}
extension MenuBarIcon: StoredValue {}
extension AppAppearance: StoredValue {}
extension AppLanguage: StoredValue {}
extension PanelPosition: StoredValue {}
