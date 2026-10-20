# Tachimanga 5.1 — الحزمة وبيئة Java

العينة: الإصدار 5.1، البناء 520، من ملف IPA الذي قدمه المستخدم، وبصمته
`e8e3ab5152a85f60d5d617bae825d39be7d55e3f048661f3042def0009a51863`.
جميع النتائج أدناه قراءة ساكنة. لم يُشغّل التطبيق أو أي جزء تنفيذي منه.

## تغطية الحزمة

أعيدت قراءة **566/566 مدخلة ZIP** حتى نهايتها والتحقق من CRC وحساب SHA-256.
فُكّت رؤوس وقطاعات وأوامر تحميل وجداول رموز **53/53 صورة Mach-O**، إضافة إلى
82 ملف plist و29 بيان خصوصية، دون أخطاء بنيوية مسجلة. كل الصور الأصلية في
هذه العينة ARM64 وتحتوي `cryptid=0`؛ هذا يصف حالة الملفات ولا يصادق على مصدرها.

الأدلة: [ملخص الحزمة](../validation/rea/tachimanga-5.1-package-deep.json)،
[جرد الملفات والبصمات](../validation/rea/tachimanga-5.1-package-inventory.json).
السكربت القابل لإعادة التشغيل: `scripts/analyze_tachimanga_package.py`.
جداول الرموز الكاملة محفوظة خارجيًا في `package-full/native-images.json`،
وتغطي البيانات المتاحة في الجداول؛ الرموز المحذوفة والاستدعاءات غير المباشرة
تحتاج تحليلًا منفصلًا.

## مكونات التوزيع

| الطبقة | الملف/المكونات المثبتة | ما يثبته الفحص |
|---|---|---|
| المضيف | `Tachimanga`، 10,485,760 بايت | UIKit وObjective-C وجسور Flutter وOpenJ9 مدمجة في الصورة |
| واجهة التطبيق | `App.framework/App`، 20,271,568 بايت | لقطتا Dart VM/Isolate وكود AOT؛ [تفاصيل Flutter](TACHIMANGA-5.1-FLUTTER-AR.md) |
| محرك Flutter | `Flutter.framework/Flutter`، 9,854,016 بايت | محرك عرض وتنفيذ Dart AOT منفصل عن بيانات الواجهة |
| الخلفية | `MCHome.bundle/res.zip`، 60,954,239 بايت | أصناف Java/Kotlin وتبعياتها ومواردها؛ [تفاصيل Java](TACHIMANGA-5.1-JAVA-AR.md) |
| مكتبة Java القياسية | `jre/lib/modules`، 96,649,353 بايت | صورة JIMAGE تحوي 63 وحدة Java فعلية وبيانات فهرسة |
| خدمات iOS | 50 framework، تشمل App وFlutter | وجود ارتباطات بالملفات المدرجة، وليس دليل استعمال كل وظيفة |
| إضافتا التعديل | `Tachimanga.dylib` و`blatantsPatch.dylib` | المضيف يحمّلهما تحميلًا ضعيفًا؛ يجب تمييز أثرهما عن التطبيق الأصلي |

من أطر الخدمات: `sqflite_darwin` وFMDB للتخزين؛ `shared_preferences_foundation`
للتفضيلات؛ `webview_flutter_wkwebview` و`cupertino_http` و`system_proxy` للنقل
والويب؛ `file_picker` و`image_picker_ios` وSSZipArchive للملفات؛
`local_auth_darwin` وSAMKeychain للمصادقة/التخزين المحمي؛
`apple_pencil_double_tap` للقلم؛ و`flutter_nsfw` وNSFWDetector للتصنيف.
توجد أيضًا مكونات Firebase والإعلانات والمشتريات والمراجعات وتسجيل الدخول.
هذه عضوية في الحزمة وارتباطات تحميل، ولا تثبت نجاح خدمة أو تفعيلها لحساب المستخدم.

## تحديد Java من الملفات الفعلية

