# ورقة البارامترات والمراجعة الدوريّة — منظومة SaaS المشتركة

> **الغرض:** لكل بارامتر ضُبط في 2026-09-29: قيمته، **سبب** القيمة، **أمر قياسه**،
> **النطاق السليم**، و**العتبة التي تُلزمنا بتغييره**. تُستخدم هذه الورقة في مراجعة
> دوريّة للإجابة على سؤال واحد: هل القيم ما زالت مناسبة؟
>
> **القاعدة:** لا تُغيَّر أي قيمة هنا إلا بعد (1) مرجع من الممارسات المنشورة،
> (2) قياس من نظامنا يُثبت المناسبة، (3) فحص أنها لا تكسر شيئًا. والقيم المكتوبة
> أدناه مرّت بهذه الثلاثة.
>
> **أين تسكن القيم:** `shared-pg-stack/docker-compose.yml` (PostgreSQL) ·
> `shared-pg-stack/pgbouncer.ini` (المجمّع) · `docker-compose.yml` + `entrypoint.sh`
> (المستأجر) · `data/saas_type_jdoo.xml` في مستودع saas (بيئة المستأجر من الماستر).
> والقيم الحيّة على PostgreSQL مضبوطة بـ`ALTER SYSTEM` أيضًا، ونفس القيم في الكومبوز
> حتّى لا يتباعدا عند إعادة الإنشاء.

---

## 0. سكربت المراجعة الدوريّة (انسخه كما هو)

يُشغَّل على العقدة العاملة (jaah-w1) — قراءة فقط، لا يغيّر شيئًا:

```bash
# --- 1) هل المجمّع مُشبَع؟ (المؤشّر الأوّل لانقطاع 2026-09-28) ---
sudo bash -c 'set -a; . /opt/shared-pg-stack/shared-pg-stack/.env; set +a
 docker exec -e PGPASSWORD="$AUTH_PASS" shared-postgres psql -h pgbouncer -p 6432 \
   -U pgbouncer_auth -d pgbouncer -P pager=off -c "SHOW POOLS;" -c "SHOW DATABASES;"'

# --- 2) اتصالات PostgreSQL لكل قاعدة ولكل دور ---
sudo docker exec -i shared-postgres psql -U postgres -P pager=off -c \
 "SELECT datname, count(*) FROM pg_stat_activity
   WHERE backend_type='client backend' GROUP BY 1 ORDER BY 2 DESC;"

# --- 3) الجلسات الخاملة داخل معاملة (هل عتبة 30 د مناسبة؟) ---
sudo docker exec -i shared-postgres psql -U postgres -P pager=off -c \
 "SELECT datname, usename, application_name, now()-xact_start AS txn_age,
         now()-state_change AS idle_for, left(query,60)
    FROM pg_stat_activity WHERE state='idle in transaction'
   ORDER BY state_change;"

# --- 4) هل الكرون يعمل فعلاً على كل مستأجر؟ (lastcall أصدق من nextcall) ---
for db in $(sudo docker exec -i shared-postgres psql -U postgres -tAc \
  "SELECT datname FROM pg_database WHERE datname LIKE 'sub%' ORDER BY 1"); do
  printf '%-8s last_run=%s overdue=%s\n' "$db" \
   "$(sudo docker exec -i shared-postgres psql -U postgres -d $db -tAc \
      "SELECT coalesce(to_char(now()-max(lastcall),'HH24:MI:SS'),'never') FROM ir_cron WHERE active")" \
   "$(sudo docker exec -i shared-postgres psql -U postgres -d $db -tAc \
      "SELECT count(*) FROM ir_cron WHERE active AND nextcall < now()")"
done

# --- 5) إعدادات PostgreSQL الحيّة مقابل ما نتوقّعه ---
sudo docker exec -i shared-postgres psql -U postgres -P pager=off -c \
 "SELECT name, setting, source, pending_restart FROM pg_settings WHERE name IN
  ('max_connections','superuser_reserved_connections','shared_buffers',
   'effective_cache_size','random_page_cost','effective_io_concurrency',
   'log_min_duration_statement','log_statement','log_connections',
   'idle_in_transaction_session_timeout','track_activity_query_size') ORDER BY 1;"

# --- 6) كل مستأجر: البارامترات التي تصله فعلاً ---
for c in $(sudo docker ps --format '{{.Names}}' | grep -E -- '-app$'); do
  printf '%-52s %s\n' "$c" \
   "$(sudo docker exec $c grep -hE '^(db_name|dbfilter|db_maxconn|db_maxconn_gevent|limit_time_real_cron|workers) ' /etc/odoo/erp.conf | tr '\n' ' ')"
done

# --- 7) صحّة الحاويات + استجابة كل نطاق ---
sudo docker ps --format '{{.Names}}|{{.Status}}' | grep -E -- '-app\|' | grep -v healthy || echo 'كل المستأجرين سليمون'
```

