/*
 * Immediately disable zzz_object_reference_capture and
 * zzz_object_reference__fix_identity (raw ALTER EVENT TRIGGER -- nothing
 * else, not even the __object_reference bootstrap schema below, exists yet
 * to route through) for the handful of bootstrap statements that follow:
 * their OLD (0.1.0) bodies have no way to recognize "this is our own
 * update script" until their guarded replacements are installed a few
 * statements down, and CREATE SCHEMA __object_reference is exactly the
 * kind of CREATE-tagged statement _etg_capture would otherwise try (and
 * fail) to register into any capture group active during this update.
 * Their actual prior state is captured into a temp table (rather than
 * assumed 'O') and restored below, so a DBA's own prior DISABLE of either
 * trigger survives this update instead of being silently overwritten.
 */
CREATE TEMP TABLE __object_reference__bootstrap_event_trigger_state AS
  SELECT evtname, evtenabled
    FROM pg_catalog.pg_event_trigger
    WHERE evtname IN ('zzz_object_reference_capture', 'zzz_object_reference__fix_identity')
;

ALTER EVENT TRIGGER zzz_object_reference_capture DISABLE;
ALTER EVENT TRIGGER zzz_object_reference__fix_identity DISABLE;

/*
 * Uses a private __object_reference schema, mirroring
 * sql/object_reference.sql's own bootstrap/teardown convention, so every
 * function recreated here goes through the same REVOKE ALL FROM PUBLIC /
 * GRANT / COMMENT template a fresh install uses.
 */
CREATE SCHEMA __object_reference;

CREATE FUNCTION __object_reference.exec(
  sql text
) RETURNS void LANGUAGE plpgsql AS $body$
BEGIN
  RAISE DEBUG 'sql = %', sql;
  EXECUTE sql;
END
$body$;

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

