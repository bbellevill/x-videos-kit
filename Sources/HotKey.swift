import Carbon

/// Raccourci clavier global (API Carbon : aucune autorisation Accessibilité nécessaire).
/// Plusieurs raccourcis possibles (⌥⇧R enregistrer, ⌥⇧P pause) : chacun a son numéro.
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false

    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        let n = UInt32(HotKey.handlers.count + 1)
        HotKey.handlers[n] = handler
        if !HotKey.installed {
            HotKey.installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &id)
                DispatchQueue.main.async { HotKey.handlers[id.id]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        let id = EventHotKeyID(signature: OSType(0x5343_5554), id: n)  // 'SCUT'
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }
}
