# Tachimanga 5.1 — المستودعات والتثبيت وحالات فشل التنزيل

متابعة لتحليل Java للعينة 5.1/520 ذات بصمة IPA
`e8e3ab5152a85f60d5d617bae825d39be7d55e3f048661f3042def0009a51863`.
حُسمت هنا فروع محددة كانت مفقودة من pseudocode بسبب فشل CFR/Vineflower.
لم يُشغّل أي صنف أو تُجرَ طلبات شبكة بالعينة.

## منهج التحقق وحدوده

استُخدم `javap -p -c -v` على class data داخل res.zip، ثم بُني رسم تعليمات
وفروع وexception handlers لطرق مختارة. قورنت أعداد التعليمات وبصمات Code
attribute بقارئ class مستقل، وتُحقق من أن كل هدف فرع يشير إلى بداية تعليمة.

الأرقام أدناه **إزاحات bytecode داخل الطريقة المذكورة**، وليست عناوين Mach-O
أو إزاحات res.zip. الرسوم والـjavap كاملة خارج المستودع في `java-full/`،
والملخص القابل للمراجعة في
[repository-control-flow.json](../validation/rea/tachimanga-5.1-repository-control-flow.json).
هذا لا يستبدل تشغيل Java verifier أو اختبار تزامن أو كل سياسات ClassLoader.

## جلب metadata: fetch-yxL6bBk

الطريقة في `mihon.data.extension.service.ExtensionStoreService` طولها 1,600
بايت، و700 تعليمة، و71 basic block، و28 exception-table entry. جدول coroutine
له حالات 0..4. تعثر إخراج سورس لها لا يعني أن تنفيذها مفقود من الحزمة.

### انتقال العنوان وصيغ البيانات

| الشرط | النتيجة | الإزاحات |
|---|---|---|
| HttpException.code=404 والعنوان الجاري ينتهي `/index.min.json` | استبدال اللاحقة بـ`/index.pb` ثم إعادة الطلب | 282..327، نداء request عند 406 |
| أول byte بعد فك GZIP هو `[`، أي 91 | توقع legacy index؛ التحقق من أن عنوان الإدخال ينتهي `/index.min.json`، ومحاولة قراءة قائمة الإضافات، ثم طلب `/repo.json` | 538..631، بناء العنوان عند 666..674، request عند 781 |
| أول byte هو `{`، أي 123 | محاولة NetworkLegacyExtensionRepo على peek؛ عند IllegalArgumentException استعمال NetworkExtensionStore على المصدر | 1014..1104؛ exception handler عند 1070 |
| غير ذلك | قراءة bytes وفك NetworkExtensionStore بصيغة protobuf | 1117..1159 |
| metadata قديمة وفيها index_v2 | طلب العنوان الجديد مع allowIndexV2Redirect=false وscene EXTENSION_INDEX | 1171..1314 |
| تحول index_v2 مرة ثانية | IllegalStateException بدل حلقة تحويل غير محدودة | 1188..1203 |

انتقال 404 إلى index.pb غير مشروط بـallowIndexV2Redirect؛ ذلك العلم يحد
تحويل index_v2 تحديدًا. لا يُخلط بين هذين المسارين أو مع HTTP redirect.
في فرع `[` يؤدي فشل فك القائمة القديمة إلى تحذير ثم يستمر جلب metadata؛
لا يساوي ذلك نجاح قراءة قائمة الإضافات.

يفحص التمييز **أول byte**؛ لا توجد خطوة تخطي whitespace في هذه المقارنة نفسها.
لا نوسع هذا الدليل إلى أن كل JSON يمكن تمييزه قبل أي parsing آخر.

### الضغط والإلغاء

`decompressIfGzipped` تستعمل peek ثم readShort عند 26، وتقارن بـ8075، أي
`0x1f8b`، عند 31..34. فشل قراءة الرأس يعامل كعدم وجود GZIP في هذا helper؛
وعند التطابق يُنشأ GzipSource على المصدر الأصلي ثم Okio.buffer. لا يُستهلك
رأس المصدر الأصلي بمجرد الكشف، ولا يُستدل من اسم URL على الضغط.