CREATE FUNCTION __object_reference.create_function(
  function_name text
  , args text
  , options text
  , body text
  , comment text
  , grants text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql AS $body$
DECLARE
  c_clean_args text := cat_tools.routine__parse_arg_types_text(args);

  create_template CONSTANT text := $template$
CREATE OR REPLACE FUNCTION %s(
%s
) RETURNS %s AS
%L
$template$
  ;

  revoke_template CONSTANT text := $template$
REVOKE ALL ON FUNCTION %s(
%s
) FROM public;
$template$
  ;

  grant_template CONSTANT text := $template$
GRANT EXECUTE ON FUNCTION %s(
%s
) TO %s;
$template$
  ;

  comment_template CONSTANT text := $template$
COMMENT ON FUNCTION %s(
%s
) IS %L;
$template$
  ;

BEGIN
  PERFORM __object_reference.exec( format(
      create_template
      , function_name
      , args
      , options
      , body
    ) )
  ;
  PERFORM __object_reference.exec( format(
      revoke_template
      , function_name
      , c_clean_args
    ) )
  ;

  IF grants IS NOT NULL THEN
    PERFORM __object_reference.exec( format(
        grant_template
        , function_name
        , c_clean_args
        , grants
      ) )
    ;
  END IF;

  IF comment IS NOT NULL THEN
    PERFORM __object_reference.exec( format(
        comment_template
        , function_name
        , c_clean_args
        , comment
      ) )
    ;
  END IF;
END
$body$;

/*
 * New: refuse to track objects that are themselves members of the
 * object_reference extension (see the guard added to
 * _object_v__for_update() below).
 */
SELECT __object_reference.create_function(
  '_object_reference._is_own_object'
  , $args$
  classid oid
  , objid oid
$args$
  , 'boolean LANGUAGE sql STABLE'
  , $body$
SELECT
  EXISTS(
    SELECT 1
      FROM pg_catalog.pg_depend d
      WHERE d.classid = _is_own_object.classid
        AND d.objid = _is_own_object.objid
        AND d.deptype = 'e'
        AND d.refclassid = 'pg_catalog.pg_extension'::regclass
        AND d.refobjid = e.oid
  )
  /*
   * The extension's own declared schema (object_reference) is a special
   * case: CREATE EXTENSION records the EXTENSION as depending on it (a
   * plain DEPENDENCY_NORMAL row, extension -> schema), not the schema as
   * an 'e' member of the extension the way every other object it creates
   * is -- so it never matches the pg_depend check above.
   */
  OR (_is_own_object.classid = 'pg_catalog.pg_namespace'::regclass AND _is_own_object.objid = e.extnamespace)
  /*
   * The extension's own pg_extension row is also its own special case: it
   * isn't a member of itself (no 'e' row with itself as both member and
   * owner), so treat it as one explicitly.
   */
  OR (_is_own_object.classid = 'pg_catalog.pg_extension'::regclass AND _is_own_object.objid = e.oid)
FROM (SELECT oid, extnamespace FROM pg_catalog.pg_extension WHERE extname = 'object_reference') e
$body$
  , 'Is the object a member of the object_reference extension itself? (pg_depend deptype = e membership, not just co-installation.)'
);

/*
 * _etg_fix_identity/_etg_capture: gain a self-recognition guard so they skip
 * work while this extension's own event_trigger__disable() call is in
 * effect for this session (checked via to_regclass() on the temp table
 * event_trigger__disable() creates below) -- i.e. this extension's own
 * install/update script is doing delicate internal restructuring right
 * now. Installed here, ahead of the structural section below, specifically
 * so the guard is already active by the time event_trigger__disable() is
 * first called a few statements down: recreating them any later would
 * leave the OLD (0.1.0), unguarded bodies live for that whole window --
 * which mattered in practice for _etg_capture, which would otherwise try
 * to call _object_reference._object_v__for_update() (the FUNCTION) for any
 * CREATE-tagged command in this script if a capture happened to be active,
 * including a moment where that function has been dropped and not yet
 * recreated, which would fail outright. Same signatures as 0.1.0, so a
 * plain CREATE OR REPLACE (via create_function) is enough -- no DROP
 * needed.
 */
SELECT __object_reference.create_function(
  '_object_reference._etg_capture'
  , ''
  , 'event_trigger SECURITY DEFINER LANGUAGE plpgsql'
  , $body$
DECLARE
  c_group_id CONSTANT int := object_group_id FROM object_reference.capture__get_current();
      r record;
BEGIN
  /*
   * Self-recognition: skip while this extension's own event_trigger__disable()
   * is in effect (see below) -- i.e. this extension's own install/update
   * script is doing delicate internal restructuring right now. Checked via
   * to_regclass() rather than a catalog lookup that would error if the temp
   * table doesn't exist, which is the common case.
   */
  IF to_regclass('pg_temp.__object_reference__event_trigger_state') IS NOT NULL THEN
    RETURN;
  END IF;

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
        /*
         * __object_reference is this extension's own scratch install/update
         * schema (created and dropped within a single script, never an
         * extension member) -- self-recognition via the temp table above
         * can't cover the handful of bootstrap statements that run before
         * that table exists, so exclude it here too (object_identity
         * carries the name for the CREATE SCHEMA statement itself, where
         * schema_name is null).
         *
         * object_reference/_object_reference are excluded outright rather
         * than relying on _object_v__for_update()'s own _is_own_object()
         * guard: a brand-new object created by this extension's own
         * update/install script isn't yet recorded as an 'e' member in
         * pg_depend at the point its CREATE fires ddl_command_end (that
         * happens once the surrounding CREATE/ALTER EXTENSION completes),
         * so _is_own_object() can't see it as self-owned yet either --
         * confirmed by running into it: an active capture group during
         * ALTER EXTENSION UPDATE otherwise ends up with this extension's
         * own new functions as members.
         *
         * The schema-creation statement itself (CREATE SCHEMA
         * __object_reference/etc.) has schema_name = NULL, with the name
         * only available via object_identity -- checked separately, and
         * restricted to object_type = 'schema', so an unrelated object of
         * some other type whose identity happens to match one of these
         * three exact strings (e.g. a same-named extension) isn't caught
         * by this fallback.
         */
        AND coalesce(schema_name, '') NOT IN ('__object_reference', 'object_reference', '_object_reference')
        AND NOT (object_type = 'schema' AND object_identity IN ('__object_reference', 'object_reference', '_object_reference'))
    LOOP
      RAISE DEBUG 'registered %', row_to_json(r);
    END LOOP;
    RAISE DEBUG E'*** END ***\n\n';
  END IF;
END
$body$
  , 'Event trigger function to capture newly created objects in an object group.'
);
SELECT __object_reference.create_function(
  '_object_reference._etg_fix_identity'
  , ''
  , 'event_trigger SECURITY DEFINER LANGUAGE plpgsql'
  , $body$
DECLARE
  r_ddl record;
  r record;
BEGIN
  /*
   * Self-recognition: skip while this extension's own event_trigger__disable()
   * is in effect (see below) -- i.e. this extension's own install/update
   * script is doing delicate internal restructuring right now. Checked via
   * to_regclass() rather than a catalog lookup that would error if the temp
   * table doesn't exist, which is the common case.
   */
  IF to_regclass('pg_temp.__object_reference__event_trigger_state') IS NOT NULL THEN
    RETURN;
  END IF;

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
$body$
  , 'Event trigger function to update any records with object names or args that have changed.'
);

/*
 * Restore each trigger's actual prior state (captured above) now that the
 * guarded bodies above are live -- self-recognition (checking for
 * event_trigger__disable()'s temp table, created below) takes over from
 * here for the rest of this script.
 */
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT evtname, evtenabled FROM pg_temp.__object_reference__bootstrap_event_trigger_state LOOP
    EXECUTE format(
      'ALTER EVENT TRIGGER %I %s'
      , r.evtname
      , CASE r.evtenabled
          WHEN 'O' THEN 'ENABLE'
          WHEN 'R' THEN 'ENABLE REPLICA'
          WHEN 'A' THEN 'ENABLE ALWAYS'
          WHEN 'D' THEN 'DISABLE'
        END
    );
  END LOOP;
END
$$;
DROP TABLE pg_temp.__object_reference__bootstrap_event_trigger_state;

/*
 * WARNING: avoid disabling event triggers at all where any other option
 * exists. ALTER EVENT TRIGGER is ordinary transactional DDL -- like any
 * other catalog write, it's invisible to other sessions until commit (no
 * special database-wide/immediate effect: verified empirically that a
 * concurrent session's DDL neither blocks on, nor is otherwise affected by,
 * another session's still-uncommitted DISABLE) and it takes no lock at all
 * on the event trigger itself. The real risk is TWO SESSIONS both trying to
 * alter the SAME event trigger concurrently: a second writer blocks on the
 * first the way any two concurrent writes to the same catalog row would,
 * and without care, the one that unblocks second can record and later
 * restore a "prior state" that was never actually the trigger's state
 * immediately before it acted (see the FOR UPDATE lock in
 * event_trigger__disable()'s body below, which exists specifically to close
 * that gap). Prefer a self-recognition check (a session-local flag, checked
 * from inside the trigger's own body, as _etg_fix_identity/_etg_capture
 * above do) over calling this at all; reach for it only when nothing else
 * can make the trigger stay quiet, as is currently true for
 * zzz__object_reference_drop.
 *
 * General-purpose event-trigger disable/enable mechanism, replacing the
 * session_replication_role trick 0.1.0 had no equivalent of. 0.1.0 already
 * installed this extension's own event triggers, and they stay active for
 * the rest of THIS session while the structural changes below run.
 * zzz__object_reference_drop in particular queries _object_reference._object_v
 * inside its own body, so it would fire -- and error, since the view is
 * momentarily gone -- the instant this script drops that view a few
 * statements down. It can't self-recognize the way _etg_fix_identity/
 * _etg_capture above do without also touching that same view from inside
 * its own body, so it must be truly disabled for the duration of this
 * script's structural section.
 *
 * These are created now, ahead of the structural section, specifically so
 * this script itself can call event_trigger__disable() below -- a fresh
 * install only ever needs these for FUTURE update scripts, or anywhere
 * else a future need to safely quiet an event trigger comes up (hence the
 * mechanism-focused name, not one tied to "being mid-update").
 */
SELECT __object_reference.create_function(
  '_object_reference.event_trigger__disable'
  , $args$
  event_trigger_names name[]
$args$
  , 'void LANGUAGE plpgsql'
  , $body$
DECLARE
  v_name name;
  v_enabled "char";
BEGIN
  /*
   * WARNING: avoid disabling event triggers at all where any other option
   * exists -- this is a database-wide change with real race-condition risk
   * against concurrent sessions' DDL. See the warning above this function.
   */
  BEGIN
    -- Save old trigger state
    CREATE TEMP TABLE __object_reference__event_trigger_state AS
      SELECT evtname, evtenabled FROM pg_catalog.pg_event_trigger WHERE false
    ;
    ALTER TABLE pg_temp.__object_reference__event_trigger_state ADD PRIMARY KEY (evtname);
  EXCEPTION WHEN duplicate_table THEN
    RAISE 'event_trigger__disable() called while a previous call is still in effect'
      USING HINT = 'A previous event_trigger__enable() call may have been skipped.'
    ;
  END;

  IF array_length(event_trigger_names, 1) <> (SELECT count(DISTINCT x) FROM unnest(event_trigger_names) x) THEN
    RAISE 'event_trigger_names contains a duplicate name' USING DETAIL = event_trigger_names::text;
  END IF;

  FOREACH v_name IN ARRAY event_trigger_names LOOP
    /*
     * FOR UPDATE locks the row before we read it, so no other session's own
     * ALTER EVENT TRIGGER on the same trigger can land between our read and
     * our DISABLE below -- without it, a concurrent change there would
     * leave us recording (and later restoring) a state that was never
     * actually the trigger's state immediately before we disabled it.
     */
    SELECT evtenabled INTO v_enabled
      FROM pg_catalog.pg_event_trigger
      WHERE evtname = v_name
      FOR UPDATE
    ;

    IF NOT FOUND THEN
      RAISE 'event trigger "%" does not exist', v_name;
    END IF;

    INSERT INTO pg_temp.__object_reference__event_trigger_state(evtname, evtenabled)
      VALUES (v_name, v_enabled);

    PERFORM _object_reference.exec(format('ALTER EVENT TRIGGER %I DISABLE', v_name));
  END LOOP;
END
$body$
  , 'Disable the given event triggers, remembering their exact prior state; pair with event_trigger__enable().'
);
SELECT __object_reference.create_function(
  '_object_reference.event_trigger__enable'
  , ''
  , 'void LANGUAGE plpgsql'
  , $body$
DECLARE
  v_names name[];
  v_states "char"[];
  i int;
BEGIN
  BEGIN
    SELECT array_agg(evtname), array_agg(evtenabled)
      INTO v_names, v_states
      FROM pg_temp.__object_reference__event_trigger_state
    ;
  EXCEPTION WHEN undefined_table THEN
    RAISE 'event_trigger__enable() called without a matching event_trigger__disable()';
  END;

  /*
   * Drop our own bookkeeping table BEFORE re-enabling anything below:
   * dropping it is itself DDL, and if zzz__object_reference_drop is one of
   * the triggers being restored here, re-enabling it first would make this
   * DROP immediately fire it -- reacting to our own internal cleanup,
   * exactly the hazard this whole mechanism exists to avoid. (Confirmed by
   * running into it: with the table dropped after, an active capture group
   * elsewhere left a stale tracked row that this DROP's cascade into
   * post_restore() then found and errored on.)
   */
  DROP TABLE pg_temp.__object_reference__event_trigger_state;

  FOR i IN 1..coalesce(array_length(v_names, 1), 0) LOOP
    PERFORM _object_reference.exec(format(
      'ALTER EVENT TRIGGER %I %s'
      , v_names[i]
      , CASE v_states[i]
          WHEN 'O' THEN 'ENABLE'
          WHEN 'R' THEN 'ENABLE REPLICA'
          WHEN 'A' THEN 'ENABLE ALWAYS'
          WHEN 'D' THEN 'DISABLE'
        END
    ));
  END LOOP;
END
$body$
  , 'Restore event triggers disabled by event_trigger__disable() to their exact prior state.'
);

SELECT _object_reference.event_trigger__disable('{zzz__object_reference_drop}');

/*
 * _object_reference.object: no column changes, just a missing
 * extension_config_dump marking on its sequence (added alongside the table
 * itself in the current source; 0.1.0 only marked the table).
 */
SELECT __object_reference.safe_dump('_object_reference.object_object_id_seq');

/*
 * Views + dependent functions -- dropped BEFORE the _object_oid table
 * alterations below, not after: _object_v / _object_v__for_update (views)
 * both SELECT the reg* columns directly, so the columns can't be dropped out
 * from under them first. CREATE OR REPLACE VIEW also cannot remove columns,
 * so both views must be DROP+CREATE'd regardless. _object_oid__add() and the
 * _object_v__for_update() FUNCTION (a
 * distinct catalog object from the view of the same name -- Postgres allows
 * a relation and a function to share a name, since they live in pg_class and
 * pg_proc respectively) both RETURN _object_reference._object_v, which is a
 * formal pg_depend edge (not just a body reference), so a non-CASCADE DROP
 * VIEW would fail with them still around: they must be dropped first, in
 * this order, then the table altered, then the views recreated, then the
 * functions recreated (via create_function, which uses CREATE OR REPLACE --
 * fine here since neither currently exists).
 *
 * _object_oid__add's own signature also changes (classid regclass -> oid,
 * following the table alteration below), which on its own would require a
 * DROP FUNCTION before a same-named CREATE regardless of the view: CREATE OR
 * REPLACE FUNCTION with different parameter types creates a new, distinct
 * overload rather than replacing the old one, leaving the wrong-typed
 * original behind.
 */
DROP FUNCTION _object_reference._object_oid__add(int, cat_tools.object_type, regclass, oid, int);
DROP FUNCTION _object_reference._object_v__for_update(cat_tools.object_type, oid, int, int, regclass);
DROP VIEW _object_reference._object_v__for_update;
DROP VIEW _object_reference._object_v;

/*
 * _object_reference._object_oid: drop the reg* pseudotype columns, the
 * count_nulls-backed trigger that enforced "exactly one is set", and
 * object_oid itself (it only ever existed to collapse whichever reg* column
 * applied into a single plain-oid value -- with no reg* columns left, it's
 * pure redundant storage of objid and buys nothing). Order below is fully
 * explicit (constraints/indexes/trigger dropped by name, not left to an
 * implicit CASCADE) so nothing is silently dropped alongside a `DROP COLUMN`
 * we did not ask for.
 */
ALTER TABLE _object_reference._object_oid
  DROP CONSTRAINT regclass_classid
  , DROP CONSTRAINT regconfig_classid
  , DROP CONSTRAINT regdictionary_classid
  , DROP CONSTRAINT regnamespace_classid
  , DROP CONSTRAINT regoperator_classid
  , DROP CONSTRAINT regprocedure_classid
  , DROP CONSTRAINT regtype_classid
  , DROP CONSTRAINT objid_must_match
;

DROP TRIGGER null_count ON _object_reference._object_oid;

DROP INDEX _object_reference._object_oid__u_regclass;
DROP INDEX _object_reference._object_oid__u_regconfig;
DROP INDEX _object_reference._object_oid__u_regdictionary;
DROP INDEX _object_reference._object_oid__u_regoperator;
DROP INDEX _object_reference._object_oid__u_regprocedure;
DROP INDEX _object_reference._object_oid__u_regtype;

ALTER TABLE _object_reference._object_oid
  DROP COLUMN regclass
  , DROP COLUMN regconfig
  , DROP COLUMN regdictionary
  , DROP COLUMN regnamespace
  , DROP COLUMN regoperator
  , DROP COLUMN regprocedure
  , DROP COLUMN regtype
  , DROP COLUMN object_oid
  , ALTER COLUMN classid TYPE oid USING classid::oid
;

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

  -- Refuse to track objects that are themselves members of this extension
  IF _object_reference._is_own_object(c_classid, objid) THEN
    RAISE 'cannot track an object that is a member of the object_reference extension itself'
      USING DETAIL = format('object %s belongs to the object_reference extension', r_identity.identity)
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
  , 'Return details of a object record, creating a new record if one does not exist. Heavy-weight compared to a plain read of _object_reference._object_v -- use that instead when an existing record is all that''s needed.'
);

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

