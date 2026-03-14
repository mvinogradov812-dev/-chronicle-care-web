import SwiftUI
import Combine
import Speech
import AVFoundation
import SwiftData
import UserNotifications

@Model
class DiaryEntry {
    var id: UUID
    var text: String
    var date: Date
    var category: String
    var amount: Double?
    var spendingCategory: String?
    var isCompleted: Bool = false
    var photoPath: String? = nil  // relative filename in Documents/diary_photos/

    init(text: String, date: Date, category: String, amount: Double? = nil, spendingCategory: String? = nil) {
        self.id = UUID()
        self.text = text
        self.date = date
        self.category = category
        self.amount = amount
        self.spendingCategory = spendingCategory
        self.isCompleted = false
    }
}

// MARK: - Photo storage helper
struct PhotoStorage {
    static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("diary_photos")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func save(_ image: UIImage) -> String? {
        let name = UUID().uuidString + ".jpg"
        let url = folder.appendingPathComponent(name)
        guard let data = image.jpegData(compressionQuality: 0.82) else { return nil }
        try? data.write(to: url)
        return name
    }

    static func load(_ name: String) -> UIImage? {
        let url = folder.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    static func delete(_ name: String) {
        let url = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
    }
}

class NotificationSettings: ObservableObject {
    @Published var isEnabled: Bool { didSet { UserDefaults.standard.set(isEnabled, forKey: "notificationsEnabled") } }
    @Published var reminderMinutes: Int { didSet { UserDefaults.standard.set(reminderMinutes, forKey: "reminderMinutes") } }
    @Published var dailyReminderEnabled: Bool { didSet { UserDefaults.standard.set(dailyReminderEnabled, forKey: "dailyReminderEnabled") } }
    @Published var dailyReminderHour: Int { didSet { UserDefaults.standard.set(dailyReminderHour, forKey: "dailyReminderHour") } }
    init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: "notificationsEnabled")
        self.reminderMinutes = UserDefaults.standard.integer(forKey: "reminderMinutes") == 0 ? 60 : UserDefaults.standard.integer(forKey: "reminderMinutes")
        self.dailyReminderEnabled = UserDefaults.standard.bool(forKey: "dailyReminderEnabled")
        self.dailyReminderHour = UserDefaults.standard.integer(forKey: "dailyReminderHour") == 0 ? 20 : UserDefaults.standard.integer(forKey: "dailyReminderHour")
    }
}

class AppNavigationState: ObservableObject {
    @Published var selectedTab: Int = 0
    @Published var showWeeklyReport: Bool = false
    @Published var pendingAIQuery: String = ""
}

// MARK: - Notification action identifiers
struct NotificationActions {
    static let categoryHealth   = "HEALTH_REMINDER"
    static let actionTaken      = "ACTION_TAKEN"
    static let actionSkipped    = "ACTION_SKIPPED"
}

class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        registerCategories()
    }

    // Register interactive action buttons
    func registerCategoriesPublic() { registerCategories() }
    private func registerCategories() {
        let lang = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.systemDefault.rawValue) ?? .ru
        let takenTitle  = lang == .ru ? "✓ Принял" : "✓ Taken"
        let skippedTitle = lang == .ru ? "✗ Пропустил" : "✗ Skipped"

        let taken = UNNotificationAction(
            identifier: NotificationActions.actionTaken,
            title: takenTitle,
            options: []
        )
        let skipped = UNNotificationAction(
            identifier: NotificationActions.actionSkipped,
            title: skippedTitle,
            options: []
        )
        let category = UNNotificationCategory(
            identifier: NotificationActions.categoryHealth,
            actions: [taken, skipped],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func requestPermission(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func scheduleReminder(title: String, body: String, date: Date) {
        let content = UNMutableNotificationContent()
        let lang = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.systemDefault.rawValue) ?? .ru
        content.title = title
        content.body = body
        content.subtitle = lang == .ru ? "Зажми чтобы отметить выполнение" : "Hold to mark as done"
        content.sound = .default
        content.categoryIdentifier = NotificationActions.categoryHealth
        content.userInfo = ["reminderBody": body]
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        )
    }

    func scheduleDailyReminder(hour: Int) {
        removeDailyReminder()
        let content = UNMutableNotificationContent()
        let lang = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.systemDefault.rawValue) ?? .ru
        content.title = L10n.t(.dailyReminderTitle, lang)
        content.body = L10n.t(.dailyReminderBody, lang)
        content.sound = .default
        var components = DateComponents(); components.hour = hour; components.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "daily_reminder", content: content, trigger: trigger)
        )
    }

    func removeDailyReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["daily_reminder"])
    }

    // MARK: - Weekly report notification
    func scheduleWeeklyReport(weekday: Int, hour: Int) {
        removeWeeklyReport()
        let content = UNMutableNotificationContent()
        let lang = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.systemDefault.rawValue) ?? .ru
        content.title = lang == .ru ? "📊 Итоги недели" : "📊 Weekly Summary"
        content.body  = lang == .ru ? "Ваш персональный AI-отчёт готов" : "Your personal AI report is ready"
        content.sound = .default
        content.userInfo = ["type": "weeklyReport"]
        var components = DateComponents()
        components.weekday = weekday  // 1=Sun, 2=Mon ... 7=Sat
        components.hour = hour
        components.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "weekly_report", content: content, trigger: trigger)
        )
    }

    func removeWeeklyReport() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["weekly_report"])
    }

    // MARK: - Handle action buttons from notification
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let lang = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.systemDefault.rawValue) ?? .ru
        let body = response.notification.request.content.userInfo["reminderBody"] as? String ?? response.notification.request.content.body

        // Handle weekly report tap
        if response.notification.request.content.userInfo["type"] as? String == "weeklyReport" {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .showWeeklyReport, object: nil)
            }
            completionHandler()
            return
        }

        switch response.actionIdentifier {
        case NotificationActions.actionTaken:
            let text = lang == .ru ? "✓ \(body)" : "✓ \(body)"
            createEntryFromNotification(text: text, completed: true)

        case NotificationActions.actionSkipped:
            let text = lang == .ru ? "✗ Пропустил: \(body)" : "✗ Skipped: \(body)"
            createEntryFromNotification(text: text, completed: false)

        default:
            break
        }
        completionHandler()
    }

    // Show notification while app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    private func createEntryFromNotification(text: String, completed: Bool) {
        DispatchQueue.main.async {
            let lang = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "") ?? .ru
            let category = lang == .ru ? "Здоровье" : "Health"
            let entry = DiaryEntry(text: text, date: Date(), category: category)
            entry.isCompleted = completed
            NotificationCenter.default.post(
                name: .createEntryFromNotification,
                object: nil,
                userInfo: ["entry": entry]
            )
        }
    }
}

extension Notification.Name {
    static let createEntryFromNotification = Notification.Name("createEntryFromNotification")
    static let showWeeklyReport = Notification.Name("showWeeklyReport")
}


class EventParser {
    static func extractEvent(from text: String) -> (eventText: String, date: Date?)? {
        let lower = text.lowercased()
        let calendar = Calendar.current

        let hasRuDate = lower.contains("сегодня") || lower.contains("завтра") || lower.contains("послезавтра")
            || lower.contains("понедельник") || lower.contains("вторник")
            || lower.contains("среду") || lower.contains("среда") || lower.contains("четверг")
            || lower.contains("пятницу") || lower.contains("пятница")
            || lower.contains("субботу") || lower.contains("суббота") || lower.contains("воскресенье")
        let hasEnDate = lower.contains("today") || lower.contains("tomorrow") || lower.contains("day after tomorrow")
            || lower.contains("monday") || lower.contains("tuesday") || lower.contains("wednesday")
            || lower.contains("thursday") || lower.contains("friday") || lower.contains("saturday") || lower.contains("sunday")
        let timePatternCheck = #"(\d{1,2})[:.\-](\d{2})"#
        let hasTime = (try? NSRegularExpression(pattern: timePatternCheck))?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        let hasEnTime = lower.contains(" am") || lower.contains(" pm")
            || lower.contains("in the morning") || lower.contains("in the evening") || lower.contains("in the afternoon")
        guard hasRuDate || hasEnDate || hasTime || hasEnTime else { return nil }

        var eventDate: Date? = nil

        // Russian relative days
        if lower.contains("сегодня") { eventDate = Date() }
        if lower.contains("послезавтра") { eventDate = calendar.date(byAdding: .day, value: 2, to: Date()) }
        else if lower.contains("завтра") { eventDate = calendar.date(byAdding: .day, value: 1, to: Date()) }

        // English relative days
        if eventDate == nil {
            if lower.contains("day after tomorrow") { eventDate = calendar.date(byAdding: .day, value: 2, to: Date()) }
            else if lower.contains("tomorrow") { eventDate = calendar.date(byAdding: .day, value: 1, to: Date()) }
            else if lower.contains("today") { eventDate = Date() }
        }

        // Russian weekdays
        let ruWeekdays = ["понедельник": 2, "вторник": 3, "среда": 4, "среду": 4, "четверг": 5,
                          "пятница": 6, "пятницу": 6, "суббота": 7, "субботу": 7, "воскресенье": 1]
        if eventDate == nil {
            for (day, weekday) in ruWeekdays where lower.contains(day) {
                eventDate = EventParser.nextWeekday(weekday, calendar: calendar); break
            }
        }

        // English weekdays
        let enWeekdays = ["monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5,
                          "friday": 6, "saturday": 7, "sunday": 1]
        if eventDate == nil {
            for (day, weekday) in enWeekdays where lower.contains(day) {
                eventDate = EventParser.nextWeekday(weekday, calendar: calendar); break
            }
        }

        // Numeric time HH:MM
        let timePattern = #"(\d{1,2})[:.\-](\d{2})"#
        var parsedHour: Int? = nil
        var parsedMinute: Int = 0
        if let regex = try? NSRegularExpression(pattern: timePattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r1 = Range(match.range(at: 1), in: text), let r2 = Range(match.range(at: 2), in: text),
           let h = Int(text[r1]), let m = Int(text[r2]) {
            parsedHour = h; parsedMinute = m
        }

        // Russian verbal time
        let ruVerbal = #"(\d{1,2})\s*(?:час[а-я]*)?\s*(утра|утром|дня|днём|вечера|вечером|ночи|ночью)"#
        if parsedHour == nil,
           let regex = try? NSRegularExpression(pattern: ruVerbal, options: .caseInsensitive),
           let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let r1 = Range(match.range(at: 1), in: lower), let r2 = Range(match.range(at: 2), in: lower),
           let h = Int(lower[r1]) {
            switch String(lower[r2]) {
            case "утра", "утром":           parsedHour = h == 12 ? 0 : h
            case "дня", "днём":             parsedHour = h == 12 ? 12 : h + 12
            case "вечера", "вечером":       parsedHour = h == 12 ? 12 : min(h + 12, 23)
            case "ночи", "ночью":           parsedHour = h == 12 ? 0 : (h < 5 ? h : h + 12)
            default:                        parsedHour = h
            }
        }

        // English verbal time: "at 3pm", "at 9 am", "3 in the evening"
        let enVerbal = #"(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm|in the morning|in the afternoon|in the evening)"#
        if parsedHour == nil,
           let regex = try? NSRegularExpression(pattern: enVerbal, options: .caseInsensitive),
           let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let r1 = Range(match.range(at: 1), in: lower),
           let h = Int(lower[r1]) {
            parsedMinute = Range(match.range(at: 2), in: lower).flatMap { Int(lower[$0]) } ?? 0
            let period = Range(match.range(at: 3), in: lower).map { String(lower[$0]) } ?? ""
            switch period {
            case "am", "in the morning":              parsedHour = h == 12 ? 0 : h
            case "pm", "in the afternoon", "in the evening": parsedHour = h == 12 ? 12 : min(h + 12, 23)
            default:                                   parsedHour = h
            }
        }

        if let h = parsedHour {
            var c = calendar.dateComponents([.year, .month, .day], from: eventDate ?? Date())
            c.hour = h; c.minute = parsedMinute
            eventDate = calendar.date(from: c)
        }
        guard let finalDate = eventDate, finalDate > Date() else { return nil }
        let isTodayOnly = (lower.contains("сегодня") || lower.contains("today")) && !hasTime && parsedHour == nil
        if isTodayOnly { return nil }
        return (text, finalDate)
    }

    private static func nextWeekday(_ weekday: Int, calendar: Calendar) -> Date {
        var c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        c.weekday = weekday
        if let d = calendar.date(from: c), d > Date() { return d }
        let d = calendar.date(from: c) ?? Date()
        return calendar.date(byAdding: .weekOfYear, value: 1, to: d) ?? d
    }
}


class AmountExtractor {
    static func extract(from text: String) -> Double? {
        let normalizedText = normalizeEnglishNumberWords(in: text)
        let patterns = [
            #"(\d[\d\s]*(?:[.,]\d{1,2})?)\s*(?:руб(?:л[ейя])?|₽|р\.?|eur|euro|euros|€|usd|dollar|dollars|\$|доллар(?:ов|а)?|евро)"#,
            #"(?:₽|€|\$)\s*(\d[\d\s]*(?:[.,]\d{1,2})?)"#
        ]
        var total: Double = 0
        var found = false
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let matches = regex.matches(in: normalizedText, range: NSRange(normalizedText.startIndex..., in: normalizedText))
            for match in matches {
                let range = match.numberOfRanges > 1 ? match.range(at: 1) : match.range(at: 0)
                if let swiftRange = Range(range, in: normalizedText) {
                    let numStr = normalizedText[swiftRange]
                        .replacingOccurrences(of: " ", with: "")
                        .replacingOccurrences(of: ",", with: ".")
                    if let amount = Double(numStr), amount > 0, amount < 10_000_000 {
                        total += amount
                        found = true
                    }
                }
            }
            if found { break } // use first pattern that matched
        }
        return found ? total : nil
    }

    private static func normalizeEnglishNumberWords(in text: String) -> String {
        let units: [String: Int] = [
            "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
            "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
            "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
            "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19
        ]
        let tens: [String: Int] = [
            "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
            "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
        ]

        let cleaned = text
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: " and ", with: " ")

        let tokens = cleaned.split(whereSeparator: \.isWhitespace).map(String.init)
        var out: [String] = []
        var i = 0

        while i < tokens.count {
            var j = i
            var current = 0
            var total = 0
            var consumed = false

            while j < tokens.count {
                let token = tokens[j].trimmingCharacters(in: .punctuationCharacters)

                if let value = units[token] {
                    current += value
                    consumed = true
                    j += 1
                } else if let value = tens[token] {
                    current += value
                    consumed = true
                    j += 1
                } else if token == "hundred" {
                    current = max(1, current) * 100
                    consumed = true
                    j += 1
                } else if token == "thousand" {
                    total += max(1, current) * 1000
                    current = 0
                    consumed = true
                    j += 1
                } else {
                    break
                }
            }

            if consumed {
                out.append(String(total + current))
                i = j
            } else {
                out.append(tokens[i])
                i += 1
            }
        }

        return out.joined(separator: " ")
    }
}