**المراجعة مطلوبة:** شهريًّا، **و** بعد أي إضافة مستأجر، **و** بعد أي ترقية لصورة
PostgreSQL أو PgBouncer.

---

## 1. PgBouncer — مجمّع الاتصالات

الملف: `shared-pg-stack/pgbouncer.ini`. الميزانية الكاملة في ترويسة الملف،
ويؤكّدها اختبار آلي (`tests/test_proxy_and_pool.sh`).

| البارامتر | القيمة | لماذا |
|---|---|---|
| `pool_mode` | `session` | **لا يتغيّر.** أودو يحتفظ بجلستَي LISTEN دائمتين لكل مستأجر (`server.py` cron_trigger و`bus.py` imbus)، وحالة LISTEN/NOTYFY وprepared statements لكل جلسة. أي تجميع بالمعاملة يكسر Discuss والكرون صامتًا |
| `max_db_connections` (عام، للمستأجرين) | **18** | ذروة مستأجر مقيسة **12** اتصالاً (sub8/sub13) → 1.5×. والقيمة القديمة 30 لم تكن كرمًا بل بلا ميزانية (16×30 يتجاوز العنقود) |
| `default_pool_size` / `reserve_pool_size` | **15 / 3** | 15+3 = 18 = السقف، فيصل المستأجر إلى احتياطه قبل السقف |
| مدخل `postgres` الصريح | `pool_size=4 reserve_pool=1 max_db_connections=100` | **جذر الانقطاع.** قاعدة الصيانة كانت ترث السقف العام (30) وعليها 44 اتصالاً من 16 مستأجرًا. و20×(4+1)=100 **بالتساوي** فلا يأكل مستأجر نصيب آخر |
| مدخل `pgb_auth_lookup` | `pool_size=4 reserve_pool=2 max_db_connections=6` | `auth_query` كان يعمل على نفس دلو `postgres` المُشبَع، فلمّا امتلأ لم يعد PgBouncer يصادق **أي** عميل لأي مستأجر. PgBouncer يحاسب لكل **مفتاح مدخل** لا لكل قاعدة حقيقية، فهذا دلو مستقل على نفس القاعدة الفيزيائية. **بلا `user=`** (وجودها تسريب لمُتحقِّقات SCRAM) |
| `max_user_connections` | **30** | مستأجر يحتاج 18+5=23، فلا يقيّد قبل سقوف القواعد |
| `query_wait_timeout` | 120 → **60** | من انتظر دقيقتين خسر المستخدم. الانتظار القصير يُظهر المشكلة بدل إخفائها |
| `listen_backlog` | (128) → **1024** | بعد أي إعادة إنشاء يعيد 16 مستأجرًا × ~11 عملية الاتصال دفعة واحدة؛ الفائض عن الطابور **قطع اتصال لا إعادة محاولة** |
| `tcp_keepalive*` | 1 / 60 / 10 / 6 | طرف اختفى بلا FIN يحتجز مقعدًا ساعتين بالافتراضي → ~دقيقتان |
| `pidfile` | **فارغ** | pgbouncer هو PID 1 في المقدّمة؛ الملف يبقى في طبقة الحاوية بعد `docker restart` فيقتلها بـ`FATAL pidfile exists` (شوهد: 11220 إعادة تشغيل) |
| `client_idle_timeout` | **ممنوع** | يقطع عميلَي LISTEN الدائمين (خاملان بطبيعتهما) |
| `stats_users` | يبقى فيه `pgbouncer_auth` | الهوية الوحيدة القادرة على وحدة التحكّم (`get_auth` يستثني السوبر يوزر)، وحذفها = العمى في الحادث التالي |

