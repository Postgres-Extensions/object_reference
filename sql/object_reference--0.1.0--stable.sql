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
 * 0.1.0 already installed this extension's own event triggers, and they
 * stay active for the rest of THIS session while the structural changes
 * below run. zzz__object_reference_drop in particular queries
 * _object_reference._object_v inside its own body, so it would fire -- and
 * error, since the view is momentarily gone -- the instant this script drops
 * that view a few statements down. All three are default-enabled (origin),
 * so setting session_replication_role = replica suppresses them for the
 * rest of this transaction -- reverting automatically once the update
 * completes, with no explicit re-enable needed even across the cleanup at
 * the end of this script. A fresh install never hits this: it creates these
 * event triggers only at the very end, once nothing they reference is still
 * being modified.
 */
SET LOCAL session_replication_role = replica;

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

-- vi: expandtab sw=2 ts=2
