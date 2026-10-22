# فحص محرك Java على iPhone

هذا تطبيق تشخيص منفصل باسم **MSL Engine Check** وبمعرّف `app.mangashelf.enginecheck`.
يُبنى المحرك وملفات Java الأساسية من مصدر OpenJDK Mobile المثبت، مع libffi.
لا يتضمن أي كود من IPA المرجعي، ولا يغيّر مكتبة MangaShelf.

## ما الذي يتحقق منه؟

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