class SpendingCategoryDetector {
    static func detect(from text: String) -> String? {
        let lower = text.lowercased()
        guard AmountExtractor.extract(from: text) != nil else { return nil }

        if lower.contains("продукт") || lower.contains("магазин") || lower.contains("супермаркет") || lower.contains("овощ") || lower.contains("фрукт") || lower.contains("молоко") || lower.contains("хлеб") || lower.contains("банан") || lower.contains("яблок") || lower.contains("пятёрочка") || lower.contains("пятерочка") || lower.contains("вкусвилл") || lower.contains("азбука вкуса") || lower.contains("азбука") || lower.contains("лента") {
            return "Продукты"
        }
        if lower.contains("кафе") || lower.contains("ресторан") || lower.contains("кофе") || lower.contains("американо") || lower.contains("капучино") || lower.contains("обед") || lower.contains("ужин") || lower.contains("завтрак") || lower.contains("пицц") || lower.contains("суши") || lower.contains("бургер") || lower.contains("сендвич") || lower.contains("сэндвич") {
            return "Кафе и рестораны"
        }
        if lower.contains("такси") || lower.contains("убер") || lower.contains("бензин") || lower.contains("заправ") || lower.contains("метро") || lower.contains("автобус") || lower.contains("парковк") {
            return "Транспорт"
        }
        if lower.contains("кино") || lower.contains("театр") || lower.contains("концерт") || lower.contains("игр") || lower.contains("netflix") || lower.contains("spotify") || lower.contains("подписк") || lower.contains("боулинг") {
            return "Развлечения"
        }
        if lower.contains("одежд") || lower.contains("куртк") || lower.contains("кроссовк") || lower.contains("ботинк") || lower.contains("платье") || lower.contains("джинс") || lower.contains("футболк") {
            return "Одежда"
        }
        return "Другое"
    }
}

class DiaryStore: NSObject, ObservableObject {
    let objectWillChange = PassthroughSubject<Void, Never>()
    func detectCategory(text: String) -> String {
        let lower = text.lowercased()

        if AmountExtractor.extract(from: text) != nil {
            return "Финансы"
        }

        if lower.contains("работ") || lower.contains("встреч") || lower.contains("проект") || lower.contains("клиент") || lower.contains("офис") { return "Работа" }
        if lower.contains("здоровь") || lower.contains("здоров") || lower.contains("самочувств") || lower.contains("чувствую себя") || lower.contains("врач") || lower.contains("таблетк") || lower.contains("болит") || lower.contains("лекарств") || lower.contains("health") || lower.contains("healthy") || lower.contains("well") || lower.contains("sick") {
            return "Здоровье"
        }
        return "Личное"
    }
}

class SpeechManager: NSObject, ObservableObject {
    let objectWillChange = PassthroughSubject<Void, Never>()
    var isRecording = false { willSet { objectWillChange.send() } }
    var isFinishing = false { willSet { objectWillChange.send() } }
    var recognizedText = "" { willSet { objectWillChange.send() } }
    var recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    var request: SFSpeechAudioBufferRecognitionRequest?
    var task: SFSpeechRecognitionTask?
    var engine = AVAudioEngine()
    private var silenceTimer: Timer?

    func startRecording() {
        updateRecognizerLocale()
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else { return }
            DispatchQueue.main.async { self.beginRecording() }
        }
    }

    private func updateRecognizerLocale() {
        let langRaw = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.systemDefault.rawValue
        let lang = AppLanguage(rawValue: langRaw) ?? .ru
        let localeID = lang == .en ? "en-US" : "ru-RU"
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID))
    }
    private func beginRecording() {
        request = SFSpeechAudioBufferRecognitionRequest()
        guard let request = request else { return }
        request.shouldReportPartialResults = true
        let node = engine.inputNode; node.removeTap(onBus: 0)
        let format = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        engine.prepare(); try? engine.start(); isRecording = true
        task = recognizer?.recognitionTask(with: request) { [weak self] result, _ in
            guard let self = self else { return }
            if let result = result { DispatchQueue.main.async { self.recognizedText = result.bestTranscription.formattedString } }
        }
    }
    func stopRecording(completion: @escaping (String) -> Void) {
        isFinishing = true; silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
            DispatchQueue.main.async {
                let finalText = self.recognizedText
                self.engine.stop(); self.engine.inputNode.removeTap(onBus: 0)
                self.request?.endAudio(); self.task?.cancel()
                self.isRecording = false; self.isFinishing = false
                completion(finalText)
            }
        }
    }
    func cancelRecording() {
        silenceTimer?.invalidate(); engine.stop(); engine.inputNode.removeTap(onBus: 0)
        request?.endAudio(); task?.cancel()
        isRecording = false; isFinishing = false; recognizedText = ""
    }
}

class AIService {
    static let shared = AIService()
    private let apiKey = anthropicAPIKey

    func ask(question: String, entries: [DiaryEntry], lang: AppLanguage) async -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short
        dateFormatter.locale = Locale(identifier: lang == .ru ? "ru_RU" : "en_US")

        let today = dateFormatter.string(from: Date())
        let entriesText = entries.map { entry -> String in
            let completionTag = (entry.category == "Здоровье" && entry.isCompleted) ? " [✓ Выполнено]" : (entry.category == "Health" && entry.isCompleted ? " [✓ Done]" : "")
            return "[\(dateFormatter.string(from: entry.date))] [\(entry.category)]\(completionTag) \(entry.text)"
        }.joined(separator: "\n")


        let genderRaw = UserDefaults.standard.string(forKey: "userGender") ?? "unspecified"
        let genderInstruction: String
        switch genderRaw {
        case "male":   genderInstruction = "Пользователь — мужчина. Обращайся к нему в мужском роде."
        case "female": genderInstruction = "Пользователь — женщина. Обращайся к ней в женском роде."
        default:       genderInstruction = "Пол пользователя неизвестен. Избегай форм с явным родом."
        }
        let systemPromptRu = "Ты персональный AI ассистент голосового дневника. Сегодня: \(today).\nОтвечай на русском языке. Будь конкретным и полезным.\nНе используй markdown форматирование. Пиши простым текстом.\n\(genderInstruction)\nЗаписи дневника:\n\(entriesText.isEmpty ? "Записей пока нет." : entriesText)"
        let systemPromptEn = "You are a personal AI assistant for a voice diary. Today: \(today).\nReply in English. Be specific and helpful.\nDo not use markdown. Write plain text.\nDiary entries:\n\(entriesText.isEmpty ? "No entries yet." : entriesText)"

        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1024,
            "system": lang == .ru ? systemPromptRu : systemPromptEn,
            "messages": [["role": "user", "content": question]]
        ]
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: urlRequest)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let content = json["content"] as? [[String: Any]],
               let text = content.first?["text"] as? String { return text }
            return "Ошибка: \(String(data: data, encoding: .utf8) ?? "")"
        } catch { return "Ошибка соединения: \(error.localizedDescription)" }
    }
}

// MARK: - Design System
struct AppColors {
    static let blue = Color(red: 0.36, green: 0.52, blue: 0.98)
    static let rose = Color(red: 0.98, green: 0.45, blue: 0.62)
    static func gradient(_ startPoint: UnitPoint = .topLeading, _ endPoint: UnitPoint = .bottomTrailing) -> LinearGradient {
        LinearGradient(colors: [blue, rose], startPoint: startPoint, endPoint: endPoint)
    }
}

struct AppTheme {
    static var bg: Color { Color(uiColor: .systemBackground) }
    static var card: Color { Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 0.18, alpha: 0.95)
            : UIColor(white: 1.0, alpha: 0.94)
    }) }
    static var cardStroke: Color { Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.10)
            : UIColor(white: 1.0, alpha: 0.70)
    }) }
    static var cardShadow: Color { Color.black.opacity(0.14) }
    static let screenPadding: CGFloat = 24
    static let radiusCard: CGFloat = 20
    static let radiusPill: CGFloat = 18
    static let radiusControl: CGFloat = 16
}

struct AppType {
    static let s34: CGFloat = 34
    static let s26: CGFloat = 26
    static let s20: CGFloat = 20
    static let s17: CGFloat = 17
    static let s14: CGFloat = 14
    static let s12: CGFloat = 12
}

enum AppCurrency: String, CaseIterable {
    case rub = "rub"
    case usd = "usd"
    case eur = "eur"

    var symbol: String {
        switch self {
        case .rub: return "₽"
        case .usd: return "$"
        case .eur: return "€"
        }
    }

    func title(_ lang: AppLanguage) -> String {
        switch self {
        case .rub: return lang == .ru ? "Рубли" : "Rubles"
        case .usd: return lang == .ru ? "Доллары" : "US Dollars"
        case .eur: return lang == .ru ? "Евро" : "Euro"
        }
    }
}

enum AppAppearanceMode: String, CaseIterable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    func title(_ lang: AppLanguage) -> String {
        switch self {
        case .system: return lang == .ru ? "Система" : "System"
        case .light: return lang == .ru ? "Светлая" : "Light"
        case .dark: return lang == .ru ? "Темная" : "Dark"
        }
    }
}

enum AppLanguage: String, CaseIterable {
    case ru = "ru"
    case en = "en"

    static var systemDefault: AppLanguage {
        let code = Locale.current.language.languageCode?.identifier ?? "ru"
        return code == "en" ? .en : .ru
    }

    static func detect(from text: String, fallback: AppLanguage) -> AppLanguage {
        if text.range(of: "[А-Яа-я]", options: .regularExpression) != nil { return .ru }
        if text.range(of: "[A-Za-z]", options: .regularExpression) != nil { return .en }
        return fallback
    }

    var locale: Locale {
        Locale(identifier: self == .ru ? "ru_RU" : "en_US")
    }
}

struct L10n {
    enum Key {
        case tabDiary, tabFinance, tabAssistant, tabSettings
        case greetingMorning, greetingDay, greetingEvening, greetingNight
        case today, earlier, calendar
        case noEntriesDay, diaryEmptyTitle, diaryEmptySubtitle
        case editTitle, cancel, save
        case speaking, saving, holdToRecord, releaseToCancel
        case financeTitle, period, week, month, allTime
        case totalSpent, vsLastWeek, byDays, topExpenses, byCategories
        case noFinanceTitle, noFinanceSubtitle
        case assistantTitle, assistantHello, assistantHelloName, assistantHelpLine
        case suggestWeek, suggestSpent, suggestHealth, suggestPlans
        case askPlaceholder, thinking
        case settingsTitle, profile, name, namePlaceholder
        case notifications, enableNotifications, remindAhead, dailyReminder, remindDiary, dailyReminderTitle, dailyReminderBody
        case noPermissionTitle, openSettings, noPermissionMsg
        case remindAlertTitle, create, remindAt, reminderTitle
        case onboardingTitle, onboardingTagline, featuresTitle
        case featureVoice, featureAI, featureFinance
        case nameQuestion, nameReason, nameField
        case lastStep, permissionsMsg, mic, notifs
        case next, start
        case language
        case langRu, langEn
    }

    static func t(_ key: Key, _ lang: AppLanguage) -> String {
        switch key {
        case .tabDiary: return lang == .ru ? "Дневник" : "Diary"
        case .tabFinance: return lang == .ru ? "Финансы" : "Finance"
        case .tabAssistant: return "AI Assistant"
        case .tabSettings: return lang == .ru ? "Настройки" : "Settings"
        case .greetingMorning: return lang == .ru ? "Доброе утро" : "Good morning"
        case .greetingDay: return lang == .ru ? "Добрый день" : "Good afternoon"
        case .greetingEvening: return lang == .ru ? "Добрый вечер" : "Good evening"
        case .greetingNight: return lang == .ru ? "Доброй ночи" : "Good night"
        case .today: return lang == .ru ? "Сегодня" : "Today"
        case .earlier: return lang == .ru ? "Ранее" : "Earlier"
        case .calendar: return lang == .ru ? "Календарь" : "Calendar"
        case .noEntriesDay: return lang == .ru ? "Нет записей за этот день" : "No entries for this day"
        case .diaryEmptyTitle: return lang == .ru ? "Зажми кнопку и говори" : "Hold and speak"
        case .diaryEmptySubtitle: return lang == .ru ? "Твои мысли и события\nбудут сохранены здесь" : "Your thoughts and events\nwill be saved here"
        case .editTitle: return lang == .ru ? "Редактировать" : "Edit"
        case .cancel: return lang == .ru ? "Отмена" : "Cancel"
        case .save: return lang == .ru ? "Сохранить" : "Save"
        case .speaking: return lang == .ru ? "Говорите..." : "Speak..."
        case .saving: return lang == .ru ? "Сохраняю..." : "Saving..."
        case .holdToRecord: return lang == .ru ? "Удерживай для записи" : "Hold to record"
        case .releaseToCancel: return lang == .ru ? "← Отпусти для отмены" : "Release to cancel"
        case .financeTitle: return lang == .ru ? "Финансы" : "Finance"
        case .period: return lang == .ru ? "Период" : "Period"
        case .week: return lang == .ru ? "Неделя" : "Week"
        case .month: return lang == .ru ? "Месяц" : "Month"
        case .allTime: return lang == .ru ? "Всё время" : "All time"
        case .totalSpent: return lang == .ru ? "Итого потрачено" : "Total spent"
        case .vsLastWeek: return lang == .ru ? "%d%% по сравнению с прошлой неделей" : "%d%% vs last week"
        case .byDays: return lang == .ru ? "По дням" : "By days"
        case .topExpenses: return lang == .ru ? "Топ трат" : "Top expenses"
        case .byCategories: return lang == .ru ? "По категориям" : "By categories"
        case .noFinanceTitle: return lang == .ru ? "Нет финансовых записей" : "No finance entries"
        case .noFinanceSubtitle: return lang == .ru ? "Надиктуй запись с суммой\nнапример: «кофе 350 рублей»" : "Dictate an entry with an amount\nfor example: “coffee 350 rubles”"
        case .assistantTitle: return lang == .ru ? "AI ассистент" : "AI Assistant"
        case .assistantHello: return lang == .ru ? "Привет, %@ 👋🏻" : "Hi, %@ 👋🏻"
        case .assistantHelloName: return lang == .ru ? "Привет, %@ 👋🏻" : "Hi, %@ 👋🏻"
        case .assistantHelpLine: return lang == .ru ? "Чем я могу помочь?" : "How can I help you?"
        case .suggestWeek: return lang == .ru ? "Что я делал на этой неделе?" : "What did I do this week?"
        case .suggestSpent: return lang == .ru ? "Сколько я потратил?" : "How much did I spend?"
        case .suggestHealth: return lang == .ru ? "Как моё здоровье?" : "How is my health?"
        case .suggestPlans: return lang == .ru ? "Что мне нужно не забыть сделать?" : "What do I need to remember to do?"
        case .askPlaceholder: return lang == .ru ? "Задай вопрос..." : "Ask a question..."
        case .thinking: return lang == .ru ? "Думаю..." : "Thinking..."
        case .settingsTitle: return lang == .ru ? "Настройки" : "Settings"
        case .profile: return lang == .ru ? "Профиль" : "Profile"
        case .name: return lang == .ru ? "Имя" : "Name"
        case .namePlaceholder: return lang == .ru ? "Как тебя зовут?" : "Your name"
        case .notifications: return lang == .ru ? "Уведомления" : "Notifications"
        case .enableNotifications: return lang == .ru ? "Включить уведомления" : "Enable notifications"
        case .remindAhead: return lang == .ru ? "Напоминать заранее" : "Remind ahead"
        case .dailyReminder: return lang == .ru ? "Ежедневное напоминание" : "Daily reminder"
        case .remindDiary: return lang == .ru ? "Напоминать вести дневник" : "Remind to journal"
        case .dailyReminderTitle: return lang == .ru ? "Chronicle" : "Chronicle"
        case .dailyReminderBody: return lang == .ru ? "Как прошёл твой день? Запиши воспоминания!" : "How was your day? Record your memories!"
        case .noPermissionTitle: return lang == .ru ? "Нет разрешения" : "No permission"
        case .openSettings: return lang == .ru ? "Открыть настройки" : "Open settings"
        case .noPermissionMsg: return lang == .ru ? "Разреши уведомления в настройках iPhone" : "Allow notifications in iPhone settings"
        case .remindAlertTitle: return lang == .ru ? "Создать напоминание?" : "Create reminder?"
        case .create: return lang == .ru ? "Создать" : "Create"
        case .remindAt: return lang == .ru ? "Напомнить %@?" : "Remind at %@?"
        case .reminderTitle: return lang == .ru ? "Напоминание" : "Reminder"
        case .onboardingTitle: return lang == .ru ? "Chronicle" : "Chronicle"
        case .onboardingTagline: return lang == .ru ? "Записывай мысли, события и траты\nпросто своим голосом" : "Record thoughts, events, and spending\nusing only your voice"
        case .featuresTitle: return lang == .ru ? "Всё что тебе нужно" : "Everything you need"
        case .featureVoice: return lang == .ru ? "Голосовые записи" : "Voice notes"
        case .featureAI: return lang == .ru ? "AI Ассистент" : "AI Assistant"
        case .featureFinance: return lang == .ru ? "Финансы" : "Finance"
        case .nameQuestion: return lang == .ru ? "Как тебя зовут?" : "What is your name?"
        case .nameReason: return lang == .ru ? "Чтобы приветствовать тебя по имени" : "So I can greet you by name"
        case .nameField: return lang == .ru ? "Твоё имя" : "Your name"
        case .lastStep: return lang == .ru ? "Последний шаг" : "Final step"
        case .permissionsMsg: return lang == .ru ? "Нам нужно несколько разрешений\nдля работы приложения" : "We need a few permissions\nfor the app to work"
        case .mic: return lang == .ru ? "Микрофон" : "Microphone"
        case .notifs: return lang == .ru ? "Уведомления" : "Notifications"
        case .next: return lang == .ru ? "Далее" : "Next"
        case .start: return lang == .ru ? "Начать" : "Start"
        case .language: return lang == .ru ? "Язык" : "Language"
        case .langRu: return lang == .ru ? "Русский" : "Russian"
        case .langEn: return lang == .ru ? "English" : "English"
        }
    }