/*
 * object_reference.unsupported(): additionally exclude "partitioned
 * table"/"partitioned index" (pg_get_object_address() only recognizes the
 * base "table"/"index" types they derive from, so identity tracking can't
 * round-trip them). Same signature as 0.1.0, so a plain CREATE OR REPLACE
 * (via create_function) is enough -- no DROP needed.
 */
SELECT __object_reference.create_function(
  'object_reference.unsupported'
  , ''
  , 'cat_tools.object_type[] LANGUAGE sql IMMUTABLE'
  , $body$
SELECT cat_tools.objects__shared()
  || cat_tools.objects__address_unsupported()
  /*
   * pg_get_object_address() doesn't recognize "partitioned table" or
   * "partitioned index" (only the base "table"/"index" types it derives
   * from), so object identity tracking can't round-trip them.
   */
  || '{event trigger, partitioned table, partitioned index}'
$body$
  , 'Returns array of object types that are not supported.'
  , 'object_reference__usage'
);

/*
 * New: automatic object cleanup when removed from a group.
 */
SELECT __object_reference.create_function(
  '_object_reference._object_group__object__cleanup_trigger'
  , ''
  , 'trigger LANGUAGE plpgsql'
  , $body$
BEGIN
  PERFORM object_reference.object__cleanup(OLD.object_id);
  RETURN OLD;
END
$body$
  , 'Trigger function to automatically attempt cleanup of objects when removed from groups.'
);
CREATE TRIGGER object_group__object__cleanup
  AFTER DELETE ON _object_reference.object_group__object
  FOR EACH ROW
  EXECUTE FUNCTION _object_reference._object_group__object__cleanup_trigger();

