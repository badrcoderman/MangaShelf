# Tachimanga 5.1 — مناطق اللمس واختيار اتجاهها

دراسة ساكنة للعينة المعدلة 5.1/520 نفسها. بصمة Flutter App هي
`4ee96f784bd111cd23842e98f66d5f8b49fd635ef6ed1bee92d22c763c255469`.
كل عنوان أدناه نسبي للصورة قبل ASLR. لم يُشغّل App أو Dart أو أي كود مستخرج.

## التغطية وطريقة التحقق

فُحصت عشر طرق من اختيار التخطيط، وبناء التخطيطات الأربعة، وتركيب القارئ،
والتفضيلات. قورنت **1,915 تعليمة، 7,660 بايت و53 موضع تحقق** من تصدير dae
بفك Capstone المستقل لبايتات App. تشمل مواضع التحقق operands الحقول وأوزان
flex، لا أسماء الدوال وحدها. لا يعد هذا اختبارًا لمحرك إيماءات Flutter.

الأداة: [review_tachimanga_navigation.py](../scripts/review_tachimanga_navigation.py)،
مع القارئ المشترك [review_tachimanga_reader.py](../scripts/review_tachimanga_reader.py).
الأدلة: [reader-navigation.json](../validation/rea/tachimanga-5.1-reader-navigation.json).
إعادة التشغيل لا تنفذ كود العينة:

```bash
python3 scripts/review_tachimanga_navigation.py /path/to/tachimanga-analysis-5.1 /tmp/navigation.json
```

## الهوية وترتيب التفسير

`ReaderView.build` عند `0x3e1b0c` يركب GestureDetector أبًا، ثم يضع معه
`ReaderNavigationLayoutWidget` كطبقة أخرى. يحمل الأخير layout وreaderMode
ووظيفتَي callback في الحقلين `0x1f` و`0x27`، كما يظهر في
`0x3e1ba8..0x3e1bc0`.

نسمّي الوظيفتين الأصليتين **C1 وC2** لأن أسماءهما الدلالية النهائية لم تحسم
من موضع البناء هذا. بعد شرط التبديل، تصل إلى التخطيط وظيفتا **A وB**، في
الحقلين `0x0f` و`0x17`. لا نفترض أن A تعني دائمًا «السابق».

يبني كل تخطيط مناطق GestureDetector بسلوك `translucent` المثبت من pool
`0xb580`. لكنه يترك مساحات بلا GestureDetector خاص بالتخطيط. نسمّيها **G**؛
قد يصل النقر فيها إلى الأب، لكن لم يثبت هنا أن فعله النهائي دائمًا فتح الأدوات.
عرض label إرشادي في هذه المساحة ليس إثباتًا مستقلًا لتلك الوظيفة.

## الأشكال الفعلية

الرسوم التالية **استنتاج لشجرة Row/Column وأوزان Expanded**؛ ليست لقطات
مرجعية أو قياسات بكسلات. الأعمدة بترتيب أبناء Row، والصفوف بترتيب أبناء
Column. لا تعني الأعمدة تلقائيًا اليسار الفيزيائي ثم اليمين: Directionality
الموروثة وحدود viewport وSafe Area لم تختبر هنا.

كل خلية في الرسم تمثل ثلث البعد في توزيع المساحة المتاحة:

| الفهرس والتخطيط | الصف الأول | الصف الثاني | الصف الثالث |
|---|---|---|---|
| 1 — LShaped | A A A | A G B | B B B |
| 2 — RightAndLeft | A G B | A G B | A G B |
| 3 — Edge | B G B | B G B | B A B |
| 4 — Kindlish | G G G | A B B | A B B |

أدلة الشجرة والأوزان:

- **RightAndLeft، `0x3f8e54`:** Row من ثلاث مناطق بعرض متساو؛ الطرفان
  لهما callback، والوسط G. callback الأول من `0x0f`، والأخير من `0x17`.
- **Edge، `0x3f81d8`:** Row من ثلاثة أبناء بأوزان 1:1:1. الجانبان B،
  والوسط Column من G بوزن 2 ثم A بوزن 1؛ انظر `0x3f8310` و`0x3f83d0`.
- **Kindlish، `0x3f8618`:** Column من G بوزن 1 ثم Row بوزن 2. داخل الصف
  السفلي A بوزن 1 وB بوزن 2؛ انظر `0x3f8810` و`0x3f88e0`.
