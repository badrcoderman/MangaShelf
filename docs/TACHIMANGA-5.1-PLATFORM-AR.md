# Tachimanga 5.1 — خدمات iOS والنسخ الاحتياطي

قراءة ساكنة للعينة 5.1/520. عنوان المضيف يبدأ بـ`0x100000000`؛ عناوين Dart
نسبية لصورة App. لم يُشغّل تطبيق أو استعادة أو تنزيل أو حساب في هذا الفحص.
الأدلة: [عقد النسخ](../validation/rea/tachimanga-5.1-backup-contract.json)،
[عقود المنصة والواجهة](../validation/rea/tachimanga-5.1-feature-contracts.json).

## توزيع أوامر MAGIC_PIPE

معالج Flutter الأصلي عند `0x10001ad34` يقارن اسم الطلب، وبعض المقارنات
`hasPrefix:`، ثم يستدعي plugin المناسب. أمثلة ثبتت بتعليمات النداء:

| الطلب/السابقة | موضع مرجع النص | الوجهة |
|---|---|---|
| `BACKUP:` | `0x10001bd6c` | MCBackupPlugin.handle:result:parent: عند `0x10001bda8` |
| `SOCKET:` | `0x10001c080` | MCBackendPlugin.handle عند `0x10001c0bc` |
| `BACKEND:` | `0x10001c0e0` | MCBackendPlugin.handle عند `0x10001c11c` |
| `DOWNLOAD:` | `0x10001c140` | MCDownloadPlugin.handle عند `0x10001c17c` |
| `ICON:` | `0x10001c020` | MCAppIconPlugin.handle عند `0x10001c05c` |
| `FIREBASE:` | `0x10001c1a0` | MCFirebasePlugin.handle عند `0x10001c1dc` |
| `SCREEN_ON` | `0x10001b9dc` | فرع إبقاء الشاشة ضمن المعالج |
| `READER:IMAGE:OCR` | `0x10001c39c` | مسار OCR الأصلي |
| `READER:IMAGE:PREVIEW` | `0x10001c2f8` | مسار معاينة الصور الأصلي |
| `APPEARANCE:SET:STYLE` | `0x10001c478` | تغيير المظهر الأصلي |

يتضمن المعالج أيضًا LogEvent/LogEvent2 وAnalytics#logEvent وEXPORT_LOG،
وأوامر HTTPDUMP الثلاثة، وClearCookies/GetCookies/CleanCache/SEND_MAIL،
وREADER_DEFER_EDGE_GESTURES، وDEBUG:OPEN_CF_WEBVIEW، وASK_RATE/TEST_RATE،
وSHARE:/AD:/SECURITY:/STORAGE:/USERAGENT:/CF:MUTE:، وSHOW_SANDBOX.

توجد مقارنة SHOW_FLEX وفرع يعيد OK، دون إثبات تشغيل FLEX في ذلك الفرع؛ لذلك
لا تُحوّل أسماء أوامر التشخيص وحدها إلى ادعاء أداة عاملة. كذلك بعض الأوامر
READER:* الأخرى في Flutter هي tags للتحليلات/بوابات المنتج، ولا يُفترض أنها
كلها handlers أصلية مستقلة. يجب متابعة موضع النداء والوجهة لكل أمر.

## صيغة iOS `.tmb`: تتبع الإنشاء

`MCBackupPlugin.createBackupModel:` عند `0x100048128` يبني الاسم
`Tachimanga_backup_<date>.tmb`، من literal `tmb` عند `0x1000481c8` والصيغة
عند `0x1000481d4`. يضبط createAt/updateAt بالثواني منذ epoch، وstate=1،
والنوع من backupType، وversion من **CFBundleVersion** العددي، وcloudBackup.
هذا version ليس بالضرورة إصدار مخطط قاعدة البيانات.

`createBackup:complete:` عند `0x100047d9c` ينشئ السياق والمجلد المؤقت، ينسخ
الملفات، يفحص قاعدة البيانات، ويطلب إنشاء ZIP. مسار نسخ المحتوى عند
`0x100048598` يستدعي نسخ DB ثم JAR ثم prefs ثم UserDefaults، مع فحص error
بعد كل خطوة.

