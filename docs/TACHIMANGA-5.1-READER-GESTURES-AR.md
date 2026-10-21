# Tachimanga 5.1 — المؤشر والضغط المطوّل وتغيير السرعة

21 أكتوبر 2026. متابعة ثابتة للعينة المعدلة 5.1/520 نفسها؛ لا تشغيل للتطبيق
أو Dart أو JAR مستخرج، ولا إثبات مطابقة على iPhone. بصمة App:
`4ee96f784bd111cd23842e98f66d5f8b49fd635ef6ed1bee92d22c763c255469`.

## الأدلة والتغطية

قورنت **12 طريقة، 1,643 تعليمة و6,572 بايت** من تعليقات disassembly في
تصدير dae بقراءة Capstone مستقلة لبايتات App. ثُبت **51 موضع تحقق** للنداءات
والفروع وoperands المهمة. هذه ليست محاكاة لتنفيذ الدوال أو اختبار gesture arena.

- الأداة: [review_tachimanga_gestures.py](../scripts/review_tachimanga_gestures.py).
- النتائج: [reader-gestures.json](../validation/rea/tachimanga-5.1-reader-gestures.json).
- مراجعة الأرقام والـcallbacks: [pool-followup.json](../validation/rea/tachimanga-5.1-pool-followup.json)
  و[review_tachimanga_pool.py](../scripts/review_tachimanga_pool.py).

```bash
python3 scripts/review_tachimanga_gestures.py /path/to/tachimanga-analysis-5.1 /tmp/gestures.json
python3 scripts/review_tachimanga_pool.py /path/to/tachimanga-analysis-5.1 /tmp/pool-review.json
```

## لماذا احتاجت الثوابت قراءة إضافية؟

