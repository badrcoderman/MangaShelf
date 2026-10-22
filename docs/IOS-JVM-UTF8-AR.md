# فشل أسماء الملفات العربية في فحص iPhone

وصل تقرير المستخدم من iOS 26.2 لنسخة الفحص عند `2075088` والمحرك المبني في
`39769103017`: نجح بدء VM (`start_code=0`)، ثم فشل استدعاء Java
(`call_code=5`) عند `Files.createTempFile` للاسم العربي، مع
`java.nio.file.InvalidPathException` داخل `UnixPath.encode`.
[التقرير المنقول وحدوده](../validation/ios-jvm-device-39806485937-iphone-report.json).
تكرار نص التقرير لا يعد محاولات مستقلة. لم يكتمل فحص MIME أو JNI echo أو
تنفيذ إضافة حقيقية.

## السبب والتصحيح

في مصدر OpenJDK Mobile المثبت عند `c1ed06aaef34c8dccf71e236d1ffa20918a77cfb`،
يفرض
[java_props_md.c](https://github.com/openjdk/mobile/blob/c1ed06aaef34c8dccf71e236d1ffa20918a77cfb/src/java.base/unix/native/libjava/java_props_md.c#L448)
UTF-8 لمسارات MACOSX فقط. يأخذ فرع iOS ترميز اللغة المحلية؛ في `C` يمكن
أن يكون ASCII، فيرفض UnixPath المحارف العربية قبل إنشاء الملف.
اختلاف file.encoding الافتراضي إلى UTF-8 لا يغير codec مسارات النظام.

تستبدل
[SystemProps](https://github.com/openjdk/mobile/blob/c1ed06aaef34c8dccf71e236d1ffa20918a77cfb/src/java.base/share/classes/jdk/internal/util/SystemProps.java#L77)
قيم sun.jnu.encoding وnative.encoding أثناء البدء، لذلك لا يصلح تمرير
`-Dsun.jnu.encoding=UTF-8` كتصحيح لهذا المسار.

أضيف فرع iOS صريح يختار UTF-8 لكل من native encoding وfilesystem encoding،
مع إبقاء استخراج لغة/بلد المستخدم وسلوك المنصات الأخرى. تحتاج المكتبة
الأصلية libjava إلى إعادة البناء؛ لا تُعدل خصائص NIO بعد تهيئتها ولا يحذف
الاختبار العربي.

## التحقق المنفذ

- يثبت التحضير SHA-256 لملف java_props_md.c ضمن 13 مدخلًا قبل أي كتابة.
- يجمع `verify-ios-jvm-encoding.py` ملف الخصائص الأصلي والمعدل كاملًا على
  Linux، مع رؤوس أصلية مثبتة وstubs محددة لـJNI وخدمات macOS. أظهر فرع
  iOS في `C` الانتقال من ASCII إلى UTF-8 مع بقاء اللغة en؛ بقيت نتائج
  macOS وLinux وBSD كما كانت.
- على macOS يستعمل الفاحص فرع اختيار الترميز الأصلي المقتطع ويجمعه كـC،
  مع تسجيل نطاقه الأضيق صراحة؛ ترجمة الملف الكامل لـiOS تتحقق في بناء JVM.
- يرفض فحص المصدر غياب إصلاح الترميز وتغير المدخلات وتكرار التصحيح.
  [نتيجة المصدر](../validation/ios-jvm-source-fixes.json) لا تثبت تشغيل جهاز.
- بقي اسم ملف MIME العربي الأصلي. أضيف اختبار قراءة/كتابة/تعداد مسار عربي
  وemoji والتحقق من UTF-8 URI والتنظيف. نجح على Java 27 في المضيف، مع
  تسجيل خصائص الترميز قبل الاستثناء المتوقع؛
  [نتيجة fixture](../validation/ios-device-fixture-host.json).

## نسخة الهاتف التالية

نسخة MSL Engine Check التالية 0.1.1، البناء 2. تحفظ JVM/file diagnostics
في report.json قبل بدء فحوص الملفات، وتشترط runtime يحمل إصلاح UTF-8
في manifest لتمنع إعادة استعمال الصورة السابقة بالخطأ. يبقى الحد الأدنى
iOS 26.0، وتبقى المحاولة واحدة داخل العملية.

نجح بناء صورة المحرك المصححة عند `0e792191ce5b85c66384682f20af37e8e89f16d5`
في [39818913578](https://github.com/badrcoderman/MangaShelf/actions/runs/39818913578).
طابقت بصمة artifact `15230e0d9a6c8e38cf2c90442a74ae529135e836a06295f32d7bb1e8eb9d346e`،
وتحققت البصمات الـ35 في manifest وملف C المصحح ووجود modules وtzdb وjava.security.
تغيرت بصمة libjava.a إلى
`b30fbec807fe569ac58e5b17481dabb0a27e4f7dc26193740b370c888ae3d959`؛
[دليل البناء والتحقق](../validation/ios-jvm-image-39818913578.json).

نجح بناء IPA المصححة 0.1.1، البناء 2، وفحصها في
[39823313828](https://github.com/badrcoderman/MangaShelf/actions/runs/39823313828).
[التنزيل وإعادة اختبار الهاتف](IPHONE-ENGINE-CHECK-AR.md#النسخة-المصححة-011-البناء-2)؛
وصل تقرير الهاتف الجديد بنتيجة passed على iOS 26.2، وبخصائص UTF-8 كلها
وunicode_roundtrip=true. اجتازت مسارات العربية وemoji وMIME وJNI؛
[الإثبات المنقول وحدوده](../validation/ios-jvm-device-39823313828-iphone-report.json).
هذا يغلق فشل الترميز واختبار fixture الحالي، مع بقاء إغلاق VM وتشغيل
المصادر الحقيقية وبقية JNI ضمن ENG-01/05/11/12.