**المراقبة والعتبات:**

| نراقب | سليم | يُلزمنا بالتغيير |
|---|---|---|
| `cl_waiting` على أي صفّ | **0** | ≥1 بشكل مستمرّ → ارفع سقف ذلك المستأجر أو افحص ما يحتجز اتصالاته |
| `maxwait` | **0** | > 0 = انقطاع يبدأ. إجهاض فوري لأي نشر جارٍ |
| `current_connections` على `postgres` | < 60 من 100 | ≥ 80 → ارفع السقف **مع** `PG_MAX_CONNECTIONS` (يحتاج نافذة) أو راجع ما يفتح جلسات صيانة |
| `current_connections` لمستأجر | ≤ 12 | ≥ 16 من 18 بشكل متكرّر → ارفع سقفه فرديًّا وأعد حساب الميزانية |
| عدد المستأجرين على العقدة | ≤ **20** | > 20 → **أعد حساب الميزانية بالكامل** قبل نشر المستأجر 21 |

---

## 2. PostgreSQL المشترك

الملف: `shared-pg-stack/docker-compose.yml`. القيم الحيّة مضبوطة بـ`ALTER SYSTEM`
لتجنّب إعادة الإنشاء.

🔴 **أسبقيّة الإعدادات — مقيسة على jaah-w1 في 2026-09-29، وهي عكس ما يُفترض عادةً:**
وسيط `-c` في سطر أوامر الحاوية **يتجاوز** `postgresql.auto.conf`. الدليل: ضبطتُ
`effective_cache_size = 65GB` بـ`ALTER SYSTEM` فبقيت القيمة العاملة 3 غيغا و`source
= command line`. النتائج العمليّة:
1. أي `ALTER SYSTEM` لمفتاح **موجود أصلاً في سطر الأوامر = عديم الأثر**، وأسوأ من
   ذلك: قنبلة موقوتة تنفجر يوم يُحذف الوسيط. لذلك أزلتُ الإدخال الميّت.
2. الأحد عشر إعدادًا التي طبّقتها حيًّا **فعّالة** لأنها ليست في سطر أوامر الحاوية
   العاملة (أُضيفت للكومبوز ولم يُعَد إنشاء الحاوية بعد) — وكلّها تظهر
   `source = configuration file`.
3. بعد النافذة ستأتي القيم من سطر الأوامر؛ وهي متطابقة فلا يتغيّر السلوك، و`ALTER
   SYSTEM RESET` لها يصبح نظافةً لا ضرورة.
4. **`effective_cache_size` يحتاج النافذة فعلاً** — لأنه في سطر الأوامر، لا لأن
   سياقه `postmaster` (سياقه `user`).

