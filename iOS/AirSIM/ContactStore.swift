import Contacts
import Foundation

enum ContactAuthorizationState: Equatable {
    case notDetermined
    case authorized
    case denied
}

enum ContactAccessAction: Equatable {
    case request
    case load
    case waitForUser
    case blocked
}

enum ContactAccessPolicy {
    static func action(
        for state: ContactAuthorizationState,
        userInitiated: Bool
    ) -> ContactAccessAction {
        switch state {
        case .authorized: return .load
        case .notDetermined: return userInitiated ? .request : .waitForUser
        case .denied: return .blocked
        }
    }
}

/// 非主线程联系人读取器，避免在 Swift 6 下跨线程持有 CNContactStore。
struct ContactFetcher: Sendable {
    func authorizationState() -> ContactAuthorizationState {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized { return .authorized }
        if #available(iOS 18.0, *), status == .limited { return .authorized }
        return status == .notDetermined ? .notDetermined : .denied
    }

    func requestAccess() async throws -> Bool {
        try await CNContactStore().requestAccess(for: .contacts)
    }

    func fetchAll() throws -> [ContactStore.Contact] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
            CNContactIdentifierKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault
        var contacts: [ContactStore.Contact] = []
        try store.enumerateContacts(with: request) { contact, _ in
            let name = Self.displayName(contact)
            let phones = contact.phoneNumbers
                .map { ContactStore.normalized($0.value.stringValue) }
                .filter { !$0.isEmpty }
            guard !name.isEmpty, !phones.isEmpty else { return }
            contacts.append(.init(
                id: contact.identifier,
                name: name,
                phones: phones,
                emails: contact.emailAddresses.map { $0.value as String },
                photoData: contact.thumbnailImageData
            ))
        }
        return contacts
    }

    func save(id: String?, name: String, phones: [String]) throws {
        let store = CNContactStore()
        let contact: CNMutableContact
        if let id {
            let existing = try store.unifiedContact(withIdentifier: id, keysToFetch: [
                CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor
            ])
            contact = existing.mutableCopy() as! CNMutableContact
        } else {
            contact = CNMutableContact()
        }
        let changed = Self.applyEdits(to: contact, name: name, phones: phones)
        guard id == nil || changed else { return }
        let request = CNSaveRequest()
        if id == nil { request.add(contact, toContainerWithIdentifier: nil) }
        else { request.update(contact) }
        try store.execute(request)
    }

    private static func displayName(_ contact: CNContact) -> String {
        let cjkName = containsCJK(contact.givenName + contact.familyName)
        let parts = cjkName ? [contact.familyName, contact.givenName] : [contact.givenName, contact.familyName]
        return parts.filter { !$0.isEmpty }.joined(separator: cjkName ? "" : " ")
    }

    @discardableResult
    static func applyEdits(to contact: CNMutableContact, name: String, phones: [String]) -> Bool {
        var changed = false
        if name != displayName(contact) {
            contact.givenName = name
            contact.familyName = ""
            changed = true
        }
        let original = contact.phoneNumbers
        var remaining = Array(original.indices)
        // 编辑器显示归一化号码；未改变的号码保留通讯录中的国家码、格式、标签和标识。
        let matches: [Int?] = phones.map { phone in
            guard let position = remaining.firstIndex(where: {
                ContactStore.normalized(original[$0].value.stringValue) == ContactStore.normalized(phone)
            }) else { return nil }
            return remaining.remove(at: position)
        }
        let updated = phones.enumerated().map { index, phone in
            if let match = matches[index] { return original[match] }
            if !remaining.isEmpty {
                let previous = original[remaining.removeFirst()]
                return previous.settingValue(CNPhoneNumber(stringValue: phone))
            }
            return CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: phone))
        }
        if original.count != updated.count || !zip(original, updated).allSatisfy({ pair in pair.0 === pair.1 }) {
            contact.phoneNumbers = updated
            changed = true
        }
        return changed
    }

    func displayName(for number: String) throws -> String? {
        guard authorizationState() == .authorized else { return nil }
        let target = ContactStore.normalized(number)
        guard !target.isEmpty else { return nil }
        let contacts = try fetchAll()
        if let exact = contacts.first(where: { $0.phones.contains(target) }) {
            return exact.name
        }
        guard target.count >= 7 else { return nil }
        let suffix = target.suffix(7)
        return contacts.first { contact in
            contact.phones.contains { $0.count >= 7 && $0.hasSuffix(suffix) }
        }?.name
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x3040...0x30FF:
                return true
            default:
                return false
            }
        }
    }
}

