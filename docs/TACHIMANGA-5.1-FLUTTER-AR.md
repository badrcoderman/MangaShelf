# Tachimanga 5.1 — تفكيك واجهة Flutter والقارئ

هذا الجزء يدرس `App.framework/App` من عينة 5.1/520 المقدمة؛ بصمة الملف
`4ee96f784bd111cd23842e98f66d5f8b49fd635ef6ed1bee92d22c763c255469`.
لم يُشغّل التطبيق. العناوين هنا نسبية لصورة App قبل ASLR، وقاعدتها صفر؛ تختلف
عن عناوين مضيف iOS التي تبدأ بـ`0x100000000`.

## التفكيك الفعلي والتغطية

طابقت بصمة snapshot `f956f595844a2f845a55707faaaa51e4` تعريف Dart 3.6.1.
الخصائص المشحونة: product وARM64 iOS و`no-compressed-pointers` وdedup instructions.
هذا يحدد إصدار Dart المطابق للتنسيق؛ لم يُثبت إصدار Flutter الكامل أو commit التطبيق.

بعد مسح strings مستقل، استُخدمت أداة التحليل [dae](https://github.com/ejfkdev/dae)
الإصدار v0.1.13، ذات SHA-256
`37fb8ddea7fe0710d6994ac3f9c0484d9b1aa9b320cfae134fc76a78b9f5db7f`،
مطابقة لبصمة أصل الإصدار. الأداة تقرأ snapshot ولا تشغّل Dart الخاص بالعينة.

فشلت محاولة تصدير أولى بسبب إنشاء threads مع حد ذاكرة منخفض. أعيدت المحاولة
بملف تشغيل مختلف: CPU واحدة، حد address space قدره 3 GiB، ومهلة 180 ثانية.
انتهت بنجاح exit 0 خلال 171.268 ثانية. المجلد المعتمد هو
`flutter-full/dae-export-single-cpu`؛ مجلد `dae-export` الأول غير مكتمل.

| الناتج | العدد والنطاق |
|---|---:|
| سجلات Function من snapshot | 55,758، تشمل التبعيات |
| عناوين وظائف مسماة/كتل pseudocode | 54,287 |
| دوال لها disassembly في التصدير | 49,740 |
| ملفات Dart pseudocode | 1,775 |
| مكتبات التطبيق ذات وظائف | 593، تحوي 7,182 سجل وظيفة |
| كتل pseudocode منظمة | 52,056 |
| كتل غير منظمة | 2,231 |
| direct call edges | 189,587 |
| مواضع استدعاء غير مباشر | 22,911، أهدافها ليست مثبتة كلها |
| ملفات التصدير الكاملة | 3,552، مجموع 357,691,806 بايت |

هذه الأعداد لها نطاقات مختلفة: 1,775 serialized library objects لا يساوي
1,866 export library groups، و5,754 serialized class objects لا يساوي
8,954 export class records. لا تُجمع للوصول إلى نسبة استرداد سورس.

الأداة أبلغت عن سطر unmapped واحد. ملفات Dart الناتجة تحتوي عمليات سجلات
وذاكرة و`callIndirect` وpseudo-runtime placeholders؛ **ليست المشروع الأصلي
القابل لبناء التطبيق**، ولم يُجر اختبار Dart analyzer أو تكافؤ تشغيل عليها.

الأدلة: [ملخص Flutter](../validation/rea/tachimanga-5.1-flutter-deep.json)،
[العقود المنتقاة](../validation/rea/tachimanga-5.1-feature-contracts.json).
الفهرس الخارجي `flutter-full/dae-output-manifest.json` يحفظ hashes جميع الملفات؛
بصمته `f749688bdce8be1a93a03effbf378e7ff63d5a33f25b181c88cb24728d439552`.

## من أزرار التصفح إلى محرك المصادر

اكتُشف endpoint افتراضي `http://127.0.0.1:4567` عند `0x159a84`، مع إعدادات
لتغييره؛ ليس عنوان خدمة ثابتًا لا يمكن تغييره. يربط DioClient الطلبات بخلفية Java
المضمنة، التي تسجل مسارات `api/v1/`، كما يثبت [تقرير Java](TACHIMANGA-5.1-JAVA-AR.md).

| المستودع/العملية | مدخل App | دليل العقد |
|---|---|---|
| SourceRepository.getSourceList | `0x4436a0` | literal `/source/list` عند `0x443720` |
| getSourceListForSearch | `0x450e28` | `/source/listForSearch` عند `0x450ea8` |
| getMangaList | `0x44fb64` | بناء طلب قائمة المصدر والفلاتر؛ ليس scraper داخل الواجهة |
| updateMeta / queryMeta | `0x467208` / `0x85e20c` | `/source/meta/update` و`/source/meta/query` |
| getPreferenceList / updatePreferenceList | `0x4685dc` / `0x46a94c` | تفضيلات المصدر لها طلبات مستقلة |
| ExtensionRepository.getExtensionList | `0x437328` | استدعاء قائمة الإضافات عبر المستودع |
| installExtensionFile / updateExtension | `0x439064` / `0x448314` | مساران مختلفان للاستيراد والتحديث |
| RepoRepository.getRepoList / createRepo | `0x3c6808` / `0x5382a8` | إدارة المستودعات مستقلة عن المصادر |
| SyncRepository.syncNow | `0x4359f4` | `/sync/syncNow` ثم DioClient.get |
| enableSync / disableSync | `0x5942d8` / `0x594964` | `/sync/enableSync` و`/sync/disableSync` |
| syncNowIfEnable / socketUpdates | `0x5a1030` / `0x85b2dc` | `/sync/syncNowIfEnable` و`/sync/ws` |

هذه أفعال ونداءات ثابتة. لم يُرصد نجاح طلب فعلي أو تسجيل حساب أو مزامنة شبكة.
عقود المصادقة والسحابة لا تعني إمكانية نسخ خدمة Tachimanga الخاصة داخل MSL.

## القنوات الأصلية: دليل مستقل عن المضيف

`getMagicPipe` عند `0x159fb0` يحمّل كائن MethodChannel من pool offset `0x3720`؛
اسم الكائن `MAGIC_PIPE`، بترميز StandardMethodCodec/StandardMessageCodec.
`notifyChannel` عند `0x5a3d18` يحمّل كائنًا من `0x1ed00` اسمه `MC_NOTIFY`.
وهذا يطابق تسجيل القناتين في ViewController داخل المضيف.

لا يكفي البحث المباشر عن مراجع نص `MAGIC_PIPE`: النداء يستخدم كائنًا ثابتًا
يحمل الاسم. حفظت هوية الكائن وحقوله بدل اعتبار غياب xref النصي نفيًا للقناة.

حُلّت كذلك 44,733 قراءة PP نمطية عبر 591 ملف تطبيق، تشمل نمطي LDR المباشر
وADD إلى PP ثم LDR المتجاور. الفهرس `flutter-full/app-pool-references.json`.
هذا resolver نحوي محدود، ولا يحل كل التحويلات أو الاستدعاءات غير المباشرة.
أوامر النسخ الأصلية مرتبطة بمواضع Flutter وiOS في [تقرير المنصة](TACHIMANGA-5.1-PLATFORM-AR.md).

## القارئ: مكونات وحالة وتقدم

### اختيار العرض

`ReaderScreen2.build` عند `0x4e89c4` يستدعي بصورة مباشرة:

- `MangaWithChaptersWithIdFamily.call` لبيانات العنوان والفصول.
- `ReaderAppearance.resolve` و`ReaderBackground.resolve` لحل مظهر القارئ.
- providers لخلفية العنوان واتجاهه، مرتبطة بـmangaId.
- `MangaTypeUtil.isWebtoonMangaType`، لاختبار نوع العنوان قبل بناء العرض.

توجد مكونات تنفيذ منفصلة: ContinuousReaderMode2 عند `0x4fb8c4`،
وDoublePageReaderModeV2 عند `0x500f60`، وPageReaderMode. يطلب مسار الصفحتين
`ReaderSinglePageSetWithMangeIdFamily` و`CropBorderWithMangaIdFamily` و
`InvertDoublePagesWithMangaIdFamily`. يبني `buildDoublePageWidget` عند
`0x502648` الصور عبر `buildPageImageWidget` عند `0x502af8`.

وجود single-page set وإعداد عكس الزوج يثبت أن العرض المزدوج له حالة إضافية؛
لا يثبت وحده كل قاعدة لصفحة الغلاف أو الصور العريضة. يلزم اختبار تسلسل صفحات
فعلي قبل اعتماد خوارزمية الاقتران في MSL.

### الإعدادات لكل عنوان

حقول snapshot تربط providers مثل `_$CropBorderWithMangaId` و
`_$InvertDoublePagesWithMangaId` و`_$MangaChapterFilterUnreadWithMangaId`
بـ`mangaId` عند field offset `0x18`.
`CropBorderWithMangaId.build` عند `0x864704` يقرأ MangaWithIdFamily؛
ومسار update عند `0x4fac08` يحتوي مفاتيح meta
`flutter_cropBorder` و`flutter_cropBorderPad` وفرع `ipad`.
هذا دليل تخزين وحل إعداد مرتبط بالعنوان، مع تمييز الجهاز في القص.

ReaderToolbarActions يربط أفعال القص والتمرير المستمر والتمرير أثناء الضغط
بـproviders، بدل الاقتصار على النصوص المعروضة. توجد شاشة tap zones عند
`0x564c18` وشاشة لتخصيص الأدوات ومفاتيح Apple Pencil المزدوج/squeeze.
وجود الخيارات لا يثبت نجاح القلم أو تعارضاته على جهاز بعينه.

### قص الهوامش

`ReaderPageImageTransformer.transform` عند `0x74d710` يصل إلى
`CropBorderUtil.cropImage` عند `0x74b904` و`detectCropInsets` عند `0x74c3b0`.
الأخير يستدعي `_downscale` عند `0x74d470` و`_detectEdge` أربع مرات؛
وتوجد `_isColBorder` و`_isRowBorder` و`_detectBorderColor`.
إذًا للقص مسار معالجة صور فعلي؛ لم تُثبت دقته أو عتباته بصور اختبار.

### التقدم ودورة الحياة

`updateLastRead` عند `0x4eb684` يحتوي فرع تخطي عند وجود التطبيق بالخلفية،
واستدعاءات AutoDelete.addToDeleteList وUpdatePageRefreshChapterSignal.update
وتحديث بيانات الفصول المحلي والصامت. يميز نص التشخيص `isFinalPage` وحالة read؛
لم تُثبت جميع حدود الصفحات/الفصول أو سباقات الحفظ أثناء الإغلاق.

يتبادل القارئ `SCREEN_ON` بقيمتي `0` و`1` في مساري الإنهاء والبدء عند
`0x4ecbe4` و`0x4ed320`، مع منطق إعادة الاتجاه السابق. وتوجد استدعاءات OCR
للصفحة عند `0x4f232c` ونوافذ الإجراءات، وطلب `READER:NO_CHAPTER_AD`؛ لا تُنسب
نتائج بوابات الشراء في هذه العينة المعدلة إلى التوزيع الرسمي.

## المكتبة وشكل iOS 26

`LibraryScreen.build` عند `0x4a35a4` يصل إلى
`useNativeLiquidGlassActionToolbar`، وشاشات المكتبة تملك filter/sort منفصلين،
ومرشحات متتبعات؛ مثل `_LibraryTrackerFilters` الذي يحدث
LibraryMangaFilterTrackerList.updateTracker عند `0x5bdf4c`.

توجد طبقة native_root_*_26؛ `NativeRootAppBar26.build` عند `0x59ea30` يقرأ
NativeRootTabs26 وNativeRootAppBarScope26، ويفحص isSmallTabletOrWider
وينشر الحالة عبر NativeRootAppBarController26.publish عند `0x59f488`.
هذا يثبت واجهة تتغير حسب المضيف/الجهاز، ويشرح لماذا لا تكفي محاكاة لقطة قديمة
لنسخ مظهر 5.1 على iOS 26. لم تُقَس هندسة هذه الفروع على الهاتف.

ملفات routes توثق وجهات التفاصيل والقارئ والمصدر والتفضيلات والمستودع والترحيل
والتتبع، لكن الصورة البصرية والحركة واللمس وVoiceOver تتطلب لقطات وتجارب مرجعية.

## الموارد واللغة

المسح المستقل أحصى 75,266 كائن string مرشحًا: 54,040 Latin-1 و21,226 UTF-16LE،
منها 1,431 تحمل العربية. هذه ليست إحصاء مفاتيح ترجمة فريدة. ظهرت 25 مكتبة
localizations مولدة، و815 مسار مصدر خاص بالتطبيق و153 علامة screen/dialog/page.
عدد المسارات أكبر من ملفات الكود المستعادة لأن AOT لا يحتفظ بكل شيء بالطريقة نفسها.

فُهرست 115 مدخلة أصول UI وثلاثة خطوط وملفات cmaps. فُك NOTICES.Z بواسطة gzip
بعد التحقق من magic؛ ليس zlib عاديًا. المخرجات تحت `flutter-full/` خارج مستودع
التطبيق. لم تُنقل أصول أو خطوط غير محسومة الترخيص إلى MSL.

## أثر النتائج على MSL

تابعت [دراسة الاقتران والتقدم](TACHIMANGA-5.1-READER-PAIRING-AR.md) ثلاث عشرة
طريقة عبر مقارنة تعليمات App مباشرة بتصدير dae؛ توضح متى تُفصل الصفحة
الأولى أو المكتشفة منفردة، وكيف تُحفظ الهوية والتقدم عند تغير الأزواج.
تبقى المطابقة البصرية والإيماءات وفروع RTL الكاملة خارج هذا الإثبات.

وتوضح [متابعة مناطق اللمس](TACHIMANGA-5.1-READER-NAVIGATION-AR.md) التخطيطات
الأربعة من شجرة Row/Column، وسياسة مختلفة لـRightAndLeft وبقية التخطيطات عند
اختيار callbacks. الرسوم بترتيب الأبناء؛ لا تمثل قياسات شاشة أو اختبارًا
لتنافس recognizers أو اتجاه Row الفيزيائي في كل سياق.

1. محرك المصادر يحتاج عقد Source/SourceFactory الفعلي والتبعيات وJNI؛ إعادة
   ترتيب Browse وحدها لا تصلح الإضافات.
2. يختبر مظهر iOS 26 وفروع الهاتف/iPad والاختيار المتعدد على حدة.
3. إعداد كل عنوان يحل من العام ثم meta العنوان؛ اللغة لا تحدد اتجاه القراءة.
4. القارئ منظومة عرض وصور وتقدم وحياة تطبيق وتنزيلات، وله اختبارات منفصلة.
5. عقود النسخ والسحابة والقنوات موثقة مستقلًا؛ لا تُدمج في JSON export بسيط.

لا تثبت هذه الدراسة مطابقة بصرية أو تشغيلًا كاملًا أو استرداد السورس الأصلي.
الفهرس الموحد يحدد ما حُسم وما بقي في [تقرير التحقيق](TACHIMANGA-5.1-INVESTIGATION-AR.md).