    static func format(_ key: Key, _ lang: AppLanguage, _ args: CVarArg...) -> String {
        String(format: t(key, lang), arguments: args)
    }
}

// MARK: - Animated Background (only moving circles)
struct SoftBackground: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                AppTheme.bg
                movingBlob(color: AppColors.blue.opacity(0.26), size: CGSize(width: 420, height: 320), x: sin(t * 0.12) * 140 + sin(t * 0.03) * 40, y: cos(t * 0.10) * 180 + sin(t * 0.06) * 30)
                movingBlob(color: AppColors.rose.opacity(0.22), size: CGSize(width: 360, height: 280), x: cos(t * 0.11) * 160 + sin(t * 0.05) * 40, y: sin(t * 0.13) * 140 + cos(t * 0.04) * 30)
                movingBlob(color: AppColors.blue.opacity(0.18), size: CGSize(width: 440, height: 320), x: sin(t * 0.09) * 120 + cos(t * 0.07) * 40, y: cos(t * 0.08) * 200 + sin(t * 0.02) * 50)
                movingBlob(color: AppColors.rose.opacity(0.16), size: CGSize(width: 260, height: 220), x: sin(t * 0.17) * 90 + cos(t * 0.05) * 30, y: cos(t * 0.15) * 120 + sin(t * 0.08) * 25)
            }
            .ignoresSafeArea()
        }
    }

    private func movingBlob(color: Color, size: CGSize, x: Double, y: Double) -> some View {
        Ellipse()
            .fill(RadialGradient(colors: [color, Color.clear], center: .center, startRadius: 10, endRadius: max(size.width, size.height) / 1.6))
            .frame(width: size.width, height: size.height)
            .blur(radius: 40)
            .offset(x: x, y: y)
    }
}

extension View {
    func appCard(cornerRadius: CGFloat = AppTheme.radiusCard) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(AppTheme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(AppTheme.cardStroke, lineWidth: 1)
                    )
            )
            .shadow(color: AppTheme.cardShadow, radius: 10, x: 0, y: 4)
    }
}

// MARK: - Splash
struct LiquidBlob: View {
    @State private var animate1 = false
    @State private var animate2 = false
    @State private var animate3 = false
    @State private var animate4 = false
    @State private var animate5 = false

    var body: some View {
        ZStack {
            Ellipse()
                .fill(LinearGradient(colors: [AppColors.blue, AppColors.rose], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 320, height: 300)
                .blur(radius: 12)
                .scaleEffect(x: animate1 ? 1.15 : 0.9, y: animate1 ? 0.92 : 1.1)
                .offset(x: animate1 ? 12 : -12, y: animate1 ? -18 : 18)
                .opacity(0.95)

            Ellipse()
                .fill(LinearGradient(colors: [AppColors.rose, AppColors.blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 210, height: 190)
                .blur(radius: 10)
                .scaleEffect(animate2 ? 1.12 : 0.85)
                .offset(x: animate2 ? -68 : -38, y: animate2 ? 48 : 78)
                .opacity(0.9)

            Ellipse()
                .fill(LinearGradient(colors: [AppColors.blue, AppColors.rose], startPoint: .bottomLeading, endPoint: .topTrailing))
                .frame(width: 170, height: 155)
                .blur(radius: 9)
                .scaleEffect(animate3 ? 0.88 : 1.18)
                .offset(x: animate3 ? 78 : 48, y: animate3 ? 68 : 38)
                .opacity(0.88)

            Circle().fill(AppColors.rose).frame(width: 75, height: 75).blur(radius: 6).offset(x: animate4 ? -128 : -98, y: animate4 ? -88 : -58).scaleEffect(animate4 ? 1.3 : 0.75).opacity(0.9)
            Circle().fill(AppColors.blue).frame(width: 60, height: 60).blur(radius: 5).offset(x: animate5 ? 108 : 88, y: animate5 ? -68 : -98).scaleEffect(animate5 ? 0.8 : 1.2).opacity(0.88)
            Circle().fill(AppColors.rose).frame(width: 42, height: 42).blur(radius: 4).offset(x: animate1 ? 138 : 118, y: animate1 ? 88 : 58).opacity(0.85)
            Circle().fill(AppColors.blue).frame(width: 30, height: 30).blur(radius: 3).offset(x: animate2 ? -138 : -108, y: animate2 ? 68 : 98).opacity(0.8)
            Circle().fill(AppColors.rose).frame(width: 20, height: 20).blur(radius: 2).offset(x: animate3 ? 52 : 32, y: animate3 ? -125 : -105).opacity(0.75)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 3.8).repeatForever(autoreverses: true)) { animate1 = true }
            withAnimation(.easeInOut(duration: 4.5).repeatForever(autoreverses: true).delay(0.5)) { animate2 = true }
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true).delay(1.0)) { animate3 = true }
            withAnimation(.easeInOut(duration: 5.1).repeatForever(autoreverses: true).delay(0.3)) { animate4 = true }
            withAnimation(.easeInOut(duration: 4.2).repeatForever(autoreverses: true).delay(0.8)) { animate5 = true }
        }
    }
}

struct SplashView: View {
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.systemDefault.rawValue
    private var lang: AppLanguage { AppLanguage(rawValue: appLanguage) ?? .ru }

    @State private var opacity = 0.0
    @State private var scale = 0.85
    var onFinish: () -> Void
    var body: some View {
        ZStack {
            SoftBackground()
            Text(L10n.t(.onboardingTitle, lang))
                .font(.system(size: 44, weight: .bold, design: .serif))
                .foregroundColor(.primary)
                .opacity(opacity).scaleEffect(scale)
        }
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) { opacity = 1; scale = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeOut(duration: 0.2)) { opacity = 0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { onFinish() }
            }
        }
    }
}

// MARK: - Floating Bubble Section
struct FloatingBubbleSection<Content: View>: View {
    let title: String
    @State var isExpanded: Bool = true
    let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: { withAnimation(.spring(response: 0.4)) { isExpanded.toggle() } }) {
                ZStack {
                    Capsule()
                        .fill(LinearGradient(colors: [AppColors.blue.opacity(0.85), AppColors.rose.opacity(0.75)], startPoint: .leading, endPoint: .trailing))
                        .frame(height: 44)
                        .shadow(color: AppColors.blue.opacity(0.3), radius: 10, x: 0, y: 4)
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: AppType.s17, weight: .semibold))
                            .foregroundColor(.white)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: AppType.s12)).foregroundColor(.white.opacity(0.8))
                    }
                }
                .padding(.horizontal, AppTheme.screenPadding)
            }
            .animation(.spring(), value: isExpanded)

            if isExpanded { content() }
        }
    }
}

extension String {
    var canonicalDiaryCategory: String {
        switch self.lowercased() {
        case "работа", "work": return "Работа"
        case "финансы", "finance": return "Финансы"
        case "здоровье", "health": return "Здоровье"
        default: return "Личное"
        }
    }

    var canonicalSpendingCategory: String {
        switch self.lowercased() {
        case "продукты", "groceries": return "Продукты"
        case "кафе и рестораны", "cafes & restaurants": return "Кафе и рестораны"
        case "транспорт", "transport": return "Транспорт"
        case "развлечения", "entertainment": return "Развлечения"
        case "одежда", "clothes": return "Одежда"
        default: return "Другое"
        }
    }

    func localizedDiaryCategory(_ lang: AppLanguage) -> String {
        let canonical = canonicalDiaryCategory
        if lang == .ru { return canonical }
        switch canonical {
        case "Работа": return "Work"
        case "Финансы": return "Finance"
        case "Здоровье": return "Health"
        default: return "Personal"
        }
    }

    func localizedSpendingCategory(_ lang: AppLanguage) -> String {
        let canonical = canonicalSpendingCategory
        if lang == .ru { return canonical }
        switch canonical {
        case "Продукты": return "Groceries"
        case "Кафе и рестораны": return "Cafes & Restaurants"
        case "Транспорт": return "Transport"
        case "Развлечения": return "Entertainment"
        case "Одежда": return "Clothes"
        default: return "Other"
        }
    }

    var categoryColor: Color {
        switch canonicalDiaryCategory {
        case "Работа": return AppColors.blue
        case "Финансы": return Color(red: 0.4, green: 0.7, blue: 0.5)
        case "Здоровье": return AppColors.rose
        default: return Color(red: 0.67, green: 0.42, blue: 0.96)
        }
    }
    var categoryIcon: String {
        switch canonicalDiaryCategory {
        case "Работа": return "briefcase.fill"
        case "Финансы":
            return UIImage(systemName: "dollarsign.bag.fill") != nil ? "dollarsign.bag.fill" : "banknote.fill"
        case "Здоровье": return "heart.fill"
        default: return "person.fill"
        }
    }
}

// MARK: - Custom Tab Bar
struct CustomTabBarView: View {
    @Binding var selectedTab: Int
    @ObservedObject var speech: SpeechManager
    @Binding var isCancelling: Bool
    @Binding var micPulse: Bool
    let lang: AppLanguage

    @EnvironmentObject var store: DiaryStore
    @EnvironmentObject var notificationSettings: NotificationSettings
    @EnvironmentObject var navigationState: AppNavigationState
    @Environment(\.modelContext) var context

    @State private var showReminderAlert = false
    @State private var reminderText = ""
    @State private var reminderDate: Date = Date()

    var body: some View {
        ZStack(alignment: .bottom) {
                    // Page content
                    Group {
                        switch selectedTab {
                        case 0: DiaryView(externalSpeech: speech)
                        case 1: AnalyticsView()
                        case 2: AIAssistantView()
                        case 3: SettingsView()
                        default: DiaryView(externalSpeech: speech)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .bottom) {
                        Color.clear.frame(height: 120)
                    }
                    // Custom tab bar
                    HStack(alignment: .center, spacing: 10) {
                        HStack(spacing: 0) {
                            tabBtn(icon: "book.fill", label: L10n.t(.tabDiary, lang), tag: 0)
                            tabBtn(icon: "chart.bar.fill", label: L10n.t(.tabFinance, lang), tag: 1)
                            tabBtn(icon: "sparkles", label: L10n.t(.tabAssistant, lang), tag: 2)
                            tabBtn(icon: "gear", label: L10n.t(.tabSettings, lang), tag: 3)
                        }
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())

                        micButton
                            .background(
                                Circle()
                                    .fill(.ultraThinMaterial)
                                    .frame(width: 66, height: 66)
                            )
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .ignoresSafeArea(edges: .bottom)
                .background(Color.clear)
        .alert(L10n.t(.remindAlertTitle, lang), isPresented: $showReminderAlert) {
            Button(L10n.t(.create, lang)) {
                if reminderDate < Date() {
                    // просто не создаём напоминание — пользователь уже видит дату в alert и может исправить
                } else {
                    NotificationManager.shared.scheduleReminder(
                        title: L10n.t(.reminderTitle, lang),
                        body: reminderText,
                        date: reminderDate
                    )
                }
            }
            Button(L10n.t(.cancel, lang), role: .cancel) {}
        } message: {
            let f = DateFormatter()
            f.dateStyle = .medium; f.timeStyle = .short
            f.locale = Locale(identifier: lang == .ru ? "ru_RU" : "en_US")
            return Text(L10n.format(.remindAt, lang, f.string(from: reminderDate)))
        }
    }

    @ViewBuilder
    private func tabBtn(icon: String, label: String, tag: Int) -> some View {
        Button(action: {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                selectedTab = tag
            }
        }) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: selectedTab == tag ? .semibold : .regular))
                    .foregroundStyle(selectedTab == tag ? AnyShapeStyle(AppColors.gradient()) : AnyShapeStyle(Color.secondary))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(selectedTab == tag ? AppColors.blue : .secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private var micButton: some View {
        ZStack {
            // Pulse ring
            Circle()
                .fill(AppColors.blue.opacity(speech.isRecording ? 0.20 : 0.0))
                .frame(width: 68, height: 68)
                .scaleEffect(speech.isRecording ? (micPulse ? 1.25 : 0.90) : 1.0)
                .opacity(speech.isRecording ? (micPulse ? 0.6 : 0.2) : 0)
                .blur(radius: speech.isRecording ? 8 : 0)
                .animation(
                    speech.isRecording
                        ? .easeInOut(duration: 0.85).repeatForever(autoreverses: true)
                        : .easeOut(duration: 0.2),
                    value: micPulse
                )

            // Main circle
            Circle()
                .fill(
                    speech.isRecording || speech.isFinishing
                        ? AnyShapeStyle(isCancelling ? AppColors.rose : AppColors.rose.opacity(0.9))
                        : AnyShapeStyle(AppColors.gradient())
                )
                .frame(width: 56, height: 56)
                .shadow(color: AppColors.blue.opacity(0.4), radius: speech.isRecording ? 16 : 8, x: 0, y: 4)

            Image(systemName: speech.isFinishing ? "ellipsis" : (speech.isRecording ? "waveform" : "mic.fill"))
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)
        }
        .scaleEffect(speech.isRecording ? 1.12 : 1.0)
        .animation(.spring(response: 0.3), value: speech.isRecording)
        .onChange(of: speech.isRecording) { _, isRecording in
            micPulse = isRecording
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !speech.isRecording && !speech.isFinishing { speech.startRecording() }
                    isCancelling = abs(value.translation.width) > 50
                }
                .onEnded { value in
                    let cancelled = abs(value.translation.width) > 50
                    if cancelled {
                        speech.cancelRecording()
                        isCancelling = false
                    } else {
                        speech.stopRecording { finalText in
                            if !finalText.isEmpty {
                                let amount = AmountExtractor.extract(from: finalText)
                                let sc = SpendingCategoryDetector.detect(from: finalText)
                                let entry = DiaryEntry(
                                    text: finalText,
                                    date: Date(),
                                    category: store.detectCategory(text: finalText),
                                    amount: amount,
                                    spendingCategory: sc
                                )
                                context.insert(entry)
                                if notificationSettings.isEnabled,
                                   let event = EventParser.extractEvent(from: finalText),
                                   let eventDate = event.date {
                                    let remDate = eventDate.addingTimeInterval(-Double(notificationSettings.reminderMinutes * 60))
                                    reminderText = finalText
                                    reminderDate = remDate
                                    showReminderAlert = true
                                }
                            }
                            isCancelling = false
                        }
                    }
                }
        )
    }
}

