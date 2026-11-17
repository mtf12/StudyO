import SwiftUI

/// App language. Follows the system language unless the user picks one in Settings.
final class Lang: ObservableObject {
    static let shared = Lang()
    /// "system", "ar" or "en".
    @Published var setting: String {
        didSet {
            UserDefaults.standard.set(setting, forKey: "lang")
            code = Self.resolve(setting)
        }
    }
    /// The language actually in use: "ar" or "en".
    @Published private(set) var code: String
    var isArabic: Bool { code == "ar" }
    var direction: LayoutDirection { isArabic ? .rightToLeft : .leftToRight }

    private init() {
        let saved = UserDefaults.standard.string(forKey: "lang") ?? "system"
        setting = saved
        code = Self.resolve(saved)
    }

    private static func resolve(_ setting: String) -> String {
        if setting == "ar" || setting == "en" { return setting }
        let system = Locale.preferredLanguages.first ?? "en"
        return system.hasPrefix("ar") ? "ar" : "en"
    }
}

/// Returns the text in the current app language. English is the key.
func L(_ english: String) -> String {
    Lang.shared.isArabic ? (arabic[english] ?? english) : english
}

private let arabic: [String: String] = [
    "Open…": "فتح…",
    "Add Subtitle File…": "إضافة ملف ترجمة…",
    "Playback": "التشغيل",
    "Play / Pause": "تشغيل / إيقاف مؤقت",
    "Back 10 s": "رجوع ١٠ ثوانٍ",
    "Forward 10 s": "تقديم ١٠ ثوانٍ",
    "Full Screen": "ملء الشاشة",
    "Display": "العرض",
    "Open Video…": "فتح فيديو…",
    "Choose a video or audio file": "اختر ملف فيديو أو صوت",
    "Choose a subtitle file (.srt, .ass, .vtt…)": "اختر ملف ترجمة (.srt, .ass, .vtt…)",
    "Could not start the video engine.": "تعذّر تشغيل محرك الفيديو.",
    "This file could not be opened.": "تعذّر فتح هذا الملف.",
    "This file could not be played.": "تعذّر تشغيل هذا الملف.",
    "Back 10 seconds": "رجوع ١٠ ثوانٍ",
    "Forward 10 seconds": "تقديم ١٠ ثوانٍ",
    "Play / Pause (Space)": "تشغيل / إيقاف مؤقت (مسافة)",
    "Mute (M)": "كتم الصوت (M)",
    "Playback speed": "سرعة التشغيل",
    "Subtitles": "الترجمة",
    "Off": "إيقاف",
    "Audio track": "مسار الصوت",
    "Full screen (F)": "ملء الشاشة (F)",
    "Look again for AIs on this Mac": "ابحث من جديد عن أدوات الذكاء الاصطناعي على هذا الجهاز",
    "Choose an AI": "اختر ذكاءً اصطناعيًا",
    "Start Ollama": "تشغيل Ollama",
    "What is on screen right now?": "ماذا يظهر على الشاشة الآن؟",
    "Explain this scene": "اشرح هذا المشهد",
    "Read the text on screen": "اقرأ النص الظاهر على الشاشة",
    "Ask about this moment…": "اسأل عن هذه اللحظة…",
    "Open a video, then ask…": "افتح فيديو ثم اسأل…",
    "Stop": "إيقاف",
    "Send": "إرسال",
    "Jump back to this moment": "ارجع إلى هذه اللحظة",
    "Thinking…": "يفكّر…",
    "Stopped.": "تم الإيقاف.",
    "No answer came back.": "لم يصل أي رد.",
    "Not connected": "غير متصل",
    "Connected": "متصل",
    "Connect": "ربط",
    "Disconnect": "قطع الاتصال",
    "Cancel": "إلغاء",
    "Checking your account…": "جارٍ التحقق من الحساب…",
    "Finish signing in in your browser, then come back here.": "أكمل تسجيل الدخول في المتصفح ثم عُد إلى هنا.",
    "Sign-in was not completed.": "لم يكتمل تسجيل الدخول.",
    "Connect an AI first.": "سجّل الدخول إلى المساعد أولًا.",
    "Sees the current frame": "يرى اللقطة الحالية",
    "Not installed": "غير مثبّت",
    "Install Claude Code, then press refresh.": "ثبّت Claude Code ثم اضغط تحديث.",
    "No models downloaded": "لا توجد نماذج محمّلة",
    "Download a vision model in Terminal: ollama pull llava": "حمّل نموذجًا يدعم الصور من Terminal: ollama pull llava",
    "Ollama · sees the current frame": "Ollama · يرى اللقطة الحالية",
    "Ollama · text only (no frame)": "Ollama · نص فقط (بدون لقطة)",
    "Installed, not running": "مثبّت لكنه لا يعمل",
    "Ollama is installed but its server is not running.": "Ollama مثبّت لكن الخادم لا يعمل.",
    "New chat": "محادثة جديدة",
    "Nothing installed yet": "لا يوجد مساعد مثبّت",
    "Ask about this moment": "اسأل عن هذه اللحظة",
    "Sign in once, then ask about any moment of your video.": "سجّل الدخول مرة واحدة، ثم اسأل عن أي لحظة في الفيديو.",
    "Runs on this Mac. No account needed.": "يعمل على هذا الجهاز دون حساب.",
    "Sees the frame you are watching": "يرى اللقطة التي تشاهدها",
    "Reads the subtitles around it": "يقرأ الترجمة المصاحبة لها",
    "Only runs when you ask": "يعمل فقط عندما تسأل",
    "Sign In": "تسجيل الدخول",
    "Open sign-in page": "فتح صفحة الدخول",
    "Uses the account you already have in": "يستخدم حسابك الحالي في",
    "Drop to play": "أفلِت الملف للتشغيل",
    "Open a video, or drop one anywhere in this window.": "افتح فيديو أو اسحبه إلى أي مكان في النافذة.",
    "Settings": "الإعدادات",
    "General": "عام",
    "Shortcuts": "الاختصارات",
    "Language": "اللغة",
    "Left": "اليسار",
    "Right": "اليمين",
    "Keep the window on top while playing": "إبقاء النافذة في المقدمة أثناء التشغيل",
    "Continue each video where I stopped": "متابعة كل فيديو من حيث توقفت",
    "Start playing as soon as a video opens": "بدء التشغيل فور فتح الفيديو",
    "Repeat the video when it ends": "إعادة الفيديو عند انتهائه",
    "Arrow keys skip": "مقدار التنقل بالأسهم",
    "seconds": "ثوانٍ",
    "Default speed": "السرعة الافتراضية",
    "Remember the volume": "تذكّر مستوى الصوت",
    "Load a subtitle file with the same name as the video": "تحميل ملف الترجمة الذي يحمل اسم الفيديو",
    "Subtitle size": "حجم الترجمة",
    "Small": "صغير",
    "Normal": "عادي",
    "Large": "كبير",
    "Very large": "كبير جدًا",
    "The size applies the next time you open StudyO Player.": "يُطبَّق الحجم عند فتح StudyO Player في المرة القادمة.",
    "No assistant found": "لا يوجد مساعد",
    "Account": "الحساب",
    "Send the current frame with my question": "إرسال اللقطة الحالية مع سؤالي",
    "Send nearby subtitle lines": "إرسال سطور الترجمة القريبة",
    "Answer language": "لغة الرد",
    "Same as my question": "لغة السؤال نفسها",
    "Skip back / forward": "رجوع / تقديم",
    "Volume": "مستوى الصوت",
    "Mute": "كتم الصوت",
    "Open a video": "فتح فيديو",
    "Spread or pinch two fingers": "فتح أو ضمّ إصبعين",
    "Instructor": "المعلّم",
    "Previous chats": "المحادثات السابقة",
    "Your chats will appear here.": "ستظهر محادثاتك هنا.",
    "Delete": "حذف",
    "Delete All": "حذف الكل",
    "Saved chats": "المحادثات المحفوظة",
    "ChatGPT model": "نموذج ChatGPT",
    "Gemini model": "نموذج Gemini",
    "Paste your API key. It is kept in your Mac's Keychain.": "الصق مفتاح API. يُحفظ في سلسلة المفاتيح على جهازك.",
    "API key": "مفتاح API",
    "Get an API key": "الحصول على مفتاح API",
    "Paste your API key first.": "الصق مفتاح API أولًا.",
    "Checking your key…": "جارٍ التحقق من المفتاح…",
    "The key could not be saved to the Keychain.": "تعذّر حفظ المفتاح في سلسلة المفاتيح.",
    "Drag to resize": "اسحب لتغيير الحجم",
    "Pause on anything and ask. Your instructor sees the frame you are watching.": "توقّف عند أي لقطة واسأل. مُعلّمك يرى ما تشاهده الآن.",
    "Show or hide the assistant": "إظهار أو إخفاء المعلّم",
    "About StudyO Player": "حول StudyO Player",
    "Free Edition": "النسخة المجانية",
    "Contact Support…": "التواصل مع الدعم…",
    "Version": "الإصدار",
    "All rights reserved.": "جميع الحقوق محفوظة.",
    "StudyO Player collects no data.": "StudyO Player لا يجمع أي بيانات.",
    "Appearance": "المظهر",
    "System": "النظام",
    "Light": "فاتح",
    "Dark": "داكن",
    "Show Instructor": "إظهار المعلّم",
    "Hide Instructor": "إخفاء المعلّم",
    "Instructor on the Left": "المعلّم على اليسار",
    "Instructor on the Right": "المعلّم على اليمين",
    "Instructor panel side": "موضع لوحة المعلّم",
    "Study with your AI": "ذاكر مع الذكاء الاصطناعي",
    "%@ was not found.": "تعذّر العثور على %@.",
    "%@ stopped with an error (code %d).": "توقّف %@ بسبب خطأ (الرمز %d).",
    "ChatGPT reported an error.": "أبلغ ChatGPT عن خطأ.",
    "Claude Code reported an error.": "أبلغ Claude Code عن خطأ.",
    "No Ollama model selected.": "لم يتم اختيار نموذج Ollama.",
    "Ollama returned an error (HTTP %d).": "أعاد Ollama خطأ (HTTP %d).",
]