| البارامتر | القيمة | لماذا |
|---|---|---|
| `max_connections` | **500** | مدخل ميزانية المجمّع: 466 من 490 المتاحة (500 − 10 محجوزة للسوبر). المحجوزة هي ما سمح للماستر بتشخيص الانقطاع عبر المقبس المحلي وقت التشبّع |
| `shared_buffers` | **1 غيغا حيًّا · 25 غيغا مكتوبة في `.env`** | ¼ ذاكرة العقدة (100 غيغا) — القاعدة المعيارية. تكتبها خطوة النشر **إن غاب المفتاح فقط**. 🔴 `context = postmaster`: القيمة في `.env` **لا تسري حتّى إعادة إنشاء الحاوية** (مؤجَّلة لنافذة)، والعامل الآن 1 غيغا |
| `effective_cache_size` | **3 غيغا حيًّا · 65% مكتوبة في `.env`** | تقدير ما يخزّنه النظام مؤقّتًا؛ يوجّه المُخطِّط. `context = user` لكنه يأتي من سطر أوامر الحاوية، فيسري مع إعادة الإنشاء |
| `random_page_cost` | 4 → **1.1** | **قِستُ العتاد**: قرص VM 104 على ZFS فوق NVMe (`nvme-MO001600KXVYH`, `ssd=1,discard=on`). الافتراضي 4 رقم أقراص دوّارة يدفع المُخطِّط للمسح التسلسلي بدل الفهارس |
| `effective_io_concurrency` | 1 → **200** | «مئات» للأقراص الحديثة؛ 200 قيمة إنتاجية متكرّرة. تُستخدم في bitmap scans |
| `log_min_duration_statement` | ‎-1 → **1000** | «ابدأ بـ1000 ثم اخفضها» هي التوصية الشائعة. لم يكن هناك **أي** أثر ليلة الحادث |
| `log_connections` / `log_disconnections` | off → **on** | رخيص عندنا تحديدًا: مع `pool_mode=session` و`server_lifetime=3600` تبديل الخوادم مئات في الساعة لا ملايين |
| `log_statement` | none → **ddl** | يمسك تهيئة المستأجرين وحذفهم وتركيب المديولات. `all` هو الطوفان |
| `log_line_prefix` | `+%q%u@%d/%a ` | الافتراضي لا يسمح بنسب سطر إلى مستأجر. أودو يضبط `application_name` فيظهر أي عملية |
| `log_lock_waits` / `log_temp_files=8MB` / `log_autovacuum_min_duration=10s` | مفعّلة | أنماط بطء شائعة في أودو |
| `idle_in_transaction_session_timeout` | 0 → **30 دقيقة** | 0 لا يستعيد تسريبًا أبدًا. **ولماذا 30 لا 15**: قِستُ عامل أودو على sub8 يحتجز معاملة **4 دقائق** بعد قراءة `ir_module_module` (نداء خارجي داخل معاملة)، و15 كانت 3.75× الذروة فقط وذيلها يعتمد على مهلة HTTP لا نتحكّم بها. **و`pg_dump` لا يتأثّر**: يصدر `SET idle_in_transaction_session_timeout = 0` لجلسته (مُتحقَّق من البرنامج نفسه) |
| `idle_session_timeout` | **ممنوع** | يقتل جلستَي LISTEN الدائمتين |
| `logging_collector` | **off** | Docker يجمع stderr ويدوّره؛ المُجمِّع يدفن السجل داخل PGDATA بلا تدوير |

**المراقبة والعتبات:**

| نراقب | سليم | يُلزمنا بالتغيير |
|---|---|---|
| `pending_restart` لأي إعداد | `f` لكل ما نضبطه حيًّا | **إنذار كاذب معروف** على `max_connections` و`shared_buffers`: صورة postgres تحمل 100 و128 ميغا في `postgresql.conf`، والأمر السطري (`-c`) يتجاوزها، فأي `pg_reload_conf` يوسمهما `t` بلا أن يكون شيء معلَّقًا — عند إعادة التشغيل يفوز السطر. أمّا `t` على إعداد **نحن** غيّرناه فهو حقيقي ويحتاج نافذة |
| `context` قبل أي `ALTER SYSTEM` | `user`/`sighup` | `postmaster` → **لا يُطبَّق حيًّا مهما فعلت**؛ ضعه في المؤجَّل. تحقّق بـ`SELECT name, context FROM pg_settings WHERE name = '…'` |
| أطول جلسة خاملة داخل معاملة | < 5 دقائق | > 20 دقيقة بانتظام → افحص العامل الذي يحتجزها قبل أن تفكّر في رفع العتبة |
| مَن يحتجزها (خيط معروف) | — | قِيس 2026-09-29: جلسة على مستأجر مدفوع احتجزت 4 دقائق. المرشّح: `j_base/models/j_agent.py::_call_master_rpc` ينادي الماستر بمهلة **300 ثانية** **داخل** معاملة الطلب — بخلاف `_send_webhook` المجاور الذي يُرسل بعد الـcommit بمهلة 5 ثوان. مناديه `ai/19.0/j_ai/controllers/j_ai_controller.py` (7 مواضع). **بند متابعة في مستودعَي tools وai، خارج نطاق هذا الإصلاح** |
| حجم سجلّات الحاوية | < 250 ميغا | يقترب → راجع `PG_LOG_MAX_SIZE`/`MAX_FILE` (الحدّ 50م × 5) |
| `log_min_duration_statement` | 1000 | لو صار السجل مزعجًا ارفعها إلى 2000؛ ولو تحسّن الأداء اخفضها إلى 500 لرؤية أدقّ |
| ذاكرة العقدة مقابل `shared_buffers` | ¼ | تغيّرت ذاكرة العقدة → صحّح `PG_SHARED_BUFFERS` في `.env` (يحتاج نافذة) |