مُنسّق نص pool في dae v0.1.13 يختار بعض الأنواع بأرقام CID ثابتة، منها
Array=89/90 وDouble=61؛ راجع [المصدر المثبت](https://github.com/ejfkdev/dae/blob/9f65eeaef92b9709b169c2a9a503a89bbdd14b72/src/export/ppobjs.rs).
لكن profile الخاص بهذه العينة، Dart 3.6.1 دون ضغط المؤشرات، يستعمل
Array=90 وImmutableArray=91 وDouble=62 وFunction=7. لذلك كان pp.txt يعرض
ImmutableArray وDouble وFunction دون البيانات اللازمة لهذه المتابعة.
هذا قصور في العرض المحدد، وليس إثباتًا أن كل التحليل السابق خاطئ.

أضيف استعلام قراءة إلى checkout خارجي مثبت لـdae، دون استيراد كوده أو
مخرجاته الخام إلى التطبيق. يعرض المصفوفات وFunctionRec التي يحتفظ بها المحلل،
ويقرأ Double بواسطة قارئ جانبي لا يغير مؤشر قارئ fill الأصلي.
الوصفة [prepare_tachimanga_pool_tool.py](../scripts/prepare_tachimanga_pool_tool.py)
ترفض مصدرًا أو بصمات مختلفة، وتضيف [المساعد المستقل](../scripts/tachimanga_pool_audit.rs).
بُني بوضع release، وCargo.lock مثبت، ودون ميزة asm، باستخدام Rust 1.90.0.
بصمات المصدر والأداة والبناء والـprofiles محفوظة في دليل JSON أعلاه.

أوقف وضع debug القراءة بسبب overflow في shift قديم بمسار instance bitmap
داخل المحلل الخارجي. نجح release، دون تعديل ذلك المسار، وبلا warnings:
71,800 عنصر pool، و58,419 سجل Function في snapshot، و490 قيمة Double ملتقطة.
عدد pool يطابق التصدير السابق؛ أعداد Function هنا ليست عدد عناوين الدوال الفريدة.
فُك ترميز **16 رقمًا مختارًا** مستقلًا في Python من نطاقاتها داخل App، وقورنت
IEEE-754 bits بالقيم الناتجة. بنية المصفوفة وربط Function يظلان معتمدين على
المحلل المراجع؛ لا يُدّعى وجود محللين مستقلين كاملين للـsnapshot.

لإعادة بناء الاستعلام في checkout خارجي نظيف عند commit المثبت:

```bash
python3 scripts/prepare_tachimanga_pool_tool.py /path/to/dae-source
```

ثم يبنى داخل ذلك checkout بواسطة
`cargo build --release --locked --no-default-features --bin pool_audit`.
صيغة الاستدعاء هي `pool_audit APP SDK_PROFILE PLATFORM_PROFILE PP_OFFSET...`،
بـprofiles `dart-3.6.1-w64-no-compressed.json` و`macho-arm64.json`، وإزاحات
`query_offsets` المسجلة في دليل JSON. يحفظ stdout في
`flutter-full/pool-followup/pool-values.json`؛ استُخدمت CPU واحدة و3 GiB
و60 ثانية CPU و90 ثانية مهلة كلية، وفُحص SHA-256 لـApp قبل الاستدعاء.
تبقى الأداة الثنائية ومصدرها ومخرجاتها الخام خارج مستودع الإنتاج.

## الحالة المخزنة وربط الأحداث

FocusWrapper.build عند `0x510b10` ينشئ hooks للحالة التالية:

| حقل السياق | المعنى المستنتج من القراءة والكتابة |
|---|---|
| `0x1f` | LongPressState: init=0، wait=1، longPressing=2 |
| `0x27` | Timer اختياري |
| `0x2f` | عدد المؤشرات/الأحداث النشطة؛ يبدأ بصفر |
| `0x37` | توقيت بدء الانتظار بالمللي ثانية |
| `0x3f` | معرّف المؤشر المتتبّع، اختياري، وليس Set |
| `0x47` / `0x4f` | آخر موضع / موضع بدء الضغط المطوّل |
| `0x57` | مستوى السرعة؛ يبدأ بـ4 |

المعرف والقيم Tagged Smi حيث تنطبق؛ القيمة الآلية 8 تعني العدد 4.
هوية الـcallback حُسمت من pool: down عند `0x511520`، move عند `0x511174`،
up عند `0x51111c`. مدخلا pool للـup والـcancel لهما مرجعان مختلفان لكن
**عنوان تعليمات واحد `0x51111c`**.

ربط Listener للحقل `0x37` عند `0x510eb0` يصل إلى render field `0xcf`
عبر `Listener.updateRenderObject` عند `0x26fbcc..0x26fbd0`، ثم يستدعيه
`RenderPointerListener.handleEvent` عند `0x3839b4` بعد اختبار نوع cancel.
فُحص ربط CID 3814 لـ_TransformedPointerCancelEvent و4571 لـPointerCancelEvent.
إذًا الإلغاء يدخل محول الرفع نفسه، وليس مجرد تشابه أسماء.

تثبيت pointer callbacks مشروط بحقلين في widget وقيمة provider يراقبها build.
لم تُحسم هنا أسماء كل هذه الحقول أو القيمة الافتراضية لذلك provider؛ لا يعني
وجود المعالج أنه متاح دائمًا في كل وضع قارئ أو إعداد تكبير.

## البدء والانتظار والحركة

onPointerDown عند `0x511a68` يزيد العداد. إذا وجد pointerEvent ولم يوجد معرف
متتبّع، يحفظ المعرف والموضع؛ لا يستبدل المعرف بمؤشر لاحق.
من حالة init ينتقل إلى wait، ويسجل الوقت، وينشئ Timer واحدًا بمهلة
**500,000 ميكروثانية = 500 مللي ثانية**؛ العقدة الثابتة عند pool `0x6650`.

فرع down أثناء wait يختبر العداد ثم فرق التوقيت. في مسار المؤشر الإضافي
قبل 500 مللي ثانية يلغي Timer ويعيد init. إذا بلغ فرق التوقيت 500 أو أكثر
يخرج ذلك الفرع دون إلغائه هناك. لا يُستنتج أن كل لمس متعدد يلغي الانتظار
في كل توقيت، ولا أن التأخر في تسليم timer على جهاز قد اختُبر.

onPointerMove يطابق event.pointer مع المعرف المحفوظ، ويحدّث آخر موضع.
قبل longPressing لا يظهر في هذا المعالج حد مسافة/slop يلغي الانتظار؛
لا تُسقط عليه تلقائيًا قواعد LongPressGestureRecognizer المعتادة.

عندما يعمل timer عند `0x511f84`، يضع longPressing، ويأخذ آخر موضع كأصل،
ويعيد مستوى السرعة إلى 4، ثم يستدعي callback الحقل `0x1f` في widget.
يظهر mediumImpact عندما يكون pointerEvent غائبًا فقط في هذا الفرع.
لا يظهر إعادة فحص wait داخل callback المؤقت نفسه.

## مستويات السرعة والهامش

مصفوفة pool `0x38f88` تحتوي القيم التي تُمرّر إلى callback السرعة:

| المستوى | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| القيمة | 3.0 | 2.0 | 1.5 | 1.25 | 1.0 | 0.75 | 0.5 | 0.25 |

ومصفوفة الحدود `0x38f98` هي: **−180، −120، −60، −30، 60، 120، 180**.
المدخل deltaY هو الموضع الرأسي الحالي ناقص موضع بدء الضغط المطوّل.
resolveLongPressScrollSpeedLevel عند `0x511418` يقيد المستوى الحالي إلى 0..7، ثم:

1. ينقص المستوى طالما deltaY ≤ الحد السابق − **12**.
2. يزيده طالما deltaY ≥ الحد الحالي + **12**.
3. قد يعبر عدة مستويات في حدث حركة واحد.

إذًا النتيجة تعتمد على المستوى السابق؛ ليست تقسيمًا ثابتًا لـdeltaY فقط.
مثلًا من المستوى 4 ينتقل إلى 3 عند deltaY ≤ −42، ويعود إلى 4 من 3 عند
deltaY ≥ −18. لا ينتقل من 4 إلى 5 إلا عند deltaY ≥72.
عند تغير المستوى فقط، يحدّث الحالة ويطلب selectionClick ثم يستدعي حقل
widget `0x27` بالقيمة الجديدة. **وحدة السرعة النهائية وطريقة استخدام المعامل
في التمرير تتطلبان تتبع المستدعي**؛ لا نسمّي الرقم وحده بكسلًا/ثانية أو مدة.

## الرفع والإلغاء والتنظيف

onPointerUp عند `0x5115e8` ينقص العداد مع حد أدنى صفر، ويحسب هل يطابق
الحدث المؤشر المتتبّع:

- أثناء wait: يعيد init ويلغي Timer ويمسح مرجعه، ثم يستدعي الفعل القصير
  في widget field `0x17`، دون اشتراط مطابقة المعرف في هذا الفرع.
- أثناء longPressing: ينهي الحالة إذا طابق المعرف **أو** وصل العداد إلى صفر،
  ثم يستدعي callback النهاية في الحقل `0x2f`.
- تنظيف المعرف وآخر موضع والأصل وإعادة المستوى إلى 4 يحدث إذا طابق المعرف.
  لا يعني انتهاء الحالة دائمًا أن هذه الحقول مُسحت في كل مسار.
- effect cleanup عند `0x5115a0` يلغي Timer الموجود فقط؛ لا تظهر فيه إعادة
  ضبط شاملة لبقية الحالة.

لأن cancel يدخل محول up نفسه، يجب التحقق على الجهاز مما إذا كان الفعل القصير
يُلاحظ بعد cancel أثناء wait، وكيف يمنع المستدعي أثرًا غير مرغوب فيه.
لا يستنتج التحليل وحده أن نظام Flutter يسلم كل السيناريوهات المفترضة.

## ما بقي قبل نقله إلى MSL

لم يوجد مسار longPress في ملفات ReaderView وOnlineReaderView وReaderCore/Library
الحالية عند المراجعة. التنفيذ ضمن READ-13B لا يغلق إلا باختبار المؤقت والحركة
والإصبع الثاني والرفع والإلغاء، والتكبير وWebtoon والخلفية ومنافسة النقر المزدوج.
تبقى لوحة المفاتيح والقلم والتأثير النهائي لكل callback والوحدات والاتجاه الفيزيائي
للشاشة خارج هذه المتابعة. أسماء C1/C2 في [مناطق اللمس](TACHIMANGA-5.1-READER-NAVIGATION-AR.md)
حُلت إلى عناوين closures في pool، لكن دلالتها النهائية تتطلب تتبع الحقول المستقبلة.