struct ContentView: View {
    @StateObject var store = DiaryStore()
    @StateObject var notificationSettings = NotificationSettings()
    @StateObject var navigationState = AppNavigationState()
    @State private var showSplash = true
    @State private var showWeeklyReportSheet = false
    @StateObject private var sharedSpeech = SpeechManager()
    @State private var isCancellingGlobal = false
    @State private var micPulseGlobal = false
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.systemDefault.rawValue
    @AppStorage("appAppearance") private var appAppearance = AppAppearanceMode.system.rawValue
    @Query(sort: \DiaryEntry.date, order: .reverse) var allEntries: [DiaryEntry]
    @Environment(\.modelContext) var globalContext
    private var lang: AppLanguage { AppLanguage(rawValue: appLanguage) ?? .ru }
    private var preferredColorScheme: ColorScheme? {
        switch AppAppearanceMode(rawValue: appAppearance) ?? .system {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var body: some View {
        ZStack {
            if showSplash {
                SplashView { showSplash = false }.transition(.opacity)
            } else {
                CustomTabBarView(
                    selectedTab: $navigationState.selectedTab,
                    speech: sharedSpeech,
                    isCancelling: $isCancellingGlobal,
                    micPulse: $micPulseGlobal,
                    lang: lang
                )
                .environmentObject(store)
                .environmentObject(notificationSettings)
                .environmentObject(navigationState)
                .transition(.opacity)
            }
        }
        .tracking(-0.25)
        .animation(.easeInOut(duration: 0.5), value: showSplash)
        .preferredColorScheme(preferredColorScheme)
        .sheet(isPresented: $showWeeklyReportSheet) {
            WeeklyReportView(lang: lang, entries: allEntries)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showWeeklyReport)) { _ in
            showWeeklyReportSheet = true
        }
    }
}

struct EditEntryView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var store: DiaryStore
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.systemDefault.rawValue
    private var lang: AppLanguage { AppLanguage(rawValue: appLanguage) ?? .ru }

    let entry: DiaryEntry
    @State var editedText: String

    init(entry: DiaryEntry) { self.entry = entry; self._editedText = State(initialValue: entry.text) }

    var body: some View {
        NavigationStack {
            VStack {
                TextEditor(text: $editedText)
                    .padding()
                    .background(AppTheme.card)
                    .overlay(RoundedRectangle(cornerRadius: AppTheme.radiusControl, style: .continuous).stroke(AppTheme.cardStroke, lineWidth: 1))
                    .cornerRadius(AppTheme.radiusControl)
                    .shadow(color: AppTheme.cardShadow, radius: 8, x: 0, y: 3)
                    .padding()
                Spacer()
            }
            .navigationTitle(L10n.t(.editTitle, lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button(L10n.t(.cancel, lang)) { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.t(.save, lang)) { entry.text = editedText; entry.category = store.detectCategory(text: editedText); dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }
}

struct SwipeToDeleteCard: View {
    let entry: DiaryEntry
    let onTap: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var offset: CGFloat = 0
    @State private var showActions = false

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                Button(action: onEdit) {
                    ZStack { RoundedRectangle(cornerRadius: 16).fill(AppColors.blue); Image(systemName: "pencil").foregroundColor(.white).font(.title3) }
                }
                .frame(width: 80)
                Button(action: onDelete) {
                    ZStack { RoundedRectangle(cornerRadius: 16).fill(AppColors.rose); Image(systemName: "trash").foregroundColor(.white).font(.title3) }
                }
                .frame(width: 80)
            }
            .frame(width: 160)
            .opacity(showActions ? 1 : 0)

            EntryCard(entry: entry)
                .offset(x: offset)
                .gesture(
                    DragGesture(minimumDistance: 20, coordinateSpace: .local)
                        .onChanged { value in
                            let horizontal = abs(value.translation.width)
                            let vertical = abs(value.translation.height)
                            guard horizontal > vertical else { return }
                            if value.translation.width < 0 {
                                offset = max(value.translation.width, -160)
                            } else if showActions {
                                offset = min(value.translation.width - 160, 0)
                            }
                        }
                        .onEnded { value in
                            let horizontal = abs(value.translation.width)
                            let vertical = abs(value.translation.height)
                            guard horizontal > vertical else { return }
                            withAnimation(.spring()) {
                                if value.translation.width < -60 { offset = -160; showActions = true }
                                else { offset = 0; showActions = false }
                            }
                        }
                )
                .onTapGesture {
                    if showActions { withAnimation(.spring()) { offset = 0; showActions = false } }
                    else { onTap() }
                }
        }
        .padding(.horizontal, AppTheme.screenPadding)
    }
}

// MARK: - DiaryView
struct DiaryView: View {
    @EnvironmentObject var store: DiaryStore
    @EnvironmentObject var notificationSettings: NotificationSettings
    @EnvironmentObject var navigationState: AppNavigationState
    @AppStorage("userName") var userName: String = ""
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.systemDefault.rawValue
    private var lang: AppLanguage { AppLanguage(rawValue: appLanguage) ?? .ru }

    var externalSpeech: SpeechManager? = nil
    @State var selectedDate = Date()
    @State var showCalendar = false
    @State var showNotificationsSheet = false
    @State var showWeeklyReportSheet = false
    @State var entryToEdit: DiaryEntry? = nil
    @Query(sort: \DiaryEntry.date, order: .reverse) var allEntriesForReport: [DiaryEntry]

    @Query(sort: \DiaryEntry.date, order: .reverse) var entries: [DiaryEntry]
    @Environment(\.modelContext) var context

    var entriesForSelectedDate: [DiaryEntry] { entries.filter { Calendar.current.isDate($0.date, inSameDayAs: selectedDate) } }
    var todayEntries: [DiaryEntry] { entries.filter { Calendar.current.isDateInToday($0.date) } }
    var olderEntries: [DiaryEntry] { entries.filter { !Calendar.current.isDateInToday($0.date) } }

    var body: some View {
        NavigationStack {
            ZStack {
                SoftBackground()

                if showCalendar {
                    VStack {
                        HStack {
                            Spacer()
                            Button(action: { showCalendar.toggle() }) {
                                Image(systemName: "list.bullet")
                                    .font(.system(size: AppType.s20, weight: .semibold))
                                    .foregroundStyle(AppColors.gradient())
                                    .padding(14)
                                    .background(AppTheme.card)
                                    .clipShape(Circle())
                            }
                        }
                        .padding(.horizontal, AppTheme.screenPadding)
                        .padding(.bottom, 10)

                        DatePicker("", selection: $selectedDate, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .dynamicTypeSize(.xLarge)
                            .environment(\.locale, lang.locale)
                            .padding(.horizontal, AppTheme.screenPadding)

                        if entriesForSelectedDate.isEmpty {
                            VStack { Spacer(); Text(L10n.t(.noEntriesDay, lang)).foregroundColor(.gray); Spacer() }
                        } else {
                            ScrollView(.vertical, showsIndicators: false) {
                                VStack(spacing: 10) {
                                    ForEach(entriesForSelectedDate) { entry in
                                        SwipeToDeleteCard(entry: entry, onTap: { entryToEdit = entry }, onEdit: { entryToEdit = entry }, onDelete: { context.delete(entry) })
                                    }
                                }
                                .padding(.vertical, 10)
                            }
                            .background(Color.clear)
                        }
                    }
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(userName.isEmpty ? "Hello" : "Hello, \(userName)")
                                    .font(.system(size: 38, weight: .regular))
                                    .foregroundColor(.primary)
                                    .tracking(-0.6)
                                Text("Today's Summary")
                                    .font(.system(size: 38, weight: .regular))
                                    .foregroundColor(.primary)
                                    .tracking(-0.6)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, AppTheme.screenPadding)
                            .padding(.top, 34)
                            .padding(.bottom, 50)

                            HStack(alignment: .center) {
                                HStack(alignment: .lastTextBaseline, spacing: 10) {
                                    Text(String(format: "%02d", todayEntries.count))
                                        .font(.system(size: 40, weight: .bold))
                                        .foregroundColor(.primary)
                                    Text(lang == .ru ? "Записей\nсегодня" : "Entries\ntoday")
                                        .font(.system(size: AppType.s14))
                                        .foregroundColor(.secondary)
                                        .lineSpacing(2)
                                }
                                Spacer()
                                Button(action: { showCalendar.toggle() }) {
                                    Image(systemName: "calendar")
                                        .font(.system(size: AppType.s20, weight: .semibold))
                                        .foregroundStyle(AppColors.gradient())
                                        .padding(14)
                                        .background(AppTheme.card)
                                        .clipShape(Circle())
                                }
                            }
                            .padding(.horizontal, AppTheme.screenPadding)
                            .padding(.bottom, 50)

                            ChronicleAssistantCard(lang: lang, onAsk: {
                                navigationState.selectedTab = 2
                            })
                            .padding(.top, 10)
                            .padding(.horizontal, AppTheme.screenPadding)
                            .padding(.bottom, 40)

                            DiaryReferenceTiles(lang: lang)
                                .frame(maxWidth: .infinity)
                                .padding(.bottom, 16)

                            VStack(spacing: 20) {
                                if entries.isEmpty {
                                    VStack(spacing: 16) {
                                        Spacer(minLength: 40)
                                        ZStack {
                                            Circle().fill(AppColors.blue.opacity(0.1)).frame(width: 120, height: 120)
                                            Image(systemName: "mic.circle.fill").font(.system(size: 60)).foregroundStyle(AppColors.gradient())
                                        }
                                        Text(L10n.t(.diaryEmptyTitle, lang)).font(.system(size: AppType.s20, weight: .medium)).foregroundColor(.secondary)
                                        Text(L10n.t(.diaryEmptySubtitle, lang)).font(.system(size: AppType.s14)).foregroundColor(.secondary).multilineTextAlignment(.center)
                                    }
                                } else {
                                    if !todayEntries.isEmpty {
                                        FloatingBubbleSection(title: L10n.t(.today, lang)) {
                                            VStack(spacing: 10) {
                                                ForEach(todayEntries) { entry in
                                                    SwipeToDeleteCard(entry: entry, onTap: { entryToEdit = entry }, onEdit: { entryToEdit = entry }, onDelete: { context.delete(entry) })
                                                }
                                            }
                                        }
                                    }
                                    if !olderEntries.isEmpty {
                                        FloatingBubbleSection(title: L10n.t(.earlier, lang)) {
                                            VStack(spacing: 10) {
                                                ForEach(olderEntries) { entry in
                                                    SwipeToDeleteCard(entry: entry, onTap: { entryToEdit = entry }, onEdit: { entryToEdit = entry }, onDelete: { context.delete(entry) })
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.top, 0).padding(.bottom, 120)
                        }
                    }
                    .background(Color.clear)
                }

                if !showCalendar, let speech = externalSpeech, speech.isRecording || speech.isFinishing {
                    VStack {
                        Spacer()
                        VStack(spacing: 6) {
                            if !speech.recognizedText.isEmpty {
                                Text(speech.recognizedText)
                                    .font(.system(size: AppType.s14))
                                    .foregroundColor(.primary)
                                    .padding(12)
                                    .appCard(cornerRadius: AppTheme.radiusPill)
                                    .padding(.horizontal, AppTheme.screenPadding)
                            }
                            if speech.isFinishing {
                                Text(L10n.t(.saving, lang))
                                    .font(.system(size: AppType.s12))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.bottom, 90)
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !showCalendar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        HStack(spacing: 0) {
                            Button(action: { showNotificationsSheet = true }) {
                                Image(systemName: "bell")
                                    .font(.system(size: AppType.s17, weight: .medium))
                                    .foregroundStyle(AppColors.gradient())
                                    .frame(width: 40, height: 32)
                            }
                            Divider()
                                .frame(height: 18)
                                .opacity(0.4)
                            Button(action: { showWeeklyReportSheet = true }) {
                                Image(systemName: "calendar.badge.clock")
                                    .font(.system(size: AppType.s17, weight: .medium))
                                    .foregroundStyle(AppColors.gradient())
                                    .frame(width: 40, height: 32)
                            }
                        }
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                    }
                }
            }
            .sheet(isPresented: $showNotificationsSheet) {
                NotificationsInboxView(lang: lang)
            }
            .sheet(isPresented: $showWeeklyReportSheet) {
                WeeklyReportView(lang: lang, entries: allEntriesForReport)
            }
            .sheet(item: $entryToEdit) { entry in EditEntryView(entry: entry).environmentObject(store) }

            .onReceive(NotificationCenter.default.publisher(for: .createEntryFromNotification)) { notification in
                guard let entry = notification.userInfo?["entry"] as? DiaryEntry else { return }
                context.insert(entry)
            }
        }
    }

    func greetingLine1() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let greeting: String
        switch hour {
        case 5..<12: greeting = L10n.t(.greetingMorning, lang)
        case 12..<17: greeting = L10n.t(.greetingDay, lang)
        case 17..<22: greeting = L10n.t(.greetingEvening, lang)
        default: greeting = L10n.t(.greetingNight, lang)
        }
        return userName.isEmpty ? greeting : "\(greeting),"
    }
}



struct NotificationsInboxView: View {
    let lang: AppLanguage
    @Environment(\.dismiss) var dismiss
    @State private var rows: [NotificationRow] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if rows.isEmpty {
                    Text(lang == .ru ? "Уведомлений пока нет" : "No notifications yet")
                        .font(.system(size: AppType.s17))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    List(rows) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.title.isEmpty ? (lang == .ru ? "Уведомление" : "Notification") : row.title)
                                .font(.system(size: AppType.s14, weight: .semibold))
                            if !row.body.isEmpty {
                                Text(row.body)
                                    .font(.system(size: AppType.s14))
                                    .foregroundColor(.secondary)
                            }
                            Text(row.meta)
                                .font(.system(size: AppType.s12))
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(lang == .ru ? "Уведомления" : "Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(lang == .ru ? "Закрыть" : "Close") { dismiss() }
                }
            }
            .task { await loadNotifications() }
        }
    }

    private func loadNotifications() async {
        let center = UNUserNotificationCenter.current()

        let pending: [UNNotificationRequest] = await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(returning: requests)
            }
        }

        let delivered: [UNNotification] = await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { notifications in
                continuation.resume(returning: notifications)
            }
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short
        dateFormatter.locale = lang.locale

        let pendingRows: [NotificationRow] = pending.map { request in
            let nextDate = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
            let meta = lang == .ru
                ? "Ожидает\(nextDate != nil ? " • \(dateFormatter.string(from: nextDate!))" : "")"
                : "Pending\(nextDate != nil ? " • \(dateFormatter.string(from: nextDate!))" : "")"
            return NotificationRow(title: request.content.title, body: request.content.body, meta: meta)
        }

        let deliveredRows: [NotificationRow] = delivered.map { notification in
            let metaPrefix = lang == .ru ? "Получено" : "Delivered"
            return NotificationRow(
                title: notification.request.content.title,
                body: notification.request.content.body,
                meta: "\(metaPrefix) • \(dateFormatter.string(from: notification.date))"
            )
        }

        await MainActor.run {
            rows = (deliveredRows + pendingRows)
            isLoading = false
        }
    }
}

struct NotificationRow: Identifiable {
    let id = UUID()
    let title: String
    let body: String
    let meta: String
}