---

## 3. المستأجر (أودو)

| البارامتر | القيمة | لماذا | أين يسكن |
|---|---|---|---|
| `dbfilter` | **فارغ/محذوف** | ضبطه يُلغي اختصار `service/db.py:list_dbs` فيفتح أودو جلسة على قاعدة `postgres` عند كل نداء لقائمة القواعد — وهو الحمل الذي أشبع المجمّع. والعزل لا يعتمد عليه: `http.py:db_filter` يرتدّ إلى تطابق نصّي تامّ مع `db_name`، أضيق من أي regex، ومعه `REVOKE CONNECT` على العنقود | مستودع saas (محذوف من النوع والخطة) |
| `db_name` | اسم المستأجر | **هو** العزل على طبقة أودو الآن | دينامي من الماستر |
| `list_db` | `True` | `False` كان يُبلّغ عن نظام فرعي خاطئ عند فشل تحليل القاعدة | النوع |
| `limit_time_real_cron` | 0 → **3600** | 0 يعني «بلا حدّ» فيُعطّل حارس عامل الكرون كليًّا (`server.py`: `config[...] or None`) — وعلى قاعدة مشتركة يحتجز العامل المعلَّق مقعدًا إلى الأبد. فحصت الـ16: لا أحد يحتاج كرونًا بلا حدّ (لا `server_wide_modules`، والمستأجر الوحيد بـ`j_queue_pro` يوزّع عبر Redis وحلقته الطويلة تُثبّت كل دفعة). **ويصحّحه `entrypoint.sh`** لأن Dokploy يكتب كومبوزه المخزَّن فوق نسخة git | `entrypoint.sh` + كومبوز المستأجر |
| `db_maxconn` | 64 → **8** | 4 عمّال + كرون؛ صيغة أودو نفسها تفترض ~2 مؤشّر لكل خيط، فـ`PoolError` بعيد. والافتراضي 64 لم يكن سقفًا بل غيابه | `entrypoint.sh` (مصدر واحد) |
| `db_maxconn_gevent` | غائب → **12** | بدونه يرث 8؛ وعامل gevent يخدم greenlets كثيرة ويحمل جلسة imbus الدائمة | `entrypoint.sh` |
| `workers` / `max_cron_threads` | محسوبان | من cgroup الحاوية لا من المضيف | `entrypoint.sh` |
| فحص الصحّة | طبقتان | `/web/health` (بلا قاعدة) + مسار يتطلّب القاعدة، ومقارنة **200 بالضبط**. القديم كان يقبل 303 «قاعدتك غير محلولة» كصحّة، ولا يكشف قاعدة ميتة، ويفتح جلستَي `postgres` كل 15 ثانية | `healthcheck.sh` |

**المراقبة والعتبات:**