@MainActor
final class ContactStore: ObservableObject {
    struct Contact: Codable, Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let phones: [String]
        let emails: [String]
        let photoData: Data?

        var groupInitial: String {
            let latin = name.applyingTransform(.toLatin, reverse: false) ?? name
            let folded = latin.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).uppercased()
            guard let first = folded.trimmingCharacters(in: .whitespaces).first,
                  ("A"..."Z").contains(String(first)) else { return "#" }
            return String(first)
        }
    }

    @Published private(set) var contacts: [Contact] = []
    @Published private(set) var isAuthorized = false
    @Published private(set) var authorizationState: ContactAuthorizationState = .notDetermined
    @Published var errorMessage: String?
    private let cache: ContactCacheStore
    private let defaults: UserDefaults
    @Published private var favoriteIDs: Set<String>
    @Published private var preferredModules: [String: String]

    var favoriteContacts: [Contact] { contacts.filter { favoriteIDs.contains($0.id) } }
    func isFavorite(id: String) -> Bool { favoriteIDs.contains(id) }
    func toggleFavorite(id: String) {
        if favoriteIDs.contains(id) { favoriteIDs.remove(id) } else { favoriteIDs.insert(id) }
        defaults.set(favoriteIDs.sorted(), forKey: "airsim.contacts.favorites")
    }
    func preferredModuleID(for contactID: String) -> String? { preferredModules[contactID] }
    func setPreferredModuleID(_ moduleID: String?, for contactID: String) {
        preferredModules[contactID] = moduleID
        defaults.set(preferredModules, forKey: "airsim.contacts.preferred-modules")
    }

    @discardableResult
    func saveContact(id: String? = nil, name: String, phones: [String]) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let phones = phones.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !Self.normalized($0).isEmpty }
        guard !name.isEmpty, !phones.isEmpty else {
            errorMessage = "请填写姓名和至少一个电话号码"
            return false
        }
        if ContactFetcher().authorizationState() == .notDetermined {
            await requestAccessAndLoad()
        }
        guard ContactFetcher().authorizationState() == .authorized else {
            errorMessage = "请在系统设置中允许 AirSIM 访问通讯录后再保存"
            return false
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                try ContactFetcher().save(id: id, name: name, phones: phones)
            }.value
            await refresh(userInitiated: true)
            return true
        } catch {
            errorMessage = "联系人未保存，请检查通讯录权限或账户是否允许编辑后重试"
            return false
        }
    }

    init(fileManager: FileManager = .default, defaults: UserDefaults = .standard) {
        let defaults = UITestScenario.active ? UITestScenario.defaults : defaults
        self.defaults = defaults
        favoriteIDs = Set(defaults.stringArray(forKey: "airsim.contacts.favorites") ?? [])
        preferredModules = defaults.dictionary(forKey: "airsim.contacts.preferred-modules") as? [String: String] ?? [:]
        cache = ContactCacheStore(fileManager: fileManager)
        if UITestScenario.active {
            if UITestScenario.name == "design-empty" {
                contacts = []
            } else if UITestScenario.name == "design-a1" || UITestScenario.name?.hasPrefix("design-messages") == true
                || ["v2-incoming-fixture", "v2-active-fixture", "v2-dialing-fixture"].contains(UITestScenario.name ?? "") {
                let names = ["陈默", "陈明", "林晓", "苏晴", "张凯", "周宁"] + (UITestScenario.name?.hasPrefix("design-messages") == true ? ["顺丰速运"] : [])
                contacts = names.enumerated().map { index, name in
                    .init(id: "design-contact-\(index)", name: name, phones: [String(format: "%011d", index + 1)], emails: [], photoData: nil)
                }
            } else {
                contacts = [.init(id: "qa-contact", name: "QA虚构联系人", phones: ["00000000001"], emails: [], photoData: nil)]
            }
            authorizationState = .authorized; isAuthorized = true
            return
        }
        // 联系人属于手机数据。模块离线或系统联系人数据库暂不可读时，先展示本机副本。
        contacts = cache.load()
        let state = ContactFetcher().authorizationState()
        authorizationState = state
        isAuthorized = state == .authorized
    }

    nonisolated static func normalized(_ phone: String) -> String {
        var value = phone.filter { $0.isNumber || $0 == "+" }
        if value.hasPrefix("+86") {
            value.removeFirst(3)
        } else if value.hasPrefix("86"), value.count > 11 {
            value.removeFirst(2)
        }
        return value
    }

    func loadIfAuthorized() async {
        await refresh(userInitiated: false)
    }

    func requestAccessAndLoad() async {
        await refresh(userInitiated: true)
    }

    private func refresh(userInitiated: Bool) async {
        if UITestScenario.active { return }
        do {
            // 手机重启后可能先在数据保护尚未解锁时读取到空数组；每次前台刷新都重试磁盘缓存。
            let cachedContacts = cache.load()
            if !cachedContacts.isEmpty {
                contacts = cachedContacts
            }

            var state = await Task.detached(priority: .userInitiated) {
                ContactFetcher().authorizationState()
            }.value
            authorizationState = state

            switch ContactAccessPolicy.action(for: state, userInitiated: userInitiated) {
            case .request:
                let granted = try await Task.detached(priority: .userInitiated) {
                    try await ContactFetcher().requestAccess()
                }.value
                state = granted ? .authorized : .denied
                authorizationState = state
                guard granted else {
                    isAuthorized = false
                    errorMessage = "未获得通讯录访问权限"
                    return
                }
            case .load:
                break
            case .waitForUser:
                isAuthorized = false
                errorMessage = nil
                return
            case .blocked:
                isAuthorized = false
                errorMessage = "通讯录权限已关闭，请在系统设置中开启"
                return
            }

            isAuthorized = true
            // 非用户主动刷新时优先使用已恢复的缓存，避免每次切换联系人页都完整枚举通讯录。
            guard userInitiated || contacts.isEmpty else {
                errorMessage = nil
                return
            }
            contacts = try await Task.detached(priority: .userInitiated) {
                try ContactFetcher().fetchAll()
            }.value
            guard cache.save(contacts) else {
                errorMessage = "通讯录已读取，但保存到本机失败"
                return
            }
            errorMessage = nil
        } catch {
            isAuthorized = false
            errorMessage = error.localizedDescription
        }
    }

    func contact(for number: String) -> Contact? {
        let target = Self.normalized(number)
        guard !target.isEmpty else { return nil }
        if let exact = contacts.first(where: { $0.phones.contains(target) }) { return exact }
        guard target.count >= 7 else { return nil }
        let suffix = target.suffix(7)
        return contacts.first { contact in
            contact.phones.contains { $0.count >= 7 && $0.hasSuffix(suffix) }
        }
    }

    func displayName(for number: String?) -> String {
        guard let number, !number.isEmpty else { return "未知号码" }
        return contact(for: number)?.name ?? number
    }
}

/// 通讯录缓存仅保存在 App 沙盒，不会上传到模块或 Push Relay。
private final class ContactCacheStore {
    private let fileManager: FileManager
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let durableRoot = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Documents", isDirectory: true)
        let directory = durableRoot.appendingPathComponent("AirSIM", isDirectory: true)
        fileURL = directory.appendingPathComponent("contacts.json")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func load() -> [ContactStore.Contact] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONDecoder().decode([ContactStore.Contact].self, from: data)
        } catch {
            Self.log("读取通讯录缓存失败：\(error.localizedDescription)")
            return []
        }
    }

    @discardableResult
    func save(_ contacts: [ContactStore.Contact]) -> Bool {
        do {
            let data = try JSONEncoder().encode(contacts)
            try data.write(to: fileURL, options: [.atomic])
            return true
        } catch {
            Self.log("保存通讯录缓存失败：\(error.localizedDescription)")
            return false
        }
    }

    private static func log(_ message: String) {
#if DEBUG
        print("[AirSIM Contacts] \(message)")
#endif
    }
}
