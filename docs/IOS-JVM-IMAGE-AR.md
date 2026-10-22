# بناء صورة Java الخاصة بتجربة iPhone

## الحالة المثبتة

فشل التشغيل [39384913153](https://github.com/badrcoderman/MangaShelf/actions/runs/39384913153)
عند المراجعة `793fe88722da13b7fa46ce85bb23f3aeb73daffc` في هدف
`legacy-jre-image`. سبق الفشل إنشاء المكتبات الساكنة، لكن ذلك لا ينتج وحده
`lib/modules` أو إعدادات Java ولا يثبت بدء VM على iPhone.

الخطأ الحاسم في كل من VM الهدف وbuild JDK كان:

```text
ld: unknown options: -soname=libjvm.so
```

لا نستخدم artifact هذا التشغيل كتجربة جهاز ناجحة. الأدلة السابقة للربط الساكن
مستقلة، وتبقى ENG-01 وENG-11 مفتوحتين.

## التصحيح

1. `prepare-ios-jvm-source.py` يتحقق حاليًا من SHA-256 لتسعة ملفات من مراجعة
   OpenJDK Mobile المثبتة **قبل أي كتابة**، ثم يطبق تعريفات Zero السابقة
   وإصلاحات Apple التالية:
   - امتداد المكتبة الديناميكية `.dylib` بدل اختيار `.so` الافتراضي لـiOS.
   - خيارات clang من نوع `-dynamiclib`.
   - اسم المكتبة عبر `-install_name,@rpath/...` بدل `-soname`.
   - قواعد origin للمكتبات والبرامج عبر `@loader_path` بدل GNU/ELF، واستبعاد
     خيارات ELF مثل `-z,noexecstack` من مسار Apple.
   - ربط `libjava` على iOS بـCoreFoundation التي يستخدمها كود اللغة والتنسيق؛
     لا يضيف أطر macOS الأخرى إلى iOS ولا يغيّر خيارات المنصات الأخرى.
   - استبعاد `java_md.c` العام من `libjli` على iOS كما على macOS؛ الملف
     `java_md_macosx.m` يوفّر بالفعل تنفيذ Apple وفروع `__IOS__`، وإدراج
     الملفين يكرر رموز المشغّل.
   - ربط `libnio` على iOS بـCoreFoundation التي يستدعيها UTIFileTypeDetector؛
     تبقى خيارات libnet كما هي، وقائمة macOS وLinux في libnio مستقلة.
   - تحويل نقطة نوع الملف على iOS إلى مساعدة مؤلفة للمشروع تستخدم UTType،
     مع ARC وتنظيف الاستثناءات وأطر Foundation/UniformTypeIdentifiers؛
     [التنفيذ والحدود](IOS-FILETYPE-AR.md).
2. يُبنى JDK أدوات المضيف **من المصدر المثبت نفسه** بإعداد macOS مستقل، ثم
   يمرر إلى configure الخاص بـiOS عبر `--with-build-jdk`. هذا يمنع الاعتماد
   على buildjdk-spec الذي يرث بعض قيم منصة الهدف في هذه المراجعة.
3. تُبنى المكتبات وصورة Java الخاصة بـiOS في إعداد منفصل؛ لا يُنسخ JDK المضيف
   إلى تجربة الجهاز. الصورة تأتي من هدف `legacy-jre-image`، لا من IPA المرجعي.
4. يحتفظ artifact بفرق المصدر ونتيجة فحص خيارات الربط وإصدار أدوات المضيف
   وبصماتها ضمن build-provenance، مع بقاء `execution_proven=false`.

المصادر المقروءة مباشرة من المراجعة المثبتة:
[Link.gmk](https://github.com/openjdk/mobile/blob/c1ed06aaef34c8dccf71e236d1ffa20918a77cfb/make/common/native/Link.gmk)،
[flags-cflags.m4](https://github.com/openjdk/mobile/blob/c1ed06aaef34c8dccf71e236d1ffa20918a77cfb/make/autoconf/flags-cflags.m4)،
[toolchain.m4](https://github.com/openjdk/mobile/blob/c1ed06aaef34c8dccf71e236d1ffa20918a77cfb/make/autoconf/toolchain.m4)،
[buildjdk-spec](https://github.com/openjdk/mobile/blob/c1ed06aaef34c8dccf71e236d1ffa20918a77cfb/make/autoconf/buildjdk-spec.gmk.template)،
[CoreLibraries.gmk](https://github.com/openjdk/mobile/blob/c1ed06aaef34c8dccf71e236d1ffa20918a77cfb/make/modules/java.base/lib/CoreLibraries.gmk)،
[HostLocaleProviderAdapter_md.c](https://github.com/openjdk/mobile/blob/c1ed06aaef34c8dccf71e236d1ffa20918a77cfb/src/java.base/macosx/native/libjava/HostLocaleProviderAdapter_md.c)،
[native/Flags.gmk](https://github.com/openjdk/mobile/blob/c1ed06aaef34c8dccf71e236d1ffa20918a77cfb/make/common/native/Flags.gmk)،
[java.base/Lib.gmk](https://github.com/openjdk/mobile/blob/c1ed06aaef34c8dccf71e236d1ffa20918a77cfb/make/modules/java.base/Lib.gmk)،
[UTIFileTypeDetector.c](https://github.com/openjdk/mobile/blob/c1ed06aaef34c8dccf71e236d1ffa20918a77cfb/src/java.base/macosx/native/libnio/fs/UTIFileTypeDetector.c).

## التحقق الذي نُفّذ

- نُزّلت الملفات التسعة كنص من GitHub عند commit المحدد؛ بصماتها مثبتة في
  سكربت التحضير. قُرئ كذلك كود HostLocale وملف اختيار خيارات الربط الأصلي؛
  تثبت أداة التحقق بصمة `native/Flags.gmk` قبل تقييمه.
- `test_ios_jvm_source.py PRISTINE_PINNED_OPENJDK_ROOT` نفّذ فحصًا قابلًا
  للتكرار في مجلد مؤقت: رفض تعديل كل من الملفات التسعة قبل أي كتابة، ثم
  طبق الإصلاح على المدخلات الأصلية ورفض تكرار التطبيق.
- `verify-ios-jvm-source.py` قيّم فروع shell وMake الفعلية لاختيار الامتداد
  وخيارات المكتبة واسمها على iOS وmacOS وLinux؛ حالات Apple تختار install_name
  وdynamiclib وloader_path دون خيارات ELF، وLinux يحتفظ بخيارات soname/origin
  وnoexecstack. فُحص noexecstack مع تفعيل نتيجة probe حتى لا تخفيه قيمة فارغة.
- تقييم استدعاء `BUILD_LIBJAVA` الفعلي مع معالج خيارات `SetupLinkerFlags`
  الأصلي: كان فرع iOS بلا مكتبات منصة وأصبح `-framework CoreFoundation`؛
  ظلت قائمة macOS كما هي واحتفظ Linux بـ`-ldl`. حذف الإصلاح مع إبقاء
  إصلاحات Darwin السابقة يجعل الفحص يفشل؛ لا يُكتفى بالبحث عن نص التصحيح.
- تقييم شرط `LIBJLI_EXCLUDE_FILES` الفعلي بـMake لكل منصة: يختار iOS وmacOS
  استبعاد `java_md.c`، ولا يغيّر Linux. إعادة الشرط القديم الخاص بـmacOS فقط
  تفشل فحص iOS مع إبقاء إصلاح CoreFoundation؛ فُحص التصحيحان كل على حدة.
- تقييم استدعاء `BUILD_LIBNIO` واختيار `LIBS_ios` عبر معالج الربط الأصلي؛
  يختار iOS أطر المساعدة الأصلية، وتبقى فروع macOS وLinux مطابقة للأصل. فُحص أيضًا
  `BUILD_LIBNET` على المنصات الثلاث للتأكد من عدم تغيير المكتبة المجاورة.
  إزالة إصلاح NIO وحده تفشل الفحص حتى مع بقاء إصلاحات Java وJLI.
- فُحصت فروع نقطة UTI بالـpreprocessor ونسخة المساعدة وإعداد ARC؛ نقل فحص
  ترجمتها بـSDK Apple إلى ما قبل بناء المضيف الطويل لا يثبت تشغيلها على جهاز.
- اجتاز سكربت البناء `bash -n`.

النتيجة المحدودة: [ios-jvm-source-fixes.json](../validation/ios-jvm-source-fixes.json).
هذه فحوص مصدر وخيارات بناء على Linux؛ لا تحل محل الربط باستخدام SDK Apple.

## البوابات التالية

المحاولة [39455667631](https://github.com/badrcoderman/MangaShelf/actions/runs/39455667631)
اجتازت تطبيق الإصلاح وفحص خيارات الربط، ثم رفض configure خيار headless-only
للمضيف macOS قبل بدء تجميع JDK المضيف. أزيل الخيار من إعداد المضيف؛ لا تُسجل
المحاولة نجاحًا لبناء الصورة.

في [39480348541](https://github.com/badrcoderman/MangaShelf/actions/runs/39480348541)
نجح بناء أدوات المضيف من المصدر نفسه، وبدأ بناء مكتبات وصورة iOS، ثم توقف
ربط libjava/libverify عند `ld: unknown options: -z`. سبب الفرع المفحوص في
JdkNativeCompilation.gmk أنه اختار GNU origin لـiOS. أضيفت معالجة Apple لهذا
الفرع، وفحص منفصل لاستبعاد خيار noexecstack الخاص بـELF. يبقى نجاح الصورة
مرهونًا بالمحاولة التالية.

انتهت المحاولة
[39486371640](https://github.com/badrcoderman/MangaShelf/actions/runs/39486371640)
عند `44856f4` بالفشل كذلك. تجاوز الربط أخطاء soname وorigin السابقة، ثم
فشل libjava.dylib عند رموز CoreFoundation المستعملة في
HostLocaleProviderAdapter_md، ومنها CFArrayGetCount ورموز تنسيق الأرقام.
تأكد السبب من المصدر المثبت: `HostLocaleProviderAdapter_md.c` يتضمن
CoreFoundation ويستدعيها، بينما يحتوي استدعاء `BUILD_LIBJAVA` على
`LIBS_macosx` ولا يحتوي على `LIBS_ios`. أضيفت المكتبة لهذا الاستدعاء فقط
وفُحص اختيارها بـMake. لم تُبن صورة Java كاملة أو IPA فحص المحرك من هذا
التشغيل، ولا يُستعمل artifact الفشل كإثبات تنفيذ. نجاح ربط SDK الفعلي ينتظر
إعادة البناء بعد التصحيح.

انتهت إعادة البناء في
[39641238252](https://github.com/badrcoderman/MangaShelf/actions/runs/39641238252)
عند `858a94e59d5952e4ee768744254f94af8b007ffa` بالفشل. نجحت أدوات المضيف
والمكتبات الساكنة، ولم يظهر خطأ رموز CoreFoundation السابق. توقف الربط هذه
المرة عند `libjli.dylib` بسبب 10 رموز مكررة بين `java_md.o` و
`java_md_macosx.o`، ومنها `LoadJavaVM` و`JVMInit`.
[دليل المحاولة](../validation/ios-jvm-image-39641238252.json) يحفظ السبب
والسجل وبصمته؛ لا يُستخدم artifact الفشل للهاتف.

قُرئ مصدر
[java_md_macosx.m](https://github.com/openjdk/mobile/blob/c1ed06aaef34c8dccf71e236d1ffa20918a77cfb/src/java.base/macosx/native/libjli/java_md_macosx.m)
وفرع `LIBJLI_EXCLUDE_FILES` في CoreLibraries: استبعاد الملف العام كان خاصًا
بـmacOS فقط رغم وجود تنفيذ Apple ذي فروع iOS ضمن المدخلات. وُسّع هذا الشرط
إلى `macosx ios`. اجتاز فحص Make؛ إعادة البناء بـSDK Apple مطلوبة بعد هذا التعديل.

انتهت المحاولة
[39645343405](https://github.com/badrcoderman/MangaShelf/actions/runs/39645343405)
عند `9fa7b57` بالفشل بعد تصحيح اختيار libjli؛ لم يظهر تكرار رموزه السابق،
واستخدم البناء تسعة ملفات بدل عشرة لـJLI. توقف `libnio.dylib` عند
`CFStringCreateWithCharacters` من UTIFileTypeDetector. المصدر يكوّن CFString
قبل شرط `__IOS__`، بينما يعرف `BUILD_LIBNIO` مكتبات macOS فقط. أضيفت
CoreFoundation إلى `LIBS_ios` لهذا الاستدعاء وفُحصت فروع المنصات؛ نجاح SDK
ينتظر إعادة البناء. [دليل المحاولة](../validation/ios-jvm-image-39645343405.json)
يحفظ الفشل والسجل ولا يجيز استعمال artifact كتجربة هاتف.

المراجعة كشفت أيضًا أن شرط iOS في UTIFileTypeDetector يحجب تحويل MIME
وCFRelease بعد إنشاء CFString. عولج المسار في المصدر بمساعدة UTType ذات
ARC؛ يبقى نجاح ترجمتها وإثبات السلوك والموارد على iPhone ضمن ENG-15 قبل
المحرك الإنتاجي.

بدأت إعادة البناء
[39762272353](https://github.com/badrcoderman/MangaShelf/actions/runs/39762272353)
عند `8f7872a` في 22 أكتوبر، وتشمل ترجمة مساعدة MIME بـSDK ثم بناء الصورة
الكاملة. كانت جارية عند تسجيل [الحالة](../validation/ios-jvm-image-39762272353.json)؛
لا تُسجل ترجمة SDK أو تشغيل iPhone كنجاح من حالة job الجارية وحدها.

1. نجاح Actions في بناء المكتبات وصورة Java من المصدر نفسه، والتحقق من
   `modules / tzdb / java.security / release` ومنشأ الملفات.
2. إنتاج IPA منفصلة غير موقعة لتجربة VM وJAR مؤلف في المشروع، وفحص محتوياتها.
3. تثبيتها وتسجيل بدء VM وتحميل الأصناف والخيوط والملفات وUnicode على iPhone.
4. تنفيذ ABI المصدر الحقيقي وتبعياته، ثم إضافة موثوقة تنفذ البحث والتفاصيل
   والفصول والصفحات على الجهاز. اختبار JAR المشروع لا يغلق هذه الخطوة.

Tachimanga المشحون يستخدم Java 17/OpenJ9؛ تجربة المصدر الحالية تستخدم
OpenJDK Mobile/Zero، وتعلن في سجل configure نسخة `28-internal`. لا نفترض تكافؤ
التوافق أو الأداء بينهما من مجرد دعم class version أقدم. ستحدد نتائج الجهاز
واختبار المصدر الحقيقي صلاحية هذا المحرك للإنتاج.