في fetch تُعاد CancellationException من handler عند 1542..1546.
بقية Exception المفحوصة تسجل ثم تغلف في Kotlin Result.failure عند 1547..1585.
إذًا إلغاء العملية ليس نتيجة فهرس فارغ ناجحة.

## اختيار قائمة الإضافات: getExtensions-0E7RQCE

الطريقة طولها 1,240 بايت و540 تعليمة و66 basic block و20 exception-table entry.
تسلسل الاختيار المثبت:

1. عند وجود `store.extensionList`، تتحول إلى OnlineExtension مباشرة عند 132..148.
2. وإلا، عند وجود `extensionListUrl`، يُطلب الملف بـscene EXTENSION_LIST؛
   يُكشف GZIP، ثم `{` لقائمة ExtensionList JSON، وإلا protobuf، ثم toOnlineExtensions.
3. وإلا، إن لم يكن المستودع legacy، يعاد جلب `indexUrl` بـscene EXTENSION_INDEX،
   وفك NetworkExtensionStore بصيغة JSON أو protobuf، ثم استعمال extensionList.
4. وإلا، إن وجدت `legacyExtensionList` المخزنة مع metadata، تُستعمل مباشرة.
5. وإلا يُبنى مسار `/index.min.json` من عنوان repo.json، ويُطلب ويفك كقائمة legacy.

ينتهي النجاح بتغليف القائمة في Result عند 1187..1200. الإلغاء يُعاد من
1203..1207، وبقية Exception تُحوّل إلى Result.failure عند 1208..1225.
الترتيب مهم: وجود embedded list يجعل طلب ملف list منفصل غير لازم.

### أشكال JSON وهوية المستودع

قورنت نماذج NetworkExtensionStore وNetworkLegacyExtensionRepo وExtensionList
ومحوّلاتها إلى نموذج المجال. الحقول الأساسية ذات الصلة بتنفيذ MSL:

| الشكل | metadata | القائمة والموارد |
|---|---|---|
| حديث | name وbadgeLabel وsigningKey وcontact | extensionList ككائن يحوي extensions، أو extensionListUrl منفصل |
| عنصر حديث | name وpackageName وversionCode وversionName وextensionLib | resources.jarUrl وresources.iconUrl وresources.apkUrl؛ sources تحوي id/name/language/homeUrl |
| metadata قديمة | meta.name وmeta.shortName وmeta.website وmeta.signingKeyFingerprint | index_v2 اختياري؛ القائمة القديمة index.min.json بجوار repo.json |
| قائمة قديمة | مصفوفة عناصر legacy، ويمكن حفظها أثناء جلب metadata | تعاد للاستعمال في getExtensions دون تنزيل المصفوفة ثانية |

يمرر المحوّل signingKey الحديث وmeta.signingKeyFingerprint القديم إلى حقل
هوية المجال نفسه. هذه قيمة metadata معتمة في نموذج MSL الحالي؛ لا يثبت
تشابه الحقل أن البصمة مفتاح تحقق تشفيري. استمرارية القيمة بين طلبين لا تعوض
التحقق من الناشر أو توقيع الحزمة.

معرف Source هو Long ذو إشارة في نموذج المرجع، ويجب أن تتطابق هويته بين
JSON وprotobuf؛ العدد ذو البتات الأربعة والستين كلها 1 يمثّل -1 عند تفسيره
كـLong. لا يُحوّل sourceId إلى packageName، ولا يُختزل versionCode إلى عدد
صحيح من 32 بت في قارئ MSL.

