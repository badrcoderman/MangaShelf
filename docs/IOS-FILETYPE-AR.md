# نوع الملف في محرك iOS التجريبي

المصدر المثبت لـOpenJDK Mobile ينشئ CFString في UTIFileTypeDetector، ثم يحجب
على iOS تحويل MIME وتحرير المورد بشرط `__IOS__`. لا يكفي إصلاح خيار الربط
لحسم هذا السلوك. أضيف تنفيذ مستقل للمشروع في `runtime-native/ios_filetype.m`،
وتحول إليه نقطة JNI على iOS؛ مسار macOS السابق محفوظ.

## التنفيذ

- يستخدم `UTType.typeWithFilenameExtension` و`preferredMIMEType` من
  [واجهة Apple العامة](https://developer.apple.com/documentation/uniformtypeidentifiers/uttypereference?language=objc).
  يُرجع null عندما لا يوفر النظام نوع MIME؛ لا يفحص محتوى الملف أو يضمن صيغته.
- تُنسخ سلسلة Java UTF-16 إلى NSString ويُحرر `GetStringChars` في `finally`.
  الرد يمر عبر JNI NewString مع فحص حدود jsize وتحرير مخزنه في `finally`.
- تستخدم الكائنات ARC وautoreleasepool محلية للخيط، مع تفعيل تنظيف ARC عند
  الاستثناءات. تتحول استثناءات Objective-C إلى استثناء Java؛ لا تعبر حد JNI.
- يضيف التحضير الملف المؤلف للمشروع إلى مصادر NIO بعد التحقق من بصمات أحد عشر
  ملفًا أصليًا قبل أي كتابة. تُحفظ نسخة الملف وبصمتها ضمن دليل البناء.
- تربط NIO على iOS بـFoundation وUniformTypeIdentifiers وCoreFoundation وobjc.
  يتلقى فحص الربط وتطبيق الهاتف الأطر نفسها. يبقى ملف المساعدة فارغًا عند
  بناء المضيف macOS؛ لا يغير تنفيذ نوع الملف فيه.

## التحقق الحالي

- اجتاز فحص التحضير وقواعد Make وغياب ARC وإصلاحات الربط، وفحص فروع C
  بالـpreprocessor: نقطة iOS تختار المساعدة، وmacOS يحتفظ بالمصدر السابق.
- اجتازت fixture Java المؤلفة للمشروع على المضيف فحص `text/plain` و
  `image/png` عبر Files.probeContentType، مع اسم ملف عربي وبقاء فحوص JAR
  وUnicode والخيوط وGZIP والملفات. هذا يشغل كاشف المضيف، ولا يشغل مساعدة iOS.
- أضيفت خطوة ترجمة المساعدة بـSDK iOS 26 قبل بناء JDK الطويل، مع حفظ السجل
  وملف object. اجتازت هذه الخطوة في Actions 39762272353؛ توقف بناء الصورة
  لاحقًا عند libprefs وlibinstrument، كما في [دليل المحاولة](../validation/ios-jvm-image-39762272353.json).
- تطبيق فحص الهاتف يتطلب runtime بمنشأ يثبت إدراج التنفيذ الجديد؛ فحصه الآن
  يتضمن MIME أيضًا. إثبات السلوك والموارد على iPhone ما زال ضمن ENG-15.

الأدلة المحلية: [خيارات المصدر](../validation/ios-jvm-source-fixes.json)،
[fixture المضيف](../validation/ios-device-fixture-host.json). لا تتضمن الخطوة
كودًا أو حمولات تنفيذية من IPA المرجعي ولا تفعّل المحرك في القارئ الإنتاجي.