| نراقب | سليم | يُلزمنا بالتغيير |
|---|---|---|
| `dbfilter` في `erp.conf` لأي مستأجر | **غائب** | ظهوره = رجوع الحمل؛ افحص من أعاده (النوع/الخطة/مزامنة Dokploy) |
| `db_maxconn` في `erp.conf` | **8** | `PoolError` في سجلّ مستأجر → ارفعه لذلك المستأجر بـ`DB_MAXCONN` وأعد حساب الميزانية |
| `limit_time_real_cron` | **3600** | ظهور 0 = الحارس معطَّل؛ ومهمّة مشروعة تُقتل عند 3600 → ارفعها لذلك المستأجر بـ`LIMIT_TIME_REAL_CRON` |
| آخر تنفيذ كرون | < 10 دقائق | «never» أو > ساعة → أعد تشغيل الحاوية وافحص جلسات LISTEN |
| `env_converge_state` على الماستر | `done` للجميع | `pending` متبقٍّ = مستأجر لم تصله القيم بعد؛ `failed` = اقرأ `env_converge_message` |

---

## 4. مؤجَّل بوعي (يحتاج نافذة صيانة)

إعادة إنشاء `shared-postgres` تقطع **كل** جلسات العقدة، فهذه البنود تنتظر نافذة
مستقلّة — وخطوة النشر تطبع إشعارًا صريحًا عند اكتشافها ولا تلمس PostgreSQL:

| البند | القيمة المنتظرة | لماذا يحتاج نافذة |
|---|---|---|
| `ulimits.nofile` للحاويتين | 65536 | الحدّ الناعم الموروث 1024 يُسقِف العقدة كلها عند ~500 عميل ويفشل كـ`accept(): Too many open files` بلا أي إشارة إلى الملفّات |
| `shm_size` | 1 غيغا | `/dev/shm` الافتراضي 64 ميغا فتفشل الخطط المتوازية بـ«could not resize shared memory segment» |
| `superuser_reserved_connections` | 10 (صريح) | مدخل الميزانية؛ سارٍ فعلاً من سطر الأوامر |
| `track_activity_query_size` | 1024 → **4096** | `context = postmaster` فلا يُطبَّق حيًّا بحال. الافتراضي يقطع كل استعلام أودو مثير للاهتمام في منتصفه. موجود في الكومبوز، يسري مع إعادة الإنشاء |
| `shared_buffers` / `effective_cache_size` | 25 غيغا / 65% | مكتوبة في `.env` وتنتظر إعادة الإنشاء؛ العامل الآن 1 غيغا / 3 غيغا |
| `pidfile` فارغ (سارٍ) + `listen_backlog` | سارية فعلاً | وصلت مع إعادة إنشاء pgbouncer، لا تحتاج شيئًا |

وبنود مستقلّة عن هذه المنظومة: `onboot` على VMs 100/103/104، وجدول Verify دوري
في PBS، ونسخ احتياطي تطبيقي لكل مستأجر على jaah-w1 (لا يوجد اليوم).

---

## 5. سجل القرارات

| التاريخ | القرار | السبب |
|---|---|---|
| 2026-09-29 | سقف المستأجر 15 → **18**، ومدخل `postgres` 140 → **100** | القياس الحيّ صحّح التقدير: ذروة مستأجر 12 لا 6–9، و`postgres` عند 44 من 60 |
| 2026-09-29 | `idle_in_transaction_session_timeout` 15 → **30 دقيقة** | جلسة مقيسة تحتجز 4 دقائق؛ 15 كانت قريبة أكثر مما يجب |
| 2026-09-29 | `limit_time_real_cron` يُصحَّح في `entrypoint.sh` لا في الكومبوز فقط | Dokploy يكتب كومبوزه المخزَّن فوق نسخة git، فالصورة هي القناة الوحيدة التي تصل |
| 2026-09-29 | التقارب يستخدم `action_deploy` لا `action_redeploy` | `compose.redeploy` (rebuildCompose) لا يحدّث المصدر؛ المستأجر بقي على التزام عمره شهران |
| 2026-09-29 | `dbfilter` يبقى **فارغًا** نهائيًّا — قرار المالك | لا حاجة له؛ العزل بـ`db_name` + `REVOKE CONNECT` |
