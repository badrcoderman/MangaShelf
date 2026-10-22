# فحص محرك Java على iPhone

هذا تطبيق تشخيص منفصل باسم **MSL Engine Check** وبمعرّف `app.mangashelf.enginecheck`.
يُبنى المحرك وملفات Java الأساسية من مصدر OpenJDK Mobile المثبت، مع libffi.
لا يتضمن أي كود من IPA المرجعي، ولا يغيّر مكتبة MangaShelf.

## ما الذي يتحقق منه؟

آخر نتيجة هاتف: بدأ المحرك على iOS 26.2، ثم فشل اختبار الاسم العربي بسبب
ترميز مسارات النظام. يجري تصحيح مصدر JVM وإعادة البناء؛
[السبب والنتيجة المحددة](IOS-JVM-UTF8-AR.md). لا تُعاد تجربة النسخة القديمة
39806485937 لإثبات إصلاح الترميز.

زر «بدء فحص المحرك» يستدعي `JNI_CreateJavaVM` على خيط مستقل، ثم يشغّل كودًا
كتبناه داخل JAR منفصل لاختبار تحميل الأصناف والانعكاس والعربية وemoji وخيط Java
وGZIP والقراءة والكتابة داخل مجلد التطبيق. النتيجة `passed` لا تثبت توافق إضافات
Tachiyomi أو عمل البحث والفصول أو وصول الشبكة.

يتضمن الفحص أيضًا Files.probeContentType لملف نصي باسم عربي وملف PNG،
ويطلب text/plain وimage/png. هذا يفحص نوع الملف بالامتداد، لا فك الصورة.
تتطلب النسخة الحالية runtime يحوي [تنفيذ نوع الملف على iOS](IOS-FILETYPE-AR.md).

بعد اختبار JAR يستدعي native طريقة echo بالعربية وemoji، ثم يتحقق من أن
النتيجة المطابقة عبرت Java→UTF-8→NSString. لا يشمل ذلك NUL المضمّن في واجهة
C-string، أو استثناءات JNI عند OOM، أو كل خيارات عمر VM. تسجل أخطاء fixture
إلى stderr قبل إعادة رميها كي لا تختفي أسبابها عندما يمسحها الجسر.

فُحصت طريقتا fixture الجديدتان على Java 27 في المضيف: تحميل JAR المشروع،
والـecho، وتسجيل استثناء متوقع ثم إعادة رميه. النتيجة في
[ios-device-fixture-host.json](../validation/ios-device-fixture-host.json)،
ويعيدها `python3 scripts/test-ios-device-fixture.py`. هذا لا يثبت JNI أو iOS.

## البناء

1. شغّل `Build experimental iOS JVM` على الفرع المطلوب، وانتظر النجاح. يجب أن
   يتضمن artifact ملف `jre/lib/modules` وتقرير `build-provenance.json`.
2. شغّل `Link experimental iOS JVM` وأدخل رقم التشغيل الناجح في `runtime_run_id`
   مع تفعيل `device_ipa=true`.
   يتحقق المسار من المستودع والـcommit ونجاح التشغيل وبصمة artifact وملفات المحرك.
3. حمّل artifact باسم `MangaShelfEngineCheck-unsigned`. ملف IPA يحتاج توقيعك قبل
   التثبيت، ويتطلب iOS 26.0 أو أحدث.

لا يُعاد استخدام المحاولة القديمة `39382504723` لبناء هذا التطبيق: تلك النسخة
تحتوي المكتبات الأصلية فقط، دون ملفات Java الضرورية لبدء المحرك.

