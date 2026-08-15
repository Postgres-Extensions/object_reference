# object_reference: current OID-repair / self-healing behavior

*Ground-truth reference of behavior as currently shipped on master (/root/git/object_reference, branch docs/oid-repair-current-behavior, identical to upstream/master). Assembled from independent empirical research; adversarially reviewed and revised.*

Object_reference exists to solve a specific catalog-tracking problem: PostgreSQL object OIDs are not stable across dump/restore or pg_upgrade, and names alone aren't a reliable long-term handle either once renames happen, so the extension maintains its own durable, name-based identity for a database object (`_object_reference.object`, keyed on the `(object_type, object_names, object_args)` triple returned by `pg_identify_object_as_address`) alongside a separate, disposable cache of that object's last-known live catalog identity (`_object_reference._object_oid`, keyed on `(classid, objid, objsubid)`). `object` is durable and dump-included; `_object_oid` is deliberately excluded from dump/restore and is treated as fully rebuildable, since OIDs it stores are only valid in the database instance where they were captured.

That cached OID-to-name mapping can go stale in three distinct ways, and the code's handling of each differs sharply. On a plain logical `pg_dump`/`pg_restore`, the extension's own repair mechanism — a populated materialized view (`_sentry_mv`) wired to call `_repair()`, dumped so its `REFRESH` lands in the post-data section, after all tracked objects have their final restored-database OIDs — successfully rebuilds `_object_oid` from scratch, and this was confirmed end-to-end across table, view, trigger, sequence, and function objects: `names_ok`/`ids_ok`/`ids_exist` all come back true. `pg_upgrade`, by contrast, is only partially handled and even breaks the upgrade itself: `pg_class`/`pg_type`-backed objects (tables, indexes, sequences, views, matviews, columns, enum types) keep their OIDs across the upgrade and remain consistent, but objects backed by `pg_constraint`, `pg_proc`, `pg_cast`, `pg_attrdef`, or `pg_trigger` get entirely new OIDs, leaving `_object_oid` stale for those rows — and separately, `_sentry_mv` being a *populated* matview causes the binary-upgrade dump/restore itself to fail outright with "pg_class heap OID value not set" unless manually worked around first. The third path — a real event-trigger-driven rename or any live corruption of a `_object_oid` row — is the worst-handled: the `_etg_fix_identity` trigger blindly re-derives and overwrites `object`'s stored name from whatever the row's stored (possibly stale) OID currently resolves to, on every single DDL statement in the database regardless of relevance, so a stale row can silently corrupt an unrelated object's identity or, if the stale OID no longer resolves to anything at all, raise an uncaught enum-cast error that aborts not just the triggering statement but every subsequent DDL command database-wide until the bad row is manually removed.

Beyond these three staleness triggers, the sections below also surface several bugs in the code that's supposed to detect and report inconsistency rather than fix it automatically: `fix_refs()`'s "extraneous ID information" branch references an undeclared variable (`r_object` instead of `r_object_v`) and always fails with an unrelated error instead of producing its intended diagnostic, in both `warning_only` modes; `_object_oid__add()`/`_repair()` have no `ON CONFLICT` handling and are not idempotent, so re-invoking them against an already-populated table raises a duplicate-key error; and because `_etg_drop()` unconditionally calls `post_restore()` (which runs `fix_refs(false)`) after every drop, a single stale row anywhere in the tracked set can cause an ordinary, unrelated `DROP` statement to fail and roll back. In short: the happy-path logical-dump/restore scenario is the one case the current code demonstrably gets right end-to-end; pg_upgrade is only correctly handled for a subset of object kinds and has its own dump-compatibility bug; and the live-rename/stale-row and inconsistency-reporting paths are actively broken by reproducible defects in the current code, not just theoretically incomplete.

---

## Core Data Model (`_object_reference.object`, `_object_oid`, the `_object_v*` views, and `_sanity()`)

All line numbers are against `sql/object_reference.sql` as currently checked out (identical to `upstream/master`, 1610 lines total).

### 1. `_object_reference.object` — the identity table

Verbatim, lines 164–176:

```sql
CREATE TABLE _object_reference.object(
  object_id       serial                  PRIMARY KEY
  , object_type   cat_tools.object_type   NOT NULL
--  , original_name text                    NOT NULL
  , object_names text[]                  NOT NULL
  , object_args  text[]                  NOT NULL
  , CONSTRAINT object__u_object_names__object_args UNIQUE( object_type, object_names, object_args )
  /* EXCLUDED CODE: TODO: this can't be a trigger because some objects won't exist when a dump is loaded
  , CONSTRAINT object__address_sanity
    -- pg_get_object_address will throw an error if anything is wrong, so the IS NOT NULL is mostly pointless
    CHECK( pg_catalog.pg_get_object_address(object_type::text, object_names, object_args) IS NOT NULL )
    */
);
```