| المصدر | اسم/موضع داخل محتوى النسخة | دليل التعليمات |
|---|---|---|
| `Tachidesk/sqlite8.db` | `tachimanga.db` | `0x1000486f0` و`0x10004870c`، copyItem عند `0x100048748` |
| `Tachidesk/extensions` | `extensions/` | طريقة `0x1000487cc`، وفرع انتقاء امتداد `.jar` |
| `Preferences` | `prefs/` | طريقة `0x100048b10`، مع بادئتي suwayomi.tachidesk. وcom.apple.java.util.prefs |
| UserDefaults المنتقاة | `pref.json` | `0x100048fb8` |
| تمثيل جميع UserDefaults | `pref-all.json` | `0x100048fe8`؛ لا يعني أن الاستعادة تعيدها كلها |

هذه الطريقة تنسخ ملف SQLite بواسطة NSFileManager؛ لم يُثبت من هذه الخطوة
وحدها أخذ snapshot متسق مع WAL أو عمل quiesce لكل كاتب. لا تُقلد هذه الجزئية
في MSL دون تصميم اتساق واختبار مستقلين.

### الأرشيف المتداخل والـchecksum

المجلد المؤقت يحوي `contents/` و`contents.zip` و`meta.json`، ومسار ZIP خارجي.
`createBackup_createZipFile:error:` عند `0x1000490ac` يقوم بالتسلسل:

1. `createZipFileAtPath:withContentsOfDirectory:` عند `0x100049128` لضغط المحتوى.
2. `createBackup_createMeta:error:` عند `0x100049150`.
3. ضغط **contents.zip وmeta.json** عبر `withFilesAtPaths:` عند `0x100049234`.
4. نقل الملف النهائي إلى `backups/` المحلي أو `Backups/` داخل حاوية iCloud،
   حسب backupToCloud، ثم إزالة المجلد المؤقت عند نجاح المسار.

`createMeta` عند `0x1000495d0` يقرأ حجم **contents.zip** ويضعه في size،
ويستدعي `FileHash.sha1HashOfFileAtPath:` عند `0x1000496f8` ويضع الناتج
في checksum، ثم يحول BackupModel إلى JSON ويحفظ meta.json.
إذًا SHA-1 هنا checksum للمحتوى المضغوط؛ **ليس توقيعًا تشفيريًا يثبت جهة النسخة**.

التركيب المستنتج من هذين المسارين:

```text
Tachimanga_backup_<date>.tmb       (ZIP خارجي)
├── meta.json                     (BackupModel، الحجم وSHA-1 لـcontents.zip)
└── contents.zip                  (ZIP داخلي)
    ├── tachimanga.db
    ├── extensions/*.jar
    ├── prefs/...
    ├── pref.json
    └── pref-all.json
```

هذا مخطط ثابت من كود الإنشاء؛ لا توجد نسخة `.tmb` من بيانات المستخدم ضمن
مدخلات هذا التحقيق لتأكيد بنية فعلية أو تجربة round trip.

### قائمة UserDefaults

`getUserDefaultsWhiteList` عند `0x100048e38` يعيد NSConstantArray عند
`0x10090dfc0`. فُكّت عناصره **62/62** عبر chained pointers؛ محفوظة كاملة في
دليل JSON. منها themeMode وreaderMode وreaderPageLayout وinvertDoublePages،
والـtap zones والقلم واللغة وفلاتر المصادر والإضافات ومفاتيح الجدولة والتنزيلات
وcustomTabs وpersistentTabs وعدد الأعمدة للهاتف/الوضع الأفقي.

وجود مفتاح بالقائمة لا يثبت قيمة افتراضية أو تفعيلًا للمستخدم، ولا يعني أن
كل إعداد حديث في 5.1 مشمول بالقائمة.

## الاستعادة والتحقق

`restoreBackup:orPath:autoBackup:closeDb:complete:` عند `0x1000499dc`
يفحص وجود الملف، ويستخرج، ويملك فرع نسخة تلقائية قبل الاستعادة.
`restoreBackup_extract:error:` عند `0x100049f8c` يقوم بما يلي:

- إنشاء مجلد Tachimanga_restore مؤقت ثم فك ZIP الخارجي.
- قراءة meta.json وبناؤه كـMCBackupModel.
- حساب SHA-1 لـcontents.zip عند `0x10004a2f0` ومقارنته بـchecksum عند `0x10004a330`.
- مقارنة backup.version بإصدار CFBundleVersion الحالي عند `0x10004a418`؛
  ينتقل إلى الاستمرار عند `b.le` ويرفض النسخة الأحدث برسالة
  BACKUP_RESTORE_VERSION_NOT_SUPPORT.
- فك contents.zip إلى contents، ثم فحص tachimanga.db.

`restoreBackup_restore:error:` عند `0x10004a750` يعيد مجلد الإضافات والتفضيلات،
ويقرأ pref.json، ويقيد مفاتيح UserDefaults بالقائمة وأنواع NSString/NSArray/NSNumber.
يملك مسار closeDb وتأخير، وحذف DB الحالية، ثم نسخ tachimanga.db إلى
Tachidesk/sqlite8.db وإزالة الملفات المؤقتة. هذه خطوات استبدال فعلية؛ لم يُثبت
أن الاستعادة transaction واحدة أو قابلة للتراجع عند كل فشل جزئي.

المسار يختلف عن Java `ProtoBackupExport`: الأخير ينتج protobuf مضغوطًا بـGZIP
بامتداد `.tachibk`. لا يكفي دعم أحدهما للادعاء بتوافق الآخر.

## iCloud والمهام المستمرة

MCCloudDocumentPlugin يستعمل حاوية المستندات، وMCCloudDocumentQuery يستعمل
NSMetadataQuery لبدء/إيقاف مراقبة الملفات. توجد قائمة نسخ محلية ودمج سجلاتها
مع السحابة وطلب تنزيل ملف iCloud. نجاح الحساب والاستحقاقات وتعارض الملفات
غير مُشاهد؛ العينة معدلة وفيها hooks متعلقة بالاستحقاقات.

MCContinuedTaskPlugin.setup عند `0x10000a200` يسجل معرفين مشتقين من bundle ID
باللاحقتين `.task1` و`.task2` عبر registerForTaskWithIdentifier:usingQueue:launchHandler:
عند `0x10000a2e8` و`0x10000a390`، وله فرع تجاوز للأنظمة غير iOS 26.
توجد property بنوع BGContinuedProcessingTask، وsubmitTaskRequest:error: عند
`0x10000aa90`، ومعالجان للتنزيل والتحديث.

Java NativeChannel يرسل DOWNLOAD:START وUPDATE:STATUS، والمضيف يوجههما إلى
هذه الطبقة؛ وفي الاتجاه المقابل يطلب حالة Java عبر JavaChannel. هذا يشرح
تقاسم مسؤولية طابور Java واستمرار المهمة الأصلية. لا يثبت استمرار تنزيل بعد
إنهاء التطبيق أو قبول النظام لكل task أو سلامة مسار expiration.

## النقل والويب التفاعلي

MCURLSession.init عند `0x100021678` ينشئ جلسة عادية وجلسة تمنع اتباع redirect
وأخرى لا تقبل cookies ولا تتبع redirect. dataTaskWithRequest عند `0x100021814`
يقرأ followRedirects ثم noCookie لاختيار الجلسة. القيمة noCookie تقود إلى
الجلسة الأخيرة في الفرع المفحوص؛ لا يُفترض أن جميع تركيبات القيم مستقلة.

checkCloudflareBlock عند `0x100021e6c` يفحص disableBypass وheaders منها
cf-mitigated وServer وCF-RAY وchallenge. MCCloudflareInterceptor.load عند
`0x100032388` يقرأ كوكيز URL وUser-Agent ويحمّل الطلب داخل WKWebView، مع
نافذة تفاعلية ومهلة وإيقاف. notifyFlutter عند `0x100032698` يرسل
BYPASS_NOTIFY عبر MC_NOTIFY. يوجد كتم للتنبيهات حسب المضيف.

هذه دراسة لحدود النقل وتجربة WebView، وليست تشغيلًا أو إثبات تجاوز حماية موقع.
لم تُحل كل فروع إعادة الطلب أو التشفير أو التزامن. على MSL تنفيذ نقل واضح
وWebView تفاعلي واختبار cookies وredirect والإلغاء بدل افتراض أن OkHttp وحده
يكفي لكل مصدر.