struct ChronicleAssistantCard: View {
    let lang: AppLanguage
    let onAsk: () -> Void
    var onReport: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Chronicle AI")
                        .font(.system(size: AppType.s26, weight: .regular))
                        .foregroundColor(.primary)
                    Text(lang == .ru ? "Виртуальный помощник" : "Virtual assistant")
                        .font(.system(size: AppType.s14))
                        .foregroundColor(.secondary)
                }
                Spacer()
                ZStack {
                    TimelineView(.animation) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        ZStack {
                            Circle()
                                .fill(AppColors.blue.opacity(0.20))
                                .frame(width: 18, height: 18)
                                .blur(radius: 4)
                                .offset(
                                    x: cos(t * 0.95) * 40,
                                    y: sin(t * 0.95) * 40
                                )
                            Circle()
                                .fill(AppColors.rose.opacity(0.18))
                                .frame(width: 16, height: 16)
                                .blur(radius: 4)
                                .offset(
                                    x: cos(t * 1.20 + 1.2) * 38,
                                    y: sin(t * 1.20 + 1.2) * 38
                                )
                            Circle()
                                .fill(Color.white.opacity(0.45))
                                .background(.ultraThinMaterial, in: Circle())
                            Circle()
                                .fill(AppColors.blue.opacity(0.42))
                                .frame(width: 50, height: 50)
                                .blur(radius: 9)
                                .offset(
                                    x: sin(t * 1.15) * 14 + cos(t * 0.55) * 5,
                                    y: cos(t * 0.95) * 12
                                )
                            Circle()
                                .fill(AppColors.rose.opacity(0.38))
                                .frame(width: 40, height: 40)
                                .blur(radius: 8)
                                .offset(
                                    x: cos(t * 0.85) * 13,
                                    y: sin(t * 1.25) * 13 + cos(t * 0.35) * 3
                                )
                            Circle()
                                .fill(AppColors.blue.opacity(0.24))
                                .frame(width: 30, height: 30)
                                .blur(radius: 7)
                                .offset(
                                    x: sin(t * 1.45) * 11,
                                    y: cos(t * 1.35) * 11
                                )
                        }
                    }
                }
                .frame(width: 86, height: 86)
                .clipShape(Circle())
                .offset(x: -6)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 14)
            .background(Color(uiColor: UIColor { t in
                t.userInterfaceStyle == .dark
                    ? UIColor(white: 0.16, alpha: 0.97)
                    : UIColor(white: 1.0, alpha: 0.90)
            }))

            Divider()

            Button(action: onAsk) {
                HStack {
                    Text(lang == .ru ? "Задать вопрос" : "Ask a question")
                        .font(.system(size: AppType.s17, weight: .semibold))
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: AppType.s17, weight: .semibold))
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
                .background(Color(uiColor: UIColor { t in
                    t.userInterfaceStyle == .dark
                        ? UIColor(white: 0.22, alpha: 0.80)
                        : UIColor(white: 1.0, alpha: 0.35)
                }))
            }
            .buttonStyle(.plain)

        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous)
                .stroke(AppTheme.cardStroke, lineWidth: 1)
        )
        .shadow(color: AppTheme.cardShadow, radius: 10, x: 0, y: 4)
    }
}

// MARK: - Widget types for user customisation
enum HomeWidget: String, CaseIterable {
    case health      = "health"
    case spending    = "spending"
    case reminders   = "reminders"
    case streak      = "streak"
    case todayNotes  = "todayNotes"

    func title(_ lang: AppLanguage) -> String {
        switch self {
        case .health:     return lang == .ru ? "Здоровье" : "Health"
        case .spending:   return lang == .ru ? "Расходы"  : "Spending"
        case .reminders:  return lang == .ru ? "События"  : "Events"
        case .streak:     return lang == .ru ? "Серия"    : "Streak"
        case .todayNotes: return lang == .ru ? "Записи"   : "Notes"
        }
    }

    func subtitle(_ lang: AppLanguage) -> String {
        switch self {
        case .health:     return lang == .ru ? "Сегодня" : "Today"
        case .spending:   return lang == .ru ? "Сегодня" : "Today"
        case .reminders:  return lang == .ru ? "Сегодня" : "Today"
        case .streak:     return lang == .ru ? "Дней подряд" : "Days in a row"
        case .todayNotes: return lang == .ru ? "За день" : "Today"
        }
    }

    func localizedName(_ lang: AppLanguage) -> String { title(lang) }
}

struct DiaryReferenceTiles: View {
    let lang: AppLanguage
    @Query(sort: \DiaryEntry.date, order: .reverse) var entries: [DiaryEntry]
    @State private var pendingCount: Int = 0

    // Widget slots — default values, user can override in Settings
    @AppStorage("widget1") private var widget1Raw: String = HomeWidget.health.rawValue
    @AppStorage("widget2") private var widget2Raw: String = HomeWidget.spending.rawValue
    @AppStorage("widget3") private var widget3Raw: String = HomeWidget.reminders.rawValue

    private var w1: HomeWidget { HomeWidget(rawValue: widget1Raw) ?? .health }
    private var w2: HomeWidget { HomeWidget(rawValue: widget2Raw) ?? .spending }
    private var w3: HomeWidget { HomeWidget(rawValue: widget3Raw) ?? .reminders }

    // MARK: — Computed values
    private var healthPercent: Int {
        let today = entries.filter { Calendar.current.isDateInToday($0.date) && $0.category == "Здоровье" }
        guard !today.isEmpty else { return 0 }
        let done = today.filter { $0.isCompleted }.count
        return Int(Double(done) / Double(today.count) * 100)
    }

    @AppStorage("preferredCurrency") private var appCurrencyRaw: String = AppCurrency.rub.rawValue
    private var currencySymbol: String {
        switch AppCurrency(rawValue: appCurrencyRaw) ?? .rub {
        case .rub: return "₽"
        case .usd: return "$"
        case .eur: return "€"
        }
    }

    private var spendingToday: Double {
        entries
            .filter { Calendar.current.isDateInToday($0.date) && $0.category == "Финансы" }
            .compactMap { $0.amount }
            .reduce(0, +)
    }

    private var spendingString: String {
        spendingToday == 0 ? "—" :
            spendingToday >= 1000
                ? String(format: "%.0fk%@", spendingToday / 1000, currencySymbol)
                : String(format: "%.0f%@", spendingToday, currencySymbol)
    }

    private var streakDays: Int {
        var streak = 0
        var day = Date()
        let cal = Calendar.current
        while true {
            let hasEntry = entries.contains { cal.isDate($0.date, inSameDayAs: day) }
            if hasEntry { streak += 1 } else { break }
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return streak
    }

    private var todayNotesCount: Int {
        entries.filter { Calendar.current.isDateInToday($0.date) }.count
    }

    private func value(for widget: HomeWidget) -> String {
        switch widget {
        case .health:     return "\(healthPercent)%"
        case .spending:   return spendingString
        case .reminders:  return "\(pendingCount)"
        case .streak:     return "\(streakDays)"
        case .todayNotes: return "\(todayNotesCount)"
        }
    }

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 12
            let hPad: CGFloat = AppTheme.screenPadding
            let cardW = (geo.size.width - hPad * 2 - spacing * 2) / 3

            HStack(spacing: spacing) {
                ForEach([w1, w2, w3], id: \.rawValue) { widget in
                    tile(
                        title: widget.title(lang),
                        subtitle: widget.subtitle(lang),
                        value: value(for: widget),
                        width: cardW
                    )
                }
            }
            .padding(.horizontal, hPad)
        }
        .frame(height: 174)
        .onAppear { loadPendingCount() }
    }

    private func loadPendingCount() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let cal = Calendar.current
            let count = requests.filter { req in
                guard let trigger = req.trigger as? UNCalendarNotificationTrigger,
                      let next = trigger.nextTriggerDate() else { return false }
                return cal.isDateInToday(next)
            }.count
            DispatchQueue.main.async { pendingCount = count }
        }
    }

    private func tile(title: String, subtitle: String, value: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: AppType.s14, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(.system(size: AppType.s12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(AppColors.gradient())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(14)
        .frame(width: width, height: 174, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous)
                .fill(AppTheme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous)
                .stroke(AppTheme.cardStroke, lineWidth: 1)
        )
        .shadow(color: AppTheme.cardShadow, radius: 6, x: 0, y: 3)
    }
}

// MARK: - Weekly report settings
struct ExportPDFButton: View {
    let lang: AppLanguage
    @Environment(\.modelContext) private var modelContext
    @State private var showExportSheet = false
    @State private var pdfURL: URL? = nil
    @State private var isGenerating = false

    var body: some View {
        Button(action: { generatePDF() }) {
            HStack {
                Image(systemName: "arrow.down.doc.fill")
                    .foregroundColor(AppColors.blue)
                Text(lang == .ru ? "Экспорт здоровья в PDF" : "Export Health to PDF")
                Spacer()
                if isGenerating {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
        }
        .sheet(isPresented: $showExportSheet) {
            if let url = pdfURL {
                ShareSheet(url: url)
            }
        }
    }

    func generatePDF() {
        isGenerating = true
        let descriptor = FetchDescriptor<DiaryEntry>(
            predicate: #Predicate { $0.category == "Здоровье" || $0.category == "Health" },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        let entries = (try? modelContext.fetch(descriptor)) ?? []

        DispatchQueue.global(qos: .userInitiated).async {
            let url = PDFExporter.export(entries: entries, lang: lang)
            DispatchQueue.main.async {
                self.pdfURL = url
                self.isGenerating = false
                self.showExportSheet = true
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct PDFExporter {
    static func export(entries: [DiaryEntry], lang: AppLanguage) -> URL {
        let pageWidth: CGFloat = 595.2
        let pageHeight: CGFloat = 841.8
        let margin: CGFloat = 48
        let contentWidth = pageWidth - margin * 2

        let pdfData = NSMutableData()
        UIGraphicsBeginPDFContextToData(pdfData, CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight), nil)

        var currentY: CGFloat = 0
        var pageOpen = false

        func newPage() {
            if pageOpen { UIGraphicsGetCurrentContext()?.endPage() }
            UIGraphicsBeginPDFPage()
            pageOpen = true
            currentY = margin

            // Header
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .bold),
                .foregroundColor: UIColor(red: 0.4, green: 0.49, blue: 0.92, alpha: 1)
            ]
            let title = lang == .ru ? "Chronicle — Записи здоровья" : "Chronicle — Health Records"
            title.draw(at: CGPoint(x: margin, y: currentY), withAttributes: titleAttrs)
            currentY += 30

            let dateAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 11),
                .foregroundColor: UIColor.secondaryLabel
            ]
            let dateStr = lang == .ru ? "Создано: \(DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .short))" : "Generated: \(DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .short))"
            dateStr.draw(at: CGPoint(x: margin, y: currentY), withAttributes: dateAttrs)
            currentY += 20

            // Divider
            let path = UIBezierPath()
            path.move(to: CGPoint(x: margin, y: currentY))
            path.addLine(to: CGPoint(x: pageWidth - margin, y: currentY))
            UIColor(red: 0.4, green: 0.49, blue: 0.92, alpha: 0.3).setStroke()
            path.lineWidth = 1
            path.stroke()
            currentY += 16
        }

        newPage()

        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        df.locale = Locale(identifier: lang == .ru ? "ru_RU" : "en_US")

        for entry in entries {
            if currentY > pageHeight - margin - 80 { newPage() }

            // Date chip background
            let chipRect = CGRect(x: margin, y: currentY, width: contentWidth, height: 28)
            let chipPath = UIBezierPath(roundedRect: chipRect, cornerRadius: 6)
            UIColor(red: 0.4, green: 0.49, blue: 0.92, alpha: 0.08).setFill()
            chipPath.fill()

            let dateAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: UIColor(red: 0.4, green: 0.49, blue: 0.92, alpha: 1)
            ]
            df.dateFormat = "d MMM yyyy HH:mm";            let dateStr = df.string(from: entry.date)
            dateStr.draw(at: CGPoint(x: margin + 8, y: currentY + 7), withAttributes: dateAttrs)

            // Completed badge
            if entry.isCompleted {
                let badge = lang == .ru ? "✓ Принято" : "✓ Done"
                let badgeAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: UIColor(red: 0.13, green: 0.62, blue: 0.43, alpha: 1)
                ]
                let badgeWidth = (badge as NSString).size(withAttributes: badgeAttrs).width + 12
                let badgeRect = CGRect(x: pageWidth - margin - badgeWidth - 4, y: currentY + 5, width: badgeWidth, height: 18)
                let badgePath = UIBezierPath(roundedRect: badgeRect, cornerRadius: 4)
                UIColor(red: 0.13, green: 0.62, blue: 0.43, alpha: 0.12).setFill()
                badgePath.fill()
                badge.draw(at: CGPoint(x: pageWidth - margin - badgeWidth + 2, y: currentY + 7), withAttributes: badgeAttrs)
            }

            currentY += 36

            // Entry text
            let textAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 13),
                .foregroundColor: UIColor.label
            ]
            let textRect = CGRect(x: margin, y: currentY, width: contentWidth, height: 200)
            let boundingRect = (entry.text as NSString).boundingRect(with: CGSize(width: contentWidth, height: 200), options: .usesLineFragmentOrigin, attributes: textAttrs, context: nil)
            (entry.text as NSString).draw(in: textRect, withAttributes: textAttrs)
            currentY += boundingRect.height + 20
        }

        if pageOpen { UIGraphicsGetCurrentContext()?.endPage() }
        UIGraphicsEndPDFContext()

        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("chronicle_health.pdf")
        pdfData.write(to: tmpURL, atomically: true)
        return tmpURL
    }
}
struct WeeklyReportSettingsSection: View {
    let lang: AppLanguage
    @AppStorage("weeklyReportEnabled") private var enabled: Bool = false
    @AppStorage("weeklyReportWeekday") private var weekday: Int = 1  // 1=Sun
    @AppStorage("weeklyReportHour") private var hour: Int = 20

    private var weekdayOptions: [(Int, String)] {
        lang == .ru
            ? [(1,"Воскресенье"),(2,"Понедельник"),(3,"Вторник"),(4,"Среда"),(5,"Четверг"),(6,"Пятница"),(7,"Суббота")]
            : [(1,"Sunday"),(2,"Monday"),(3,"Tuesday"),(4,"Wednesday"),(5,"Thursday"),(6,"Friday"),(7,"Saturday")]
    }

    var body: some View {
        Section(header: Text(lang == .ru ? "Еженедельный отчёт" : "Weekly Report")) {
            Toggle(lang == .ru ? "Присылать отчёт" : "Send weekly report", isOn: $enabled)
                .tint(AppColors.blue)
                .onChange(of: enabled) { _, on in
                    if on { NotificationManager.shared.scheduleWeeklyReport(weekday: weekday, hour: hour) }
                    else  { NotificationManager.shared.removeWeeklyReport() }
                }
            if enabled {
                Picker(lang == .ru ? "День" : "Day", selection: $weekday) {
                    ForEach(weekdayOptions, id: \.0) { opt in
                        Text(opt.1).tag(opt.0)
                    }
                }
                .onChange(of: weekday) { _, val in
                    NotificationManager.shared.scheduleWeeklyReport(weekday: val, hour: hour)
                }
                Picker(lang == .ru ? "Время" : "Time", selection: $hour) {
                    ForEach([8,9,10,17,18,19,20,21], id: \.self) { h in
                        Text(String(format: "%02d:00", h)).tag(h)
                    }
                }
                .onChange(of: hour) { _, val in
                    NotificationManager.shared.scheduleWeeklyReport(weekday: weekday, hour: val)
                }
            }
        }
    }
}

// MARK: - Widget picker for Settings
struct WidgetSettingsSection: View {
    let lang: AppLanguage
    @AppStorage("widget1") private var widget1Raw: String = HomeWidget.health.rawValue
    @AppStorage("widget2") private var widget2Raw: String = HomeWidget.spending.rawValue
    @AppStorage("widget3") private var widget3Raw: String = HomeWidget.reminders.rawValue

    var body: some View {
        Section(header: Text(lang == .ru ? "Виджеты на главном экране" : "Home screen widgets")) {
            widgetPicker(label: lang == .ru ? "Виджет 1" : "Widget 1", selection: $widget1Raw)
            widgetPicker(label: lang == .ru ? "Виджет 2" : "Widget 2", selection: $widget2Raw)
            widgetPicker(label: lang == .ru ? "Виджет 3" : "Widget 3", selection: $widget3Raw)
        }
    }

    private func widgetPicker(label: String, selection: Binding<String>) -> some View {
        Picker(label, selection: selection) {
            ForEach(HomeWidget.allCases, id: \.rawValue) { w in
                Text(w.title(lang)).tag(w.rawValue)
            }
        }
    }
}