نُفذ جزء جلب metadata في MSL عند `4ebb7e2`؛ اجتازت الحالات الأربع عشرة
الجديدة ضمن **86 اختبار Swift** في
[Actions 39490806730](https://github.com/badrcoderman/MangaShelf/actions/runs/39490806730)،
مع بناء IPA ARM64. تشمل الحالات التحويل مرة واحدة و404 المخصص وإعادة استعمال
القائمة والروابط النسبية بعد HTTP redirect وتغيّر هوية metadata. هذه حالات
مصطنعة لعقد القراءة، ولا تثبت سياسات CDN أو نجاح إضافة فعلية على iPhone.

## GitHub وjsDelivr: نوع آخر من fallback

`JsDelivrFallback.run` يملك Key من owner وScene، ومجموعة fallbackKeys في الذاكرة.
يحول صيغ raw.githubusercontent.com وgithub.com/.../raw/... إلى
cdn.jsdelivr.net/gh/owner/repo@ref/path، ويملك التحويل العكسي للصيغة المطابقة.
العناوين غير المطابقة تعود كما هي.

إذا كان Key مسجلًا والعنوان البديل مختلفًا، يُستعمل البديل مباشرة. وإلا يُجرب
الأصل، وتُعاد CancellationException، ثم يحدد shouldFallback إن كان يسمح
بتجربة البديل عند Throwable. يسجل Key قبل محاولة البديل، ولا يثبت هذا وجود
سياسة persisted بين إقلاعين أو صلاحية كل مرجع GitHub يحوي `/` داخل اسمه.

هذا fallback يختلف عن index_v2 وعن index.min.json→index.pb وعن JAR→APK.
وجود كلمة fallback في أسماء متعددة لا يجعلها سياسة واحدة.

## تنزيل JAR ثم APK

داخل `ExtensionGithubApi.downloadExtension`، يؤدي useJarVersion إلى استدعاء
`downloadJar`. إن أعاد مسارًا، تنتهي العملية به؛ وإن أعاد null، تنتقل إلى APK.

`downloadJar` يبني مسارًا مؤقتًا ينتهي `_tmp.jar`. يأخذ jarUrl الصريح، وإلا
يبني `baseUrl + jar/<name>.jar`. يستخدم JsDelivrFallback مع Scene.JAR، لكن
predicate `downloadJar$lambda$0` يعيد false تحديدًا لـHttpException 404.
يلتقط downloadJar ذلك الخطأ ويعيد null عند 343..357؛ بقية أخطاء HTTP تُعاد.

إذًا 404 في JAR يفتح مسار APK؛ لا يثبت هذا fallback إلى APK بعد كل خطأ
TLS/timeout/فشل نقل. الإلغاء في `downloadApk` يعاد، وتسجيل فشل التنزيل لا
يحوّل الفشل إلى تثبيت ناجح.

## التحقق من الحزمة وترتيب التثبيت

`validateExtensionPackage` يتحقق من وجود feature باسم `tachiyomi.extension`،
ثم يحل رقم extensionLib من `tachiyomix.extensionLib` إذا كانت قيمة قابلة
للاستعمال، وإلا من prefix versionName قبل آخر نقطة. المجال المقبول 1.3..1.6.
هذه **مطابقة ABI/نوع الحزمة**، وليست تحققًا تشفيريًا لجهة الناشر.

`installAPK` يتبع الترتيب التالي:

| الإجراء | موضع النداء |
|---|---:|
| تحليل APK أو prepareJarExtension بحسب امتداد الملف | قبل 290 |
| validateExtensionPackage | 325 |
| uninstallExtension للحزمة الحالية | 344 |
| finalizeApkExtension أو finalizeJarExtension | 391 أو 416 |
| installPreparedExtension، وإنشاء المصدر/SourceFactory وتسجيله | 434 |

لا توجد exception-table entries في installAPK نفسها. لذلك لا يثبت هذا المسار
rollback للنسخة السابقة عند فشل ما بعد uninstall. قد توجد معالجة أعلى أو
تفاصيل ملفات في helpers؛ لم تُختبر استعادة إصدار سابق على جهاز.

finalizeJarExtension يقارن canonical file paths، ويحذف الوجهة الموجودة إذا
اختلف المسار، ثم renameTo؛ عند فشل النقل يرمي خطأ، ثم يعالج icon. لا يوصف
ذلك بأنه تثبيت atomic متعدد الخطوات أو سياسة ثقة.

## ما ثبت عن التوقيع، وما لم يثبت

تُظهر التعليمات ثلاثة أنواع منفصلة من العمل:

- PackageTools.getPackageInfo يجمع بيانات شهادات APK في PackageInfo.signatures.
- getSignatureHash يحسب SHA-256 لأول signature عند وجودها؛ وجود helper لا يثبت استعماله في التثبيت.
- persistStore يقارن metadata، ثم يكتب signingKey في حقل signingKeyFingerprint داخل RepoTable عند تحديثها. لا يرمي فشلًا لتغير البصمة ضمن هذه الطريقة.

في البحث المباشر عبر **1,610 class entry المختارة** لم يوجد نداء إلى
PackageTools.getSignatureHash أو Extension.removeJarSignatures أو
InstalledPackage.verify. هذا حد البحث، وليس نفيًا للاستدعاء بالانعكاس أو
خارج النطاق أو تحقق JAR الداخلي في مكتبة Java القياسية.

توجد InstalledPackage.verify في طبقة AndroidCompat، وتستدعي
ApkVerifier.Builder.build().verify().isVerified(). لكن أصناف
`com/android/apksig/ApkVerifier` وBuilder وResult **غير موجودة في res.zip**
بحسب جرد 27,688 class. وجود هذه الطريقة لا يثبت أن المسار قابل للاستدعاء في
runtime المشحون أو أنه يستخدم فعلًا في تثبيت الإضافات.

`removeJarSignatures` يحذف أعضاء META-INF عند إعادة ZIP، لكن لا يوجد له نداء
مباشر في النطاق المذكور. لا ننسب أثره إلى تثبيت فعلي لمجرد وجود الطريقة.

الاستنتاج المحدد: **لم يُثبت pinning/تحقق ناشر كامل لمسار التثبيت من هذه
الطرق**. لا يصح اعتبار قراءة signingKey أو استخراج شهادة أو نجاح فحص ABI
قرار ثقة. هذا أيضًا ليس حكمًا بأن كل مسار في التطبيق يفتقد أي تشفير.

## حلقة تنزيل الفصول التي فشل تفكيكها

`Downloader.run` طولها 1,297 بايت و568 تعليمة و88 basic block و39
exception-table entry، مع coroutine states 0..7. تتبعت الفروع التالية:

- تفحص أن الطابور غير فارغ وأن coroutine context ما زال active عند 121..157.
- تحت ReentrantLock، تختار عنصرًا يطابق sourceId للعامل؛ حالته Queued أو
  Error مع tries < 3 عند 220..265، ثم تضبطه Downloading قبل تحرير القفل.
- تجهز بيانات الفصل، ثم FolderProvider2.download، ثم Finished وتحديث قاعدة
  البيانات، وتأخير 300 ms، وإزالة العنصر الناجح من الطابور وإشعار الحالة.
- handler الإلغاء عند 968 يحدد العناصر Downloading ويعيدها Queued، ثم
  notifier(false)، ثم يعود إلى بداية الحلقة؛ اختبار isActive التالي يسمح
  بالخروج من run. لا يُخلط هذا مع سياسة الإلغاء في جلب المستودعات.
- PauseDownloadException عند 1164 يعيد العنصر الحالي Queued ويشعر الحالة.
- Throwable عند 1201 يزيد tries، ويضبط Error ورسالة الخطأ، ثم يشعر الحالة
  ويعود للحلقة. القيد tries < 3 يمنع استمرار اختيار ذلك العنصر بلا حد.
- finally عند 1263 يشعر الحالة ثم يعيد الاستثناء غير المعالج في ذلك الفرع.

هذا يحسم منطق الحلقة المحدد، ولا يثبت كل سلوك FolderProvider2، أو بقاء
الطابور بعد إنهاء العملية، أو قبول BGContinuedProcessingTask أو جميع سباقات
عمال تنزيل متوازية. هذه تحتاج أدلة واختبارات أوسع.

## أثر هذه النتائج على MSL

تضاف إلى عقد المصادر نفسه: فصل metadata/list/legacy/JSON/protobuf/GZIP، وحد
تحويل index_v2، وإلغاء صريح، وسياسات fallback مختلفة، وتثبيت يحافظ على الإصدار
السابق حتى نجاح المصدر الجديد، والتحقق الفعلي من الناشر. لا تُنسخ المخاطر أو
السلوك غير المتحقق لمجرد السعي للمطابقة.

تظل أخطاء decompilers الأصلية محفوظة. التقدم هنا **استعادة عقود من bytecode
وتحقق فروعها**، وليس ادعاء أن الأدوات أنتجت سورسًا أصليًا صحيحًا لتلك الطرق.