الأداة `jimage` المثبتة محليًا تخص Java 27 ورفضت صورة JIMAGE 1.0 بسبب اختلاف
الإصدار. حُفظ هذا الفشل، ثم استُخدم قارئ مستقل لبنية الإصدار 1.0 استنادًا إلى
[تعريف OpenJDK للتنسيق](https://github.com/openjdk/jdk17u/blob/master/src/java.base/share/native/libjimage/imageFile.hpp).
القارئ `scripts/inspect_jimage.py` لا يحمّل أي صنف Java.

فُهرست **20,123/20,123 موردًا** مع مواقعها وأحجامها وبصماتها، منها 1,726 موردًا
لفهرسة الوحدات والحزم. الوحدات الفعلية 63 بعد فصل سجلات `modules` و`packages`
والسجل الخالي عن أسماء الوحدات. تحتوي الصورة 18,159 ملف class غير مضغوط:
18,135 بالإصدار 61، و7 بالإصدار 52، و17 بالإصدار 50. لم توجد حمولات class
مضغوطة في هذا الفحص. [الدليل](../validation/rea/tachimanga-5.1-jimage.json).

استُخرجت `java.base/java/lang/VersionProps.class` كبيانات وفُحصت بـ`javap -constants`،
فظهرت قيم الحقول الثابتة التالية:

| الحقل | القيمة |
|---|---|
| `java_version` | `17.0.15-internal` |
| `java_runtime_version` | `17.0.15-internal+0-adhoc.mobile.openj9-openjdk-jdk17` |
| `java_version_date` | `2025-04-15` |
| `VENDOR` | `Eclipse OpenJ9` |
| `CLASSFILE_MAJOR_MINOR` | `61.0` |

بصمة الصنف `d3eef806c409e7ac38d05c6e24a259bef695e6fe1c2dd369889122daebc3ad71`،
عند إزاحة `2,697,834` في صورة modules. تثبت هذه القيم هوية مكتبة Java المضمنة؛
لم تُقَس قيمة `java.vm.version` أثناء تشغيل التطبيق. وجود وحدات `openj9.*`
ومسار `J9_CreateJavaVM` في [تقرير المضيف](TACHIMANGA-5.1-NATIVE-AR.md) دليلان
مستقلان متوافقان مع هذه الهوية. لا تحدد البيانات commit تعديلات منفذ iOS الأصلي.

يحوي `jvm.cfg` تعريف `-server KNOWN` وتجاهل `-client`. ويتضمن
`options.default` إعدادات OpenJ9 خاصة بالـlockword وEnsureHashed. هذه خيارات
مشحونة في الحزمة، بينما خيارات الإقلاع التي يبنيها JavaLauncher مثبتة في تقرير
المضيف. الفصل بينهما لازم لفهم ما يمرر إلى VM فعلًا.

## تصريحات النظام والملفات

يحدد Info.plist الحد الأدنى iOS 15.0 وSDK البناء iphoneos26.0 ودعم iPhone وiPad.
يسجل المخططات `tachiyomi` و`tachimanga` و`mihon`، وامتداد النسخ `.tmb` بنوع
`app.tachimanga.tmb`، كما يسجل ZIP ضمن أنواع المستندات.

توجد `UIFileSharingEnabled=true` و`NSAllowsArbitraryLoads=true`، ونصوص طلب
صلاحيات Face ID والصور والشبكة المحلية والتتبع الإعلاني. لا يظهر مفتاح
`UIBackgroundModes` في Info.plist المرفق؛ لا يكفي غيابه وحده للحكم على كل
سلوك تنزيل أو مهمة أصلية بالخلفية. التسجيل لا يثبت تنفيذ كل معالج URL أو
توافق كل ملف نسخ مستورد.

تتضمن entitlements المقروءة من توقيع المضيف حاوية iCloud باسم
`iCloud.app.tachimanga` وCloudDocuments وSign in with Apple. لم يُتحقق من
صلاحية التوقيع أو الاستحقاقات على جهاز، ولا يُستنتج نجاح مزامنة iCloud من وجودها.

بيان الخصوصية الجذري يصرح ببيانات الإعلانات والأعطال وفئات UserDefaults
ووقت إقلاع النظام وطابع الملفات. فُهرست كذلك بيانات 28 مكوّنًا آخر. هذه تصريحات
الحزمة وليست تحليلًا لحركة الشبكة الفعلية أو حكمًا على مطابقتها.

## أثر العينة المعدلة

يحتوي المضيف رابطين ضعيفين إلى `@rpath/Tachimanga.dylib` و
`@rpath/blatantsPatch.dylib`. الأولى تحمل install name لمسار MobileSubstrate،
وتوجد فيها استدعاءات فعلية لتبديل methods. الثانية صغيرة، 70,848 بايت، وتحوي
رموزًا مرتبطة بإعادة ربط وظائف Keychain ومجموعة التطبيق، و23 بداية دالة و104
chained pointers. أسماء entitlement وCloudKit وKeychain فيها دليل مراجع ساكنة؛
لم تُثبت كل نتائج الاستبدال أثناء التشغيل. تفاصيل الهوية والتغطية في تقرير المضيف.

لذلك تصف هذه الدراسة **العينة المرفقة**. يلزم توزيع رسمي مطابق للمقارنة قبل نسبة
كل استحقاق أو hook أو تغير سلوكي إلى Tachimanga الرسمي.

## حدود هذا الجزء

اكتملت تغطية فهرس الحزمة والبنى المدعومة وفهرس JIMAGE المعلن. تحليل كل تعليمة
ودالة في جميع الأطر وOpenJ9، وتشغيل خدمات النظام والحسابات، ومطابقة الواجهة
بصريًا، مسائل أوسع لم تثبتها هذه الأعداد. تجمع صفحة التحقيق الرئيسية ما فُهم
من مسارات التطبيق وما بقي مفتوحًا.