struct EntryCard: View {
    let entry: DiaryEntry
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.systemDefault.rawValue
    private var lang: AppLanguage { AppLanguage(rawValue: appLanguage) ?? .ru }
    @State private var appear = false
    @State private var showPhotoPicker = false
    @State private var showFullPhoto = false
    @State private var photoImage: UIImage? = nil

    var timeString: String {
        let f = DateFormatter()
        f.locale = lang.locale
        if Calendar.current.isDateInToday(entry.date) { f.timeStyle = .short; return f.string(from: entry.date) }
        else {
            f.dateFormat = lang == .ru ? "d MMM, HH:mm" : "MMM d, HH:mm"
            return f.string(from: entry.date)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header row
            HStack(spacing: 8) {
                Image(systemName: entry.category.categoryIcon).font(.system(size: AppType.s17)).foregroundColor(entry.category.categoryColor)
                Text(entry.category.localizedDiaryCategory(lang)).font(.system(size: AppType.s17, weight: .semibold)).foregroundColor(entry.category.categoryColor)
                Spacer()
                Text(timeString).font(.system(size: AppType.s14)).foregroundColor(.secondary)
                // Camera button
                Button(action: { showPhotoPicker = true }) {
                    Image(systemName: entry.photoPath != nil ? "photo.fill" : "camera")
                        .font(.system(size: 15))
                        .foregroundStyle(entry.photoPath != nil ? AppColors.gradient() : LinearGradient(colors: [Color.secondary.opacity(0.6)], startPoint: .leading, endPoint: .trailing))
                }
                .buttonStyle(.plain)
            }

            // Text
            Text(entry.text)
                .font(.system(size: AppType.s14))
                .foregroundColor(.primary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            // Photo thumbnail
            if let img = photoImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onTapGesture { showFullPhoto = true }
                    .overlay(alignment: .topTrailing) {
                        Button(action: {
                            if let path = entry.photoPath { PhotoStorage.delete(path) }
                            entry.photoPath = nil
                            photoImage = nil
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 22))
                                .foregroundColor(.white)
                                .shadow(radius: 3)
                        }
                        .buttonStyle(.plain)
                        .padding(6)
                    }
            }

            // Health completion toggle
            if entry.category == "Здоровье" || entry.category == "Health" {
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        entry.isCompleted.toggle()
                    }
                    if entry.isCompleted {
                            entry.text = entry.text
                                .replacingOccurrences(of: "✗ Пропустил: ", with: "")
                                .replacingOccurrences(of: "✗ Skipped: ", with: "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: entry.isCompleted ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(entry.isCompleted ? AppColors.gradient() : LinearGradient(colors: [Color.secondary], startPoint: .leading, endPoint: .trailing))
                        Text(entry.isCompleted
                             ? (lang == .ru ? "Выполнено" : "Done")
                             : (lang == .ru ? "Отметить выполненным" : "Mark as done"))
                            .font(.system(size: AppType.s12, weight: .medium))
                            .foregroundColor(entry.isCompleted ? .primary : .secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .appCard()
        .scaleEffect(appear ? 1.0 : 0.98)
        .opacity(appear ? 1.0 : 0.96)
        .animation(.easeOut(duration: 0.5), value: appear)
        .onAppear {
            appear = true
            if let path = entry.photoPath { photoImage = PhotoStorage.load(path) }
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPickerView { image in
                if let name = PhotoStorage.save(image) {
                    if let old = entry.photoPath { PhotoStorage.delete(old) }
                    entry.photoPath = name
                    photoImage = image
                }
            }
        }
        .fullScreenCover(isPresented: $showFullPhoto) {
            if let img = photoImage {
                FullPhotoView(image: img)
            }
        }
    }
}

// MARK: - Photo Picker
struct PhotoPickerView: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: (UIImage) -> Void
        init(onPick: @escaping (UIImage) -> Void) { self.onPick = onPick }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { onPick(img) }
            picker.dismiss(animated: true)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

// MARK: - Full screen photo viewer
struct FullPhotoView: View {
    let image: UIImage
    @Environment(\.dismiss) var dismiss
    @State private var scale: CGFloat = 1.0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .gesture(MagnificationGesture()
                    .onChanged { scale = max(1, $0) }
                    .onEnded { _ in withAnimation(.spring()) { scale = 1 } }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(20)
            }
        }
    }
}

// MARK: - Weekly Report View
struct WeeklyReportView: View {
    let lang: AppLanguage
    let entries: [DiaryEntry]
    @Environment(\.dismiss) var dismiss

    @State private var reportText: String = ""
    @State private var isLoading = true

    private var weekEntries: [DiaryEntry] {
        let cal = Calendar.current
        return entries.filter {
            cal.dateComponents([.day], from: $0.date, to: Date()).day ?? 99 <= 7
        }
    }

    // Quick stats
    private var totalNotes: Int { weekEntries.count }
    private var healthTaken: Int { weekEntries.filter { $0.category == "Здоровье" && $0.isCompleted }.count }
    private var healthTotal: Int { weekEntries.filter { $0.category == "Здоровье" }.count }
    private var totalSpending: Double {
        weekEntries.filter { $0.category == "Финансы" }.compactMap { $0.amount }.reduce(0, +)
    }
    private var streakDays: Int {
        var streak = 0; var day = Date(); let cal = Calendar.current
        while true {
            if entries.contains(where: { cal.isDate($0.date, inSameDayAs: day) }) { streak += 1 } else { break }
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return streak
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SoftBackground()
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 20) {
                        // Header
                        VStack(spacing: 6) {
                            Text("📊")
                                .font(.system(size: 48))
                            Text(lang == .ru ? "Итоги недели" : "Weekly Summary")
                                .font(.system(size: AppType.s20, weight: .bold))
                            Text(weekRangeString)
                                .font(.system(size: AppType.s14))
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 8)

                        // Quick stats grid
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            statCard(icon: "📝", value: "\(totalNotes)", label: lang == .ru ? "Записей" : "Notes")
                            statCard(icon: "💊", value: healthTotal == 0 ? "—" : "\(healthTaken)/\(healthTotal)", label: lang == .ru ? "Лекарств" : "Meds taken")
                            statCard(icon: "🔥", value: "\(streakDays)", label: lang == .ru ? "Дней подряд" : "Day streak")
                            statCard(icon: "💰", value: totalSpending == 0 ? "—" : String(format: "%.0f", totalSpending), label: lang == .ru ? "Расходов" : "Spending")
                        }
                        .padding(.horizontal, AppTheme.screenPadding)

                        // AI insight
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(AppColors.gradient())
                                    .font(.system(size: AppType.s17, weight: .semibold))
                                Text(lang == .ru ? "Персональный инсайт" : "Personal Insight")
                                    .font(.system(size: AppType.s17, weight: .semibold))
                            }
                            if isLoading {
                                HStack(spacing: 10) {
                                    ProgressView().tint(AppColors.blue)
                                    Text(lang == .ru ? "AI анализирует вашу неделю…" : "AI is analysing your week…")
                                        .font(.system(size: AppType.s14))
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                            } else {
                                Text(reportText)
                                    .font(.system(size: AppType.s14))
                                    .foregroundColor(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(16)
                        .background(RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous).fill(AppTheme.card))
                        .overlay(RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous).stroke(AppTheme.cardStroke, lineWidth: 1))
                        .shadow(color: AppTheme.cardShadow, radius: 6, x: 0, y: 3)
                        .padding(.horizontal, AppTheme.screenPadding)

                        Spacer(minLength: 40)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(lang == .ru ? "Закрыть" : "Close") { dismiss() }
                }
            }
            .task { await generateReport() }
        }
    }

    private var weekRangeString: String {
        let cal = Calendar.current
        let end = Date()
        let start = cal.date(byAdding: .day, value: -6, to: end) ?? end
        let df = DateFormatter()
        df.dateFormat = lang == .ru ? "d MMM" : "MMM d"
        df.locale = lang.locale
        return "\(df.string(from: start)) — \(df.string(from: end))"
    }

    private func statCard(icon: String, value: String, label: String) -> some View {
        VStack(spacing: 6) {
            Text(icon).font(.system(size: 28))
            Text(value)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(AppColors.gradient())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.system(size: AppType.s12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous).fill(AppTheme.card))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous).stroke(AppTheme.cardStroke, lineWidth: 1))
        .shadow(color: AppTheme.cardShadow, radius: 4, x: 0, y: 2)
    }

    private func generateReport() async {
        guard !weekEntries.isEmpty else {
            reportText = lang == .ru
                ? "На этой неделе записей нет. Начни вести дневник — и на следующей неделе здесь появится твой персональный отчёт."
                : "No entries this week. Start journaling and your personal report will appear next week."
            isLoading = false
            return
        }

        let df = DateFormatter()
        df.locale = lang.locale
        df.dateFormat = lang == .ru ? "d MMM, HH:mm" : "MMM d, HH:mm"
        let entriesText = weekEntries.map { e in
            let tag = (e.category == "Здоровье" && e.isCompleted) ? " [✓]" : ""
            return "[\(df.string(from: e.date))] [\(e.category)]\(tag) \(e.text)"
        }.joined(separator: "\n")

        let genderRaw = UserDefaults.standard.string(forKey: "userGender") ?? "unspecified"
        let genderNote: String
        switch genderRaw {
        case "male":   genderNote = lang == .ru ? "Пользователь — мужчина, обращайся в мужском роде." : ""
        case "female": genderNote = lang == .ru ? "Пользователь — женщина, обращайся в женском роде." : ""
        default:       genderNote = ""
        }

        let prompt = lang == .ru
            ? """
            Ты AI-ассистент личного дневника. \(genderNote)
            Вот записи пользователя за последние 7 дней:
            \(entriesText)

            Напиши короткий (3-5 предложений) тёплый персональный итог недели. Отметь что получилось хорошо, что можно улучшить. Будь конкретным — ссылайся на реальные записи. Не используй markdown.
            """
            : """
            You are a personal diary AI assistant.
            Here are the user\'s entries for the past 7 days:
            \(entriesText)

            Write a short (3-5 sentences) warm personal weekly summary. Note what went well and what could improve. Be specific — reference actual entries. No markdown.
            """

        let result = await AIService.shared.ask(question: prompt, entries: weekEntries, lang: lang)
        reportText = result
        isLoading = false
    }
}