/*
 * New: OBJECT INFO FUNCTIONS
 */
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
SELECT __object_reference.create_function(
  'object_reference.object__cleanup'
  , $args$
  object_id int
$args$
  , 'void LANGUAGE plpgsql'
  , $body$
BEGIN
  DELETE FROM _object_reference.object WHERE object.object_id = object__cleanup.object_id;
EXCEPTION WHEN foreign_key_violation THEN
  -- Object is still referenced elsewhere, ignore the error
  NULL;
END
$body$
  , 'Attempts to delete an object from the tracking system. Silently returns if the object is still referenced by other tables.'
  , 'object_reference__usage'
);

/*
 * _tg_capture_safety(): gains a trailing RETURN NULL. Same signature, so a
 * plain CREATE OR REPLACE (via create_function) is enough.
 */
SELECT __object_reference.create_function(
  '_object_reference._tg_capture_safety'
  , ''
  , 'trigger LANGUAGE plpgsql'
  , $body$
BEGIN
  IF EXISTS(SELECT 1 FROM pg_temp.__object_reference__ddl_capture) THEN
    RAISE 'attempted commit while still capturing DDL'
      USING HINT = 'Did you not start a transaction? Did you forget to call object_reference.capture__stop()?'
    ;
  END IF;

  RETURN NULL;
END
$body$
  , 'Trigger function to ensure capture__stop() is called an appropriate number of times.'
);

