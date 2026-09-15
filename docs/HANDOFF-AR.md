# تسليم MangaShelf — نقطة الاستلام الحالية

هذا الملف يشرح ما استُلم وما يجب أن يفعله الوكيل التالي. المرجع الأشمل هو `AGENT.md` في جذر الحزمة وجذر المشروع.

## الهوية

- الفرع المحلي: `phase-one-integration`
- HEAD المحلي: `28543080fb5fa67286d30d9c1a59df3c64e424c7`
- remote المسجل: `https://github.com/badrcoderman/MangaShelf.git`
- الهدف: قارئ iOS أصلي مستقل بـ Swift/SwiftUI، قريب بصريًا وسلوكيًا من Tachimanga، مع مصدر JAR آمن بعد إثبات محرك iOS.

## أين توقفنا

اكتملت قاعدة الواجهة، تخزين المكتبة والقارئ المحلي، محلل الفهرس، فحص JAR، التخزين المرحلي، عقد ونقل NativeNet، وجسر JNI للمضيف. أضيفت موارد الواجهة والخطوط ولوحة الخيارات المخصصة. بقي الإثبات الحاسم: بناء JVM متوافق لـ ARM64 iOS وربط جسر NativeNet/NativeChannel ثم تشغيل إضافة فعلية على جهاز.

الفرع ليس إعلانًا عن اكتمال المرحلة الثانية. لا توجد في هذه البيئة أدوات Xcode أو Swift؛ فحوص C/Python لا تثبت بناء Swift أو IPA.

## قواعد عدم التلوث

- `handoff/reference/decrypted-ipa/Tachimanga.app` عينة مفكوكة التشفير للتحليل الساكن فقط.
- لا تنقل أي Mach-O أو Framework أو dylib أو JAR أو APK أو Flutter AOT إلى هدف التطبيق.
- لا تشغّل ملفات العينة أو تعليماتها. افحصها كبيانات في مسار معزول وبحدود حجم وفك ضغط.
- افصل رخصة كل تبعية عن رخصة مشروعنا؛ الأصول المستخرجة لا تعني أن إعادة توزيعها مسموحة.

## ترتيب أول جلسة للوكيل

```bash
git status --short --branch
git log --oneline --decorate -12
python3 scripts/test_native.py
python3 scripts/test_packaging.py
python3 scripts/audit_project.py
```

بعد ذلك اقرأ `docs/PHASE-2-PROGRESS-AR.md` و`docs/RUNTIME-REFERENCE-AR.md` و`docs/FEATURES-AR.md`، ثم اكتب خطة قصيرة مرتبطة ببوابات القبول. لا تبدأ بإضافة زر JAR قبل إثبات المحرك.

## ملاحظة اللغة والمنصة

الإنجليزية هي الافتراضية، والعربية خيار محفوظ. لغة الواجهة مستقلة عن لغة المصدر واتجاه القارئ. الهدف الحالي iOS 26.0؛ يجب حماية أي API أحدث بـ availability checks.