// MARK: - Custom Date Range
struct CustomDateRangeView: View {
    let lang: AppLanguage
    @Binding var from: Date
    @Binding var to: Date
    let onApply: () -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                SoftBackground()
                VStack(spacing: 0) {
                    VStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(lang == .ru ? "Начало периода" : "From")
                                .font(.system(size: AppType.s14, weight: .semibold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, AppTheme.screenPadding)
                            DatePicker("", selection: $from, in: ...to, displayedComponents: .date)
                                .datePickerStyle(.graphical)
                                .tint(AppColors.blue)
                                .padding(.horizontal, 8)
                        }
                        .padding(.vertical, 12)
                        .appCard()
                        .padding(.horizontal, AppTheme.screenPadding)

                        VStack(alignment: .leading, spacing: 8) {
                            Text(lang == .ru ? "Конец периода" : "To")
                                .font(.system(size: AppType.s14, weight: .semibold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, AppTheme.screenPadding)
                            DatePicker("", selection: $to, in: from..., displayedComponents: .date)
                                .datePickerStyle(.graphical)
                                .tint(AppColors.blue)
                                .padding(.horizontal, 8)
                        }
                        .padding(.vertical, 12)
                        .appCard()
                        .padding(.horizontal, AppTheme.screenPadding)
                    }
                    .padding(.top, 16)

                    Spacer()

                    Button(action: { onApply(); dismiss() }) {
                        Text(lang == .ru ? "Применить" : "Apply")
                            .font(.system(size: AppType.s17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(AppColors.gradient())
                            .cornerRadius(AppTheme.radiusControl)
                    }
                    .padding(.horizontal, AppTheme.screenPadding)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle(lang == .ru ? "Свой период" : "Custom Range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(lang == .ru ? "Отмена" : "Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Analytics
struct AnalyticsView: View {
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.systemDefault.rawValue
    @AppStorage("preferredCurrency") private var preferredCurrency = AppCurrency.rub.rawValue
    private var lang: AppLanguage { AppLanguage(rawValue: appLanguage) ?? .ru }
    private var currency: AppCurrency { AppCurrency(rawValue: preferredCurrency) ?? .rub }

    @EnvironmentObject var navigationState: AppNavigationState
    @Query(sort: \DiaryEntry.date, order: .reverse) var entries: [DiaryEntry]
    @State var selectedPeriod = 0
    @State private var showWeeklyReport = false
    @State private var showCustomRange = false
    @State private var customFrom: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customTo: Date = Date()

    var periods: [String] {
        [L10n.t(.week, lang), L10n.t(.month, lang), L10n.t(.allTime, lang),
         lang == .ru ? "Свой период" : "Custom"]
    }

    var customRangeLabel: String {
        let df = DateFormatter()
        df.dateFormat = lang == .ru ? "d MMM" : "MMM d"
        df.locale = lang.locale
        return "\(df.string(from: customFrom)) — \(df.string(from: customTo))"
    }

    var financeEntries: [DiaryEntry] {
        let now = Date(); let calendar = Calendar.current
        let filtered: [DiaryEntry]
        switch selectedPeriod {
        case 0: filtered = entries.filter { calendar.dateComponents([.day], from: $0.date, to: now).day ?? 0 <= 7 }
        case 1: filtered = entries.filter { calendar.dateComponents([.day], from: $0.date, to: now).day ?? 0 <= 30 }
        case 3:
            let from = calendar.startOfDay(for: customFrom)
            let to = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: customTo) ?? customTo
            filtered = entries.filter { $0.date >= from && $0.date <= to }
        default: filtered = entries
        }
        return filtered.filter { AmountExtractor.extract(from: $0.text) != nil }
    }

    var totalAmount: Double { financeEntries.compactMap { AmountExtractor.extract(from: $0.text) }.reduce(0, +) }
    var formattedTotalAmount: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = lang.locale
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: totalAmount)) ?? String(format: "%.2f", totalAmount)
    }

    var dailyData: [(String, Double)] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: financeEntries) { calendar.startOfDay(for: $0.date) }
        let df = DateFormatter()
        df.dateFormat = lang == .ru ? "d MMM" : "MMM d"
        df.locale = lang.locale
        return grouped
            .map { (date, dayEntries) in
                let dayTotal = dayEntries.compactMap { AmountExtractor.extract(from: $0.text) }.reduce(0, +)
                return (date, dayTotal)
            }
            .sorted { $0.0 < $1.0 }
            .map { (df.string(from: $0.0), $0.1) }
    }

    var topExpenses: [DiaryEntry] {
        financeEntries.sorted { (AmountExtractor.extract(from: $0.text) ?? 0) > (AmountExtractor.extract(from: $1.text) ?? 0) }
            .prefix(5).map { $0 }
    }

    var thisWeekTotal: Double {
        let c = Calendar.current
        return entries.filter { c.dateComponents([.day], from: $0.date, to: Date()).day ?? 0 <= 7 }
            .compactMap { AmountExtractor.extract(from: $0.text) }.reduce(0, +)
    }

    var lastWeekTotal: Double {
        let c = Calendar.current
        return entries.filter {
            let d = c.dateComponents([.day], from: $0.date, to: Date()).day ?? 0
            return d > 7 && d <= 14
        }.compactMap { AmountExtractor.extract(from: $0.text) }.reduce(0, +)
    }

    var categoryData: [(name: String, value: Double, color: Color, icon: String)] {
        var totals: [String: Double] = [:]
        for entry in financeEntries {
            let rawCat = entry.spendingCategory ?? SpendingCategoryDetector.detect(from: entry.text) ?? "Другое"
            let canonical = rawCat.canonicalSpendingCategory
            totals[canonical, default: 0] += AmountExtractor.extract(from: entry.text) ?? 0
        }

        return totals
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map { canonical, value in
                (
                    name: canonical.localizedSpendingCategory(lang),
                    value: value,
                    color: categoryColor(for: canonical),
                    icon: categoryIcon(for: canonical)
                )
            }
    }

    private func categoryColor(for canonical: String) -> Color {
        switch canonical {
        case "Продукты": return AppColors.blue
        case "Кафе и рестораны": return AppColors.rose
        case "Транспорт": return Color(red: 0.4, green: 0.7, blue: 0.5)
        case "Развлечения": return Color.purple
        case "Одежда": return Color.pink
        default: return Color.gray
        }
    }

    private func categoryIcon(for canonical: String) -> String {
        switch canonical {
        case "Продукты": return "cart.fill"
        case "Кафе и рестораны": return "fork.knife"
        case "Транспорт": return "car.fill"
        case "Развлечения": return "gamecontroller.fill"
        case "Одежда": return "tshirt.fill"
        default: return "square.grid.2x2.fill"
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SoftBackground()
                if financeEntries.isEmpty {
                    VStack(spacing: 16) {
                        ZStack { Circle().fill(AppColors.blue.opacity(0.1)).frame(width: 100, height: 100); Image(systemName: "rublesign.circle.fill").font(.system(size: 50)).foregroundStyle(AppColors.gradient()) }
                        Text(L10n.t(.noFinanceTitle, lang)).font(.system(size: AppType.s20, weight: .medium)).foregroundColor(.secondary)
                        Text(L10n.t(.noFinanceSubtitle, lang)).font(.system(size: AppType.s14)).foregroundColor(.secondary).multilineTextAlignment(.center)
                    }
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 16) {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L10n.t(.totalSpent, lang))
                                        .font(.system(size: AppType.s17, weight: .semibold))
                                        .foregroundColor(.secondary)
                                    Text("\(currency.symbol)\(formattedTotalAmount)")
                                        .font(.system(size: 54, weight: .regular))
                                        .foregroundColor(.primary)
                                        .tracking(-0.6)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                    if selectedPeriod == 0 && lastWeekTotal > 0 {
                                        let diff = thisWeekTotal - lastWeekTotal
                                        let percent = Int(abs(diff) / lastWeekTotal * 100)
                                        HStack(spacing: 4) {
                                            Image(systemName: diff > 0 ? "arrow.up" : "arrow.down")
                                            Text(L10n.format(.vsLastWeek, lang, percent))
                                        }
                                        .font(.system(size: AppType.s12))
                                        .foregroundColor(diff > 0 ? AppColors.rose : AppColors.blue)
                                    }
                                }
                                Spacer(minLength: 0)
                                Menu {
                                    ForEach(0..<periods.count, id: \.self) { index in
                                        Button(periods[index]) {
                                            if index == 3 { showCustomRange = true }
                                            else { selectedPeriod = index }
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(selectedPeriod == 3 ? customRangeLabel : periods[selectedPeriod])
                                            .font(.system(size: AppType.s14, weight: .semibold))
                                            .foregroundColor(.primary)
                                            .id("period_\(selectedPeriod)")
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: AppType.s12, weight: .semibold))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 12)
                                    .frame(height: 34)
                                    .background(
                                        Capsule().fill(AppTheme.card)
                                    )
                                    .animation(.none, value: selectedPeriod)
                                }
                            }
                            .padding(.horizontal, AppTheme.screenPadding)

                            if !categoryData.isEmpty {
                                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 10) {
                                    ForEach(Array(categoryData.enumerated()), id: \.offset) { index, item in
                                        HStack(alignment: .center, spacing: 10) {
                                            Image(systemName: item.icon)
                                                .font(.system(size: AppType.s20, weight: .semibold))
                                                .foregroundStyle(AppColors.gradient())
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(item.name)
                                                    .font(.system(size: AppType.s14, weight: .semibold))
                                                    .foregroundColor(.primary)
                                                    .lineLimit(1)
                                                Text("\(currency.symbol)\(Int(item.value))")
                                                    .font(.system(size: AppType.s14))
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                            }
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.leading, index % 2 == 0 ? 4 : -12)
                                    }
                                }
                                .padding(.horizontal, AppTheme.screenPadding)
                                .padding(.top, 2)
                                .padding(.vertical, 12)
                                .padding(.bottom, 68)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Fast Access AI Tools")
                                    .font(.system(size: AppType.s14, weight: .semibold))
                                    .foregroundColor(.primary)
                                Text("Quick and convinient\nAI actions")
                                    .font(.system(size: AppType.s14))
                                    .foregroundColor(.secondary)
                                    .lineSpacing(2)
                            }
                            .padding(.top, 10)
                            .padding(.horizontal, AppTheme.screenPadding)
                            .frame(maxWidth: .infinity, alignment: .leading)

                            GeometryReader { geo in
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) {
                                        let tileWidth = (geo.size.width - AppTheme.screenPadding * 2 - 12) / 2
                                        financeToolTile(title: "Financial\nInsights", width: tileWidth) {
                                            let queries = ["Сделай краткий финансовый инсайт за последнюю неделю", "Сделай краткий финансовый инсайт за последний месяц", "Сделай краткий финансовый инсайт за всё время"]
                                            navigationState.pendingAIQuery = queries[min(selectedPeriod, queries.count - 1)]
                                            navigationState.selectedTab = 2
                                        }
                                        financeToolTile(title: "Assistance\nDesk", width: tileWidth) {
                                            navigationState.pendingAIQuery = "Помоги мне оптимизировать траты и составить план бюджета"
                                            navigationState.selectedTab = 2
                                        }
                                    }
                                    .padding(.horizontal, AppTheme.screenPadding)
                                    .padding(.vertical, 4)
                                }
                            }
                            .frame(height: 176)
                            .padding(.bottom, 8)

                            if !dailyData.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(L10n.t(.byDays, lang)).font(.system(size: AppType.s17, weight: .semibold)).padding(.horizontal, AppTheme.screenPadding)
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(alignment: .bottom, spacing: 8) {
                                            ForEach(dailyData, id: \.0) { item in
                                                VStack(spacing: 4) {
                                                    Text("\(currency.symbol)\(Int(item.1))").font(.system(size: AppType.s12)).foregroundColor(.secondary)
                                                    let maxVal = dailyData.map(\.1).max() ?? 1
                                                    RoundedRectangle(cornerRadius: 6).fill(AppColors.gradient(.top, .bottom))
                                                        .frame(width: 36, height: max(20, CGFloat(item.1 / maxVal) * 120))
                                                    Text(item.0).font(.system(size: AppType.s12)).foregroundColor(.secondary)
                                                }
                                            }
                                        }
                                        .padding(.horizontal, AppTheme.screenPadding)
                                        .padding(.bottom, 4)
                                    }
                                }
                                .padding(.vertical, 12)
                                .appCard()
                                .padding(.horizontal, AppTheme.screenPadding)
                            }

                            if !topExpenses.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(L10n.t(.topExpenses, lang)).font(.system(size: AppType.s17, weight: .semibold)).padding(.horizontal, AppTheme.screenPadding)
                                    ForEach(Array(topExpenses.enumerated()), id: \.offset) { index, entry in
                                        HStack(spacing: 12) {
                                            ZStack { Circle().fill(AppColors.blue.opacity(0.12)).frame(width: 32, height: 32); Text("\(index + 1)").font(.system(size: AppType.s12, weight: .bold)).foregroundStyle(AppColors.gradient()) }
                                            Text(entry.text).font(.system(size: AppType.s14)).lineLimit(2)
                                            Spacer()
                                            Text("\(currency.symbol)\(Int(AmountExtractor.extract(from: entry.text) ?? 0))").font(.system(size: AppType.s14, weight: .semibold)).foregroundStyle(AppColors.gradient())
                                        }.padding(.horizontal, AppTheme.screenPadding)
                                        if index < topExpenses.count - 1 { Divider().padding(.leading, 56) }
                                    }
                                }
                                .padding(.vertical, 12)
                                .appCard()
                                .padding(.horizontal, AppTheme.screenPadding)
                            }

                        }
                        .padding(.vertical, 16)
                                                .padding(.bottom, 80)
                                                .frame(maxWidth: .infinity)
                    }
                    .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                }
            }
            .navigationTitle(L10n.t(.financeTitle, lang))

            .sheet(isPresented: $showWeeklyReport) {
                WeeklyReportView(lang: lang, entries: entries)
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("showWeeklyReportFromDiary"))) { _ in
                showWeeklyReport = true
            }
            .sheet(isPresented: $showCustomRange) {
                CustomDateRangeView(
                    lang: lang,
                    from: $customFrom,
                    to: $customTo,
                    onApply: { selectedPeriod = 3 }
                )
            }
        }
    }

    private func financeToolTile(title: String, width: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppColors.gradient())
                        .frame(width: 40, height: 40)
                        .shadow(color: AppColors.rose.opacity(0.35), radius: 10, x: 0, y: 4)
                    Image(systemName: "sparkles")
                        .font(.system(size: AppType.s17, weight: .semibold))
                        .foregroundColor(.white)
                }
                Spacer(minLength: 0)
                Text(title)
                    .font(.system(size: AppType.s17, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineSpacing(2)
            }
            .padding(14)
            .frame(width: width, height: 168, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous)
                    .fill(AppTheme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous)
                            .stroke(AppTheme.cardStroke, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - AI Assistant
struct AIAssistantView: View {
    @AppStorage("userName") var userName: String = ""
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.systemDefault.rawValue
    private var lang: AppLanguage { AppLanguage(rawValue: appLanguage) ?? .ru }

    @EnvironmentObject var navigationState: AppNavigationState
    @State var question = ""
    @State var isLoading = false
    @State var messages: [(String, String)] = []
    @StateObject var speech = SpeechManager()
    @State var isCancelling = false
    @Query(sort: \DiaryEntry.date, order: .reverse) var entries: [DiaryEntry]

    var suggestions: [(String, String)] {
        [
            (L10n.t(.suggestWeek, lang), "clock"),
            (L10n.t(.suggestSpent, lang), "rublesign.circle"),
            (L10n.t(.suggestHealth, lang), "checkmark.circle"),
            (L10n.t(.suggestPlans, lang), "calendar")
        ]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SoftBackground()
                VStack(spacing: 0) {
                    if messages.isEmpty && !isLoading {
                        VStack(spacing: 0) {
                            Spacer()

                            VStack(spacing: 2) {
                                Text(L10n.format(.assistantHelloName, lang, userName.isEmpty ? (lang == .ru ? "Илья" : "Alex") : userName))
                                    .font(.system(size: 38, weight: .regular))
                                    .foregroundColor(.primary)
                                    .multilineTextAlignment(.center)

                                Text(L10n.t(.assistantHelpLine, lang))
                                    .font(.system(size: 38, weight: .regular))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.horizontal, AppTheme.screenPadding)
                            .padding(.bottom, 24)

                            Spacer()

                            ViewThatFits {
                                VStack(spacing: 8) {
                                    HStack(spacing: 8) {
                                        SuggestionPill(text: suggestions[2].0, icon: suggestions[2].1) { ask(suggestions[2].0) }
                                        SuggestionPill(text: suggestions[3].0, icon: suggestions[3].1) { ask(suggestions[3].0) }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .center)

                                    HStack(spacing: 8) {
                                        SuggestionPill(text: suggestions[0].0, icon: suggestions[0].1) { ask(suggestions[0].0) }
                                        SuggestionPill(text: suggestions[1].0, icon: suggestions[1].1) { ask(suggestions[1].0) }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .center)
                                }

                                VStack(spacing: 8) {
                                    HStack(spacing: 8) {
                                        SuggestionPill(text: suggestions[2].0, icon: suggestions[2].1) { ask(suggestions[2].0) }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .center)

                                    HStack(spacing: 8) {
                                        SuggestionPill(text: suggestions[0].0, icon: suggestions[0].1) { ask(suggestions[0].0) }
                                        SuggestionPill(text: suggestions[1].0, icon: suggestions[1].1) { ask(suggestions[1].0) }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .center)

                                    HStack(spacing: 8) {
                                        SuggestionPill(text: suggestions[3].0, icon: suggestions[3].1) { ask(suggestions[3].0) }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .center)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.horizontal, AppTheme.screenPadding)
                            .padding(.bottom, 12)
                        }
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView(.vertical, showsIndicators: false) {
                                LazyVStack(alignment: .leading, spacing: 12) {
                                    ForEach(messages.indices, id: \.self) { i in
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack { Spacer()
                                                Text(messages[i].0).font(.system(size: AppType.s14)).foregroundColor(.white)
                                                    .padding(.horizontal, 14).padding(.vertical, 10)
                                                    .background(AppColors.gradient()).cornerRadius(18)
                                            }
                                            HStack(alignment: .top, spacing: 8) {
                                                ZStack { Circle().fill(AppColors.blue.opacity(0.1)).frame(width: 28, height: 28); Image(systemName: "sparkles").font(.system(size: AppType.s12)).foregroundStyle(AppColors.gradient()) }
                                                Text(messages[i].1).font(.system(size: AppType.s14))
                                                    .padding(.horizontal, 14).padding(.vertical, 10)
                                                    .background(Color(.systemBackground))
                                                    .cornerRadius(18)
                                                    .shadow(color: Color.black.opacity(0.05), radius: 6, x: 0, y: 2)
                                                Spacer()
                                            }
                                        }
                                    }
                                    if isLoading {
                                        HStack(spacing: 8) {
                                            ZStack { Circle().fill(AppColors.blue.opacity(0.1)).frame(width: 28, height: 28); Image(systemName: "sparkles").font(.system(size: AppType.s12)).foregroundStyle(AppColors.gradient()) }
                                            HStack(spacing: 4) {
                                                ProgressView().scaleEffect(0.7)
                                                Text(L10n.t(.thinking, lang)).font(.system(size: AppType.s14)).foregroundColor(.secondary)
                                            }
                                            .padding(.horizontal, 14).padding(.vertical, 10)
                                            .background(Color(.systemBackground))
                                            .cornerRadius(18)
                                            Spacer()
                                        }
                                        .id("loading")
                                    }
                                    Color.clear.frame(height: 1).id("bottom")
                                }
                                .padding(.horizontal, AppTheme.screenPadding)
                                .padding(.vertical, 12)
                            }
                            .onChange(of: messages.count) { _, _ in
                                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                            }
                            .onChange(of: isLoading) { _, _ in
                                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                            }
                        }
                    }

                    VStack(spacing: 6) {
                        if speech.isRecording && !speech.recognizedText.isEmpty {
                            Text(speech.recognizedText).font(.system(size: AppType.s12)).foregroundColor(.primary).padding(.horizontal, AppTheme.screenPadding).multilineTextAlignment(.center)
                        }
                        if speech.isRecording {
                            Text(isCancelling ? L10n.t(.releaseToCancel, lang) : L10n.t(.speaking, lang))
                                .font(.system(size: AppType.s12))
                                .foregroundColor(isCancelling ? AppColors.rose : .secondary)
                        }
                        HStack(spacing: 10) {
                            TextField(L10n.t(.askPlaceholder, lang), text: $question)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(AppTheme.card)
                                .overlay(RoundedRectangle(cornerRadius: AppTheme.radiusControl, style: .continuous).stroke(AppTheme.cardStroke, lineWidth: 1))
                                .cornerRadius(AppTheme.radiusControl)
                                .submitLabel(.send)
                                .onSubmit { ask(question) }

                            ZStack {
                                Circle().fill(isCancelling ? AppColors.rose : (speech.isRecording ? AppColors.rose : AppColors.blue)).frame(width: 40, height: 40)
                                Image(systemName: speech.isRecording ? "waveform" : "mic.fill").font(.system(size: AppType.s12)).foregroundColor(.white)
                            }
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in if !speech.isRecording && !speech.isFinishing { speech.startRecording() }; isCancelling = abs(value.translation.width) > 50 }
                                    .onEnded { value in
                                        if abs(value.translation.width) > 50 { speech.cancelRecording(); isCancelling = false }
                                        else { speech.stopRecording { t in if !t.isEmpty { ask(t) }; isCancelling = false } }
                                    }
                            )

                            Button(action: { ask(question) }) {
                                ZStack {
                                    Circle().fill(question.isEmpty ? AnyShapeStyle(Color(.systemGray4)) : AnyShapeStyle(AppColors.gradient())).frame(width: 40, height: 40)
                                    Image(systemName: "arrow.up").font(.system(size: AppType.s12, weight: .bold)).foregroundColor(.white)
                                }
                            }
                            .disabled(question.isEmpty || isLoading)
                        }
                    }
                    .padding(.horizontal, AppTheme.screenPadding).padding(.vertical, 8)
                    .padding(.bottom, 80)
                }
            }
            .navigationTitle(L10n.t(.tabAssistant, lang))
            .navigationBarTitleDisplayMode(.large)
            .gesture(DragGesture(minimumDistance: 10).onChanged { value in
                if value.translation.height > 10 {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            })
            .onAppear {
                if !navigationState.pendingAIQuery.isEmpty {
                    let q = navigationState.pendingAIQuery
                    navigationState.pendingAIQuery = ""
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { ask(q) }
                }
            }
            .onChange(of: navigationState.pendingAIQuery) { _, newValue in
                if !newValue.isEmpty {
                    let q = newValue
                    navigationState.pendingAIQuery = ""
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { ask(q) }
                }
            }
        }
    }

    func ask(_ q: String) {
        guard !q.isEmpty else { return }
        let userQuestion = q; question = ""; isLoading = true
        let langForQuestion = AppLanguage.detect(from: userQuestion, fallback: lang)
        Task {
            let response = await AIService.shared.ask(question: userQuestion, entries: entries, lang: langForQuestion)
            await MainActor.run { messages.append((userQuestion, response)); isLoading = false }
        }
    }
}