نجح بناء الصورة الكاملة في
[39769103017](https://github.com/badrcoderman/MangaShelf/actions/runs/39769103017)
عند `c465f19`؛ فُحص artifact وmanifest وبصمات المكتبات وملفات Java الأساسية.
[دليل الصورة](../validation/ios-jvm-image-39769103017.json) يثبت البناء فقط.

نسخة الفحص السابقة متاحة في
[39806485937 — MangaShelfEngineCheck-unsigned](https://github.com/badrcoderman/MangaShelf/actions/runs/39806485937/artifacts/12438686011)،
عند `2075088a71636a3d5f127534cbb916b1ed2e3905`، من المحرك المبني في 39769103017.
حجم IPA بعد فك ZIP هو 36482531 بايت، وSHA-256:
`f38cff553e4eeb6a60a4db4f9bd5c355b0ccfae7ee652e62db7333bfa3f4860a`.
فُحصت بصمة artifact وCRC و207 أعضاء، ومنصة ARM64 iOS 26 وعدم وجود توقيع،
ومطابقة 196 ملفًا لصورة Java، وJAR المشروع وjrt-fs المبنية من مصدر JDK؛
[دليل IPA](../validation/ios-jvm-device-39806485937.json).
نتيجة التشغيل على الهاتف ما زالت مطلوبة.

## مكان ملفات Java داخل تطبيق الفحص

المراجعة المثبتة تهيئ مسار Java من موقع executable قبل قراءة خيارات VM:
[threads.cpp](https://github.com/openjdk/mobile/blob/c1ed06aaef34c8dccf71e236d1ffa20918a77cfb/src/hotspot/share/runtime/threads.cpp#L480)،
[os_bsd.cpp](https://github.com/openjdk/mobile/blob/c1ed06aaef34c8dccf71e236d1ffa20918a77cfb/src/hotspot/os/bsd/os_bsd.cpp#L492).
في فرع iOS الساكن يصبح home هو `MangaShelfEngineCheck.app/lib`؛ ويبحث
[set_boot_path](https://github.com/openjdk/mobile/blob/c1ed06aaef34c8dccf71e236d1ffa20918a77cfb/src/hotspot/share/runtime/os.cpp#L1501)
عن `lib/lib/modules` نسبةً إلى حزمة التطبيق. وضع الصورة تحت `jre` يفشل
هذا الفحص قبل أن يصل التنفيذ إلى `-Djava.home`.

لذلك يضع سكربت التغليف الصورة الكاملة تحت `app/lib` ويمرر المكان نفسه إلى
`ms_java_start`. لا توجد نسخة ثانية من modules أو روابط رمزية. فُحص
`linkType.o` من المكتبة المبنية كتعليمات ARM64: تعيد الدالة
`is_vm_statically_linked()` القيمة 1؛ يطابق هذا اختيار
[linkType.cpp](https://github.com/openjdk/mobile/blob/c1ed06aaef34c8dccf71e236d1ffa20918a77cfb/src/hotspot/share/runtime/linkType.cpp)
عند STATIC_BUILD. هذا فحص ساكن للمسار، ويبقى بدء VM على الهاتف مطلوبًا.

يُستخدم مسار link المسجل سابقًا كي يمكن تشغيله على فرع التطوير عبر CLI دون
دمج workflow جديدة في الفرع الافتراضي؛ تفاصيل القيد في
[توثيق GitHub](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_dispatch).

## اختبار الهاتف

افتح التطبيق، واضغط «بدء فحص المحرك»، ثم «مشاركة تقرير المحرك» بعد ظهور النتيجة.
إذا أغلق التطبيق أثناء بدء المحرك، افتحه مجددًا وشارك التقرير قبل تكرار الفحص؛
يحتفظ بالتقرير السابق ومرحلة التنفيذ الأخيرة وسجل `runtime.log` وأي `hs_err*.log`.
النتائج موجودة أيضًا داخل Files → On My iPhone → MSL Engine Check → EngineCheck.

المحرك يدعم محاولة بدء واحدة داخل العملية. لتكرارها أغلق التطبيق من مبدّل
التطبيقات وافتحه مجددًا. لا يوجد زر إيقاف أو ادعاء بأن إعادة إنشاء JVM في العملية
نفسها آمنة. إعادة اتصال المشهد وحدها لا تعيد المحاولة.

## بعد نجاح الفحص

يبقى ربط Swift بالمحرك، وتهيئة توافق Android/Kotlin/Rx/OkHttp، وتحميل
`SourceFactory` وتسجيل معرّفات مصادره، ثم اختبار مصدر حقيقي من البحث حتى الصور.
هذه البنود ضمن ENG-02..ENG-11 في [TODO](../TODO.md).
