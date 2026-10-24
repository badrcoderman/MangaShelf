# جسر أوامر المصدر الحقيقي — 24 أكتوبر 2026

## ما نُفذ

أضيفت نقطة دخول ثابتة مملوكة للمشروع:
`mangashelf/host/SourceRuntime.dispatch(String, String): String`، لاختيارها
صراحةً عند تركيب محوّل JNI. تستعمل `ExtensionLoader` المتحقق و`SourceRegistry`
وواجهات Source 1.6 الفعلية، ثم تحول النماذج داخل حجز المصدر إلى JSON.
الـrunner القديم الذي يتوقع من الإضافات إرجاع نص JSON ليس هذا المحرك.

اجتاز مرشح MangaDex العام المثبت خمس حالات دون شبكة وتسع حالات مع الشبكة،
منها configure/load/sources/unload/close عبر نقطة الدخول الجديدة، ثم
popular → update → pages مع بيانات المصدر المحفوظة. سجلت الجلسة 9 فصول
و23 صفحة في هذا المسار. هذه استدعاءات Java مباشرة على المضيف؛ لا تثبت
الاستدعاء الكامل من Swift/JNI على iPhone.

- [المرشح المثبت وحدود شهادة debug](MANGADEX-HOST-EXECUTION-AR.md).
- [دون شبكة](../validation/mangadex-source-host.json) /
  [الشبكة المباشرة](../validation/mangadex-source-live-host.json).
- [اختبارات التحويل المؤلفة](../validation/runtime-source-commands-host.json).
- [21 حالة تحميل موقّع مؤلفة](../validation/extension-loader-host.json)،
  منها إغلاق نقطة الدخول أثناء HTTP وانتظار تنظيف interceptor قبل إغلاق
  الأرشيف وخدمات التطبيق.

