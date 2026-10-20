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

1. `prepare-ios-jvm-source.py` يتحقق من SHA-256 لأربعة ملفات من مراجعة
   OpenJDK Mobile المثبتة **قبل أي كتابة**، ثم يطبق تعريفات Zero السابقة
   وإصلاحات Apple التالية:
   - امتداد المكتبة الديناميكية `.dylib` بدل اختيار `.so` الافتراضي لـiOS.
   - خيارات clang من نوع `-dynamiclib`.
   - اسم المكتبة عبر `-install_name,@rpath/...` بدل `-soname`.
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
[buildjdk-spec](https://github.com/openjdk/mobile/blob/c1ed06aaef34c8dccf71e236d1ffa20918a77cfb/make/autoconf/buildjdk-spec.gmk.template).

## التحقق الذي نُفّذ

- نُزّلت الملفات الأربعة كنص من GitHub عند commit المحدد؛ بصماتها مثبتة في
  سكربت التحضير. لم نطبق الإصلاح على النسخة المحلية المعدلة سابقًا.
- في مجلد مؤقت: رفض مصدر معدل قبل تغيير بقية الملفات، ثم تطبيق الإصلاح على
  المدخلات الأصلية، ورفض تكرار التطبيق.
- `verify-ios-jvm-source.py` قيّم فروع shell وMake الفعلية لاختيار الامتداد
  وخيارات المكتبة واسمها على iOS وmacOS وLinux؛ حالات Apple تختار install_name
  وdynamiclib، وLinux يحتفظ بخيار soname.
- اجتاز سكربت البناء `bash -n`.

النتيجة المحدودة: [ios-jvm-source-fixes.json](../validation/ios-jvm-source-fixes.json).
هذه فحوص مصدر وخيارات بناء على Linux؛ لا تحل محل الربط باستخدام SDK Apple.

## البوابات التالية

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