/*
 * New: example/debug event-trigger functions (not wired to any CREATE EVENT
 * TRIGGER -- 0.1.0 had an equivalent commented-out "snitch" example instead).
 */
SELECT __object_reference.create_function(
  '_object_reference.etg_raise__start'
  , ''
  , 'event_trigger LANGUAGE plpgsql'
  , $body$
BEGIN
    RAISE WARNING 'etg_raise__start: % %', tg_event, tg_tag;
END;
$body$
  , $$Event trigger function to report on DDL activity. Example trigger:
CREATE EVENT TRIGGER start
  ON ddl_command_start
  --WHEN tag IN ( 'ALTER TABLE', 'DROP TABLE' )
  EXECUTE PROCEDURE _object_reference.etg_raise__start()
;
$$);
SELECT __object_reference.create_function(
  '_object_reference.etg_raise__drop'
  , ''
  , 'event_trigger LANGUAGE plpgsql'
  , $body$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT classid, objid, objsubid, object_type, schema_name, object_name, object_identity FROM pg_catalog.pg_event_trigger_dropped_objects() LOOP
    RAISE WARNING 'dropped_objects:
    classid: %
    objid: %
    objsubid: %
    object_type: %
    schema_name: %
    object_name: %
    object_identity: %
    '
      -- :^r" s/\([^ ]\+\):.*/, r.\1/
      , r.classid
      , r.objid
      , r.objsubid
      , r.object_type
      , r.schema_name
      , r.object_name
      , r.object_identity
    ;
  END LOOP;
END;
$body$
  , $$Event trigger function to report on DDL activity. Example trigger:
CREATE EVENT TRIGGER drop
  ON sql_drop
  --WHEN tag IN ( 'ALTER TABLE', 'DROP TABLE' )
  EXECUTE PROCEDURE _object_reference.etg_raise__drop()
;
$$);