- **LShaped، `0x3f89ac`:** ثلاثة صفوف متساوية؛ الأعلى A، والوسط A/G/B
  بعرض متساو، والأسفل B. لا يمكن تمثيله بحدّي X فقط.

`ReaderNavigationLayoutWidget.build` يوزع الفهارس عند `0x507360..0x507650`.
إذا وصله فهرس صفر أو قيمة أكبر من 4، يعيد overlay فارغًا. القيمة 5 اسمها
`disabled`، والصفر `defaultNavigation` في metadata. لا يعني هذا أن كل
المستدعين يمررون defaultNavigation دون حله في طبقة أعلى.

## العكس: سياستان مختلفتان

يفحص build وضعي `singleHorizontalRTL` و`continuousHorizontalRTL` عند
`0x50701c..0x507050`. ثم يفحص هل التخطيط `rightAndLeft`، ويقرأ تفضيل
`invertTap` من provider المشترك عند `0x506f2c`. تحمل شاشة إعداد العكس
provider نفسه عند `0x56dccc`.

النتيجة المباشرة للفروع `0x507074..0x507084`:

| التخطيط | شرط تبديل C1 وC2 قبل بناء A/B |
|---|---|
| RightAndLeft | وضع القراءة أحد وضعي RTL المذكورين |
| LShaped وEdge وKindlish | تفضيل invertTap يساوي true |

في RightAndLeft لا يدخل invertTap في قرار هذا الفرع؛ وفي التخطيطات الأخرى
لا يدخل اختبار RTL في قرار التبديل نفسه. **لا تطابق هذه القاعدة XOR عامًا
بين RTL والعكس.** يحتفظ دليل JSON بجدول الحالات الست عشرة كاملًا.

هذه قاعدة اختيار callback داخل widget. لا تثبت وحدها اتجاه العرض الفيزيائي
للـRow أو ترتيب الصور المزدوجة أو اتجاه سحب الصفحة؛ تلك عقود أخرى.

## التفضيلات والتعطيل المؤقت

- `ReaderNavigationLayoutKey.build` عند `0x3c40c8` يستعمل مفتاح
  `readerNavigationLayout` وقيمة ابتدائية `disabled` في الفرع المفحوص.
- Webtoon له مفتاح `readerNavigationLayoutWebtoon` مستقل. عند غياب القيمة
  التي يراقبها من الإعداد العادي، يستعمل disabled، ثم يهيئ إعداد Webtoon؛
  انظر `0x3c45d0..0x3c4600`. وجود إعداد محفوظ قد يغير النتيجة.
- `InvertTap.build` عند `0x394690` يهيئ مفتاح `invertTap` بقيمة false.
- build يراقب `tapZoneTemporarilyDisabled`؛ إذا كان true يسجل الرسالة
  ويعيد SizedBox فارغًا عند `0x50733c..0x50735c`. ليس هذا هو تعطيل التخطيط
  الدائم، ولا يثبت سبب تفعيل الحالة أو مدة بقائها.

## الفرق المراجع مع MSL

عند commit `56be08c`، يستعمل [ReaderSettings](../Sources/ReaderCore/Library.swift)
`pageStep(forTapFraction:)` موضع X فقط: أقل من 0.3 أو أكبر من 0.7، مع تبديل
الإشارة حسب ReadingDirection، وتعطيل التنقل في Webtoon. يمرر
[ZoomableImage](../iOS/MangaShelf/ReaderView.swift) الكسر الأفقي فقط، ويستعمله
القارئ المحلي و[قارئ المصادر](../iOS/MangaShelf/OnlineReaderView.swift).

هذا يثبت وجود تنقل حواف بسيط في MSL؛ لا يثبت تنفيذ التخطيطات الأربعة أو
النسب 1:2 أو سياسة invertTap المنفصلة أو إعداد Webtoon المستقل. READ-03
في TODO يظل إنجازًا لنطاق الحواف المذكور فقط؛ المطابقة الأوسع تحتاج بندًا
مفتوحًا واختبارات حدود ثنائية الأبعاد وتحديثات واجهة حقيقية.

## ما بقي

لم تحسم هذه المتابعة أسماء C1/C2 النهائية، أو اتجاه Row الفيزيائي في كل
فرع، أو أولوية الأب والطبقة في gesture arena، أو مناطق النقر بعد التكبير،
أو السحب والضغط المطول وdouble tap والقلم والإلغاء. لا يُغلق REV-09 أو
اختبار الهاتف أو المطابقة البصرية بهذه الأعداد وحدها.