تأكيد CI عند `b6c9ebe`: نجح المحرك وC/JNI على Linux وmacOS في
[40045606077](https://github.com/badrcoderman/MangaShelf/actions/runs/40045606077).
طابقت بصمات المصادر وartifacts ذات 20/28 ملفًا وCRC، وتطابقت JAR بين
المنصتين. نجحت 7 حالات تحويل و21 تحميلًا موقّعًا، بينها تمييز مهلة المصدر
عن الإلغاء، و12 حالة C لكل نمط و17 codec لكل نمط، وأعيد compile/link
لـarm64 iOS مع 27 object و11 رمز JNI دون test hooks.
[تقرير الفحص](../validation/runtime-host-40045606077.json).

نجح أيضًا [بناء iOS 40045605922](https://github.com/badrcoderman/MangaShelf/actions/runs/40045605922):
137 اختبار Swift، واحد متجاوز لفقد مدخل snapshot الاختياري، وصفر فشل؛
اجتازت الحالات السبع الجديدة. فُحصت IPA من 66 عضوًا وarm64/iOS 26، وثُبت
وجود رمزي الرد المملوك وتحريره في executable. رقمها ما زال 0.5.0 build 6؛
لا تحمل JAR المضيف أو صورة JVM، ولم تُختبر على iPhone.
[أدلة الاختبارات وIPA](../validation/ios-40045605922.json).

## العقد

| الأمر | المدخلات الأساسية | النتيجة |
| --- | --- | --- |
| ping | كائن فارغ | حالة المضيف وschemaVersion 1 |
| configure | dataDirectory مطلق، applicationId، versionName، versionCode، userAgent، platformRelease الحقيقي | configured |
| load | package، path، archiveSha256، trustedCertificateSha256، versionCode، versionName، mainClass، sources بــid/language | loaded وقائمة المصادر الفعلية |
| sources | كائن فارغ | قائمة id/package/name/language |
| unload | package | unloaded بعد انتهاء تحرير الحزمة |
| popular/latest | sourceId، page ابتداءً من 1 | mangas وhasNextPage المصدر |
| search | السابق مع query | صفحة النتائج |
| details/chapters/update | sourceId، url، وsourceMetadataJSON إن وجدت | التفاصيل أو الفصول أو كلاهما |
| pages | sourceId، url الفصل، وsourceMetadataJSON إن وجدت | الصفحات بترتيب المصدر |
| close | كائن فارغ | closed بعد إلغاء العمل المملوك وانتظاره وإغلاق الخدمات |

معرّفات المصادر نصوص decimal من Long، وليست أرقام floating point.
load يتطلب بصمة الحزمة وشهادة موثوقة صراحةً ومطابقة المصدر/الإصدار وmetadata؛
حقول package/path/mainClass القديمة وحدها لا تكفي. لا يمنح هذا العقد ثقة
تلقائية لمفتاح مستودع أو لشهادة debug.

الأخطاء كائن `error` برمز من المضيف، ولا تعبر exception أو نماذج الإضافة
حدود الحجز. closing يمنع عملًا جديدًا ويلغي مهام المضيف وينتظرها، ثم يغلق
السجل والخدمات. close لا يدمر JVM العملية أو يعيد تشغيلها، ولا يفرض إيقاف
خيط غير متعاون أنشأته إضافة بنفسها. يوجد حد 16 عملية مملوكة متزامنة ومهلة
90 ثانية للعمل المتعاون؛ تنظيف الإلغاء قد يستغرق أطول إذا تجاهله المصدر.

## حفظ حالة المصدر

يحمل `sourceMetadataJSON` غلافًا بإصدار 1 ونوع manga/chapter/page ومعرّف
المصدر والحقول الأصلية. يتضمن جميع حقول SManga/SChapter العامة وmemo،
ويحتفظ للصفحة بـindex وurl وimageUrl الخام. يعاد التحقق من النوع ومعرّف
المصدر والرابط قبل بناء نموذج الطلب التالي.

dateUpload في رد الفصول ثواني Unix المناسبة لـReaderCore؛ تبقى القيمة الأصلية
بميلي ثانية في الغلاف. فهرس الصفحة المعروض كثيف من صفر حسب ترتيب القائمة؛
يبقى index الأصلي في sourceIndex والغلاف، حتى إن تكرر أو لم يكن مرتبًا.
تحل روابط الصور عبر imageRequest المصدر. لا ينزل هذا الأمر جسم الصور بعد.

أضيف الغلاف الاختياري إلى نماذج Swift والمكتبة والفصول وكاش الصفحات، مع
استمرار فك البيانات القديمة التي لا تحمله. يُرفض كاش يتجاوز 4 MiB قبل حذف
صور الكاش السابق. لا يغير ذلك صيغة نسخ MSL الحالية إلى TMB.

## الاستجابة المملوكة والخيط العامل

تعرض CSafeArchive الآن `ms_bridge_dispatch_owned` و`ms_bridge_free_string`
من دون رؤوس JNI في Swift. يسجل المحوّل الأصلي واجهتي الرد معًا. تُنفذ
العملية مرة واحدة، ويُحرر التخصيص بعد فك UTF-8. الحد 16 MiB للمحوّل المملوك؛
تبقى استدعاءات callbacks القديمة بحدها 16 KiB دون إعادة تنفيذ لتكبير المخزن.
تُرفض حدود الرد التالفة وNUL الداخلية، وتبقى المخرجات NULL/zero عند الخطأ.

اجتازت 12 حالة C لكل من strict وASan/UBSan مع كشف التسرب محليًا، واجتاز
الجسر المشترك محوّل JNI الحقيقي باستخدام JAR المشروع، بما في ذلك رد كبير
وUnicode والاستثناءات والتزامن وعمر attach/detach.
[C](../validation/bridge-test-results.json) /
[JNI](../validation/java-bridge-host.json).

تنقل طرق ExtensionRuntime المعلقة الاستدعاء الحاجب إلى worker. إلغاء Swift
قبل بدء worker يمنع العمل، وبعد بدء JNI ينتظر الرد ثم يتجاهل نتيجة المصدر
المتأخرة. تستهلك load/unload إقرار العملية أولًا لتحديث حالة الحزمة المحلية،
ثم تبلغ الإلغاء. الربط بإلغاء طلب Java منفرد عبر قناة تحكم ما زال مطلوبًا.

## المتبقي لتفعيل تطبيق iPhone

1. بدء JVM وتركيب هذا المدخل من مسار التطبيق الرئيسي، وتغليف JAR المضيف
   وتبعياتها وإشعارات الرخص ومكتبات JVM/Zstd الملائمة لـiOS.
2. تمرير بصمات الثقة وmetadata الكاملة من مخزن الحزم إلى load، وتوصيل
   coordinator المشترك بالمخزن والإزالة وسحب الثقة. لا تزال API التحميل
   القديمة في Swift تحتاج هذا الاستبدال؛ لا يتجاوز المحرك التحقق لتقبلها.
3. تنزيل الصور باستخدام imageRequest وعميل المصدر وheaders/cookies
   والتجديد، ثم حفظها في كاش التطبيق؛ طلب URLSession عارٍ لا يكفي.
4. إثبات الجسر وTLS والمصدر والضغط والإلغاء على iPhone، ثم مسار التطبيق
   الكامل وإنتاج IPA قابلة للاختبار. نجاح host أو بناء unsigned وحده لا
   يغلق هذه البوابة.

مطابقة الواجهة والإعدادات والخطوط والألوان والنسخ والاستعادة ما زالت في
[TODO](../TODO.md). Wi-Fi مؤجل بطلب المستخدم.