/*
 * object_reference.capture__start(object_group_id): 0.1.0's body still has
 * a dead, commented-out CREATE TEMP TABLE ... AS attempt inside the
 * EXCEPTION handler that current source has since dropped -- functionally
 * inert either way, but pg_get_functiondef() returns comments verbatim, so
 * leaving it in place would make an updated install's function body
 * literally differ from a fresh install's (caught by this repo's own
 * fresh-vs-updated structural diff). Recreated here with the current,
 * comment-free body; the other overload (capture__start(object_group_name),
 * a thin wrapper) is untouched between 0.1.0 and current source and does
 * not need recreating.
 */
SELECT __object_reference.create_function(
  'object_reference.capture__start'
  , $args$
  object_group_id _object_reference.object_group.object_group_id%TYPE
$args$
  , 'int SECURITY DEFINER LANGUAGE plpgsql'
  , $body$
DECLARE
  c_next_level int := coalesce(capture_level, 0) + 1 FROM object_reference.capture__get_current();
BEGIN
  -- Ensure object group exists
  PERFORM object_reference.object_group__get(object_group_id);

  INSERT INTO pg_temp.__object_reference__ddl_capture 
    SELECT c_next_level, capture__start.object_group_id
  ;
  RETURN c_next_level;

EXCEPTION WHEN undefined_table THEN
  CREATE TEMP TABLE __object_reference__ddl_capture(
    capture_level int PRIMARY KEY
    , object_group_id INT NOT NULL -- temp tables can't reference permanent ones
  );
  -- This breaks if run directly under plpgsql
  EXECUTE $code$
  CREATE CONSTRAINT TRIGGER verify_capture_stop AFTER INSERT
    ON pg_temp.__object_reference__ddl_capture 
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW -- CONSTRAINT triggers must be per-ROW
    EXECUTE PROCEDURE _object_reference._tg_capture_safety()
  $code$;

  INSERT INTO pg_temp.__object_reference__ddl_capture 
    SELECT c_next_level, capture__start.object_group_id
  ;
  RETURN c_next_level;
END
$body$
  , 'Begin capturing newly created objects to <object_group_id>. Returns current capture level.'
  , 'object_reference__usage'
);

/*
 * Drop "temporary" objects -- same convention as the fresh install script.
 */
DROP FUNCTION __object_reference.create_function(
  function_name text
  , args text
  , options text
  , body text
  , comment text
  , grants text
);
DROP FUNCTION __object_reference.safe_dump(
  relation regclass
  , text
);
DROP FUNCTION __object_reference.exec(
  sql text
);
DROP SCHEMA __object_reference;

/*
 * Re-enable zzz__object_reference_drop (to its actual prior state, saved by
 * event_trigger__disable() near the top of this script), now that the
 * structural section and its cleanup are both done.
 */
SELECT _object_reference.event_trigger__enable();

-- vi: expandtab sw=2 ts=2