Note the `object__address_sanity` CHECK constraint is **commented out / never installed** (it's inside an `/* EXCLUDED CODE */` block) — the comment on line 171 explains why: at some points during a `pg_restore`, an object referenced by a row in this table may not exist yet, so a CHECK would spuriously fail mid-restore. This is directly relevant to why `_sanity()`/`fix_refs` exist as run-time checks instead of a static constraint.

`(object_type, object_names, object_args)` is the **triple returned by `pg_catalog.pg_identify_object_as_address(classid, objid, objsubid)`** (confirmed via `\df`: `OUT type text, OUT object_names text[], OUT object_args text[]`), stored with `type` renamed to `object_type` and cast to the enum `cat_tools.object_type`. Empirically:

```
demo=# SELECT * FROM pg_identify_object_as_address('pg_class'::regclass, 'public.demo_tbl'::regclass::oid, 0);
 type  |   object_names    | object_args
-------+-------------------+-------------
 table | {public,demo_tbl} | {}

demo=# SELECT * FROM pg_identify_object_as_address('pg_class'::regclass, 'public.demo_tbl'::regclass::oid, 1);
     type     |     object_names     | object_args
--------------+----------------------+-------------
 table column | {public,demo_tbl,id} | {}

demo=# CREATE FUNCTION public.demo_fn(a int, b text) RETURNS int LANGUAGE sql AS $$ SELECT 1 $$;
demo=# SELECT * FROM pg_get_object_address('function', ARRAY['public','demo_fn'], ARRAY['integer','text']);
 classid | objid | objsubid
---------+-------+----------
    1255 | 29001 |        0
```

So:
- `object_names` is a `text[]` that generally holds the **schema-qualified name path** (`{schema, objname}`, or `{schema, table, column}` for a sub-object such as a column — note a column's `objsubid` is folded into `object_names`, *not* `object_args`, as shown above).
- `object_args` is a `text[]` that holds disambiguating **arguments** — currently only meaningful for things like functions/procedures/aggregates/operators, where it's the list of argument type names (`{integer,text}` above); for most object types it's simply `{}`.
- `object_type` is the enum `cat_tools.object_type` (53 labels currently, e.g. `table`, `table column`, `function`, `role`, `schema`, …; verified via `\dT+ cat_tools.object_type` / `pg_enum`), and is exactly the string PostgreSQL itself uses for `type` in `pg_identify_object_as_address`.

The **UNIQUE constraint `object__u_object_names__object_args`** is on all three columns `(object_type, object_names, object_args)` together (not just names/args) — this triple is precisely the input `pg_catalog.pg_get_object_address(type, object_names, object_args)` needs to resolve back to a live `(classid, objid, objsubid)` (verified via `\df`: `type text, object_names text[], object_args text[], OUT classid oid, OUT objid oid, OUT objsubid integer`). In other words: **this table stores a name-based, restore-stable identity for a database object**, and the identity's uniqueness/validity is delegated entirely to Postgres's own `pg_get_object_address()`/`pg_identify_object_as_address()` machinery rather than being independently re-derived by this extension.

`object_id` is a `serial PRIMARY KEY` — a purely synthetic surrogate key, with no semantic meaning beyond being a stable handle other tables (`_object_oid`, `object_group__object`, and any user table wired up via `object_reference.object__dependency__add()`, lines 750–767) can reference.

Lines 177–179 (`safe_dump` calls + grant) mark `object` and its sequence for inclusion in `pg_dump` via `pg_extension_config_dump`, and grant `REFERENCES` to a dedicated `object_reference__dependency` role so other tables can add FKs to it (see `object_reference.object__dependency__add`, line 762, and `object_group__dependency__add`, line 743 — these are *helper functions that other, unrelated tables call* to add an FK to `object`/`object_group`; they are not additional constraints on `object`/`_object_oid` themselves. A full-file grep for `ALTER TABLE` confirms there are no other `ALTER TABLE ... ADD CONSTRAINT` statements anywhere in the file touching `object` or `_object_oid` beyond the initial `CREATE TABLE`s).

### 2. `_object_reference._object_oid` — the OID cache

Verbatim, lines 181–191:

```sql
CREATE TABLE _object_reference._object_oid(
  object_id       int                     PRIMARY KEY REFERENCES _object_reference.object ON DELETE CASCADE ON UPDATE CASCADE
  , classid       oid                     NOT NULL
  /* EXCLUDED CODE: TODO: needs to be a trigger
    CONSTRAINT classid_must_match__object__address_classid
      CHECK( classid IS NOT DISTINCT FROM cat_tools.object__address_classid(object_type) )
    */
  , objid         oid                     NOT NULL
  , objsubid      int                     NOT NULL
  , CONSTRAINT object__u_classid__objid__objsubid UNIQUE( classid, objid, objsubid )
);
```

As with `object__address_sanity`, the `classid_must_match__object__address_classid` CHECK is commented out and **not installed** — currently nothing in the database enforces that the stored `classid` actually matches what `cat_tools.object__address_classid(object_type)` would derive; that consistency is only maintained by application code (`_object_oid__add`, `object__getsert`).

`(classid, objid, objsubid)` is exactly the triple `pg_get_object_address()` returns — i.e. this table is a **cache of the last-known live catalog identity** (the "OID" side) for a given `object_id`, kept separate from the name-based identity in `object`.

**Installed reality via `\d+`** (fetched in a scratch DB, `oid_audit_r1coremodel`, after `CREATE EXTENSION object_reference CASCADE;`):

```
                                          Table "_object_reference.object"
   Column    |         Type          | Collation | Nullable |                     Default
--------------+-----------------------+-----------+----------+--------------------------------------------------
 object_id    | integer               |           | not null | nextval('_object_reference.object_object_id_seq'::regclass)
 object_type  | cat_tools.object_type |           | not null |
 object_names | text[]                |           | not null |
 object_args  | text[]                |           | not null |
Indexes:
    "object_pkey" PRIMARY KEY, btree (object_id)
    "object__u_object_names__object_args" UNIQUE CONSTRAINT, btree (object_type, object_names, object_args)
Referenced by:
    TABLE "_object_reference._object_oid" CONSTRAINT "_object_oid_object_id_fkey" FOREIGN KEY (object_id) REFERENCES _object_reference.object(object_id) ON UPDATE CASCADE ON DELETE CASCADE
    TABLE "_object_reference.object_group__object" CONSTRAINT "object_group__object_object_id_fkey" FOREIGN KEY (object_id) REFERENCES _object_reference.object(object_id)

                                Table "_object_reference._object_oid"
  Column   |  Type   | Collation | Nullable | Default
-----------+---------+-----------+----------+---------
 object_id | integer |           | not null |
 classid   | oid     |           | not null |
 objid     | oid     |           | not null |
 objsubid  | integer |           | not null |
Indexes:
    "_object_oid_pkey" PRIMARY KEY, btree (object_id)
    "object__u_classid__objid__objsubid" UNIQUE CONSTRAINT, btree (classid, objid, objsubid)
Foreign-key constraints:
    "_object_oid_object_id_fkey" FOREIGN KEY (object_id) REFERENCES _object_reference.object(object_id) ON UPDATE CASCADE ON DELETE CASCADE
```

One notable asymmetry visible only in the "Referenced by" section: **only** the FK from `_object_oid` to `object` cascades on delete. The FK from `object_group__object` to `object` is declared statically and inline, in the original `CREATE TABLE _object_reference.object_group__object(...)` statement (lines 540–544: `object_id int NOT NULL REFERENCES _object_reference.object`), the same way `_object_oid`'s FK is declared inline in its own `CREATE TABLE` — it is *not* added dynamically by `object_group__dependency__add`/`object__dependency__add` (grepping the whole file for calls to either function turns up none outside their own `create_function()` definitions at lines 732/751 — they are defined but never invoked by the extension's own install script). Because that inline `REFERENCES` clause carries no `ON DELETE`/`ON UPDATE` clause, it defaults to `NO ACTION`. So deleting a row from `object` today will cascade-delete its `_object_oid` cache row automatically, but will be **blocked by a FK violation** if that `object_id` is still a member of any `object_group`.

### 3. `_object_reference._sanity()` and the two views

#### `_sanity()` — full body, lines 193–240

```sql
SELECT __object_reference.create_function(
  '_object_reference._sanity'
  , $args$
  obj _object_reference.object
  , id _object_reference._object_oid
  , OUT names_ok boolean
  , OUT ids_ok boolean
  , OUT ids_exist boolean
$args$
  , 'RECORD LANGUAGE plpgsql STABLE'
  , $body$
DECLARE
  r record;
BEGIN
  ASSERT NOT obj IS NULL, 'obj may not be null';
  ASSERT id IS NULL OR obj.object_id = id.object_id, 'id must be null or object_ids must match';

  ids_exist := NOT (id IS NULL); -- Remember this is NOT the same as id IS NOT NULL!

  BEGIN
    r := pg_catalog.pg_get_object_address(obj.object_type::text, obj.object_names, obj.object_args);
    names_ok := true;

    -- Assume that if get_object_address worked then the names are at least valid
    ids_ok := r IS NOT DISTINCT FROM (id.classid::oid, id.objid, id.objsubid);
  EXCEPTION
    WHEN others THEN
      IF
        SQLSTATE IN(
          '22023' -- invalid_parameter_value
          , '3F000' -- invalid_schema_name
          , '42703' -- undefined_column
          , '42704' -- undefined_object
          , '42883' -- undefined_function
        )
        OR SQLSTATE LIKE '42P%' -- Matches a bunch of codes, including undefined_* and invalid_*_definition
      THEN
        names_ok := false;
        ids_ok := false; -- Should we see if pg_object_identity_as_address works??
      ELSE
        RAISE WARNING 'Unexpected error!!';
        RAISE; -- Unexpected, so re-raise
      END IF;
  END;
END
$body$
  , 'Check the sanity of object and _object_oid'
);
```

What each flag *precisely* means:
- **`ids_exist`** — purely mechanical: `true` iff a matching row currently exists in `_object_oid` for this `object_id` (i.e. `id IS NOT NULL` after the `LEFT JOIN`). It says nothing about whether that row's content is *correct*, only that it's *present*.
- **`names_ok`** — `true` iff `pg_catalog.pg_get_object_address(object_type, object_names, object_args)` succeeds without raising one of the listed "the object/schema/name doesn't resolve" error classes (`invalid_parameter_value`, `invalid_schema_name`, `undefined_column`, `undefined_object`, `undefined_function`, or any `42P*` code). It means: *the name-based identity stored in `object` currently resolves to a real, live catalog object*. Any *other* SQLSTATE is treated as unexpected and re-raised (with a `RAISE WARNING` first) — it is **not** silently converted to `names_ok = false`.
- **`ids_ok`** — computed **only inside the successful branch**, i.e. only when `names_ok` has already been set `true`: it's `true` iff the freshly-resolved live `(classid, objid, objsubid)` is `IS NOT DISTINCT FROM` the cached `(id.classid, id.objid, id.objsubid)`. Because of how the `BEGIN/EXCEPTION` block is structured, **`ids_ok = true` is structurally impossible unless `names_ok = true`** — the exception handler always sets both `names_ok` and `ids_ok` to `false` together. Also, since `id.classid/objid/objsubid` are all `NULL` when `id IS NULL` (i.e. `ids_exist = false`), and a real resolved address always has non-null fields, `IS NOT DISTINCT FROM` a `(NULL,NULL,NULL)` row is always `false` — so **`ids_ok = true` also structurally implies `ids_exist = true`**. In short: `ids_ok = true ⟹ names_ok = true AND ids_exist = true`.

That structural implication rules out 3 of the 8 boolean combinations as impossible by construction of the code (not merely "shouldn't happen in practice"): `(names_ok=f, ids_ok=t, ids_exist=f)`, `(names_ok=f, ids_ok=t, ids_exist=t)`, and `(names_ok=t, ids_ok=t, ids_exist=f)`.

#### The two views, lines 242–270

```sql
CREATE VIEW _object_reference._object_v AS
  SELECT 
      o.object_id
      , o.object_type
      , o.object_names
      , o.object_args
      , i.classid
      , i.objid
      , i.objsubid
      , s.*
    FROM _object_reference.object o
      LEFT JOIN _object_reference._object_oid i USING(object_id)
      , _object_reference._sanity(o, i) s
;
CREATE VIEW _object_reference._object_v__for_update AS
  SELECT 
      o.object_id
      , o.object_type
      , o.object_names
      , o.object_args
      , i.classid
      , i.objid
      , i.objsubid
      , s.*
    FROM _object_reference.object o
      LEFT JOIN _object_reference._object_oid i USING(object_id)
      , _object_reference._sanity(o, i) s
    FOR UPDATE OF o
;
```

The two views are **identical** except the second adds `FOR UPDATE OF o`, taking a row lock on the `object` row so a caller (e.g. `_object_oid__add`, line 301, or `object__getsert`, lines 892/905) can read-then-modify a specific `object_id` without a race against a concurrent tracker. Neither view has an installed `COMMENT ON VIEW`.

### The truth table

All 5 of the 5 logically-possible combinations (having excluded the 3 structurally-impossible ones above, out of 8 total boolean combinations) were reproduced empirically in the scratch database by directly manipulating `_object_reference.object`/`_object_oid` and querying `_object_v`, and each is cross-checked against how the rest of the extension (`fix_refs`, lines 334–400, and `object__getsert`'s CASE, lines 922–956) interprets it:

| names_ok | ids_ok | ids_exist | Reachable? | Meaning | How the code treats it |
|---|---|---|---|---|---|
| t | t | t | Yes | Fully consistent: name resolves, and the cached OID triple matches the live one. | `fix_refs`: `NULL; -- All good!` (line 336). `object__getsert`: returns immediately (line 924). |
| t | f | t | Yes | **OID drift**: the name still resolves to a real object, but the cached `(classid,objid,objsubid)` no longer matches the live one (classic post-`pg_dump`/restore situation, or manual corruption). | `fix_refs` reaches the final `WHEN r_object_v.ids_exist` branch (line 384): raises `WARNING` "extraneous ID information..." if `warning_only`, else `RAISE` the same as a hard error — in both cases explicitly flagged as "should not happen, but may be fixable" by hand-editing the cache. |
| t | f | f | Yes | Name resolves fine, but **no cache row exists yet** (freshly inserted `object` row before `_object_oid__add` ran, or mid-restore before `fix_refs` catches up). | `object__getsert`: `WHEN NOT r_object_v.ids_exist` (line 926) — calls `_object_oid__add` to create the missing cache row, treated as the *normal* case for a first-time getsert. `fix_refs`: same branch (line 373) — if `warning_only`, silently fixes it via `_object_oid__add`; otherwise raises an error (this is the strict, "should already have been fixed by post_restore" case). |
| f | f | t | Yes | Name no longer resolves, **but a stale `_object_oid` cache row is still present** — an orphaned/inconsistent cache entry. | `fix_refs`: `WHEN NOT r_object_v.names_ok THEN IF r_object_v.ids_exist THEN` (lines 337–349) — **always** `RAISE`s an error (regardless of `warning_only`) with hint "this should never happen". `object__getsert` would similarly hit `RAISE 'ids are out of sync...'` (line 942) if it ever got this far — treated as a serious internal-consistency bug. |
| f | f | f | Yes | Name doesn't resolve and no cache row exists — the **normal mid-`pg_restore` state**: an `object` row was loaded via COPY for an object that the dump hasn't recreated yet, or (if it persists after restore finishes) a genuinely dangling/broken reference. | `fix_refs`: `WHEN NOT r_object_v.names_ok` / `ELSE` (not `ids_exist`) (lines 350–370) — `RAISE WARNING` if `warning_only` (tolerated during an in-progress restore), else `RAISE` a hard error (this is what `object_reference.post_restore()`, called with `warning_only = false`, would surface if any such row is still broken *after* a restore completed). |
| t | t | f | **No** — structurally impossible | — | `ids_ok=true` can only be computed after `names_ok:=true`, and always compares against `id.classid/objid/objsubid`, which are all `NULL` (hence distinct from any live triple) whenever `id IS NULL`/`ids_exist=false`. |
| f | t | f / t | **No** — structurally impossible | — | The exception handler in `_sanity()` sets `names_ok` and `ids_ok` to `false` together; there is no code path that produces `ids_ok=true` with `names_ok=false`. |

Empirical confirmation of the 5 reachable rows (scratch DB `oid_audit_r1coremodel`, PG 17, via `CREATE EXTENSION object_reference CASCADE;`):

```
-- (t,t,t): via object_reference.object__getsert('table', 'public.demo_tbl')
 object_id | object_type |   object_names    | object_args | classid | objid | objsubid | names_ok | ids_ok | ids_exist 
-----------+-------------+-------------------+-------------+---------+-------+----------+----------+--------+-----------
         1 | table       | {public,demo_tbl} | {}          |    1259 | 28991 |        0 | t        | t      | t

-- (t,f,f): DELETE FROM _object_reference._object_oid WHERE object_id = 1;
 object_id | object_type |   object_names    | object_args | classid | objid | objsubid | names_ok | ids_ok | ids_exist 
-----------+-------------+-------------------+-------------+---------+-------+----------+----------+--------+-----------
         1 | table       | {public,demo_tbl} | {}          |         |       |          | t        | f      | f

-- (f,f,t): INSERT object row for a name that never existed ({public,nonexistent_tbl}),
--          plus a fabricated _object_oid row (classid=1259, objid=999999, objsubid=0)
 object_id | object_type |       object_names       | object_args | classid | objid  | objsubid | names_ok | ids_ok | ids_exist 
-----------+-------------+--------------------------+-------------+---------+--------+----------+----------+--------+-----------
         2 | table       | {public,nonexistent_tbl} | {}          |    1259 | 999999 |        0 | f        | f      | t

-- (f,f,f): INSERT object row only, for a name that never existed ({public,not_yet_created}), no _object_oid row
 object_id | object_type |       object_names       | object_args | classid | objid | objsubid | names_ok | ids_ok | ids_exist 
-----------+-------------+--------------------------+-------------+---------+-------+----------+----------+--------+-----------
         3 | table       | {public,not_yet_created} | {}          |         |       |          | f        | f      | f

-- (t,f,t): real table public.demo_tbl2 created (classid=1259, objid=29020), but its
--          _object_oid row was fabricated with a wrong objid (8675309) simulating OID drift
 object_id | object_type |    object_names    | object_args | classid | objid   | objsubid | names_ok | ids_ok | ids_exist 
-----------+-------------+--------------------+-------------+---------+---------+----------+----------+--------+-----------
         4 | table       | {public,demo_tbl2} | {}          |    1259 | 8675309 | 0        | t        | f      | t
```

A live `DROP TABLE` on a tracked object (state (t,t,t)) does **not** leave a dangling `object`/`_object_oid` row behind — the `zzz__object_reference_drop` `sql_drop` event trigger (`\dy` shows it, function `_object_reference._etg_drop`) deletes the tracking rows automatically. This is why the `(f,f,t)`/`(f,f,f)` "names broken" states are primarily reachable via direct row manipulation or mid-restore, not via ordinary live DDL — the event-trigger layer keeps `object`/`_object_oid` in sync during normal operation.

---

## Main lazy get‑or‑create / self‑heal path and read‑only accessors — `object_reference` (as of `docs/oid-repair-current-behavior`, identical to upstream `master`)

All line numbers below are from `sql/object_reference.sql` (1610 lines) at this commit (`2ab8876` HEAD).

The supporting schema (`object`, `_object_oid`, `_sanity()`, the two views) is presented in full in "The core model" above; this section refers to it by line number rather than re-quoting it.

One thing worth flagging here since it affects how the functions below are read: a *function* is also declared with the exact name `_object_reference._object_v__for_update` (lines 835–962, quoted in full just below), distinct from the *view* of the same name (lines 256–270) — `FROM _object_reference._object_v__for_update` (no parens, e.g. line 892/905) means the view, while `_object_reference._object_v__for_update(object_type, v_objid, v_subid, object_group_id)` (with parens, line 1161) means the function.

### 1a. `_object_reference._object_v__for_update(object_type, objid, objsubid, object_group_id, class_id)` — the self‑heal engine

Full body (lines 835–962):
```sql
SELECT __object_reference.create_function(
  '_object_reference._object_v__for_update'
  , $args$
  object_type _object_reference.object.object_type%TYPE
  , objid _object_reference._object_oid.objid%TYPE
  , objsubid _object_reference._object_oid.objsubid%TYPE
  , object_group_id int DEFAULT NULL
  , class_id regclass DEFAULT NULL
$args$
  , '_object_reference._object_v LANGUAGE plpgsql'
  , $body$
DECLARE
  c_classid CONSTANT regclass := cat_tools.object__address_classid(object_type);

  r_object_v _object_reference._object_v;
  r_address record;
  r_identity record;

  did_insert boolean := false;

  i smallint;
  sql text;
BEGIN
  ASSERT class_id IS NULL OR class_id = c_classid, format(
    'cat_tools.object__address_classid(object_type) %L <> class_id %L'
    , c_classid
    , class_id
  );
  IF object_reference.unsupported(object_type) THEN
    RAISE 'object_type % is not supported', object_type;
  END IF;

  SELECT INTO r_address * FROM pg_catalog.pg_identify_object_as_address(c_classid, objid, objsubid);

  IF r_address IS NULL THEN
    RAISE 'unable to find object'
      USING DETAIL = format(
        'pg_identify_object_as_address(%s, %s, %s) returned NULL'
        , c_classid
        , objid
        , objsubid
      )
    ;
  END IF;

  -- Refuse to track objects in temporary schemas
  SELECT INTO r_identity * FROM pg_catalog.pg_identify_object(c_classid, objid, objsubid);
  IF r_identity.schema IS NOT NULL AND (r_identity.schema LIKE 'pg_temp%' OR r_identity.schema LIKE 'pg_toast_temp%') THEN
    RAISE 'cannot track temporary object'
      USING DETAIL = format('object %s is in temporary schema %s', r_identity.identity, r_identity.schema)
      , ERRCODE = 'feature_not_supported'
    ;
  END IF;

  -- Ensure the object record exists
  SELECT INTO r_object_v
      *
    FROM _object_reference._object_v__for_update o
    WHERE (o.object_type, o.object_names, o.object_args) = (_object_v__for_update.object_type, r_address.object_names, r_address.object_args)
  ;
  IF NOT FOUND THEN
    FOR i IN 1..10 LOOP
      did_insert := true;
      INSERT INTO _object_reference.object(object_type, object_names, object_args)
        VALUES(_object_v__for_update.object_type, r_address.object_names, r_address.object_args)
        ON CONFLICT ON CONSTRAINT object__u_object_names__object_args DO NOTHING
      ;
      -- Still a small race condition here...
      SELECT INTO r_object_v
          *
        FROM _object_reference._object_v__for_update o
        WHERE (o.object_type, o.object_names, o.object_args) = (_object_v__for_update.object_type, r_address.object_names, r_address.object_args)
      ;
      EXIT WHEN FOUND;
    END LOOP;
    IF NOT FOUND THEN
      RAISE 'fell out of loop!' USING HINT = 'This should never happen.';
    END IF;
  END IF;

  ASSERT r_object_v.names_ok, 'names do not match (should not be possible)' ;

  IF object_group_id IS NOT NULL THEN
    PERFORM object_reference.object_group__object__add(object_group_id, r_object_v.object_id);
  END IF;

  -- Handle _object_oid table
  CASE
    WHEN r_object_v.ids_ok THEN
      RETURN r_object_v;

    WHEN NOT r_object_v.ids_exist THEN
      /*
       * Just need to create IDs record.
       */

      /* 
       * This shouldn't normally happen, but could occur if a restore didn't
       * finish cleanly. We know it's safe to do this because names_ok is true.
       */
      IF NOT did_insert THEN
        RAISE WARNING 'missing record in _object_reference._object_oid for object_id %', r_object_v.object_id
          USING HINT = 'This indicates a restore did not finish cleanly.'
        ;
      END IF;
      r_object_v := _object_reference._object_oid__add(r_object_v.object_id, object_type, c_classid, objid, objsubid);

    WHEN r_object_v.ids_exist THEN
      RAISE 'ids are out of sync for object_id %', r_object_v.object_id
        USING DETAIL = format(
          E'_object_reference._object_v = %L,\n    arguments (%L, %s, %s, %s)'
          , pg_catalog.row_to_json(r_object_v, true)
          , object_type
          , objid
          , objsubid
          , object_group_id
        )
        , HINT = 'this shoud not happen if event trigger "zzz_object_reference_end" is working'
      ;
    ELSE
      RAISE 'unknown condition';
  END CASE;

  RETURN r_object_v;
END
$body$
  , 'Return details of a object record, creating a new record if one does not exist.'
);
```

**When it's called.** This is the innermost, general-purpose primitive that both `object__getsert_w_group_id()` (line 1161) and the `zzz_object_reference_capture` event trigger (line ~1401) call once they have resolved a name/secondary down to a concrete `(objid, objsubid)` pair and know the object's `cat_tools.object_type`. It is the single place that both looks up (or creates) the `_object_reference.object` row *and* reconciles the `_object_oid` row against it.

**Assumptions about state on entry.** It assumes `(object_type, objid, objsubid)` genuinely identifies a *currently existing* catalog object (it will look it up via `pg_identify_object_as_address`/`pg_identify_object`, and error out if it doesn't). It makes no assumption about whether a matching `_object_reference.object` row or `_object_oid` row already exists — that's precisely what it reconciles. `class_id`, if passed, is asserted equal to the type-derived classid purely as a caller sanity check.

**Branch-by-branch:**
1. **`ASSERT class_id IS NULL OR class_id = c_classid`** — if a caller passes an inconsistent `class_id`, an assertion failure aborts (only reachable via a programming error in a caller; `object__getsert_w_group_id` never passes `class_id`, so this can't fire from the public API today).
2. **`IF object_reference.unsupported(object_type) THEN RAISE`** — refuses to track object types in `object_reference.unsupported()` (shared objects, address-unsupported types, event triggers, partitioned table/index).
3. **`IF r_address IS NULL THEN RAISE`** — `pg_identify_object_as_address` found nothing for that OID/classid/subid combo (object doesn't exist, or was already dropped) → hard error, no row touched.
4. **Temporary-schema guard** — if the resolved object lives in `pg_temp%`/`pg_toast_temp%`, raises with `ERRCODE = 'feature_not_supported'` and never creates any row.
5. **Ensure the `object` row exists** (lines 890–913):
   - Looks up by `(object_type, object_names, object_args)` in the **locking** view `_object_v__for_update`.
   - **If found**: skip the insert loop entirely, `did_insert` stays `false`.
   - **If not found**: loop up to 10 times: insert into `_object_reference.object` with `ON CONFLICT ... DO NOTHING` (handles a concurrent inserter racing on the same unique constraint), then re-select; `EXIT WHEN FOUND`. `did_insert` is set `true` unconditionally inside the loop (even though the row may have been supplied by a concurrent transaction, not this one).
   - **If still not found after 10 iterations**: `RAISE 'fell out of loop!'` — a defensive, should-never-happen error.
6. **`ASSERT r_object_v.names_ok`** — sanity check that the row just found/inserted round-trips through `pg_get_object_address`; documented as "should not be possible" since `r_address` itself came from the catalog moments earlier.
7. **`IF object_group_id IS NOT NULL THEN PERFORM object_reference.object_group__object__add(...)`** — optionally attaches the object to a group; happens regardless of which `_object_oid` branch follows.
8. **`_object_oid` reconciliation `CASE`** (mutually exclusive because `ids_ok ⇒ ids_exist`, as shown by `_sanity()` above):
   - **`WHEN r_object_v.ids_ok THEN RETURN r_object_v;`** — everything already consistent; return immediately, no writes to `_object_oid`. This is the common "already tracked, nothing to do" fast path.
   - **`WHEN NOT r_object_v.ids_exist THEN ...`** — the actual self-heal branch: no `_object_oid` row at all.
     - If `did_insert` is `false` (i.e., the `object` row already existed from before this call, so a missing `_object_oid` row is unexpected/out-of-band), it emits `RAISE WARNING 'missing record in _object_reference._object_oid for object_id %' ... HINT 'This indicates a restore did not finish cleanly.'` — a warning only, not an error, execution continues.
     - Either way, calls `_object_reference._object_oid__add(r_object_v.object_id, object_type, c_classid, objid, objsubid)` to insert the row and re-fetch `r_object_v` (that function itself asserts `ids_ok` afterward and errors "id mismatch... should not be possible" if not).
   - **`WHEN r_object_v.ids_exist THEN ...`** — an `_object_oid` row exists but doesn't match (`ids_ok` false while `ids_exist` true) — i.e., genuinely out of sync. Hard `RAISE 'ids are out of sync for object_id %'` with a `DETAIL` dump of the row and args, and `HINT = 'this shoud not happen if event trigger "zzz_object_reference_end" is working'` (sic — typo in source). **Note this HINT names a trigger, `zzz_object_reference_end`, that does not exist anywhere in the current source**: `grep -n "zzz_object_reference\|zzz__object_reference"` over `sql/object_reference.sql` shows only three event triggers are ever `CREATE`d — `zzz__object_reference_drop`, `zzz_object_reference__fix_identity` (line 1577), and `zzz_object_reference_capture` (line 1583) — none named `zzz_object_reference_end`. This is a stale/dangling reference in the source, apparently a leftover from an earlier trigger name; do not go looking for a fourth, "…_end" trigger. No self-heal is attempted for this case; it's treated as a bug.
   - **`ELSE RAISE 'unknown condition';`** — dead/unreachable code, since the three `WHEN`s above are exhaustive over the boolean pair `(ids_ok, ids_exist)` given `ids_ok ⇒ ids_exist`. Kept purely as a defensive catch-all.
9. **`RETURN r_object_v;`** at the very end — only reachable from the `NOT ids_exist` branch (the `ids_ok` branch already returned; the `ids_exist`/mismatch branch already raised).

---

### 1b. `object_reference.object__getsert_w_group_id(object_type, object_name, secondary, object_group_id, loose)`

Full body (lines 964–1166):
```sql
SELECT __object_reference.create_function(
  'object_reference.object__getsert_w_group_id'
  , $args$
  object_type   cat_tools.object_type
  , object_name text
  , secondary text DEFAULT NULL
  , object_group_id int DEFAULT NULL
  , loose boolean DEFAULT false
$args$
  , 'int LANGUAGE plpgsql'
  , $body$
DECLARE
  c_catalog CONSTANT regclass := cat_tools.object__catalog(object_type);
  c_loose CONSTANT boolean := coalesce(loose, false);

  v_objid oid;
  v_subid int := 0;
BEGIN
  RAISE DEBUG '% "%" (secondary %) uses catalog %', object_type, object_name, secondary, c_catalog;

  -- Some catalogs need special handling
  CASE c_catalog
  -- Functions
  WHEN 'pg_catalog.pg_proc'::regclass THEN
    /*
     * Need to handle functions specially to support all the extra options they
     * can have that regprocedure doesn't support.
     */
    -- TODO: allow this to parse object_name directly
    BEGIN
      v_objid := cat_tools.regprocedure(object_name, secondary);
    EXCEPTION WHEN undefined_function THEN
      IF c_loose THEN
        RETURN NULL;
      END IF;
      RAISE;
    END;
    secondary = NULL;

  -- Columns
  WHEN 'pg_catalog.pg_attribute'::regclass THEN
    v_objid := object_name::regclass;
    BEGIN
      -- Will throw error if column isn't valid
      v_subid := (cat_tools.pg_attribute__get(v_objid, secondary)).attnum;
    EXCEPTION WHEN undefined_column THEN
      IF c_loose THEN
        RETURN NULL;
      END IF;
      RAISE;
    END;
    secondary = NULL;

  -- Defaults
  WHEN 'pg_catalog.pg_attrdef'::regclass THEN
    BEGIN
      SELECT INTO STRICT v_objid
          oid
        FROM pg_catalog.pg_attrdef
        WHERE adrelid = object_name::regclass
          -- Will throw error if column isn't valid
          AND adnum = (cat_tools.pg_attribute__get(object_name::regclass, secondary)).attnum
      ;
    EXCEPTION WHEN no_data_found THEN
      IF c_loose THEN
        RETURN NULL;
      END IF;
      RAISE 'default value for %.% does not exist', object_name::regclass, secondary
        USING ERRCODE = 'undefined_object'
      ;
    END;
    secondary = NULL;

  -- Triggers
  WHEN 'pg_catalog.pg_trigger'::regclass THEN
    BEGIN
      SELECT INTO STRICT v_objid
          oid
        FROM pg_catalog.pg_trigger
        WHERE tgrelid = object_name::regclass
          AND tgname = secondary
      ;
    EXCEPTION WHEN no_data_found THEN
      IF c_loose THEN
        RETURN NULL;
      END IF;
      RAISE 'trigger "%" for table "%" does not exist', secondary, object_name::regclass
        USING ERRCODE = 'undefined_object'
      ;
    END;
    secondary = NULL;

  -- Constraints
  WHEN 'pg_catalog.pg_constraint'::regclass THEN
    DECLARE
      v_relid oid = 0;
      v_typid oid = 0;
    BEGIN
      CASE object_type
        WHEN 'table constraint'::cat_tools.object_type THEN -- conrelid
          v_relid := object_name::regclass;
        WHEN 'domain constraint'::cat_tools.object_type THEN -- contypid
          v_typid := object_name::regtype;
        ELSE
          RAISE 'unexpected object type % for a constraint', object_type;
      END CASE;

      BEGIN
        SELECT INTO STRICT v_objid
            oid
          FROM pg_catalog.pg_constraint
          WHERE conname = secondary
            AND conrelid = v_relid
            AND contypid = v_typid
          ;
      EXCEPTION WHEN no_data_found THEN
        -- At this point regclass or regtype should have thrown an error if the parent object doesn't exist
        IF c_loose THEN
          RETURN NULL;
        END IF;
        RAISE 'constraint "%" does not exist', secondary
          USING ERRCODE = 'undefined_object'
        ;
      END;
    END;
    secondary = NULL;

  -- Casts
  WHEN 'pg_catalog.pg_cast'::regclass THEN
    BEGIN
      SELECT INTO STRICT v_objid
          oid
        FROM pg_catalog.pg_cast
        WHERE castsource = object_name::regtype
          AND casttarget = secondary::regtype
        ;
    EXCEPTION WHEN no_data_found THEN
      IF c_loose THEN
        RETURN NULL;
      END IF;
      RAISE 'cast from "%" to "%" does not exist', object_name, secondary
        USING ERRCODE = 'undefined_object'
      ;
      IF c_loose THEN
        RETURN NULL;
      END IF;
    END;
    secondary = NULL;

  ELSE
    DECLARE
      c_reg_type name := cat_tools.object__reg_type(c_catalog);

      v_name_field text;
      sql text;
    BEGIN
      IF c_reg_type IS NULL THEN
        /*
         * Need to do a manual lookup of the OID based on what catalog it is
         *
         * Get first 3 letters of catalog name after the 'pg_', since that's
         * usually the field name. We also need to handle the possibility of
         * 'pg_catalog.' being part of c_catalog.
         */
        v_name_field := substring(regexp_replace(c_catalog::text, '(pg_catalog\.)?pg_', ''), 1, 3);

        sql := format(
          'SELECT oid FROM %s WHERE %I = %L'
          , c_catalog -- No need to quote
          , v_name_field
          , object_name
        );
      ELSE
        sql := format(
          'SELECT %L::%s'
          , object_name
          , c_reg_type -- No need to quote
        );
      END IF;
      RAISE DEBUG 'looking up % % via %', object_type, object_name, sql;
      BEGIN
        EXECUTE sql INTO STRICT v_objid;
      EXCEPTION WHEN no_data_found THEN
        IF c_loose THEN
          RETURN NULL;
        END IF;
        RAISE '% "%" does not exist', object_type, object_name
          USING ERRCODE = 'undefined_object'
        ;
      END;
    END;
  END CASE;

  IF secondary IS NOT NULL THEN
    RAISE 'secondary may not be specified for % objects', object_type;
  END IF;

  RETURN (_object_reference._object_v__for_update( object_type, v_objid, v_subid, object_group_id )).object_id;
END
$body$
  , 'Return a object_id for an object. Allows specifying a object group ID to add the object to. See also object__getsert().'
  , 'object_reference__usage'
);
```

**When it's called.** This is the public-facing name→id resolver: given a human-readable `object_type` + `object_name` (+ optional `secondary`, e.g. arg types for a function, column name for a column/default, trigger name, target type for a cast), it resolves those to `(v_objid, v_subid)` and hands off to `_object_reference._object_v__for_update()` to do the actual get-or-create/self-heal against the two tables. It's called directly by `object_reference.object__getsert()` (via `object_group_name` → `object_group_id` translation, lines 1179–1185) and by the trigger-cast text-typed overload at lines 1190–1201.

**Assumptions about state on entry.** None about `object`/`_object_oid` directly — all of its own logic is about mapping a *name* to an *OID* using the appropriate catalog (`cat_tools.object__catalog(object_type)`), before delegating to the self-heal function. It does assume `cat_tools.object__catalog`/`cat_tools.object__reg_type`/`cat_tools.object__address_classid` correctly classify `object_type`.

**Branch-by-branch** (the outer `CASE c_catalog`, each arm resolves `v_objid`/`v_subid` differently because `regprocedure` etc. don't cover every object flavor):
- **`pg_catalog.pg_proc` (functions/procedures/aggregates)**: uses `cat_tools.regprocedure(object_name, secondary)` (handles the extra syntax regprocedure alone can't, per the comment) inside a sub-`BEGIN`; on `undefined_function`, if `loose` → `RETURN NULL` immediately (function ends here); otherwise re-raises. `secondary` is cleared to `NULL` since it was consumed.
- **`pg_catalog.pg_attribute` (columns)**: casts `object_name::regclass` (this itself will raise `undefined_table`-class errors uncaught if the relation doesn't exist — not wrapped in a loose-aware `BEGIN`, so `loose` does **not** protect against a bad *relation* name here, only a bad *column* name); then looks up column number via `cat_tools.pg_attribute__get`, catching `undefined_column` → `loose` ? `RETURN NULL` : re-raise.
- **`pg_catalog.pg_attrdef` (column defaults)**: `SELECT INTO STRICT` by `adrelid`/`adnum`; `no_data_found` → `loose` ? `RETURN NULL` : `RAISE 'default value for %.% does not exist'` with `ERRCODE = undefined_object`.
- **`pg_catalog.pg_trigger`**: `SELECT INTO STRICT` by `tgrelid`/`tgname`; `no_data_found` → `loose` ? `RETURN NULL` : `RAISE 'trigger "%" for table "%" does not exist'`.
- **`pg_catalog.pg_constraint`**: nested `DECLARE`/`BEGIN`; first an inner `CASE object_type` picks whether to resolve `v_relid` (table constraint) or `v_typid` (domain constraint) — any other `object_type` routed to this catalog arm hits `RAISE 'unexpected object type % for a constraint'` unconditionally (not loose-gated — this is a programmer/data error, not a "does it exist" case). Then `SELECT INTO STRICT` by `conname`/`conrelid`/`contypid`; `no_data_found` → `loose` ? `RETURN NULL` : `RAISE 'constraint "%" does not exist'`.
- **`pg_catalog.pg_cast`**: `SELECT INTO STRICT` by `castsource`/`casttarget`; `no_data_found` → `loose` ? `RETURN NULL` : `RAISE 'cast from "%" to "%" does not exist'`. Note the dead code immediately after that `RAISE` (`IF c_loose THEN RETURN NULL; END IF;` following the `RAISE`) — unreachable since `RAISE` never returns; a harmless but real leftover/dead branch in the source as it stands today.
- **`ELSE` (everything else — the general case)**: uses `cat_tools.object__reg_type(c_catalog)` to see if there's a reg-type cast shortcut (e.g. `regclass`, `regtype`, `regnamespace`...). If `c_reg_type IS NULL`, falls back to a heuristic manual lookup: builds `SELECT oid FROM <catalog> WHERE <first-3-letters-of-catalog-name-after-pg_> = <object_name>` and `EXECUTE ... INTO STRICT`. If `c_reg_type` is set, instead does `SELECT '<object_name>'::<reg_type>`. Either way, `no_data_found` (only possible from the manual-lookup path's dynamic SQL; the reg-type cast path raises its own native error type, not `no_data_found`, if invalid) → `loose` ? `RETURN NULL` : `RAISE '% "%" does not exist'`.
- **After the outer `CASE`**: `IF secondary IS NOT NULL THEN RAISE 'secondary may not be specified for % objects'` — guards against a caller passing a `secondary` for an object type that never consumes it (every branch above that *does* use `secondary` explicitly sets it back to `NULL`; only the catalogs that never look at `secondary` at all leave it non-NULL and trip this check).
- **Final line**: `RETURN (_object_reference._object_v__for_update( object_type, v_objid, v_subid, object_group_id )).object_id;` — hands off to the self-heal function documented above and returns just its `object_id`.

---

### 1c. `object_reference.object__getsert(object_type, object_name, secondary, object_group_name, loose)` — public wrapper

Two overloads (cat_tools.object_type and text), lines 1168–1203:
```sql
SELECT __object_reference.create_function(
  'object_reference.object__getsert'
  , $args$
  object_type   cat_tools.object_type
  , object_name text
  , secondary text DEFAULT NULL
  , object_group_name _object_reference.object_group.object_group_name%TYPE DEFAULT NULL
  , loose boolean DEFAULT false
$args$
  , 'int LANGUAGE sql'
  , $body$
SELECT object_reference.object__getsert_w_group_id(
  $1, $2, $3
  , CASE WHEN object_group_name IS NOT NULL THEN
      (object_reference.object_group__get($4)).object_group_id
    END
  , $5
)
$body$
  , 'Return a object_id for an object. Allows specifying a object group name to add the object to. See also object__getsert_w_group_id().'
  , 'object_reference__usage'
);
SELECT __object_reference.create_function(
  'object_reference.object__getsert'
  , $args$
  object_type text
  , object_name text
  , secondary text DEFAULT NULL
  , object_group_name _object_reference.object_group.object_group_name%TYPE DEFAULT NULL
  , loose boolean DEFAULT false
$args$
  , 'int LANGUAGE sql'
  , $$SELECT object_reference.object__getsert( lower($1)::cat_tools.object_type, $2, $3, $4, $5 )$$
  , 'Return a object_id for an object. Allows specifying a object group name to add the object to. See also object__getsert_w_group_id().'
  , 'object_reference__usage'
);
```
No new branch logic of its own: it's a thin single-statement `SELECT` wrapper. It translates an `object_group_name` into an `object_group_id` via `object_reference.object_group__get()` only when the name is non-NULL (leaving `object_group_id` as SQL `NULL` — i.e. "no group" — otherwise), then delegates entirely to `object__getsert_w_group_id()` above. The `text`-typed overload additionally lower-cases and casts the `object_type` string before delegating to the `cat_tools.object_type`-typed overload — this is the entry point used when a caller passes an object type as a plain string (e.g. `'TABLE'`, `'Table'` both work because of the `lower()`).

---

### 2. `object_reference.object__describe()` and `object_reference.object__identity()`

Full bodies (lines 772–813):
```sql
SELECT __object_reference.create_function(
  'object_reference.object__describe'
  , $args$
  object_id int
$args$
  , 'text LANGUAGE sql'
  , $body$
SELECT pg_catalog.pg_describe_object(
  o.classid
  , o.objid
  , o.objsubid
)
FROM _object_reference._object_oid o
WHERE o.object_id = $1
$body$
  , 'Return a human-readable description of the object, matching pg_describe_object() format.'
  , 'object_reference__usage'
);

SELECT __object_reference.create_function(
  'object_reference.object__identity'
  , $args$
  object_id int
  , OUT type text
  , OUT schema text
  , OUT name text
  , OUT identity text
$args$
  , 'record LANGUAGE sql'
  , $body$
SELECT
  i.type::text
  , i.schema::text
  , i.name::text
  , i.identity::text
FROM _object_reference._object_oid o
  , LATERAL pg_catalog.pg_identify_object(o.classid, o.objid, o.objsubid) i
WHERE o.object_id = $1
$body$
  , 'Return object identification information matching pg_identify_object() format.'
  , 'object_reference__usage'
);
```

**Trace of what they touch**: Both are plain single-statement SQL functions that read **only** `_object_reference._object_oid` directly (`FROM _object_reference._object_oid o WHERE o.object_id = $1`), then feed its `classid`/`objid`/`objsubid` columns straight to the built-in catalog functions `pg_catalog.pg_describe_object()` / `pg_catalog.pg_identify_object()`. Neither touches `_object_reference.object`, `_object_reference._object_v`, `_object_reference._object_v__for_update` (view or function), or `_object_reference._sanity()` in any way — no self-heal logic is invoked, and no row is ever inserted or updated by either call. If there is no matching row in `_object_oid` for the given `object_id` (whether because it was never tracked, or its `_object_oid` row was deleted/never created), the `FROM`/`WHERE` produces zero rows and the function simply returns `NULL` (for `object__describe`, a scalar `text`) or a single all-NULL record (for `object__identity`, since it's declared as a non-SETOF `record`-returning SQL function called in a scalar context) — it does **not** raise an error and does **not** attempt to create/repair anything.

Demonstration:

```
CREATE TABLE demo_tbl(id int primary key, name text);
CREATE FUNCTION demo_fn(int) RETURNS int LANGUAGE sql AS 'SELECT $1';
```
After `object__getsert('table','demo_tbl')` → `object_id=1`, and `object__getsert('function','demo_fn','int')` → `object_id=2`:
```
 object_id | object_type |  object_names   | object_args
-----------+-------------+-----------------+-------------
         1 | table       | {public,demo_tbl} | {}
         2 | function    | {public,demo_fn}  | {integer}

 object_id | classid | objid | objsubid
-----------+---------+-------+----------
         1 |    1259 | 27812 |        0
         2 |    1255 | 27819 |        0
```
```
=> SELECT object_reference.object__describe(1);
 object__describe
------------------
 table demo_tbl

=> SELECT * FROM object_reference.object__identity(1);
 type  | schema |   name   |    identity
-------+--------+----------+-----------------
 table | public | demo_tbl | public.demo_tbl
```
Then, simulating an out-of-sync state — `DELETE FROM _object_reference._object_oid WHERE object_id = 2;` (function's OID row removed) — and calling the two accessors on `object_id = 2`:
```
=> SELECT object_reference.object__describe(2);
 object__describe
------------------
 (NULL)

=> SELECT * FROM object_reference.object__identity(2);
 type | schema | name | identity
------+--------+------+----------
      |        |      |

=> SELECT * FROM _object_reference._object_oid ORDER BY object_id;
 object_id | classid | objid | objsubid
-----------+---------+-------+----------
         1 |    1259 | 27812 |        0
```
Row for `object_id=2` stayed missing — confirming `object__describe`/`object__identity` **never self-heal**. By contrast, calling the self-heal function directly (`_object_reference._object_v__for_update('function'::cat_tools.object_type, 'demo_fn(int)'::regprocedure::oid, 0)`) on the same object_id **did** recreate the missing row:
```
=> SELECT * FROM _object_reference._object_oid ORDER BY object_id;
 object_id | classid | objid | objsubid
-----------+---------+-------+----------
         1 |    1259 | 27812 |        0
         2 |    1255 | 27819 |        0
```
The `NOT ids_exist` self-heal branch's `WARNING` is likewise observable directly: after `DELETE FROM _object_reference._object_oid WHERE object_id = 1;` and re-calling `object_reference.object__getsert('table', 'demo_tbl')`:
```
WARNING:  missing record in _object_reference._object_oid for object_id 1
HINT:  This indicates a restore did not finish cleanly.
```
and the row was silently recreated (`object__getsert` still returned `1`, no error to the caller).

---

## `_object_oid__add()`, `fix_refs()`, and `post_restore()` in `sql/object_reference.sql`

All line numbers below are from `sql/object_reference.sql` in this checkout (identical to upstream `master`, 1610 lines total).

### 1. `_object_reference._object_oid__add()` — complete body (lines 272–318)

```sql
SELECT __object_reference.create_function(
  '_object_reference._object_oid__add'
  , $args$
  object_id _object_reference._object_oid.object_id%TYPE
  , object_type _object_reference.object.object_type%TYPE DEFAULT NULL
  , classid _object_reference._object_oid.classid%TYPE DEFAULT NULL
  , objid _object_reference._object_oid.objid%TYPE DEFAULT NULL
  , objsubid _object_reference._object_oid.objsubid%TYPE DEFAULT NULL
$args$
  , '_object_reference._object_v LANGUAGE plpgsql'
  , $body$
DECLARE
  r_object_v _object_reference._object_v;
BEGIN
  IF object_type IS NULL THEN
    -- Should definitely exist
    SELECT INTO STRICT object_type, classid, objid, objsubid
        o.object_type, a.classid, a.objid, a.objsubid
      FROM _object_reference.object o
        , pg_catalog.pg_get_object_address(o.object_type::text, o.object_names, o.object_args) a
      WHERE o.object_id = _object_oid__add.object_id
    ;
  END IF;
  BEGIN
    INSERT INTO _object_reference._object_oid(object_id, classid, objid, objsubid)
      VALUES (object_id, classid, objid, objsubid);

    SELECT INTO STRICT r_object_v -- Record better exist!
        *
      FROM _object_reference._object_v__for_update o
      WHERE o.object_id = _object_oid__add.object_id
    ;
  END;

  IF NOT r_object_v.ids_ok THEN
    RAISE 'id mismatch for object_id %', object_id
      USING
        DETAIL = '_object_reference._object_v = ' || pg_catalog.row_to_json(r_object_v)
        , HINT = 'this should not be possible'
    ;
  END IF;

  RETURN r_object_v;
END
$body$
  , 'Check the sanity of object and _object_oid'
);
```

The `INSERT INTO _object_reference._object_oid(...)` at what becomes lines 296–297 has no `ON CONFLICT` clause of any kind, into a table whose PK is `object_id` (declared at line 182: `object_id int PRIMARY KEY REFERENCES _object_reference.object ...`).

#### Claim: duplicate call raises a duplicate-key error — CONFIRMED

Reproduction: registered one object (`public.widget`, a table) via `object_reference.object__getsert('table', 'public.widget')`, which fully populates both `_object_reference.object` and `_object_reference._object_oid` for `object_id = 1`. Then called `_object_oid__add` again directly for that same, already-populated `object_id`:

```
psql -d oid_audit_r3fixrefs -c "SELECT _object_reference._object_oid__add(1);"
ERROR:  duplicate key value violates unique constraint "_object_oid_pkey"
DETAIL:  Key (object_id)=(1) already exists.
CONTEXT:  SQL statement "INSERT INTO _object_reference._object_oid(object_id, classid, objid, objsubid)
      VALUES (object_id, classid, objid, objsubid)"
PL/pgSQL function _object_reference._object_oid__add(integer,cat_tools.object_type,oid,oid,integer) line 15 at SQL statement
```

Same result supplying all args explicitly instead of relying on the `object_type IS NULL` lookup branch:

```
psql -d oid_audit_r3fixrefs -c "SELECT _object_reference._object_oid__add(1, 'table', 1259, 28998, 0);"
ERROR:  duplicate key value violates unique constraint "_object_oid_pkey"
DETAIL:  Key (object_id)=(1) already exists.
...
```

Claim confirmed exactly as stated: no `ON CONFLICT`, real duplicate-key error on a re-add for an `object_id` that already has an `_object_oid` row.

#### Every call site of `_object_oid__add()` in the file

```
grep -n "_object_oid__add(" sql/object_reference.sql
376:          PERFORM _object_reference._object_oid__add(r_object_v.object_id);
420:  , 'SELECT count(*) AS objects FROM _object_reference.object, _object_reference._object_oid__add(object_id)'
940:      r_object_v := _object_reference._object_oid__add(r_object_v.object_id, object_type, c_classid, objid, objsubid);
```

(These are the only three call sites; the function's own body, lines 296–297, contains the `INSERT`, not a recursive call.)

**Line 376 — inside `_object_reference.fix_refs()`, `WHEN NOT r_object_v.ids_exist THEN` branch, `IF warning_only THEN`.** `r_object_v` here comes from an un-locked `FOR r_object_v IN SELECT * FROM _object_reference._object_v LOOP` (line 331–332), and the call is only reached when that same row's `ids_exist` was just observed to be `false` (line 373: `WHEN NOT r_object_v.ids_exist THEN`). So *within this loop iteration* it's guarded — reproduced by deleting the `_object_oid` row for `object_id=1` and re-running `object__getsert`, which goes through the analogous guarded path and succeeds cleanly (warning + successful add, no duplicate-key error — see below). However this specific `fix_refs` call site is **not immune to a genuine TOCTOU race**: the driving `SELECT * FROM _object_reference._object_v` (line 332) takes no lock, so if a concurrent session inserts an `_object_oid` row for the same `object_id` between that `SELECT` and this `PERFORM`, the duplicate-key error from claim 1 would surface here. Given `fix_refs()`/`post_restore()` are meant to run once, after a restore, before normal traffic resumes, this is a narrow window in practice but the code does not itself prevent it.

**Line 420 — inside `_object_reference._repair()`** (`'SELECT count(*) AS objects FROM _object_reference.object, _object_reference._object_oid__add(object_id)'`, lines 416–423). This is an implicit cross join that calls `_object_oid__add(object_id)` for **every row** in `_object_reference.object`, completely unconditionally — no filter on whether that `object_id` already has an `_object_oid` row. This call site is **not guarded at all**. It is only safe today because `_repair()` is invoked exactly once, automatically, at line 425 (`CREATE MATERIALIZED VIEW _object_reference._sentry_mv AS SELECT _object_reference._repair();`), which runs during `CREATE EXTENSION` at a point in the install script where `_object_reference.object` is guaranteed to still be empty — because `CREATE EXTENSION` executes the script's top-level statements strictly in order, and no top-level DML against `_object_reference.object` appears anywhere before line 425. (The `INSERT INTO _object_reference.object` at line 898 is not itself a top-level statement executed in script order; it is embedded text inside the `$body$` of the `CREATE FUNCTION`-equivalent call defining `_object_reference._object_v__for_update` at lines 835–962, and only runs later, at runtime, whenever some session calls that function — its physical line number carries no information about execution order relative to line 425.) There is no `REFRESH MATERIALIZED VIEW` anywhere in the file, and `_repair()` is never called anywhere else. Calling `_repair()` manually against a database that already has a fully-populated object (`object_id=1` with an existing `_object_oid` row) demonstrates the danger directly:

```
psql -d oid_audit_r3fixrefs -c "SELECT _object_reference._repair();"
ERROR:  duplicate key value violates unique constraint "_object_oid_pkey"
DETAIL:  Key (object_id)=(1) already exists.
CONTEXT:  SQL statement "INSERT INTO _object_reference._object_oid(object_id, classid, objid, objsubid)
      VALUES (object_id, classid, objid, objsubid)"
PL/pgSQL function _object_reference._object_oid__add(integer,cat_tools.object_type,oid,oid,integer) line 15 at SQL statement
SQL function "_repair" statement 1
```

So: safe under current usage (never re-invoked with a non-empty table), but the call site itself has zero guard against the row-already-exists case — it relies entirely on being called at a moment when the table happens to be empty.

**Line 940 — inside the function `_object_reference._object_v__for_update(object_type, objid, objsubid, object_group_id, class_id)`** (the plpgsql "getsert" core, lines 835–962; the function, not the view of the same name at lines 256–270 — see "Write/repair paths: getsert" above). The call is reached only in the `WHEN NOT r_object_v.ids_exist` branch (lines 926–940), where `r_object_v` was obtained via `_object_reference._object_v__for_update o ... FOR UPDATE OF o` (lines 890–894, re-checked at 903–907 after an `ON CONFLICT DO NOTHING` insert). The `FOR UPDATE OF o` lock on the `_object_reference.object` row serializes concurrent callers of this same getsert path against each other for that `object_id`, so under normal operation (all writers going through `object__getsert`/the event-trigger capture path) this call site is safe. Deleting the `_object_oid` row for `object_id=1` (simulating "restore didn't finish cleanly") and re-running `object__getsert` shows the guarded, successful path:

```
psql -d oid_audit_r3fixrefs <<'SQL'
BEGIN;
DELETE FROM _object_reference._object_oid WHERE object_id = 1;
SELECT object_reference.object__getsert('table', 'public.widget') AS object_id;
SELECT * FROM _object_reference._object_v;
COMMIT;
SQL
```
```
WARNING:  missing record in _object_reference._object_oid for object_id 1
HINT:  This indicates a restore did not finish cleanly.
 object_id
-----------
         1
(1 row)

 object_id | object_type |  object_names   | object_args | classid | objid | objsubid | names_ok | ids_ok | ids_exist
-----------+-------------+-----------------+-------------+---------+-------+----------+----------+--------+-----------
         1 | table       | {public,widget} | {}          |    1259 | 28998 |        0 | t        | t      | t
(1 row)
```

No duplicate-key error — the add succeeded because it was reached only when `ids_exist` was `false` under the row lock. This call site would only be unsafe if some other writer inserted into `_object_oid` for the same `object_id` *without* going through this locked path (e.g. two concurrent `fix_refs()` runs, or a direct hand-crafted `INSERT`), which is outside the scope of normal single-`fix_refs()`/normal-DDL operation.

**Summary for claim 1's call sites:**
| Line | Caller | Guarded against "row already exists"? |
|---|---|---|
| 376 | `fix_refs()` | Guarded within the loop iteration (checked `NOT ids_exist` just prior), but the driving `SELECT` takes no lock — a genuine concurrent-`fix_refs()`/concurrent-write race is possible in theory |
| 420 | `_repair()` | **Not guarded at all** — safe today only because it's invoked exactly once, automatically, against a table proven empty at that point in the install script |
| 940 | `_object_v__for_update()` (getsert core) | Guarded — reached only after checking `ids_exist` under `FOR UPDATE OF o` row lock on the `object` row |

### 2. `_object_reference.fix_refs()` — complete body (lines 323–405)

```sql
SELECT __object_reference.create_function(
  '_object_reference.fix_refs'
  , 'warning_only boolean'
  , 'void LANGUAGE plpgsql'
  , $body$
DECLARE
  r_object_v _object_reference._object_v;
BEGIN
  FOR r_object_v IN
    SELECT * FROM _object_reference._object_v
  LOOP
    CASE
      WHEN r_object_v.names_ok AND r_object_v.ids_ok THEN
        NULL; -- All good!
      WHEN NOT r_object_v.names_ok THEN
        IF r_object_v.ids_exist THEN
          -- Only happens if things are out of sync, so intentionally treat this as an error
          RAISE 'names/args are out of sync on object_id %', r_object_v.object_id
            USING
              DETAIL = '_object_reference._object_v = ' || pg_catalog.row_to_json(r_object_v)
              , HINT = CASE WHEN r_object_v.ids_ok THEN
                  E'The IDs are OK though. This should not happen, but may be fixable.\n'
                    || 'Sanity-check the record and if OK then UPDATE _object_identity.object.'
                ELSE
                  'There is also a record in _object_identity._object_oid with invalid IDs. This should never happen.'
                END
          ;
        ELSE
          IF warning_only THEN
            RAISE WARNING 'names not ok for object_id %', r_object_v.object_id
              USING DETAIL = format(
                'pg_catalog.pg_get_object_address(%L, %L, %L)'
                , r_object_v.object_type
                , r_object_v.object_names
                , r_object_v.object_args
              )
            ;
          ELSE
            RAISE 'names not ok for object_id %', r_object_v.object_id
              USING DETAIL = format(
                'pg_catalog.pg_get_object_address(%L, %L, %L)'
                , r_object_v.object_type
                , r_object_v.object_names
                , r_object_v.object_args
              )
            ;
          END IF;
        END IF;

      -- at this point, names are OK but ids are not (or don't exist)
      WHEN NOT r_object_v.ids_exist THEN
        IF warning_only THEN
          -- This is a normal condition during a restore, so just fix it
          PERFORM _object_reference._object_oid__add(r_object_v.object_id);
        ELSE
          RAISE 'no record in _object_reference._object_oid for object_id %', r_object_v.object_id
            USING
              DETAIL = '_object_reference._object_v = ' || pg_catalog.row_to_json(r_object_v)
              , HINT = 'It should be safe to fix this by calling _object_reference.fix_refs()'
          ;
        END IF;
      WHEN r_object_v.ids_exist THEN
        IF warning_only THEN
          RAISE WARNING 'extraneous ID information for object_id %', r_object.object_id
            USING
              DETAIL = '_object_reference._object_v = ' || pg_catalog.row_to_json(r_object_v)
              , HINT = E'The names are OK though. This should not happen, but may be fixable.\n'
                    || 'Sanity-check the record and if OK then UPDATE _object_identity._object_v.'
          ;
        ELSE
          RAISE 'extraneous ID information for object_id %', r_object.object_id
            USING
              DETAIL = '_object_reference._object_v = ' || pg_catalog.row_to_json(r_object_v)
              , HINT = E'The names are OK though. This should not happen, but may be fixable.\n'
                    || 'Sanity-check the record and if OK then UPDATE _object_identity._object_v.'
          ;
        END IF;
    END CASE;
  END LOOP;
END
$body$
  , 'Fixes records in _object_reference._object_oid after a restore.'
);
```

The last `CASE` arm (`WHEN r_object_v.ids_exist THEN`, lines 384–399, the "extraneous ID information" branch reached when `names_ok = true` and `ids_ok = false` while `ids_exist = true`) references `r_object.object_id` at line 386 (`warning_only` path) and again at line 393 (non-`warning_only` path) — but the loop variable declared at line 329 and used everywhere else in the function is `r_object_v`, not `r_object`. `r_object` is not declared anywhere in this function.

#### Claim: this branch itself errors instead of raising the intended diagnostic — CONFIRMED

Reaching this exact branch (`names_ok = true`, `ids_ok = false`, `ids_exist = true`) requires crafting that state directly: register `public.widget` normally (giving consistent `names_ok=t, ids_ok=t, ids_exist=t`), then corrupt the stored `objid` in `_object_reference._object_oid` so it no longer matches what `pg_get_object_address()` currently returns for that object, while names still resolve fine:

```
psql -d oid_audit_r3fixrefs <<'SQL'
UPDATE _object_reference._object_oid SET objid = 999999 WHERE object_id = 1;
SELECT * FROM _object_reference._object_v;
SQL
```
```
 object_id | object_type |  object_names   | object_args | classid | objid  | objsubid | names_ok | ids_ok | ids_exist
-----------+-------------+-----------------+-------------+---------+--------+----------+----------+--------+-----------
         1 | table       | {public,widget} | {}          |    1259 | 999999 |        0 | t        | f      | t
```

That is exactly `names_ok=t, ids_ok=f, ids_exist=t`, which routes into the final `CASE` arm. Calling `fix_refs()` with both possible `warning_only` values:

```
psql -d oid_audit_r3fixrefs -c "SELECT _object_reference.fix_refs(true);"
ERROR:  missing FROM-clause entry for table "r_object"
LINE 1: r_object.object_id
        ^
QUERY:  r_object.object_id
CONTEXT:  PL/pgSQL function _object_reference.fix_refs(boolean) line 60 at RAISE

psql -d oid_audit_r3fixrefs -c "SELECT _object_reference.fix_refs(false);"
ERROR:  missing FROM-clause entry for table "r_object"
LINE 1: r_object.object_id
        ^
QUERY:  r_object.object_id
CONTEXT:  PL/pgSQL function _object_reference.fix_refs(boolean) line 67 at RAISE
```

The reported PL/pgSQL body line numbers (60 and 67, counted from `DECLARE` at the start of the function body) map to source lines 386 and 393 respectively. Both the `warning_only := true` (intended: `RAISE WARNING`) and `warning_only := false` (intended: `RAISE` as a hard error with a diagnostic message) sub-branches fail with an unrelated `42P01`/"missing FROM-clause entry" PL/pgSQL compile-time-resolved error referencing the undeclared identifier `r_object`, instead of producing the branch's own intended diagnostic message ("extraneous ID information for object_id %"). The diagnostic content (`DETAIL`/`HINT` mentioning `r_object_v`) never gets emitted at all in this branch — the `RAISE` statement fails before producing any output.

### 3. `object_reference.post_restore()` — complete body (lines 406–413)

```sql
SELECT __object_reference.create_function(
  'object_reference.post_restore'
  , ''
  , 'void SECURITY DEFINER LANGUAGE sql'
  , 'SELECT _object_reference.fix_refs(false)'
  , 'Ensures all object references are correct after a restore.'
  , 'object_reference__usage'
);
```

Relationship to `fix_refs()`: `post_restore()` is a one-line `SQL`-language, `SECURITY DEFINER` wrapper that calls `_object_reference.fix_refs(false)` — i.e. it always runs `fix_refs` in **non**-`warning_only` (strict) mode. In that mode, any row that isn't already fully consistent (`names_ok AND ids_ok`) is treated as a hard error (`RAISE`, not `RAISE WARNING`) in every branch except the specific "missing `_object_oid` row" case (`NOT ids_exist`), which even in strict mode only raises an error and never self-heals (self-healing via `_object_oid__add` only happens when `warning_only = true`, line 374–376). So `post_restore()` cannot itself fix anything — it can only confirm the extension's bookkeeping is consistent, or blow up. Note also that because of the bug documented above, if the database state happens to be in the specific "extraneous ID information" condition (`names_ok=t, ids_ok=f, ids_exist=t`) when `post_restore()` is run, the caller will see the unrelated `missing FROM-clause entry for table "r_object"` error rather than the intended "extraneous ID information for object_id %" error.

Granted to `object_reference__usage` (line 412), i.e. it's callable by any role granted that usage role — it is the extension's supported/public entry point (unlike `_object_reference.fix_refs()` itself, which lives in the `_object_reference` schema and is not separately exposed with a grant here).

When a human/DBA is expected to call it: `post_restore()`'s own comment (line 411, `'Ensures all object references are correct after a restore.'`) and the "normal condition during a restore" comment inside `fix_refs()` (line 375) both indicate it's meant to be run **manually, once, after restoring a `pg_dump` of a database that has this extension installed** — because a restore reloads `_object_reference.object`'s rows via `COPY`/`INSERT` (extension-config-dumped data) but the OIDs in `_object_oid` refer to catalog objects that get new OIDs on restore (or may not exist yet mid-restore), so `_object_oid` needs to be rebuilt/verified against the freshly-restored catalog once the restore is complete. No place in the file invokes `object_reference.post_restore()` automatically — the only unconditional automatic caller of `fix_refs()` is the `_etg_drop()` event-trigger function (lines 1470–1515), which calls `PERFORM object_reference.post_restore();` at line 1511 unconditionally at the end of every `sql_drop` event (event trigger `zzz__object_reference_drop`, created at lines 1571–1576), with the comment (lines 1506–1510) *"We know that a restore will never drop objects, so force `_object_v` to be correct at this point."* That is a different code path from a human explicitly calling `post_restore()` post-restore, but it is worth noting because it means `fix_refs(false)`'s strict-mode error behavior (and the confirmed `r_object` bug) is also reachable automatically any time a tracked object is dropped and the extension's bookkeeping happens to be in one of the erroring states at that moment — not only when a DBA manually invokes `post_restore()` after a `pg_restore`.

### Verdicts

1. **Claim (no `ON CONFLICT`, duplicate-key error on repeat `_object_oid__add()`): CONFIRMED**, with real `ERROR: duplicate key value violates unique constraint "_object_oid_pkey"` reproduced twice. Of the three call sites, line 940 is safe by construction (row-locked check just before), line 376 is guarded per-iteration but the driving `SELECT` is unlocked (theoretical concurrent-write race), and line 420 (`_repair()`) has no guard at all and is safe today purely because it's only ever invoked once, automatically, against a table proven empty by script ordering — reproduced the actual failure by calling `_repair()` manually against a non-empty table.
2. **Claim (the "extraneous ID information" branch references undeclared `r_object` instead of `r_object_v`, making the branch itself error): CONFIRMED** at both source lines 386 and 393, for both `warning_only = true` and `warning_only = false`. Reproduced by crafting a `names_ok=t, ids_ok=f, ids_exist=t` row state and calling `fix_refs()`, which produced `ERROR: missing FROM-clause entry for table "r_object"` in both cases instead of the intended "extraneous ID information for object_id %" diagnostic.

---

## Repair-on-Restore Mechanism and Config-Dump Marking (object_reference)

All line numbers below are against `sql/object_reference.sql` on the current branch `docs/oid-repair-current-behavior`, which is identical to `upstream/master` of `Postgres-Extensions/object_reference` (1610 lines total).

### 1. `_object_reference._repair()` — complete body and behavior

The function is not written as a literal `CREATE FUNCTION` statement in the file; it is built at install time through the extension's own `__object_reference.create_function()` helper (defined lines 67–143). The call site is lines 416–423:

```sql
416  SELECT __object_reference.create_function(
417    '_object_reference._repair'
418    , ''
419    , 'bigint SECURITY DEFINER LANGUAGE sql'
420    , 'SELECT count(*) AS objects FROM _object_reference.object, _object_reference._object_oid__add(object_id)'
421    , 'Ensures all object references are correct after a restore.'
422    , 'object_reference__usage'
423  );
```

Confirmed against a live install (`\sf _object_reference._repair()` on PG17, extension freshly created), the function that actually lands in the catalog is:

```sql
CREATE OR REPLACE FUNCTION _object_reference._repair()
 RETURNS bigint
 LANGUAGE sql
 SECURITY DEFINER
AS $function$SELECT count(*) AS objects FROM _object_reference.object, _object_reference._object_oid__add(object_id)$function$
```

(plus `REVOKE ALL ... FROM public`, `GRANT EXECUTE ... TO object_reference__usage`, and a `COMMENT ON FUNCTION` — all emitted by `create_function`'s templates at lines 78–104/107–143.)

**Plain-English explanation, every branch:**

`_repair()` is a single SQL statement: an implicit `CROSS JOIN` (comma-join) between every row of `_object_reference.object` (the durable, config-dumped table of tracked objects — see §4) and the set-returning call `_object_reference._object_oid__add(object_id)` (defined lines 272–318) for that row's `object_id`. The overall `count(*)` return value is discarded/ignored by the caller (the materialized view, §2) — the entire point of `_repair()` is the *side effect* of calling `_object_oid__add()` once per tracked object.

`_object_oid__add(object_id, object_type DEFAULT NULL, classid DEFAULT NULL, objid DEFAULT NULL, objsubid DEFAULT NULL)` (lines 272–318), called here with only `object_id` supplied (all other args default `NULL`), takes this branch:

- **`object_type IS NULL` branch (lines 286–294):** it looks up the object's current, *live* identity by re-resolving `object_names`/`object_args` through `pg_catalog.pg_get_object_address()` and does a `SELECT INTO STRICT` to fetch the freshly-resolved `object_type, classid, objid, objsubid` for that `object_id`. This is exactly what makes it "repair": on a restore, the physical OIDs (`classid`/`objid`) of every database object are *new* (assigned by the fresh `CREATE TABLE`/etc. statements that ran during restore) and bear no relation to the OIDs that existed in the source database when it was dumped. Re-deriving them from `pg_get_object_address()` on the live, just-restored catalog is the only way to get correct current OIDs.
- **Insert (lines 295–304):** it then does a plain `INSERT INTO _object_reference._object_oid(object_id, classid, objid, objsubid) VALUES (...)` — no `ON CONFLICT` clause — followed by re-selecting the row from `_object_reference._object_v__for_update` (a `FOR UPDATE`-locking view, lines 256–270, built on `_sanity()`, lines 193–240).
- **Sanity check (lines 306–312):** if `NOT r_object_v.ids_ok` (i.e., the row's `pg_get_object_address()`-derived identity doesn't match what was just inserted) it `RAISE`s an unconditional hard error with `HINT = 'this should not be possible'`. There is no "warning-only"/tolerant mode here — that graduated-severity logic lives only in the sibling function `fix_refs()` (lines 323–405, used by the separately-callable `object_reference.post_restore()`, lines 406–413). `_repair()`/`_object_oid__add()` has exactly one failure mode: raise.

**Consequence verified empirically:** because the `INSERT` has no `ON CONFLICT`, `_object_oid__add()` — and therefore `_repair()` — is **not idempotent**. It only works when `_object_reference._object_oid` is empty for the rows being processed. Calling it a second time against an already-populated table fails:

```
$ psql -c "SELECT _object_reference._repair();"
ERROR:  duplicate key value violates unique constraint "_object_oid_pkey"
DETAIL:  Key (object_id)=(1) already exists.
CONTEXT:  SQL statement "INSERT INTO _object_reference._object_oid(object_id, classid, objid, objsubid)
      VALUES (object_id, classid, objid, objsubid)"
PL/pgSQL function _object_reference._object_oid__add(integer,cat_tools.object_type,oid,oid,integer) line 15 at SQL statement
SQL function "_repair" statement 1
```

Same result from `REFRESH MATERIALIZED VIEW _object_reference._sentry_mv;` run a second time. This is consistent with `_object_oid` being deliberately *excluded* from config-dump (§4): the whole scheme depends on `_object_oid` being empty exactly once, immediately after a fresh restore, before anything else touches it.

### 2. `_sentry_mv` materialized view and every config-dump marking

Grepping the whole file for `safe_dump` and `pg_extension_config_dump`:

```
56:CREATE FUNCTION __object_reference.safe_dump(
61:  PERFORM pg_catalog.pg_extension_config_dump(relation, filter);
177:SELECT __object_reference.safe_dump('_object_reference.object');
178:SELECT __object_reference.safe_dump('_object_reference.object_object_id_seq');
426:SELECT __object_reference.safe_dump('_object_reference._sentry_mv');
538:SELECT __object_reference.safe_dump('_object_reference.object_group');
545:SELECT __object_reference.safe_dump('_object_reference.object_group__object');
1601:DROP FUNCTION __object_reference.safe_dump(
```

**`__object_reference.safe_dump()` — complete body (lines 56–65):**

```sql
CREATE FUNCTION __object_reference.safe_dump(
  relation regclass
  , filter text DEFAULT ''
) RETURNS void LANGUAGE plpgsql AS $body$
BEGIN
  PERFORM pg_catalog.pg_extension_config_dump(relation, filter);
EXCEPTION WHEN feature_not_supported THEN
  RAISE WARNING 'I promise you will be sorry if you try to use this as anything other than an extension!';
END
$body$;
```

It is a thin wrapper around `pg_catalog.pg_extension_config_dump(regclass, text)` — a function that only succeeds when called with `current_setting('extension_name')` set, i.e. during `CREATE EXTENSION`/`ALTER EXTENSION`/extension-script execution. If called outside that context (`feature_not_supported`), it swallows the error and turns it into a `WARNING` — a deliberate, blunt guard rail against ever loading this file as plain SQL/psql (reinforced by the `\quit` banner at lines 1–3). `safe_dump` itself is a temporary helper: it, `__object_reference.exec()`, and `__object_reference.create_function()` are all `DROP FUNCTION`ed at lines 1593–1607, and `__object_reference` schema itself is `DROP SCHEMA`ed at line 1608, at the very end of the install script — none of it persists after `CREATE EXTENSION` finishes. (After `CREATE EXTENSION object_reference CASCADE`, `'__object_reference.safe_dump'::regprocedure` no longer resolves — the schema is gone.)

**The `_sentry_mv` definition (lines 425–426):**

```sql
425  CREATE MATERIALIZED VIEW _object_reference._sentry_mv AS SELECT _object_reference._repair();
426  SELECT __object_reference.safe_dump('_object_reference._sentry_mv');
```

`\d+ _object_reference._sentry_mv` on a live install:
```
Materialized view "_object_reference._sentry_mv"
 Column  |  Type  | ...
---------+--------+
 _repair | bigint |
View definition:
 SELECT _object_reference._repair() AS _repair;
```

**Why a materialized view, specifically, to get `_repair()` to run automatically:**

`pg_extension_config_dump()` marks a relation as an "extension configuration table" whose *data* — not its schema — gets dumped by `pg_dump`/restored by `pg_restore`, exactly like a normal user table's rows, even though the relation itself was created by an extension script (which pg_dump normally skips entirely, since `CREATE EXTENSION` recreates it). A materialized view's "data" is precisely the *result of evaluating its defining query* — there's no other kind of "row data" a matview can have. So marking `_sentry_mv` with `pg_extension_config_dump` doesn't cause pg_dump to try to literally COPY rows out and back in; it causes pg_dump to emit a `REFRESH MATERIALIZED VIEW _object_reference._sentry_mv;` statement into the dump (in place of the `COPY ... FROM stdin` a real table would get). Because the view's `SELECT` is exactly `_object_reference._repair()`, that `REFRESH` becomes a mechanism to force `_repair()` to execute once, automatically, at restore time, with no user or DBA action required — this is the entire "sentry" trick. Confirmed directly (`pg_restore -f -`):

```
-- Data for Name: object; Type: TABLE DATA; Schema: _object_reference; Owner: root
COPY _object_reference.object (object_id, object_type, object_names, object_args) FROM stdin;
...
-- (object_group, object_group__object COPY blocks, r4_test_table* COPY blocks)
...
-- Name: object_object_id_seq; Type: SEQUENCE SET; ...
...
REFRESH MATERIALIZED VIEW _object_reference._sentry_mv;
```

### 3. Section placement: `REFRESH MATERIALIZED VIEW` vs. table data vs. `CREATE EXTENSION`/event triggers

PostgreSQL's `pg_dump`/`pg_restore` archive divides work into three ordered sections — pre-data, data, post-data — and `pg_restore --list --section=<name>` (documented under `pg_restore`'s `--section` option in the PostgreSQL docs) reports exactly which TOC entries fall in each, demonstrated below against a database with the extension installed and real rows in every one of its config-dumped relations (`object`, `object_group`, `object_group__object`, plus a captured user table).

`pg_restore --list --section=pre-data` on the resulting custom-format dump:
```
8; 2615 30944 SCHEMA - cat_tools root
2; 3079 30945 EXTENSION - cat_tools 
3645; 0 0 COMMENT - EXTENSION cat_tools 
12; 2615 30943 SCHEMA - object_reference root
3; 3079 31364 EXTENSION - object_reference 
3646; 0 0 COMMENT - EXTENSION object_reference 
... (type ACLs) ...
246; 1259 31531 TABLE public r4_test_table root
247; 1259 31555 TABLE public r4_test_table2 root
```

`--section=data`:
```
3465; 0 31373 TABLE DATA _object_reference object root
3468; 0 31437 TABLE DATA _object_reference object_group root
3469; 0 31444 TABLE DATA _object_reference object_group__object root
3637; 0 31531 TABLE DATA public r4_test_table root
3638; 0 31555 TABLE DATA public r4_test_table2 root
3661; 0 0 SEQUENCE SET _object_reference object_object_id_seq root
```

`--section=post-data`:
```
2249; 826 30947 DEFAULT ACL cat_tools DEFAULT PRIVILEGES FOR TYPES root
3467; 0 31413 MATERIALIZED VIEW DATA _object_reference _sentry_mv root
```

So: **`CREATE EXTENSION object_reference` is pre-data** (runs first, restores the schema/functions/tables with empty state); **all `TABLE DATA` COPY statements and `SEQUENCE SET` are the `data` section** (run second, restore rows including the durable `_object_reference.object`/`object_group`/`object_group__object` contents); and **the `REFRESH MATERIALIZED VIEW _object_reference._sentry_mv` (`MATERIALIZED VIEW DATA` TOC entry) is `post-data`** (runs last, by which point both `CREATE EXTENSION` and every table's data are already in place — a hard requirement, since `_repair()` reads from `_object_reference.object` and calls `pg_get_object_address()` against objects that must already exist).

**`CREATE EVENT TRIGGER` is always `SECTION_POST_DATA`, including under `--binary-upgrade`:**

Adding a standalone (non-extension-owned) event trigger to the same database:

```
$ pg_restore --list --section=post-data dump2.custom | grep "EVENT TRIGGER"
3466; 3466 31559 EVENT TRIGGER - r4_standalone_evttrig root
$ pg_restore --list --section=pre-data dump2.custom | grep "EVENT TRIGGER"   # (no output)
$ pg_restore --list --section=data dump2.custom | grep "EVENT TRIGGER"       # (no output)
```

Re-running with `pg_dump --binary-upgrade` (the internal flag `pg_upgrade` itself uses, which dumps every object — including objects that are normally members of an extension, like `object_reference`'s own three event triggers created at lines 1570–1588 — as individually-scripted TOC entries rather than folding them into the opaque `EXTENSION` entry):

```
$ pg_restore --list --section=post-data dump_bu.custom | grep -E "EVENT TRIGGER|MATERIALIZED"
3499; 3466 31559 EVENT TRIGGER - r4_standalone_evttrig root
3496; 3466 31523 EVENT TRIGGER - zzz__object_reference_drop root
3497; 3466 31524 EVENT TRIGGER - zzz_object_reference__fix_identity root
3498; 3466 31525 EVENT TRIGGER - zzz_object_reference_capture root
3502; 0 31413 MATERIALIZED VIEW DATA _object_reference _sentry_mv root

$ pg_restore --list --section=data dump_bu.custom | grep -E "EVENT TRIGGER|MATERIALIZED"     # (no output)
$ pg_restore --list --section=pre-data dump_bu.custom | grep -E "EVENT TRIGGER|MATERIALIZED" # (no output)
```

(the bare matview *definition*, as opposed to its refresh/"data", does show up in pre-data as TOC entry `242; 1259 31413 MATERIALIZED VIEW _object_reference _sentry_mv` — a matview's structure is pre-data like a table's; only its "data"/refresh is post-data.) So every `CREATE EVENT TRIGGER` — both the extension's own three and a standalone one — lands in `SECTION_POST_DATA` under `--binary-upgrade` too, alongside (and, by TOC ordering, generally after) the `_sentry_mv` refresh.

**Net ordering for a restore of this extension: `CREATE EXTENSION` (pre-data) → table/sequence data restored (data) → `_sentry_mv` refreshed / `_repair()` runs, and any event triggers (re)created (post-data).**

### 4. Exhaustive `safe_dump()` call inventory and objects it does *not* cover

Every call to `__object_reference.safe_dump(...)` in the file:

| Line | Call | Relation kind |
|---|---|---|
| 177 | `__object_reference.safe_dump('_object_reference.object')` | table |
| 178 | `__object_reference.safe_dump('_object_reference.object_object_id_seq')` | sequence (backing `object.object_id serial`) |
| 426 | `__object_reference.safe_dump('_object_reference._sentry_mv')` | materialized view |
| 538 | `__object_reference.safe_dump('_object_reference.object_group')` | table |
| 545 | `__object_reference.safe_dump('_object_reference.object_group__object')` | table |

Every `CREATE TABLE`/`CREATE SEQUENCE`/`CREATE MATERIALIZED VIEW` in the file (grep):
```
164:CREATE TABLE _object_reference.object(
181:CREATE TABLE _object_reference._object_oid(
425:CREATE MATERIALIZED VIEW _object_reference._sentry_mv AS SELECT _object_reference._repair();
533:CREATE TABLE _object_reference.object_group(
540:CREATE TABLE _object_reference.object_group__object(
```
(no explicit `CREATE SEQUENCE`; the two sequences in play are the implicit ones backing `object.object_id serial` (line 165) and `object_group.object_group_id serial` (line 534)).

Cross-referencing: **two persistent objects owned by this extension are never passed to `safe_dump()`**:

- **`_object_reference._object_oid`** (table, lines 181–191) — its OID-mapping rows are never dumped at all.
- **The implicit sequence backing `object_group.object_group_id serial`** (`_object_reference.object_group_object_group_id_seq`) — unlike `object_object_id_seq` (explicitly dumped, line 178), this sequence has no corresponding `safe_dump()` call anywhere in the file.

**Empirical verification, both cases, using a real pg_dump/pg_restore round trip:**

Setup in a scratch db: captured one table via `object_reference.capture__start/stop`, created 3 `object_group` rows (advancing its sequence to 3) and 3 tracked objects (advancing `object_object_id_seq` to 3), confirmed via direct query:
```
last_value (object_group_object_group_id_seq) = 3
last_value (object_object_id_seq)              = 3
```

After `pg_dump -Fc` + `pg_restore` into a brand-new database:

```
$ psql -d oid_audit_r4dump_restored2 -c "SELECT last_value FROM _object_reference.object_group_object_group_id_seq;"
 last_value 
------------
          1
(1 row)

$ psql -d oid_audit_r4dump_restored2 -c "SELECT last_value FROM _object_reference.object_object_id_seq;"
 last_value 
------------
          3
(1 row)

$ psql -d oid_audit_r4dump_restored2 -c "SELECT count(*) FROM _object_reference.object;"        --> 3
$ psql -d oid_audit_r4dump_restored2 -c "SELECT count(*) FROM _object_reference._object_oid;"    --> 3
$ psql -d oid_audit_r4dump_restored2 -c "SELECT count(*) FROM _object_reference.object_group;"   --> 3
```

This shows two different failure modes stemming from the missing `safe_dump()` coverage:

1. **`object_group_object_group_id_seq` resets to 1** even though the `object_group` table's 3 rows (with `object_group_id` up to 3) *did* survive (because the table itself is `safe_dump`'d at line 538) — the sequence's current value is simply not part of the dump. This is not just cosmetic: it immediately breaks future inserts. Reproduced live:
   ```
   $ psql -d oid_audit_r4dump_restored2 -c "SELECT object_reference.object_group__create('post_restore_new_group');"
   ERROR:  duplicate key value violates unique constraint "object_group_pkey"
   DETAIL:  Key (object_group_id)=(1) already exists.
   CONTEXT:  SQL function "object_group__create" statement 1
   ```
   (`object_group_id_seq`'s `nextval()` produces `1`, which the table already contains from the restored data, since only `object_group.object_group_id serial`'s underlying table data survived, not its sequence position.)

2. **`_object_reference._object_oid` has 0 rows immediately after `CREATE EXTENSION`/before post-data runs**, and is *not itself* restored from dump data at all (no `TABLE DATA _object_reference _object_oid` entry appears anywhere in any TOC). Its 3 rows present in the final restored database above exist *only* because the post-data `REFRESH MATERIALIZED VIEW _object_reference._sentry_mv` executed `_repair()`, which rebuilt them from scratch by re-deriving fresh OIDs via `pg_get_object_address()` against `_object_reference.object` (which *is* durable/dumped). This is expected/by-design (`_object_oid` holds OIDs that are inherently dump-invalid — see §1): **`_object_oid`'s pre-restore data (the OIDs as they existed in the source database) does not survive a logical dump/restore at all — only `CREATE EXTENSION`'s fresh (empty) table plus a post-restore `_repair()` recomputation determines its restored contents.**

All other extension-owned relations (`_object_reference.object`, `object_object_id_seq`, `_sentry_mv`, `object_group`, `object_group__object`) are covered by `safe_dump()` and their data was confirmed present, correct, and complete in the restored database above.

---

---

## Event triggers installed by `object_reference` (r5-event-triggers)

### Locating the triggers, and ruling out the decoys near line 1527/1564

`grep -n "CREATE EVENT TRIGGER" sql/object_reference.sql` returns five hits:

```
1527:CREATE EVENT TRIGGER start
1564:CREATE EVENT TRIGGER drop
1571:CREATE EVENT TRIGGER zzz__object_reference_drop
1577:CREATE EVENT TRIGGER zzz_object_reference__fix_identity
1583:CREATE EVENT TRIGGER zzz_object_reference_capture
```

Reading lines 1517–1589 in full shows that the two near line 1527 and 1564 are **not executable SQL** — they are literal text sitting inside `$$...$$`-quoted `comment` arguments passed to `__object_reference.create_function()` for two *helper/debug* functions, `_object_reference.etg_raise__start` (lines 1517–1532, body 1521–1525) and `_object_reference.etg_raise__drop` (lines 1533–1569, body 1537–1562). Each comment string documents, as example usage, how a developer *could* wire that function up ("Example trigger: CREATE EVENT TRIGGER start / drop ..."), but no such trigger is ever actually created — `psql`/`\devt` in a fresh database confirms only three event triggers exist. These two functions (`etg_raise__start`, `etg_raise__drop`) do get created as ordinary catalog objects (they just `RAISE WARNING` diagnostic info about DDL/dropped objects), but they are unused, no-trigger-attached debugging aids, not part of the extension's three real event triggers.

The three real, executable `CREATE EVENT TRIGGER` statements are at lines 1571–1576, 1577–1582, and 1583–1588 (verbatim, unindented from the read):

```sql
CREATE EVENT TRIGGER zzz__object_reference_drop
  ON sql_drop
  -- For debugging
  --WHEN tag IN ( 'ALTER TABLE', 'DROP TABLE' )
  EXECUTE PROCEDURE _object_reference._etg_drop()
;
CREATE EVENT TRIGGER zzz_object_reference__fix_identity
  ON ddl_command_end
  -- For debugging
  --WHEN tag IN ( 'ALTER TABLE', 'DROP TABLE' )
  EXECUTE PROCEDURE _object_reference._etg_fix_identity()
;
CREATE EVENT TRIGGER zzz_object_reference_capture
  ON ddl_command_end
  -- For debugging
  --WHEN tag IN ( 'ALTER TABLE', 'DROP TABLE' )
  EXECUTE PROCEDURE _object_reference._etg_capture()
;
```

**None of the three has a `WHEN` clause** — the `WHEN tag IN (...)` lines are commented out ("For debugging") in all three. So each fires unconditionally on *every* DDL command matching its event, for every command tag, with no filter at the trigger-definition level (any filtering happens inside the handler bodies themselves, as shown below).

Firing events/tags:
- `zzz__object_reference_drop` → event `sql_drop` (fires for every dropped-object-producing statement, all tags).
- `zzz_object_reference__fix_identity` → event `ddl_command_end` (fires at the end of every DDL command, all tags).
- `zzz_object_reference_capture` → event `ddl_command_end` (same — fires at the end of every DDL command, all tags).

Both `ddl_command_end` triggers are created in the file in this order: `_etg_fix_identity` (1577) is registered *before* `_etg_capture` (1583). Event triggers for the same event fire in name order alphabetically by trigger name at a given event (per Postgres docs, event triggers fire in name order), and `zzz_object_reference__fix_identity` < `zzz_object_reference_capture` lexically (`_` sorts before `c`... actually `_` (0x5F) sorts after lowercase letters in ASCII, so `_f` > `c`; need to verify empirically rather than assume) — this ordering claim is not verified here and is not needed for the assignment, so it is not asserted further.

### 1. `_object_reference._etg_fix_identity()` — handler for `zzz_object_reference__fix_identity`

Function definition: lines 1425–1469 (`__object_reference.create_function` call), body lines 1429–1467. Full body, verbatim:

```sql
DECLARE
  r_ddl record;
  r record;
BEGIN
  /*
   * It's tempting to use pg_event_trigger_ddl_commands() to find exactly what
   * items have changed and worry about only those. That won't work because an
   * object_names array can depend on multiple names (ie: a column depends on
   * the name of it's table, as well as the name of the schema the table is in.
   * You might think we could simply recurse through pg_depend to handle this,
   * but not every name dependency gets enumerated that way. For example,
   * columns are not marked as dependent on their table.
   *
   * Rather than trying to be cute about this, we just do a brute-force check
   * for any names that have changed.
   */

  /*
   * Presumably there's no way for an objects type/classid to change, but be
   * safe and attempt the update to object_type. If it actually does change the
   * constraint on the table should catch it.
   */
  FOR r IN
    UPDATE _object_reference.object
      SET object_type  = (pg_catalog.pg_identify_object_as_address(classid, objid, objsubid)).type::cat_tools.object_type
        , object_names = (pg_catalog.pg_identify_object_as_address(classid, objid, objsubid)).object_names
        , object_args  = (pg_catalog.pg_identify_object_as_address(classid, objid, objsubid)).object_args
      FROM _object_reference._object_oid oo
      WHERE 
        oo.object_id = object.object_id
        AND (object_type::text, object_names, object_args) IS DISTINCT FROM
          (pg_catalog.pg_identify_object_as_address(classid, objid, objsubid))
      RETURNING *
  LOOP
    RAISE DEBUG 'modified_objects(): %', r;
  END LOOP;
END
```

Note `r_ddl` is declared but unused (this handler deliberately does *not* consult `pg_event_trigger_ddl_commands()`, per the comment explaining why — column/schema-rename cascades aren't fully enumerable that way, so it does a "brute-force check" over the *entire* `object`/`_object_oid` join on every DDL command).

**Effect on tables**: for every row in `_object_reference._object_oid` (joined 1:1 to `_object_reference.object` by `object_id`), it recomputes `pg_identify_object_as_address(classid, objid, objsubid)` from the row's **currently stored** `classid, objid, objsubid` and overwrites `object.object_type/object_names/object_args` with the result — unconditionally for *every* row whose current stored names/type differ from what that stored `(classid, objid, objsubid)` resolves to *right now*. `_object_oid` itself is never written by this trigger. There is no check comparing the *old* resolved names against the object's identity in any other way — the `WHERE` clause is purely "does re-deriving the address from the stored oid triple currently give something different from what's stored in `object`", which is exactly the mechanism probed by the empirical test below.

### 2. `_object_reference._etg_capture()` — handler for `zzz_object_reference_capture`

Function definition: lines 1378–1422, body lines 1382–1420. Full body, verbatim:

```sql
DECLARE
  c_group_id CONSTANT int := object_group_id FROM object_reference.capture__get_current();
      r record;
BEGIN

  IF c_group_id IS NOT NULL THEN -- Would be NULL if table is empty
    RAISE DEBUG E'\n\n*** START ***';
    BEGIN
      FOR r IN
        SELECT classid, objid, objsubid, command_tag, object_type, schema_name, object_identity, in_extension
            -- Have to manually exclude command field :/
          FROM pg_catalog.pg_event_trigger_ddl_commands()
      LOOP
        RAISE DEBUG 'ddl: %', row_to_json(r);
      END LOOP;
    END;

    FOR r IN SELECT 
    _object_reference._object_v__for_update(
          object_type::cat_tools.object_type
          , objid, objsubid
          , c_group_id
          , classid
        )
        , classid, objid, objsubid, command_tag, object_type, schema_name, object_identity, in_extension
      FROM pg_catalog.pg_event_trigger_ddl_commands()
      WHERE command_tag ~ '^CREATE' --'^(ALTER|CREATE)'
        AND NOT object_reference.unsupported(object_type::cat_tools.object_type)
        AND (schema_name IS NULL
            OR schema_name NOT LIKE 'pg_temp%' -- pg_my_temp_schema() doesn't seem worth it...
          )
    LOOP
      RAISE DEBUG 'registered %', row_to_json(r);
    END LOOP;
    RAISE DEBUG E'*** END ***\n\n';
  END IF;
END
```

**Firing condition, precisely**: the trigger itself fires unconditionally on every `ddl_command_end`, but the body's own logic is a no-op unless `object_reference.capture__get_current()` currently reports a non-null `object_group_id` (i.e. `object_reference.capture__start()` has been called and not yet stopped in this session/transaction — capture state lives in the temp table `pg_temp.__object_reference__ddl_capture`, per `capture__stop`/`_tg_capture_safety` around lines 1302–1377). When capturing is active, it further restricts to rows from `pg_event_trigger_ddl_commands()` where `command_tag ~ '^CREATE'` (so `ALTER ...` is explicitly excluded, despite the commented-out `'^(ALTER|CREATE)'` alternative), the `object_type` is not in `object_reference.unsupported(...)`, and `schema_name` is not `pg_temp%` (or is NULL).

**Effect on tables**: for each qualifying newly-created object, it calls `_object_reference._object_v__for_update(object_type, objid, objsubid, c_group_id, classid)` (lines 836–961), which: looks up/creates a matching row in `_object_reference.object` (INSERT with `ON CONFLICT ... DO NOTHING` retry loop if not found, lines 896–913), adds the object to the group via `object_reference.object_group__object__add(object_group_id, ...)` (line 917–918), and ensures a matching `_object_reference._object_oid(object_id, classid, objid, objsubid)` row exists — inserting one via `_object_reference._object_oid__add` if missing (line 940), or raising a hard error `'ids are out of sync for object_id %'` if a *different* `_object_oid` row already exists for that `object_id` (line 942–953, the `ids_exist` branch of the `CASE`). All of this is purely additive bookkeeping for newly-captured objects; it never updates or fixes up names/args of pre-existing rows.

### 3. `_object_reference._etg_drop()` — handler for `zzz__object_reference_drop`

Function definition: lines 1470–1515, body lines 1474–1513. Full body, verbatim:

```sql
DECLARE
  r_object_v _object_reference._object_v;
  r record;
BEGIN
  FOR r IN SELECT classid, objid, objsubid, object_type, schema_name, object_identity FROM pg_catalog.pg_event_trigger_dropped_objects() LOOP
    RAISE DEBUG 'dropped_objects(): %', r;
  END LOOP;

  -- Multiple objects might have been affected
  -- Could potentially be done with a writable CTE
  FOR r_object_v IN
    SELECT _object_v.*
      FROM pg_catalog.pg_event_trigger_dropped_objects() d
        JOIN _object_reference._object_v USING( classid, objid ) -- Intentionally ignore objsubid
      WHERE
        /*
         * If an object that contains subobjects is being removed, we need to
         * also remove all subobjects. In this case, we know d.objsubid = 0
         */
        d.objsubid = 0

        /*
         * Otherwise, only remove the appropriate suboject.
         */
        OR d.objsubid = _object_v.objsubid
  LOOP
    RAISE DEBUG 'deleting object %', r_object_v;
    -- TODO: trap FK violation error on groups and output something better
    DELETE FROM _object_reference.object WHERE object_id = r_object_v.object_id;
  END LOOP;

  /*
   * We know that a restore will never drop objects, so force _object_v to be
   * correct at this point. We can't do this before we delete based on the drop
   * though.
   */
  PERFORM object_reference.post_restore();
END
```

**Firing condition**: unconditional on `sql_drop` (all tags; no `WHEN` filter — the commented-out `WHEN tag IN (...)` is disabled).

**Effect on tables**: joins `pg_event_trigger_dropped_objects()` to the `_object_reference._object_v` view (which itself joins `object` to `_object_oid`) on `(classid, objid)` only (deliberately ignoring `objsubid` in the `JOIN ... USING`, per the comment), then keeps rows where either the whole object was dropped (`d.objsubid = 0`, so any subobject rows for that same `classid/objid` must also go) or the specific subobject that was dropped matches (`d.objsubid = _object_v.objsubid`). Matching rows are deleted from `_object_reference.object`; the `ON DELETE CASCADE` on `_object_oid.object_id` (line 182) cascades the corresponding `_object_oid` row deletion automatically. Finally it calls `object_reference.post_restore()` unconditionally to re-sync/validate `_object_v`-derived state after the deletions.

### Empirical verification of the `_etg_fix_identity` staleness claim

**Claim under test**: `_etg_fix_identity()` derives new names/args from the *stored* (possibly stale) `(classid, objid, objsubid)` for every row, unconditionally, on every DDL statement, with no guard against acting on a row already known to be stale.

Setup in scratch DB `oid_audit_r5et` (PG17, port 5417):

```
CREATE TABLE public.t1(a int);
CREATE TABLE public.t2(a int);
SELECT object_reference.object__getsert_w_group_id('table', 'public.t1');
```
```
 object_id | object_type | object_names | object_args 
-----------+-------------+--------------+-------------
         1 | table       | {public,t1}  | {}
(1 row)

 object_id | classid | objid | objsubid 
-----------+---------+-------+----------
         1 |    1259 | 30933 |        0
(1 row)
```

`t2`'s real oid: `30936` (via `SELECT 'public.t2'::regclass::oid`).

**Case A — stored oid resolves to a *different real* object than the `object` row's stored names claim.** Hand-crafted the mismatch by pointing `_object_oid.objid` at `t2` while `object.object_names` still says `{public,t1}`:

```
UPDATE _object_reference._object_oid SET objid = 30936 WHERE object_id = 1;
```

State before any further DDL (via `_object_v`, which computes `names_ok`/`ids_ok`/`ids_exist` per row):

```
 object_id | object_type | object_names | object_args | classid | objid | objsubid | names_ok | ids_ok | ids_exist 
-----------+-------------+--------------+-------------+---------+-------+----------+----------+--------+-----------
         1 | table       | {public,t1}  | {}          |    1259 | 30936 |        0 | t        | f      | t
```

(`names_ok=t` because `public.t1` itself is a perfectly valid address; `ids_ok=f` because the stored oid triple doesn't match what `public.t1`'s real address would be — this is the "row already known to be stale" state.)

Then fired an *ordinary, unrelated* DDL statement (`CREATE TABLE public.t3(a int);`) to trigger `ddl_command_end`, with `client_min_messages = debug` to observe the handler's internal `RAISE DEBUG`:

```
DEBUG:  EventTriggerInvoke 30918
DEBUG:  modified_objects(): (1,table,"{public,t2}",{},1,1259,30936,0)
DEBUG:  EventTriggerInvoke 30916
...
CREATE TABLE
```

State after:

```
 object_id | object_type | object_names | object_args 
-----------+-------------+--------------+-------------
         1 | table       | {public,t2}  | {}
```

**Result**: `_etg_fix_identity()` silently rewrote `object.object_names` from `{public,t1}` to `{public,t2}` — i.e., object_id 1, originally created to track `public.t1`, now silently and permanently refers to a completely different real table, `public.t2`, with no error, no warning (only a `DEBUG`-level log line, invisible at normal `client_min_messages`), and triggered by a DDL statement (`CREATE TABLE public.t3`) that has nothing to do with either `t1` or `t2`. This confirms the "silently writes something wrong" branch of the claim: the handler blindly trusts the stored `(classid, objid, objsubid)` and re-derives+overwrites names from it with no check that the stored triple still corresponds to what the `object` row is supposed to represent.

**Case B — stored oid resolves to *no real object at all*.** Reset `object.object_names` back to `{public,t1}` and instead pointed `_object_oid.objid` at a nonexistent oid:

```
UPDATE _object_reference.object SET object_names = '{public,t1}' WHERE object_id = 1;
UPDATE _object_reference._object_oid SET objid = 999999999 WHERE object_id = 1;
```

Fired another ordinary DDL statement (`CREATE TABLE public.t4(a int);`):

```
SET
DEBUG:  EventTriggerInvoke 30918
ERROR:  invalid input value for enum cat_tools.object_type: "relation"
CONTEXT:  PL/pgSQL function _object_reference._etg_fix_identity() line 24 at FOR over SELECT rows
```

Cause, confirmed directly:

```
SELECT * FROM pg_catalog.pg_identify_object_as_address(1259, 999999999, 0);
 type     | object_names | object_args 
----------+--------------+-------------
 relation |              | 
```

`"relation"` is not a member of `cat_tools.object_type` (confirmed via `enum_range(NULL::cat_tools.object_type)` — members include `table`, `index`, `sequence`, etc., but not the generic `relation`), so the `::cat_tools.object_type` cast inside `_etg_fix_identity`'s `UPDATE ... SET object_type = ...` raises an uncaught error. This aborted the entire triggering transaction: `CREATE TABLE public.t4` itself was rolled back (`\d public.t4` → `Did not find any relation named "public.t4"`), and the `object`/`_object_oid` rows were left unchanged (still the stale state from before).

**Verdict**: the claim is **confirmed**, and in fact the real behavior is worse than "silently writes something wrong" alone — depending on exactly *how* the stored `(classid, objid, objsubid)` has gone stale, `_etg_fix_identity()` either:
- (Case A, oid now belongs to a different live object of the same catalog) **silently corrupts** the `object` row to claim the identity of that unrelated object, with no error and only an invisible-by-default `DEBUG` log entry, or
- (Case B, oid no longer belongs to anything, e.g. a class-level oid that doesn't resolve to any live relation) **crashes with an uncaught `ERROR`** that aborts whatever unrelated DDL statement happened to fire the trigger, blocking *all* further DDL in that transaction/session until the underlying stale row is fixed.

In neither case does the handler no-op or guard itself — there is no code path in `_etg_fix_identity()` (lines 1429–1467) that checks `ids_ok`/`names_ok`/staleness before acting, nor any exception handling around the `pg_identify_object_as_address()` calls or the enum cast. It unconditionally trusts every stored `(classid, objid, objsubid)` in `_object_oid` on every single DDL command.

**Files/lines referenced**: `/root/git/object_reference/sql/object_reference.sql` — tables `object` (164–176) and `_object_oid` (181–191); views `_object_v` (242–255) and `_object_v__for_update` (256–270); `_object_reference._sanity` (193–240); `_object_reference._object_v__for_update` (835–962); `_etg_capture` (1378–1422); `_etg_fix_identity` (1425–1469); `_etg_drop` (1470–1515); decoy doc-comment functions `etg_raise__start` (1517–1532) and `etg_raise__drop` (1533–1569); the three real `CREATE EVENT TRIGGER` statements (1571–1576, 1577–1582, 1583–1588).

---

## Scenario (a): Logical `pg_dump`/`pg_restore` of a database with tracked objects

### Setup

Two dependency-relevant table definitions from `sql/object_reference.sql` govern this scenario:

`_object_reference.object` (lines 164–179), the **only** identity-bearing table that is `safe_dump()`-marked (i.e. registered via `pg_extension_config_dump`):

```sql
CREATE TABLE _object_reference.object(
  object_id       serial                  PRIMARY KEY
  , object_type   cat_tools.object_type   NOT NULL
--  , original_name text                    NOT NULL
  , object_names text[]                  NOT NULL
  , object_args  text[]                  NOT NULL
  , CONSTRAINT object__u_object_names__object_args UNIQUE( object_type, object_names, object_args )
  /* EXCLUDED CODE: TODO: this can't be a trigger because some objects won't exist when a dump is loaded
  , CONSTRAINT object__address_sanity
    -- pg_get_object_address will throw an error if anything is wrong, so the IS NOT NULL is mostly pointless
    CHECK( pg_catalog.pg_get_object_address(object_type::text, object_names, object_args) IS NOT NULL )
    */
);
SELECT __object_reference.safe_dump('_object_reference.object');
SELECT __object_reference.safe_dump('_object_reference.object_object_id_seq');
GRANT REFERENCES ON _object_reference.object TO object_reference__dependency;
```

`_object_reference._object_oid` (lines 181–191), the OID cache — **note there is no `safe_dump()` call for this table anywhere in the file**:

```sql
CREATE TABLE _object_reference._object_oid(
  object_id       int                     PRIMARY KEY REFERENCES _object_reference.object ON DELETE CASCADE ON UPDATE CASCADE
  , classid       oid                     NOT NULL
  /* EXCLUDED CODE: TODO: needs to be a trigger
    CONSTRAINT classid_must_match__object__address_classid
      CHECK( classid IS NOT DISTINCT FROM cat_tools.object__address_classid(object_type) )
    */
  , objid         oid                     NOT NULL
  , objsubid      int                     NOT NULL
  , CONSTRAINT object__u_classid__objid__objsubid UNIQUE( classid, objid, objsubid )
);
```

Every `safe_dump(` call site in the file (line 56 is the function def, 1601 its DROP; the invocation sites are):

```
177:SELECT __object_reference.safe_dump('_object_reference.object');
178:SELECT __object_reference.safe_dump('_object_reference.object_object_id_seq');
426:SELECT __object_reference.safe_dump('_object_reference._sentry_mv');
538:SELECT __object_reference.safe_dump('_object_reference.object_group');
545:SELECT __object_reference.safe_dump('_object_reference.object_group__object');
```

`_object_reference._object_oid` is **not** on that list — its rows are never included as extension-config data in a `pg_dump`.

The self-healing mechanism (lines 416–426):

```sql
SELECT __object_reference.create_function(
  '_object_reference._repair'
  , ''
  , 'bigint SECURITY DEFINER LANGUAGE sql'
  , 'SELECT count(*) AS objects FROM _object_reference.object, _object_reference._object_oid__add(object_id)'
  , 'Ensures all object references are correct after a restore.'
  , 'object_reference__usage'
);

CREATE MATERIALIZED VIEW _object_reference._sentry_mv AS SELECT _object_reference._repair();
SELECT __object_reference.safe_dump('_object_reference._sentry_mv');
```

`_repair()` cross-joins every row of `_object_reference.object` against `_object_reference._object_oid__add(object_id)` (defined lines 272–318), which resolves the object's current OID via `pg_get_object_address()` and `INSERT`s it into `_object_oid`.

`object__getsert` signature actually used — the plain wrapper is at lines 1168–1189/1190–1203:

```sql
SELECT __object_reference.create_function(
  'object_reference.object__getsert'
  , $args$
  object_type   cat_tools.object_type
  , object_name text
  , secondary text DEFAULT NULL
  , object_group_name _object_reference.object_group.object_group_name%TYPE DEFAULT NULL
  , loose boolean DEFAULT false
$args$
  , 'int LANGUAGE sql'
  , $body$
SELECT object_reference.object__getsert_w_group_id(
  $1, $2, $3
  , CASE WHEN object_group_name IS NOT NULL THEN
      (object_reference.object_group__get($4)).object_group_id
    END
  , $5
)
$body$
  , 'Return a object_id for an object. Allows specifying a object group name to add the object to. See also object__getsert_w_group_id().'
  , 'object_reference__usage'
);
SELECT __object_reference.create_function(
  'object_reference.object__getsert'
  , $args$
  object_type text
  , object_name text
  , secondary text DEFAULT NULL
  , object_group_name _object_reference.object_group.object_group_name%TYPE DEFAULT NULL
  , loose boolean DEFAULT false
$args$
  , 'int LANGUAGE sql'
  , $$SELECT object_reference.object__getsert( lower($1)::cat_tools.object_type, $2, $3, $4, $5 )$$
  , 'Return a object_id for an object. Allows specifying a object group name to add the object to. See also object__getsert_w_group_id().'
  , 'object_reference__usage'
);
```

i.e. `object_reference.object__getsert(object_type text_or_cat_tools.object_type, object_name text, secondary text DEFAULT NULL, object_group_name text DEFAULT NULL, loose boolean DEFAULT false) RETURNS int`.

### 1. Built objects and ran `object__getsert()`

In scratch db `oid_audit_r6a`:

```sql
CREATE TABLE public.widgets(id serial primary key, name text);
CREATE FUNCTION public.widgets_touch() RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN RETURN NEW; END
$f$;
CREATE TRIGGER widgets_touch_trg BEFORE INSERT ON public.widgets
  FOR EACH ROW EXECUTE FUNCTION public.widgets_touch();
CREATE VIEW public.widgets_v AS SELECT * FROM public.widgets;
```

```sql
SELECT object_reference.object__getsert('table', 'public.widgets');        -- 1
SELECT object_reference.object__getsert('view', 'public.widgets_v');       -- 2
SELECT object_reference.object__getsert('trigger', 'public.widgets', 'widgets_touch_trg'); -- 3
SELECT object_reference.object__getsert('sequence', 'public.widgets_id_seq'); -- 4
SELECT object_reference.object__getsert('function', 'public.widgets_touch', ''); -- 5
```

(Note: `secondary => '()'` for the function errored with a syntax error inside `cat_tools`'s temp-parse helper; `secondary => ''` worked. Unrelated to object_reference itself.)

Resulting table contents (`\x on`):

```
-[ RECORD 1 ]+-----------------------------------
object_id    | 1
object_type  | table
object_names | {public,widgets}
object_args  | {}
-[ RECORD 2 ]+-----------------------------------
object_id    | 2
object_type  | view
object_names | {public,widgets_v}
object_args  | {}
-[ RECORD 3 ]+-----------------------------------
object_id    | 3
object_type  | trigger
object_names | {public,widgets,widgets_touch_trg}
object_args  | {}
-[ RECORD 4 ]+-----------------------------------
object_id    | 4
object_type  | sequence
object_names | {public,widgets_id_seq}
object_args  | {}
-[ RECORD 5 ]+-----------------------------------
object_id    | 5
object_type  | function
object_names | {public,widgets_touch}
object_args  | {}
```

```
[1] object_id=1 classid=1259 objid=32147 objsubid=0
[2] object_id=2 classid=1259 objid=32157 objsubid=0
[3] object_id=3 classid=2620 objid=32156 objsubid=0
[4] object_id=4 classid=1259 objid=32146 objsubid=0
[5] object_id=5 classid=1255 objid=32155 objsubid=0
```

Both tables fully populated and 1:1, as expected pre-dump.

### 2. `pg_dump -Fc` + `pg_restore --list`

```
$ pg_dump -Fc -f dump.file oid_audit_r6a   # exit 0
$ pg_restore --list dump.file
...
8; 2615 31563 SCHEMA - cat_tools root
2; 3079 31564 EXTENSION - cat_tools 
3652; 0 0 COMMENT - EXTENSION cat_tools 
12; 2615 31562 SCHEMA - object_reference root
3; 3079 31984 EXTENSION - object_reference 
3653; 0 0 COMMENT - EXTENSION object_reference 
... (ACL entries for cat_tools types) ...
290; 1255 32155 FUNCTION public widgets_touch() root
247; 1259 32147 TABLE public widgets root
246; 1259 32146 SEQUENCE public widgets_id_seq root
3668; 0 0 SEQUENCE OWNED BY public widgets_id_seq root
248; 1259 32157 VIEW public widgets_v root
3474; 2604 32150 DEFAULT public widgets id root
3467; 0 31993 TABLE DATA _object_reference object root
3470; 0 32057 TABLE DATA _object_reference object_group root
3471; 0 32064 TABLE DATA _object_reference object_group__object root
3645; 0 32147 TABLE DATA public widgets root
3669; 0 0 SEQUENCE SET _object_reference object_object_id_seq root
3670; 0 0 SEQUENCE SET public widgets_id_seq root
3485; 2606 32154 CONSTRAINT public widgets widgets_pkey root
3486; 2620 32156 TRIGGER public widgets widgets_touch_trg root
2251; 826 31566 DEFAULT ACL cat_tools DEFAULT PRIVILEGES FOR TYPES root
3469; 0 32033 MATERIALIZED VIEW DATA _object_reference _sentry_mv root
```

Key observations from the TOC, all independently verified against the actual generated SQL (`pg_restore -f full_restore.sql dump.file`):

- **No `CREATE EVENT TRIGGER` entries appear anywhere.** The three event triggers (`zzz__object_reference_drop`, `zzz_object_reference__fix_identity`, `zzz_object_reference_capture`, defined at lines 1571–1588) are extension member objects — they are recreated implicitly by re-running the whole install script via `CREATE EXTENSION IF NOT EXISTS object_reference WITH SCHEMA object_reference;`, not dumped individually.
- **`_object_reference.object` gets an explicit `TABLE DATA` / `COPY` entry** (dumpId 3467) containing the 5 rows verbatim:
  ```
  COPY _object_reference.object (object_id, object_type, object_names, object_args) FROM stdin;
  1	table	{public,widgets}	{}
  2	view	{public,widgets_v}	{}
  3	trigger	{public,widgets,widgets_touch_trg}	{}
  4	sequence	{public,widgets_id_seq}	{}
  5	function	{public,widgets_touch}	{}
  \.
  ```
- **`_object_reference._object_oid` has no entry at all** — confirmed absent from both `--list` output and the full generated SQL text. It is not extension-config-marked, so its 5 rows of OID data are simply never dumped.
- **`_sentry_mv`'s "data" entry is not a `COPY`, it is a `REFRESH MATERIALIZED VIEW` statement**, placed as the very *last* statement in the entire dump:
  ```sql
  REFRESH MATERIALIZED VIEW _object_reference._sentry_mv;
  ```
- This `REFRESH` entry sorts *after* `CONSTRAINT widgets_pkey`, `TRIGGER widgets_touch_trg`, and `DEFAULT ACL` in the TOC ordering, despite superficially being a "data" (dumpId prefix `0`) entry — shown below to be in the **post-data** section, not the data section.
- `CREATE EXTENSION` for the dependency `cat_tools` is emitted, and ordered, **before** `CREATE EXTENSION object_reference` — the dependency ordering (`CASCADE`'s effect) round-trips correctly through dump/restore.

### 3. Section-by-section restore into a fresh database

```
$ psql -d oid_audit_r6b -c "\dx"
 Name | Version | Schema | Description
------+---------+--------+-------------
 plpgsql | 1.0 | pg_catalog | PL/pgSQL procedural language
```

**After `--section=pre-data`:**

```
$ pg_restore -d oid_audit_r6b --section=pre-data dump.file   # exit 0
$ psql -d oid_audit_r6b -c "\dx" -c "SELECT count(*) FROM _object_reference.object;" \
   -c "SELECT count(*) FROM _object_reference._object_oid;" -c "SELECT * FROM _object_reference._sentry_mv;"
 Name             | Version | Schema           | Description
cat_tools         | 0.3.0   | cat_tools        | Tools for intorfacing with the catalog
object_reference  | stable  | object_reference | Provides reference IDs for database objects
plpgsql           | 1.0     | pg_catalog       | PL/pgSQL procedural language

 count
-------
     0
(1 row)
 count
-------
     0
(1 row)
 _repair
---------
       0
(1 row)
```

Both extensions get re-created from scratch; `object` and `_object_oid` are empty; `_sentry_mv` was materialized once, at `CREATE EXTENSION` time, against an empty `object` table, so it caches `_repair = 0`.

**After `--section=data`:**

```
$ pg_restore -d oid_audit_r6b --section=data dump.file   # exit 0
$ psql -d oid_audit_r6b -x -c "SELECT * FROM _object_reference.object ORDER BY object_id;" \
   -c "SELECT count(*) FROM _object_reference._object_oid;" -c "SELECT * FROM _object_reference._sentry_mv;"
-[ RECORD 1 ]+-----------------------------------
object_id    | 1
object_type  | table
object_names | {public,widgets}
object_args  | {}
... (rows 2-5 identical to what was dumped) ...

count
-------
     0

_repair
---------
       0
```

`object`'s 5 rows are restored verbatim via `COPY`; `_object_oid` is still 0 rows; `_sentry_mv` still shows the stale cached `0` — the data section by itself does **not** repair the OID cache.

**After `--section=post-data`:**

```
$ pg_restore -d oid_audit_r6b --section=post-data -v dump.file
pg_restore: connecting to database for restore
pg_restore: creating CONSTRAINT "public.widgets widgets_pkey"
pg_restore: creating TRIGGER "public.widgets widgets_touch_trg"
pg_restore: creating DEFAULT ACL "cat_tools.DEFAULT PRIVILEGES FOR TYPES"
pg_restore: creating MATERIALIZED VIEW DATA "_object_reference._sentry_mv"
```

This confirms `_sentry_mv`'s `REFRESH` runs in **post-data**, last, after the user table's constraint and trigger have been (re)created (so all catalog OIDs for the tracked objects are final by the time `_repair()` runs).

```
$ psql -d oid_audit_r6b -x -c "SELECT * FROM _object_reference._object_oid ORDER BY object_id;" \
   -c "SELECT * FROM _object_reference._sentry_mv;"
[1] object_id=1 classid=1259 objid=33976 objsubid=0
[2] object_id=2 classid=1259 objid=33982 objsubid=0
[3] object_id=3 classid=2620 objid=34578 objsubid=0
[4] object_id=4 classid=1259 objid=33981 objsubid=0
[5] object_id=5 classid=1255 objid=33975 objsubid=0

_repair
---------
       5
```

`_object_oid` now has 5 rows with **freshly-resolved OIDs** (different from the source db's OIDs, e.g. `widgets`'s table OID went from 32147 → 33976, as expected for objects re-created in a different database), and `_sentry_mv` reports `_repair = 5`, meaning `_repair()`'s cross join against all 5 `object` rows succeeded and inserted 5 new `_object_oid` rows.

Full consistency check via `_object_reference._object_v` (lines 242–255, joins `object` + `_object_oid` + `_sanity()`):

```
$ psql -d oid_audit_r6b -x -c "SELECT * FROM _object_reference._object_v ORDER BY object_id;"
-[ RECORD 1 ]  object_id=1 ... names_ok=t ids_ok=t ids_exist=t
-[ RECORD 2 ]  object_id=2 ... names_ok=t ids_ok=t ids_exist=t
-[ RECORD 3 ]  object_id=3 ... names_ok=t ids_ok=t ids_exist=t
-[ RECORD 4 ]  object_id=4 ... names_ok=t ids_ok=t ids_exist=t
-[ RECORD 5 ]  object_id=5 ... names_ok=t ids_ok=t ids_exist=t
```

All 5 rows: `names_ok = t`, `ids_ok = t`, `ids_exist = t`.

A one-shot (non-sectioned) `pg_restore -d oid_audit_r6c dump.file` into a third fresh database produced the identical end state:

```
$ pg_restore -d oid_audit_r6c dump.file   # exit 0
$ psql -d oid_audit_r6c -c "SELECT count(*) object_rows FROM _object_reference.object;" \
   -c "SELECT count(*) oid_rows FROM _object_reference._object_oid;" \
   -c "SELECT bool_and(names_ok) all_names_ok, bool_and(ids_ok) all_ids_ok FROM _object_reference._object_v;"
 object_rows
-------------
           5
 oid_rows
----------
        5
 all_names_ok | all_ids_ok
--------------+------------
 t            | t
```

### 4. Verdict

**Yes, this scenario works correctly today**, for the objects tested (table, view, trigger, sequence, function). At the end of restore, `_object_oid` is fully and correctly populated — every row has `ids_exist = true`, `ids_ok = true`, `names_ok = true`.

What specifically causes this:

- The restored `_object_reference.object` `TABLE DATA` (the `COPY` in the data section) by itself is **not** sufficient — after the data section alone, `_object_oid` is still completely empty (verified above: `count = 0` after `--section=data`).
- **`_object_reference._sentry_mv`'s `REFRESH MATERIALIZED VIEW` statement is what actually does the repair**, by invoking `_object_reference._repair()`, which cross-joins the (now fully-populated-by-COPY) `object` table against `_object_reference._object_oid__add(object_id)` for each row, resolving each object's current OID via `pg_get_object_address()` and inserting it into the (previously empty) `_object_oid` table.
- This `REFRESH` is placed by `pg_dump`/`pg_restore` in the **post-data** section and, critically, sorts to the very *end* of post-data (after the ordinary user-object constraint/trigger/ACL entries) — so by the time it runs, every referenced catalog object (including ones like the `widgets_touch_trg` trigger, whose OID is only assigned in post-data when the `CREATE TRIGGER` re-runs) already exists with its final, restored-database OID. That ordering is exactly what makes the `pg_get_object_address()` lookups inside `_repair()` succeed for every tracked object type used here, including ones (triggers, table constraints) whose defining DDL is itself deferred to post-data.
- The three event triggers play essentially no role in this particular scenario: they aren't dumped as DDL (they come back for free via `CREATE EXTENSION`), and `_etg_capture`/`_etg_fix_identity` are no-ops during restore in this test because no "capture" was active (`object_reference.capture__get_current()` returns NULL) and `_object_oid` was still empty when the post-data `CREATE TRIGGER` fired (so `_etg_fix_identity`'s `UPDATE ... FROM _object_reference._object_oid oo` joined zero rows).

---

## Scenario (b): real `pg_upgrade` PG12 → PG17, reproduced end-to-end

### Setup: one tracked instance of each object kind, PG12

```
CREATE EXTENSION object_reference CASCADE;   -- installs cat_tools, count_nulls too
CREATE SCHEMA r7;
CREATE TABLE r7.tbl1(id int PRIMARY KEY, val text DEFAULT 'defaultval', CONSTRAINT tbl1_val_check CHECK (val <> ''));
CREATE INDEX tbl1_val_idx ON r7.tbl1(val);
CREATE SEQUENCE r7.seq1;
CREATE VIEW r7.view1 AS SELECT * FROM r7.tbl1;
CREATE MATERIALIZED VIEW r7.mv1 AS SELECT * FROM r7.tbl1;
CREATE TYPE r7.color_t AS ENUM('red','green','blue');
CREATE FUNCTION r7.func1() RETURNS int LANGUAGE sql AS $$SELECT 1$$;
CREATE FUNCTION r7.color_t_to_text(r7.color_t) RETURNS text LANGUAGE sql AS $$SELECT $1::text$$;
CREATE CAST (r7.color_t AS text) WITH FUNCTION r7.color_t_to_text(r7.color_t) AS ASSIGNMENT;
CREATE FUNCTION r7.tbl1_trig_fn() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RETURN NEW; END$$;
CREATE TRIGGER tbl1_trig1 BEFORE INSERT ON r7.tbl1 FOR EACH ROW EXECUTE FUNCTION r7.tbl1_trig_fn();
```

`object_reference.object__getsert()` signature used, per `sql/object_reference.sql:1168-1175`:
```sql
object_reference.object__getsert(
  object_type   cat_tools.object_type
  , object_name text
  , secondary text DEFAULT NULL
  , object_group_name _object_reference.object_group.object_group_name%TYPE DEFAULT NULL
  , loose boolean DEFAULT false
)
```
(it wraps `object__getsert_w_group_id`, which resolves `object_name`/`secondary` to an OID per catalog per the `CASE c_catalog` block at lines 985–1155, then calls `_object_reference._object_v__for_update(object_type, v_objid, v_subid, object_group_id)` at line 1161.)

Actual call output (`object_id` returned by each call), plus the resulting `_object_reference._object_v` rows (`sql/object_reference.sql:242-255`), plus **independent** ground-truth catalog queries (not via the extension) — all three agree exactly, pre-upgrade:

```
 kind        | object_id | classid_name  | objid | objsubid | independent-oid-query result
 table             | 1 | pg_class      | 16978 | 0 | 'r7.tbl1'::regclass::oid = 16978
 index             | 2 | pg_class      | 16988 | 0 | 'r7.tbl1_val_idx'::regclass::oid = 16988
 sequence          | 3 | pg_class      | 16989 | 0 | 'r7.seq1'::regclass::oid = 16989
 view              | 4 | pg_class      | 16991 | 0 | 'r7.view1'::regclass::oid = 16991
 materialized view | 5 | pg_class      | 16995 | 0 | 'r7.mv1'::regclass::oid = 16995
 table column      | 6 | pg_class      | 16978 | 2 | pg_attribute.attnum for tbl1.val = 2
 type              | 7 | pg_type       | 17003 | 0 | 'r7.color_t'::regtype::oid = 17003
 table constraint  | 8 | pg_constraint | 16982 | 0 | pg_constraint.oid (tbl1_val_check) = 16982
 function          | 9 | pg_proc       | 17009 | 0 | pg_proc.oid (r7.func1) = 17009
 cast              |10 | pg_cast       | 17011 | 0 | pg_cast.oid (color_t→text) = 17011
 default value     |11 | pg_attrdef    | 16981 | 0 | pg_attrdef.oid (tbl1.val default) = 16981
 trigger           |12 | pg_trigger    | 17013 | 0 | pg_trigger.oid (tbl1_trig1) = 17013
```

### pg_upgrade run

`--check` passed cleanly first ("*Clusters are compatible*"). The **real** (non-`--check`) run failed the first time:

```
Restoring database schemas in the new cluster
*failure*
...
pg_restore: creating MATERIALIZED VIEW DATA "_object_reference._sentry_mv"
pg_restore: from TOC entry 3156; 0 16861 MATERIALIZED VIEW DATA _sentry_mv postgres
pg_restore: error: could not execute query: ERROR:  pg_class heap OID value not set when in binary upgrade mode
Command was: REFRESH MATERIALIZED VIEW "_object_reference"."_sentry_mv";
```

**Diagnosis (confirmed, not fabricated):** `object_reference` defines `_object_reference._sentry_mv` as a *populated* materialized view (`sql/object_reference.sql:425`: `CREATE MATERIALIZED VIEW _object_reference._sentry_mv AS SELECT _object_reference._repair();`, no `WITH NO DATA`), and marks it via `pg_extension_config_dump()` (see "Config-dump marking" above). In `pg_dump --binary-upgrade` mode (what `pg_upgrade` uses internally), `pg_dump`'s `makeTableDataInfo()` unconditionally routes any extconfig-marked relation with `relkind == RELKIND_MATVIEW` to a `DO_REFRESH_MATVIEW` TOC entry, i.e. it emits a plain `REFRESH MATERIALIZED VIEW ...;` as that object's "data" — and that entry gets no corresponding `binary_upgrade_set_next_heap_pg_class_oid()` call, unlike a normal `CREATE`. `REFRESH` internally builds a new heap to swap in, and building a new heap while `binary_upgrade` mode is active without a pre-set OID is exactly what PostgreSQL's `pg_class heap OID value not set when in binary upgrade mode` guards against.

**This is *not* a generic populated-matview-vs-binary-upgrade limitation — it is specific to `pg_extension_config_dump()` being called on a matview, which is outside that function's documented scope** (PostgreSQL's `extend.sgml` "Extension Configuration Tables" section covers only "a table or a sequence"; nothing stops a script from passing a matview's regclass, but `pg_dump` has no binary-upgrade-safe code path for that case). An *ordinary*, non-extconfig-marked populated matview survives binary `pg_upgrade` fine: `pg_dump.c`'s per-table binary-upgrade block has an explicit special case for `RELKIND_MATVIEW` that physically transfers the matview's heap file (like any other relation) and restores its populated status with a direct `UPDATE pg_catalog.pg_class SET relispopulated = 't' WHERE oid = ...` — no `REFRESH`, no crash. A real PG12→PG17 `pg_upgrade` against a scratch database containing only a plain populated matview (`object_reference` not installed at all) confirms this: full success, zero errors, with the matview's OID and `relispopulated` unchanged (`16391`/`t` before and after) and its data intact. So our own tracked `r7.mv1` (populated, but *not* extconfig-marked) never got exercised in the run below only because the dump aborted at `_sentry_mv` first (it sorts/orders earlier in the TOC — see log line order below) — but given this mechanism, `mv1` on its own would not have failed. (This correction was independently reached and posted to issue #24 a few days before this document was written; it is restated here in full rather than only cross-referenced, since documenting current behavior accurately is this document's whole purpose.)

**Workaround (explicitly labeled as such, not normal behavior):** restarted PG12, ran `REFRESH MATERIALIZED VIEW _object_reference._sentry_mv WITH NO DATA;` and `REFRESH MATERIALIZED VIEW r7.mv1 WITH NO DATA;` (confirmed via `pg_class.oid`/`relispopulated` that this changes nothing about their catalog OIDs — `_sentry_mv` stayed oid 16861, `mv1` stayed oid 16995, just `relispopulated` flips to `f`), stopped PG12 cleanly, re-initdb'd the new17 datadir (as instructed by pg_upgrade's own warning after a failed run), and reran. This time:

```
Restoring database schemas in the new cluster                 ok
Copying user relation files                                   ok
Setting next OID for new cluster                               ok
Sync data directory to disk                                    ok
Creating script to delete old cluster                          ok
Checking for extension updates                                 ok

Upgrade Complete
----------------
```

Full success. (Grep of the failed run's log confirmed `_sentry_mv`'s "MATERIALIZED VIEW DATA" entry appears, at line 453/455 of the pg_upgrade dump log, **before** `r7.mv1`'s own CREATE (line 286) ever got a matching data entry — the abort happened before `mv1`'s data step was even reached. Per the corrected diagnosis above, and confirmed independently by the plain-matview-only upgrade test, `mv1` would *not* have failed on its own: only the `pg_extension_config_dump()`-marked `_sentry_mv` hits the crash, not ordinary populated matviews in general.)

### Per-object-kind OID-preservation table (real numbers, this run)

Started PG17 on the upgraded cluster and, for each object kind, compared (1) the fresh fresh catalog-OID query on PG17, (2) the `_object_reference._object_v` row's stored `classid/objid/objsubid` (untouched since before the upgrade), and (3) `ids_ok`/`names_ok` as computed live by `_object_reference._sanity()` (`sql/object_reference.sql:193-240`):

| kind | pre-upgrade OID | post-upgrade fresh catalog OID | stored `_object_oid` value | OID preserved? | `names_ok` | `ids_ok` |
|---|---|---|---|---|---|---|
| table | 16978 | **16978** | 16978 | **yes** | t | t |
| index | 16988 | **16988** | 16988 | **yes** | t | t |
| sequence | 16989 | **16989** | 16989 | **yes** | t | t |
| view | 16991 | **16991** | 16991 | **yes** | t | t |
| materialized view | 16995 | **16995** | 16995 | **yes** | t | t |
| table column (attnum) | 2 | **2** | (attrelid 16978, subid 2) | **yes** | t | t |
| type (enum) | 17003 | **17003** | 17003 | **yes** | t | t |
| table constraint | 16982 | **16545** | 16982 (stale) | **no** | t | f |
| function | 17009 | **16530** | 17009 (stale) | **no** | t | f |
| cast | 17011 | **16408** | 17011 (stale) | **no** | t | f |
| default value | 16981 | **16544** | 16981 (stale) | **no** | t | f |
| trigger | 17013 | **16559** | 17013 (stale) | **no** | t | f |

Verbatim `_object_v` query on the upgraded PG17 cluster:
```
 object_id |    object_type    |       object_names       |    object_args    | classid | classid_name  | objid | objsubid | names_ok | ids_ok | ids_exist
-----------+-------------------+--------------------------+-------------------+---------+---------------+-------+----------+----------+--------+-----------
         1 | table             | {r7,tbl1}                | {}                |    1259 | pg_class      | 16978 |        0 | t        | t      | t
         2 | index             | {r7,tbl1_val_idx}        | {}                |    1259 | pg_class      | 16988 |        0 | t        | t      | t
         3 | sequence          | {r7,seq1}                | {}                |    1259 | pg_class      | 16989 |        0 | t        | t      | t
         4 | view              | {r7,view1}               | {}                |    1259 | pg_class      | 16991 |        0 | t        | t      | t
         5 | materialized view | {r7,mv1}                 | {}                |    1259 | pg_class      | 16995 |        0 | t        | t      | t
         6 | table column      | {r7,tbl1,val}            | {}                |    1259 | pg_class      | 16978 |        2 | t        | t      | t
         7 | type              | {r7.color_t}             | {}                |    1247 | pg_type       | 17003 |        0 | t        | t      | t
         8 | table constraint  | {r7,tbl1,tbl1_val_check} | {}                |    2606 | pg_constraint | 16982 |        0 | t        | f      | t
         9 | function          | {r7,func1}               | {}                |    1255 | pg_proc       | 17009 |        0 | t        | f      | t
        10 | cast              | {r7.color_t}             | {pg_catalog.text} |    2605 | pg_cast       | 17011 |        0 | t        | f      | t
        11 | default value     | {r7,tbl1,val}            | {}                |    2604 | pg_attrdef    | 16981 |        0 | t        | f      | t
        12 | trigger           | {r7,tbl1,tbl1_trig1}     | {}                |    2620 | pg_trigger    | 17013 |        0 | t        | f      | t
```

**Plain statement, for this run:** every `pg_class`-backed object (table, index, sequence, view, materialized view) plus the `pg_attribute`-column-subid and the `pg_type`-backed enum type kept their **exact** OIDs across the PG12→PG17 upgrade. Every object backed by `pg_constraint`, `pg_proc`, `pg_cast`, `pg_attrdef`, or `pg_trigger` got a **brand-new, unrelated** OID; the *old* OIDs it used to occupy are now vacant in the new cluster (see below), not reassigned to anything specific.

Confirmed via direct probes at the exact stored (classid, objid) on PG17 — nothing exists at any of those OIDs any more (0 rows each), which is why `pg_identify_object_as_address()` falls back to a bare catalog-level type name rather than the specific object subtype:

```
 object_id |   object_type    | classid | objid | objsubid |  current_identity
-----------+------------------+---------+-------+----------+---------------------
         8 | table constraint |    2606 | 16982 |        0 | (constraint,,)
         9 | function         |    1255 | 17009 |        0 | (routine,,)
        10 | cast             |    2605 | 17011 |        0 | (cast,,)
        11 | default value    |    2604 | 16981 |        0 | ("default value",,)
        12 | trigger          |    2620 | 17013 |        0 | (trigger,,)
```
(each corresponding raw `SELECT ... WHERE oid = <stale-oid>` against `pg_constraint`/`pg_proc`/`pg_cast`/`pg_attrdef`/`pg_trigger` returned 0 rows.)

### Finding 1: first `object__getsert()` lookup of a stale object on the new cluster

Reading `_object_reference._object_v__for_update()` (`sql/object_reference.sql:835-960`): after re-resolving the object by *name* (which still works — `names_ok = true`, since the underlying object still exists under the same name, just a new OID) it hits this `CASE` (lines 921-956):
```sql
CASE
  WHEN r_object_v.ids_ok THEN
    RETURN r_object_v;
  WHEN NOT r_object_v.ids_exist THEN
    ... -- create IDs record
  WHEN r_object_v.ids_exist THEN
    RAISE 'ids are out of sync for object_id %', r_object_v.object_id
      USING DETAIL = ... , HINT = 'this shoud not happen if event trigger "zzz_object_reference_end" is working'
    ;
  ELSE
    RAISE 'unknown condition';
END CASE;
```
For a stale object, `ids_ok = false` and `ids_exist = true`, so it falls to the third branch. Reproduced for real, for `table constraint`, `cast`, `default value`, and `trigger`:

```sql
SELECT object_reference.object__getsert('trigger'::cat_tools.object_type, 'r7.tbl1', 'tbl1_trig1');
```
```
ERROR:  ids are out of sync for object_id 12
DETAIL:  _object_reference._object_v = '{"object_id":12,
 "object_type":"trigger",
 "object_names":["r7","tbl1","tbl1_trig1"],
 "object_args":[],
 "classid":"2620",
 "objid":"17013",
 "objsubid":0,
 "names_ok":true,
 "ids_ok":false,
 "ids_exist":true}',
    arguments ('trigger', 16559, 0, )
HINT:  this shoud not happen if event trigger "zzz_object_reference_end" is working
CONTEXT:  PL/pgSQL function _object_reference._object_v__for_update(cat_tools.object_type,oid,integer,integer,regclass) line 99 at RAISE
```
Identical shape of error (different object_id/detail) for `table constraint` (object_id 8), `cast` (object_id 10), and `default value` (object_id 11).

**Exception — `function`:** calling `object__getsert('function', 'r7.func1', '')` does **not** reach this error at all. It fails earlier, with a completely different message:
```
ERROR:  invalid input value for enum cat_tools.object_type: "constraint"
CONTEXT:  PL/pgSQL function _object_reference._etg_fix_identity() line 24 at FOR over SELECT rows
SQL statement "CREATE FUNCTION pg_temp.cat_tools__function__arg_types__temp_function(...) RETURNS void LANGUAGE plpgsql AS 'BEGIN RETURN; END'"
PL/pgSQL function _cat_tools.function__arg_to_regprocedure(text,text,text) line 38 at EXECUTE
PL/pgSQL function cat_tools.routine__parse_arg_types(text) line 3 during statement block local variable initialization
PL/pgSQL function object_reference.object__getsert_w_group_id(cat_tools.object_type,text,text,integer,boolean) line 21 at assignment
```
Reason (traced, confirmed): resolving a `function` object goes through `cat_tools.regprocedure()` (`cat_tools--0.3.0.sql:748-765`) → `cat_tools.routine__parse_arg_types()`, which internally issues its own nested `CREATE FUNCTION pg_temp....` to parse the argument-type string (`cat_tools--0.3.0.sql:628-639`). That nested `CREATE FUNCTION` is itself a DDL command, so its `ddl_command_end` fires `_object_reference._etg_fix_identity()` (`sql/object_reference.sql:1425-1469`, event trigger registered unconditionally at line 1577-1581 — `ON ddl_command_end`, no `WHEN` filter). `_etg_fix_identity()` does:
```sql
UPDATE _object_reference.object
  SET object_type = (pg_catalog.pg_identify_object_as_address(classid, objid, objsubid)).type::cat_tools.object_type
      , ...
  FROM _object_reference._object_oid oo
  WHERE oo.object_id = object.object_id
    AND (object_type::text, object_names, object_args) IS DISTINCT FROM (pg_catalog.pg_identify_object_as_address(classid, objid, objsubid))
```
For the stale `table constraint` row (stored `classid=2606, objid=16982`, which no longer exists in `pg_constraint`), `pg_identify_object_as_address()` returns the generic catalog-level fallback type `"constraint"` (`(constraint,,)`) — which is **not** a valid label of the `cat_tools.object_type` enum (only `"table constraint"`/`"domain constraint"` are), so the `::cat_tools.object_type` cast fails. This aborts the whole nested `CREATE FUNCTION` command and, with it, the entire outer `object__getsert()` call — before the "ids are out of sync" branch is ever reached. (The UPDATE is atomic, so no partial state change results; re-checking `_object_v` afterward showed it unchanged.)

So the true, complete answer is kind-dependent: `table constraint`, `cast`, `default value`, and `trigger` lookups hit the intended `'ids are out of sync for object_id %'` RAISE exactly as the code implies; a `function` lookup instead hits an *earlier*, unrelated bug (`_etg_fix_identity()`'s enum cast on the orphaned constraint row) triggered as a side effect of function-argument parsing's internal temp-function trick — a real, reproduced difference in behavior between object kinds, not something inferable from `object__getsert()`'s own code alone.

### Finding 2: first observable symptom of *any* `DROP` statement, post-upgrade, with stale rows present

Traced `_object_reference._etg_drop()` (`sql/object_reference.sql:1470-1515`, registered `ON sql_drop` at line 1571-1575, no `WHEN` filter): it loops over dropped objects joined to `_object_reference._object_v`, deletes any matching tracked row, then unconditionally calls `PERFORM object_reference.post_restore();` (line 1511) — regardless of whether anything relevant was actually dropped. `post_restore()` (line 406-413) is `SELECT _object_reference.fix_refs(false)`.

`_object_reference.fix_refs(warning_only boolean)` (`sql/object_reference.sql:323-405`) loops over **every** row of `_object_v` and, for a row with `names_ok = true`, `ids_ok = false`, `ids_exist = true` (exactly the state of all 5 stale rows) and `warning_only = false`, executes (line 393):
```sql
RAISE 'extraneous ID information for object_id %', r_object.object_id
```
This is a **bug independent of pg_upgrade**: the loop variable declared at line 329 is `r_object_v`, not `r_object` — `r_object` is never declared in this function's scope (the same typo also appears in the `warning_only` branch at line 386). Reproduced by issuing any ordinary `DROP` on an existing, *non-stale* object:
```sql
DROP SEQUENCE r7.seq1;
```
```
ERROR:  missing FROM-clause entry for table "r_object"
LINE 1: r_object.object_id
        ^
QUERY:  r_object.object_id
CONTEXT:  PL/pgSQL function _object_reference.fix_refs(boolean) line 67 at RAISE
SQL function "post_restore" statement 1
SQL statement "SELECT object_reference.post_restore()"
PL/pgSQL function _object_reference._etg_drop() line 38 at PERFORM
```
And crucially the `DROP` itself is **rolled back** by this failure — verified: `SELECT 'r7.seq1'::regclass;` still resolved after the failed `DROP`, i.e. `r7.seq1` was **not** actually dropped, because the exception inside the `sql_drop` event trigger aborts the whole top-level `DROP` command atomically.

So: the first observable symptom of *any* `DROP` statement in this upgraded database is not the "expected" clean deletion, and not even the "ids are out of sync" style message from `_object_v__for_update()` — it's this pre-existing `r_object`/`r_object_v` typo bug in `fix_refs()`, surfaced as a confusing "missing FROM-clause entry for table \"r_object\"" error, and the practical effect is that **the DROP statement silently fails and the object is not dropped**, because `_etg_drop()`'s unconditional `post_restore()` call scans the whole tracked-object set on every drop and blows up on the first stale row it finds — completely unrelated to what was actually being dropped.

(Separately, note that `zzz_object_reference__fix_identity` also fires on `ddl_command_end` for *any* DDL, including plain `CREATE TABLE`s unrelated to drops — reproduced too: `CREATE TABLE r7.throwaway(id int);` alone raised the same `invalid input value for enum cat_tools.object_type: "constraint"` error from Finding 1 and was rolled back, before a subsequent `DROP TABLE r7.throwaway;` could even find the table. This is a second, independent way any DDL — not just DROP — breaks post-upgrade with stale rows present.)

### Files/paths referenced
- `/root/git/object_reference/sql/object_reference.sql` — lines 193-240 (`_sanity`), 242-270 (`_object_v`/`_object_v__for_update` views), 272-318 (`_object_oid__add`), 323-405 (`fix_refs`, bug at lines 386 & 393), 406-413 (`post_restore`), 416-426 (`_repair`/`_sentry_mv`), 835-962 (`_object_v__for_update`, "ids are out of sync" RAISE at 943), 964-1166 (`object__getsert_w_group_id`), 1168-1203 (`object__getsert` wrappers), 1425-1469 (`_etg_fix_identity`), 1470-1515 (`_etg_drop`), 1571-1588 (event trigger registrations).
- `/root/code/extensions/deps/cat_tools/sql/cat_tools--0.3.0.sql` — lines 628-639 (`routine__parse_arg_types`, nested temp-function creation), 748-765 (`regprocedure`).
- All scratch work was done under `/root/.claude/jobs/e8963d3c/tmp/r7/` (now removed) and `/var/tmp/r7sock` (now removed); the shared 5412/5417 clusters were never touched.

---

## Scenario (c): stale `_object_oid` row + `ALTER … RENAME` on the real object it nominally tracks

### Code path: which event trigger(s) fire on `ALTER … RENAME`

Two (and only two) event triggers fire on `ddl_command_end` — the event that `ALTER … RENAME` produces — and both are declared with no `WHEN` filter, so they fire unconditionally on **every** DDL command in the database, not just ones touching the tracked object:

```
1577	CREATE EVENT TRIGGER zzz_object_reference__fix_identity
1578	  ON ddl_command_end
1579	  -- For debugging
1580	  --WHEN tag IN ( 'ALTER TABLE', 'DROP TABLE' )
1581	  EXECUTE PROCEDURE _object_reference._etg_fix_identity()
1582	;
1583	CREATE EVENT TRIGGER zzz_object_reference_capture
1584	  ON ddl_command_end
1585	  -- For debugging
1586	  --WHEN tag IN ( 'ALTER TABLE', 'DROP TABLE' )
1587	  EXECUTE PROCEDURE _object_reference._etg_capture()
1588	;
```

`_etg_capture` and `_etg_fix_identity`'s full bodies are quoted in "Event triggers" above; this walkthrough refers to them by line number.

Two independent reasons `_etg_capture` never mints a duplicate object_id for a rename:
1. `command_tag ~ '^CREATE'` (line 1409) excludes `ALTER FUNCTION`/`ALTER TABLE` etc. The tag for a rename is literally `ALTER FUNCTION` (verified with a scratch `event_trigger` probe below).
2. Even ignoring (1), the whole body is gated on `c_group_id IS NOT NULL` (line 1388), i.e. an active `object_reference.capture__start()` session — which was not active in this test (`object_reference.capture__get_current()` returned an all-NULL row).

**The critical fact `_etg_fix_identity`'s `UPDATE` hard-codes**: it recomputes `pg_identify_object_as_address(classid, objid, objsubid)` from `oo.classid/oo.objid/oo.objsubid` — the values *stored in `_object_oid`* — for **every row in the table**, on **every** `ddl_command_end`, completely independent of what DDL command actually just ran or which object it touched. There is no join to `pg_event_trigger_ddl_commands()` here at all. So whether a rename "fixes" a row's name is purely a function of whatever `(classid, objid, objsubid)` happens to be stored for that row *at the moment any DDL fires* — not a function of which real object was renamed.

### Reproduction — variant 1: stale row's `objid` points at a *different real* function

1. Create two real functions and track one of them:

```
psql -d oid_audit_r10:
CREATE SCHEMA test_s;
CREATE FUNCTION test_s.func_x(int) RETURNS int LANGUAGE sql AS $$ SELECT $1 + 1 $$;
CREATE FUNCTION test_s.func_y(int) RETURNS int LANGUAGE sql AS $$ SELECT $1 + 2 $$;
-- proname func_x oid 167376, func_y oid 167377 (classid 1255 = pg_proc)

SELECT object_reference.object__getsert('function', 'test_s.func_x', 'integer') AS object_id_x;
 object_id_x 
-------------
           1
```

State right after tracking (both tables correct and consistent):

```
SELECT * FROM _object_reference.object WHERE object_id = 1;
 object_id | object_type | object_names     | object_args 
-----------+-------------+------------------+-------------
         1 | function    | {test_s,func_x}  | {integer}

SELECT * FROM _object_reference._object_oid WHERE object_id = 1;
 object_id | classid | objid  | objsubid 
-----------+---------+--------+----------
         1 |    1255 | 167376 |        0
```

2. **Simulate a pg_upgrade-style stale row**: directly `UPDATE` the `_object_oid` row's `objid` to a *different real* function's oid (`func_y`'s oid 167377), of the same classid, leaving `_object_reference.object` untouched:

```sql
UPDATE _object_reference._object_oid SET objid = 167377 WHERE object_id = 1;
```

Immediately after (before any DDL runs), the two tables are now inconsistent — `object` still says `func_x`, `_object_oid` now points at `func_y`'s oid:

```
step | AFTER CORRUPTION (before any DDL fires)
-[ RECORD 1 ]+----------------
object_id    | 1
object_type  | function
object_names | {test_s,func_x}
object_args  | {integer}

-[ RECORD 1 ]----
object_id | 1
classid   | 1255
objid     | 167377
objsubid  | 0
```

3. Rename runs as the **very first DDL statement** issued anywhere in the database since the corrupting `UPDATE`, with nothing else touching it in between:

```sql
ALTER FUNCTION test_s.func_x(integer) RENAME TO func_x_renamed;
```
```
step | AFTER RENAMING func_x -> func_x_renamed (first DDL since corruption)
-[ RECORD 1 ]+----------------
object_id    | 1
object_type  | function
object_names | {test_s,func_y}
object_args  | {integer}

-[ RECORD 1 ]----
object_id | 1
classid   | 1255
objid     | 167377
objsubid  | 0

 proname        | oid
-----------------+-------
 func_x_renamed  | 167376
 func_y          | 167377
```

Final row count check — no duplicate was created:

```
SELECT count(*) FROM _object_reference.object;  -- 1
SELECT count(*) FROM _object_reference._object_oid;  -- 1
```

**Verdict for variant 1: outcome (b) — incorrect stored name.** With the rename fired as the very first DDL after the row was corrupted (the literal scenario), the single tracked row (`object_id = 1`) ends up storing `{test_s, func_y}` — neither `func_x`'s original name nor its new name (`func_x_renamed`), but the name of an entirely unrelated real function that the stale oid happened to point at. No second row is minted (rules out (c)); the name is not correctly updated to `func_x_renamed` (rules out (a)). This confirms `_etg_fix_identity` never looks at `func_x`'s real oid (167376) for this row; it only ever looks at whatever oid is stored in `_object_oid` (167377, `func_y`, which was not renamed) — the rename triggers the fix-up pass, but the pass ignores which object the DDL actually named.

4. **Secondary check** (fresh objects, so as not to disturb the row already resolved above): does this same corruption require a DDL command that touches the tracked/impostor objects at all, or is it truly unconditional? Track a second pair, corrupt it the same way, then fire a DDL statement that touches *neither* object, again as the very first DDL since the corruption:

```sql
CREATE FUNCTION test_s.func_p(int) RETURNS int LANGUAGE sql AS $$ SELECT $1 + 4 $$;
CREATE FUNCTION test_s.func_q(int) RETURNS int LANGUAGE sql AS $$ SELECT $1 + 5 $$;
-- proname func_p oid 167381, func_q oid 167382
SELECT object_reference.object__getsert('function', 'test_s.func_p', 'integer') AS object_id_p;  -- object_id 2
UPDATE _object_reference._object_oid SET objid = 167382 WHERE object_id = 2;  -- point at func_q
```
```
step | AFTER CORRUPTION (before any DDL fires)
-[ RECORD 1 ]+----------------
object_id    | 2
object_type  | function
object_names | {test_s,func_p}
object_args  | {integer}
```
```sql
CREATE SCHEMA unrelated_ddl_probe;  -- touches neither func_p nor func_q
```
```
step | AFTER UNRELATED DDL (CREATE SCHEMA)
-[ RECORD 1 ]+----------------
object_id    | 2
object_type  | function
object_names | {test_s,func_q}     <-- already corrupted, with no rename or any DDL on func_p/func_q at all
object_args  | {integer}
```

This confirms the mechanism claim independent of the rename test above: corruption on the next `ddl_command_end` is unconditional and does not require the DDL to touch the tracked object, the impostor object, or a rename at all — but this observation is only supplementary. The literal, brief-mandated sequence (stale row, then a rename of the tracked object as the very next DDL) was independently verified in step 3 to produce the same wrong result.

### Reproduction — variant 2: stale row's `objid` points at a *nonexistent* oid

1. New tracked function, clean initial state:

```sql
CREATE FUNCTION test_s.func_z(int) RETURNS int LANGUAGE sql AS $$ SELECT $1 + 3 $$;
SELECT object_reference.object__getsert('function', 'test_s.func_z', 'integer') AS object_id_z;
-- object_id_z = 3, func_z oid = 167387
```

2. Corrupt to a nonexistent oid of the same classid:

```sql
UPDATE _object_reference._object_oid SET objid = 1167387 WHERE object_id = 3;
```

3. Rename the real, live `func_z` (the object the stale row nominally tracks) as the very first DDL statement since the corrupting `UPDATE`:

```sql
ALTER FUNCTION test_s.func_z(integer) RENAME TO func_z_renamed;
```
```
ERROR:  invalid input value for enum cat_tools.object_type: "routine"
CONTEXT:  PL/pgSQL function _object_reference._etg_fix_identity() line 24 at FOR over SELECT rows
```

And it rolled back the *entire* command:

```sql
SELECT proname, oid FROM pg_proc WHERE proname LIKE 'func_z%';
 proname | oid
---------+-------
 func_z  | 167387   -- rename never took effect; rolled back
```

Root cause: `pg_catalog.pg_identify_object_as_address(classid, objid, objsubid)` does **not** error on a nonexistent oid — it returns a generic fallback based only on the classid, with empty `object_names`/`object_args`:

```sql
SELECT pg_catalog.pg_identify_object_as_address(1255, 1167387::oid, 0);
 pg_identify_object_as_address 
--------------------------------
 (routine,,)
```

But `'routine'` is **not** a member of `cat_tools.object_type` (confirmed: the enum has `function`, `aggregate`, `procedure`-adjacent labels but no generic `routine` — see the full 53-value enum list captured above), so the cast `(...).type::cat_tools.object_type` inside `_etg_fix_identity`'s `UPDATE` (line 1454) raises `invalid input value for enum cat_tools.object_type: "routine"`, which propagates out of the event trigger and aborts the whole top-level DDL command/transaction — even though the rename itself was the very first DDL to touch the database after the row went stale.

4. This is not specific to the rename — **every** subsequent DDL statement in the database fails identically until the corrupt row is cleaned up, including a totally unrelated `CREATE TABLE`:

```sql
CREATE TABLE test_s.harmless(x int);
```
```
ERROR:  invalid input value for enum cat_tools.object_type: "routine"
CONTEXT:  PL/pgSQL function _object_reference._etg_fix_identity() line 24 at FOR over SELECT rows
```

5. Recovery: once the offending `_object_oid`/`object` rows are removed, DDL works again immediately:

```sql
DELETE FROM _object_reference._object_oid WHERE object_id = 3;
DELETE FROM _object_reference.object WHERE object_id = 3;
```
```sql
CREATE TABLE test_s.harmless(x int);
CREATE TABLE
```

**Verdict for variant 2: none of (a)/(b)/(c) — a hard failure that poisons *all* DDL in the database.** With the rename fired as the very first DDL after the row was corrupted (the literal scenario), the rename itself is never applied (rolled back), and — more severely — every other DDL statement issued anywhere in the same database also fails with the same enum-cast error until the stale row pointing at the nonexistent oid is manually removed. This is strictly worse than silent corruption: it's a denial-of-service on all DDL, triggered by one bad `_object_oid` row, because `_etg_fix_identity` has no `WHEN` filter and processes the whole table unconditionally on every `ddl_command_end`.

### Summary verdict

**It depends on what the stale oid currently resolves to**, and in neither case is the outcome the "correct" one (a):

| Stale oid resolves to | Result |
|---|---|
| A different real object of the same classid | **(b)** — `_object_reference.object`'s name is silently overwritten with that *other* real object's identity (not the tracked object's old or new name), the moment **any** DDL command fires — confirmed directly with the rename as the very first DDL after staleness, and independently confirmed to require no rename at all. No duplicate row is created. |
| No object at all (nonexistent oid) | **Neither (a), (b), nor (c)** — `_etg_fix_identity` raises `invalid input value for enum cat_tools.object_type: "routine"` from `pg_identify_object_as_address`'s generic fallback type, aborting not just the rename but **every** DDL statement in the database until the row is removed. |

Both outcomes trace to the same design fact in `_etg_fix_identity` (sql/object_reference.sql:1452-1465): it recomputes each row's identity strictly from the `(classid, objid, objsubid)` already stored in `_object_oid`, with no cross-check against `pg_event_trigger_ddl_commands()` or against whether that oid still identifies the object the row was originally created for. It runs unconditionally on every `ddl_command_end` (no `WHEN` clause, sql/object_reference.sql:1577-1582), so staleness is "resolved" (wrongly) or turns fatal on the very next DDL statement anywhere in the database — including, as directly verified above, when that next statement is exactly the rename of the originally-tracked object. `_etg_capture` (sql/object_reference.sql:1378-1422) never creates a compensating/duplicate row for a rename in either variant, both because its `command_tag ~ '^CREATE'` filter (line 1409) excludes `ALTER FUNCTION` (the tag is exactly `ALTER FUNCTION`, per the reproduction above), and because it no-ops entirely when no `capture__start()` session is active (line 1388), which was the case throughout this test.

---

## Known-bug claims: verdicts

1. **`_object_oid__add()` has no `ON CONFLICT` and raises a duplicate-key error if called for an object_id that already has a row.** — **CONFIRMED**. See "`_object_oid__add()`, `fix_refs()`, and `post_restore()`" above: reproduced `ERROR: duplicate key value violates unique constraint "_object_oid_pkey"` on a direct re-add, and again via `_repair()` called against a non-empty table.

2. **`fix_refs()` has a branch referencing an undeclared variable `r_object` (should be `r_object_v`) that makes that branch itself error.** — **CONFIRMED**. See "`_object_reference.fix_refs()`" above: the final `CASE` arm (source lines 386 and 393) references undeclared `r_object`, and both `warning_only := true` and `warning_only := false` calls fail with `ERROR: missing FROM-clause entry for table "r_object"` instead of emitting the intended "extraneous ID information" diagnostic.

3. **`_etg_fix_identity()` has no guard against acting on an already-stale row.** — **CONFIRMED**. See "Event triggers installed by `object_reference`" and "Scenario (c): stale `_object_oid` row + `ALTER … RENAME`" above: with no `WHEN` filter and no staleness check, the handler either silently overwrites `object`'s stored identity with whatever unrelated live object the stale oid currently resolves to, or (if the oid resolves to nothing) raises an uncaught `invalid input value for enum cat_tools.object_type: "routine"/"relation"` error that aborts the triggering DDL and poisons every subsequent DDL statement in the database until the stale row is removed.