struct SuggestionPill: View {
    let text: String; let icon: String; let action: () -> Void
    @State private var offsetX: CGFloat = 0
    @State private var offsetY: CGFloat = 0
    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon).font(.system(size: AppType.s14, weight: .semibold)).foregroundStyle(AppColors.gradient())
                Text(text)
                    .font(.system(size: AppType.s12))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(height: 40)
            .appCard(cornerRadius: AppTheme.radiusPill)
        }
        .offset(x: offsetX, y: offsetY)
        .onAppear {
            withAnimation(.easeInOut(duration: Double.random(in: 2.8...3.8)).repeatForever(autoreverses: true)) {
                offsetX = CGFloat.random(in: -5...5)
                offsetY = CGFloat.random(in: -3...3)
            }
        }
        .buttonStyle(.plain)
    }
}

struct SettingsView: View {
    @EnvironmentObject var notificationSettings: NotificationSettings
    @AppStorage("userName") var userName: String = ""
    @AppStorage("appLanguage") var appLanguage = AppLanguage.systemDefault.rawValue
    @AppStorage("appAppearance") var appAppearance = AppAppearanceMode.system.rawValue
    @AppStorage("preferredCurrency") var preferredCurrency = AppCurrency.rub.rawValue
    @AppStorage("userGender") var userGender: String = "unspecified"
    private var lang: AppLanguage { AppLanguage(rawValue: appLanguage) ?? .ru }

    @State var showPermissionAlert = false

    var reminderOptions: [(Int, String)] {
        if lang == .ru {
            return [(15, "За 15 минут"), (30, "За 30 минут"), (60, "За 1 час"), (120, "За 2 часа"), (1440, "За 1 день")]
        } else {
            return [(15, "In 15 min"), (30, "In 30 min"), (60, "In 1 hour"), (120, "In 2 hours"), (1440, "In 1 day")]
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SoftBackground()
                List {
                    Section(header: Text(L10n.t(.profile, lang))) {
                        HStack {
                            Text(L10n.t(.name, lang)); Spacer()
                            TextField(L10n.t(.namePlaceholder, lang), text: $userName)
                                .multilineTextAlignment(.trailing)
                                .foregroundColor(.secondary)
                        }
                        Picker(lang == .ru ? "Пол" : "Gender", selection: $userGender) {
                            Text(lang == .ru ? "Не указан" : "Unspecified").tag("unspecified")
                            Text(lang == .ru ? "Мужской" : "Male").tag("male")
                            Text(lang == .ru ? "Женский" : "Female").tag("female")
                        }
                        .pickerStyle(.segmented)
                        .tint(AppColors.blue)
                    }
                    Section(header: Text(L10n.t(.language, lang))) {
                        Picker(L10n.t(.language, lang), selection: $appLanguage) {
                            Text(L10n.t(.langRu, lang)).tag(AppLanguage.ru.rawValue)
                            Text(L10n.t(.langEn, lang)).tag(AppLanguage.en.rawValue)
                        }
                        .pickerStyle(.segmented)
                        .tint(AppColors.blue)
                    }
                    Section(header: Text(lang == .ru ? "Тема" : "Appearance")) {
                        Picker(lang == .ru ? "Тема" : "Appearance", selection: $appAppearance) {
                            ForEach(AppAppearanceMode.allCases, id: \.rawValue) { mode in
                                Text(mode.title(lang)).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .tint(AppColors.blue)
                    }
                    Section(header: Text(lang == .ru ? "Валюта" : "Currency")) {
                        Picker(lang == .ru ? "Валюта" : "Currency", selection: $preferredCurrency) {
                            Text(AppCurrency.rub.title(lang)).tag(AppCurrency.rub.rawValue)
                            Text(AppCurrency.usd.title(lang)).tag(AppCurrency.usd.rawValue)
                            Text(AppCurrency.eur.title(lang)).tag(AppCurrency.eur.rawValue)
                        }
                        .pickerStyle(.segmented)
                        .tint(AppColors.blue)
                    }
                    Section(header: Text(lang == .ru ? "Экспорт данных" : "Export Data")) {
                        ExportPDFButton(lang: lang)
                    }
                    WidgetSettingsSection(lang: lang)
                    WeeklyReportSettingsSection(lang: lang)
                    Section(header: Text(L10n.t(.notifications, lang))) {
                        Toggle(L10n.t(.enableNotifications, lang), isOn: $notificationSettings.isEnabled)
                            .tint(AppColors.blue)
                            .onChange(of: notificationSettings.isEnabled) { _, newValue in
                                if newValue { NotificationManager.shared.requestPermission { granted in if !granted { notificationSettings.isEnabled = false; showPermissionAlert = true } } }
                            }
                    }
                    if notificationSettings.isEnabled {
                        Section(header: Text(L10n.t(.remindAhead, lang))) {
                            ForEach(reminderOptions, id: \.0) { option in
                                HStack {
                                    Text(option.1); Spacer()
                                    if notificationSettings.reminderMinutes == option.0 { Image(systemName: "checkmark").foregroundStyle(AppColors.gradient()) }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { notificationSettings.reminderMinutes = option.0 }
                            }
                        }
                        Section(header: Text(L10n.t(.dailyReminder, lang))) {
                            Toggle(L10n.t(.remindDiary, lang), isOn: $notificationSettings.dailyReminderEnabled)
                                .tint(AppColors.blue)
                                .onChange(of: notificationSettings.dailyReminderEnabled) { _, newValue in
                                    if newValue { NotificationManager.shared.scheduleDailyReminder(hour: notificationSettings.dailyReminderHour) }
                                    else { NotificationManager.shared.removeDailyReminder() }
                                }
                            if notificationSettings.dailyReminderEnabled {
                                let label = lang == .ru ? "В \(notificationSettings.dailyReminderHour):00" : "At \(notificationSettings.dailyReminderHour):00"
                                Stepper(label, value: $notificationSettings.dailyReminderHour, in: 0...23)
                                    .onChange(of: notificationSettings.dailyReminderHour) { _, newValue in NotificationManager.shared.scheduleDailyReminder(hour: newValue) }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.insetGrouped)
                .padding(.horizontal, 4)
                                .padding(.bottom, 80)
            }
            .navigationTitle(L10n.t(.settingsTitle, lang))
            .alert(L10n.t(.noPermissionTitle, lang), isPresented: $showPermissionAlert) {
                Button(L10n.t(.openSettings, lang)) { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                Button(L10n.t(.cancel, lang), role: .cancel) {}
            } message: { Text(L10n.t(.noPermissionMsg, lang)) }
        }
    }
}

// MARK: - Онбординг
struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding: Bool = false
    @AppStorage("userName") var userName: String = ""
    @AppStorage("appLanguage") var appLanguage = AppLanguage.systemDefault.rawValue
    private var lang: AppLanguage { AppLanguage(rawValue: appLanguage) ?? .ru }

    @State var currentPage = 0
    @State var nameInput = ""
    @State var animateContent = false

    var body: some View {
        ZStack {
            SoftBackground()

            VStack(spacing: 0) {
                Spacer()
                Group {
                    if currentPage == 0 { onbPage0 }
                    else if currentPage == 1 { onbPage1 }
                    else if currentPage == 2 { onbPage2 }
                    else { onbPage3 }
                }
                .opacity(animateContent ? 1 : 0)
                .offset(y: animateContent ? 0 : 30)
                .animation(.spring(response: 0.6, dampingFraction: 0.8), value: animateContent)

                Spacer()

                VStack(spacing: 24) {
                    HStack(spacing: 8) {
                        ForEach(0..<4, id: \.self) { i in
                            Capsule()
                                .fill(i == currentPage ? Color.white : Color.white.opacity(0.4))
                                .frame(width: i == currentPage ? 24 : 8, height: 8)
                                .animation(.spring(), value: currentPage)
                        }
                    }

                    Button(action: nextPage) {
                        HStack {
                            Text(currentPage == 3 ? L10n.t(.start, lang) : L10n.t(.next, lang))
                                .font(.system(size: AppType.s17, weight: .semibold))
                            Image(systemName: currentPage == 3 ? "checkmark" : "arrow.right")
                        }
                        .foregroundStyle(AppColors.gradient())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.white.opacity(0.9))
                        .cornerRadius(16)
                        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 4)
                    }
                    .padding(.horizontal, 32)
                    .disabled(currentPage == 2 && nameInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.bottom, 48)
            }
        }
        .onAppear { triggerAnimation() }
    }

    var onbPage0: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle().fill(Color.white.opacity(0.2)).frame(width: 140, height: 140)
                Circle().fill(Color.white.opacity(0.15)).frame(width: 110, height: 110)
                Image(systemName: "mic.fill").font(.system(size: 52)).foregroundColor(.white)
            }
            VStack(spacing: 12) {
                Text(L10n.t(.onboardingTitle, lang)).font(.system(size: AppType.s34, weight: .bold)).foregroundColor(.white)
                Text(L10n.t(.onboardingTagline, lang)).font(.system(size: AppType.s14)).foregroundColor(.white.opacity(0.85)).multilineTextAlignment(.center).lineSpacing(4)

                Picker(L10n.t(.language, lang), selection: $appLanguage) {
                    Text(L10n.t(.langRu, lang)).tag(AppLanguage.ru.rawValue)
                    Text(L10n.t(.langEn, lang)).tag(AppLanguage.en.rawValue)
                }
                .pickerStyle(.segmented)
                        .tint(AppColors.blue)
                .padding(.top, 8)
                .padding(.horizontal, 24)
            }
        }.padding(.horizontal, 32)
    }

    var onbPage1: some View {
        VStack(spacing: 32) {
            Text(L10n.t(.featuresTitle, lang)).font(.system(size: AppType.s20, weight: .bold)).foregroundColor(.white)
            VStack(spacing: 20) {
                FeatureRow(icon: "mic.circle.fill", title: L10n.t(.featureVoice, lang), subtitle: L10n.t(.diaryEmptyTitle, lang), color: .white)
                FeatureRow(icon: "sparkles", title: L10n.t(.featureAI, lang), subtitle: L10n.t(.assistantHelpLine, lang), color: .white)
                FeatureRow(icon: "chart.bar.fill", title: L10n.t(.featureFinance, lang), subtitle: L10n.t(.noFinanceTitle, lang), color: .white)
            }
        }.padding(.horizontal, 32)
    }

    var onbPage2: some View {
        VStack(spacing: 28) {
            ZStack { Circle().fill(Color.white.opacity(0.2)).frame(width: 100, height: 100); Image(systemName: "person.fill").font(.system(size: 44)).foregroundColor(.white) }
            VStack(spacing: 8) {
                Text(L10n.t(.nameQuestion, lang)).font(.system(size: AppType.s20, weight: .bold)).foregroundColor(.white)
                Text(L10n.t(.nameReason, lang)).font(.system(size: AppType.s14)).foregroundColor(.white.opacity(0.8))
            }
            TextField(L10n.t(.nameField, lang), text: $nameInput)
                .font(.system(size: AppType.s17))
                .multilineTextAlignment(.center)
                .padding(.vertical, 16).padding(.horizontal, 20)
                .background(Color.white)
                .cornerRadius(16)
                .foregroundColor(.primary)
                .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 4)
        }.padding(.horizontal, 32)
    }

    var onbPage3: some View {
        VStack(spacing: 28) {
            ZStack { Circle().fill(Color.white.opacity(0.2)).frame(width: 100, height: 100); Image(systemName: "checkmark.shield.fill").font(.system(size: 44)).foregroundColor(.white) }
            VStack(spacing: 8) {
                Text(L10n.t(.lastStep, lang)).font(.system(size: AppType.s20, weight: .bold)).foregroundColor(.white)
                Text(L10n.t(.permissionsMsg, lang)).font(.system(size: AppType.s14)).foregroundColor(.white.opacity(0.8)).multilineTextAlignment(.center)
            }
            VStack(spacing: 16) {
                PermissionRow(icon: "mic.fill", title: L10n.t(.mic, lang), subtitle: L10n.t(.diaryEmptyTitle, lang))
                PermissionRow(icon: "bell.fill", title: L10n.t(.notifs, lang), subtitle: L10n.t(.remindDiary, lang))
            }
        }.padding(.horizontal, 32)
    }

    func nextPage() {
        if currentPage == 2 { userName = nameInput.trimmingCharacters(in: .whitespaces) }
        if currentPage == 3 {
            SFSpeechRecognizer.requestAuthorization { _ in }
            AVAudioApplication.requestRecordPermission { _ in }
            NotificationManager.shared.requestPermission { _ in }
            withAnimation { hasCompletedOnboarding = true }
            return
        }
        animateContent = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { currentPage += 1; triggerAnimation() }
    }
    func triggerAnimation() { animateContent = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { animateContent = true } }
}

struct FeatureRow: View {
    let icon: String; let title: String; let subtitle: String; let color: Color
    var body: some View {
        HStack(spacing: 16) {
            ZStack { Circle().fill(Color.white.opacity(0.2)).frame(width: 52, height: 52); Image(systemName: icon).font(.system(size: AppType.s17)).foregroundColor(color) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: AppType.s14, weight: .semibold)).foregroundColor(.white)
                Text(subtitle).font(.system(size: AppType.s12)).foregroundColor(.white.opacity(0.8))
            }
            Spacer()
        }
        .padding(14)
        .background(Color.white.opacity(0.15))
        .cornerRadius(16)
    }
}

struct PermissionRow: View {
    let icon: String; let title: String; let subtitle: String
    var body: some View {
        HStack(spacing: 16) {
            ZStack { Circle().fill(Color.white.opacity(0.2)).frame(width: 48, height: 48); Image(systemName: icon).font(.system(size: AppType.s17)).foregroundColor(.white) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: AppType.s14, weight: .semibold)).foregroundColor(.white)
                Text(subtitle).font(.system(size: AppType.s12)).foregroundColor(.white.opacity(0.8))
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill").foregroundColor(.white.opacity(0.6))
        }
        .padding(14)
        .background(Color.white.opacity(0.15))
        .cornerRadius(16)
    }
}

#Preview {
    ContentView().modelContainer(for: DiaryEntry.self, inMemory: true)
}
