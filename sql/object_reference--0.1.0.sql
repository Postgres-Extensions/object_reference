SET LOCAL client_min_messages = WARNING;
\echo This extension must be loaded via 'CREATE EXTENSION object_reference;'
\echo You really, REALLY do NOT want to try and load this via psql!!!
\echo It will FAIL during pg_dump! \quit

-- This BS is because count_nulls is relocatable, so could be in any schema
DO $$
BEGIN
  RAISE DEBUG 'initial search_path = %', current_setting('search_path');
  PERFORM set_config('search_path', current_setting('search_path') || ', ' || extnamespace::regnamespace::text, true) -- true = local only
    FROM pg_extension
    WHERE extname = 'count_nulls'
  ;
  RAISE DEBUG 'search_path changed to %', current_setting('search_path');
END
$$;
/*
DO $$
DECLARE
  c_schema CONSTANT name := (SELECT extnamespace::regnamespace::text FROM pg_extension WHERE extname = 'cat_tools');
BEGIN
  IF c_schema IS NULL THEN
    RAISE 'extension cat_tools is not installed';
  END IF;

  IF c_schema <> 'cat_tools' THEN
    RAISE 'having the cat_tools extension installed anywhere but the "cat_tools" schema is not currently supported'
      USING DETAIL = format('current schema for cat_tools is %s', c_schema)
    ;
  END IF;
END
$$;
*/

DO $$
BEGIN
  CREATE ROLE object_reference__usage NOLOGIN;
EXCEPTION WHEN duplicate_object THEN
  NULL;
END
$$;

DO $$
BEGIN
  CREATE ROLE object_reference__dependency NOLOGIN;
EXCEPTION WHEN duplicate_object THEN
  NULL;
END
$$;

/*
 * NOTE: All pg_temp objects must be dropped at the end of the script!
 * Otherwise the eventual DROP CASCADE of pg_temp when the session ends will
 * also drop the extension! Instead of risking problems, create our own
 * "temporary" schema instead.
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
  c_clean_args text := cat_tools.function__arg_types_text(args);

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
      , options -- TODO: Force search_path if options ~* 'definer'
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


-- Schema already created via CREATE EXTENSION
GRANT USAGE ON SCHEMA object_reference TO object_reference__usage;
CREATE SCHEMA _object_reference;
GRANT USAGE ON SCHEMA _object_reference TO object_reference__dependency;

SELECT __object_reference.create_function(
  '_object_reference.exec'
  , 'sql text'
  , 'void LANGUAGE plpgsql'
  , $body$
BEGIN
  RAISE DEBUG 'sql = %', sql;
  EXECUTE sql;
END
$body$
  , 'Execute arbitrary SQL with logging.'
);

CREATE TABLE _object_reference.object(
  object_id       serial                  PRIMARY KEY
  , object_type   cat_tools.object_type   NOT NULL
--  , original_name text                    NOT NULL
  , object_names text[]                  NOT NULL
  , object_args  text[]                  NOT NULL
  , CONSTRAINT object__u_object_names__object_args UNIQUE( object_type, object_names, object_args )
  /* TODO: this can't be a trigger because some objects won't exist when a dump is loaded
  , CONSTRAINT object__address_sanity
    -- pg_get_object_address will throw an error if anything is wrong, so the IS NOT NULL is mostly pointless
    CHECK( pg_catalog.pg_get_object_address(object_type::text, object_names, object_args) IS NOT NULL )
    */
);
SELECT __object_reference.safe_dump('_object_reference.object');
GRANT REFERENCES ON _object_reference.object TO object_reference__dependency;

CREATE TABLE _object_reference._object_oid(
  object_id       int                     PRIMARY KEY REFERENCES _object_reference.object ON DELETE CASCADE ON UPDATE CASCADE
  , classid       regclass                NOT NULL
  /* TODO: needs to be a trigger
    CONSTRAINT classid_must_match__object__address_classid
      CHECK( classid IS NOT DISTINCT FROM cat_tools.object__address_classid(object_type) )
    */
  , objid         oid                     NOT NULL
  , objsubid      int                     NOT NULL
    CONSTRAINT objid_must_match CHECK( -- _object_reference._sanity() depends on this!
      objid IS NOT DISTINCT FROM coalesce(
        regclass::oid -- Need to cast first item to generic OID
        , regconfig
        , regdictionary
        , regnamespace -- SED: REQUIRES 9.5!
        , regoperator
        , regprocedure
        , regtype
        , object_oid
      )
    )
  , CONSTRAINT object__u_classid__objid__objsubid UNIQUE( classid, objid, objsubid )
  , regclass      regclass
    CONSTRAINT regclass_classid CHECK( regclass IS NULL OR classid = cat_tools.object__reg_type_catalog('regclass') )
  , regconfig     regconfig
    CONSTRAINT regconfig_classid CHECK( regconfig IS NULL OR classid = cat_tools.object__reg_type_catalog('regconfig') )
  , regdictionary regdictionary
    CONSTRAINT regdictionary_classid CHECK( regdictionary IS NULL OR classid = cat_tools.object__reg_type_catalog('regdictionary') )
  , regnamespace  regnamespace -- SED: REQUIRES 9.5!
    CONSTRAINT regnamespace_classid CHECK( regnamespace IS NULL OR classid = cat_tools.object__reg_type_catalog('regnamespace') ) -- SED: REQUIRES 9.5!
  , regoperator   regoperator
    CONSTRAINT regoperator_classid CHECK( regoperator IS NULL OR classid = cat_tools.object__reg_type_catalog('regoperator') )
  , regprocedure  regprocedure
    CONSTRAINT regprocedure_classid CHECK( regprocedure IS NULL OR classid = cat_tools.object__reg_type_catalog('regprocedure') )
  -- I don't think we should ever have regrole since we can't create event triggers on it
--  , regrole       regrole
  , regtype       regtype
    CONSTRAINT regtype_classid CHECK( regtype IS NULL OR classid = cat_tools.object__reg_type_catalog('regtype') )
  , object_oid    oid
);
CREATE TRIGGER null_count
  AFTER INSERT OR UPDATE
  ON _object_reference._object_oid
  FOR EACH ROW EXECUTE PROCEDURE not_null_count_trigger(
    5 -- First 4 fields, + 1
    , 'only one object reference field may be set'
  )
;
CREATE UNIQUE INDEX _object_oid__u_regclass ON _object_reference._object_oid(regclass) WHERE regclass IS NOT NULL;
CREATE UNIQUE INDEX _object_oid__u_regconfig ON _object_reference._object_oid(regconfig) WHERE regconfig IS NOT NULL;
CREATE UNIQUE INDEX _object_oid__u_regdictionary ON _object_reference._object_oid(regdictionary) WHERE regdictionary IS NOT NULL;
CREATE UNIQUE INDEX _object_oid__u_regoperator ON _object_reference._object_oid(regoperator) WHERE regoperator IS NOT NULL;
CREATE UNIQUE INDEX _object_oid__u_regprocedure ON _object_reference._object_oid(regprocedure) WHERE regprocedure IS NOT NULL;
CREATE UNIQUE INDEX _object_oid__u_regtype ON _object_reference._object_oid(regtype) WHERE regtype IS NOT NULL;

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

CREATE VIEW _object_reference._object_v AS
  SELECT 
      o.object_id
      , o.object_type
      , o.object_names
      , o.object_args
      , i.classid
      , i.objid
      , i.objsubid
      , i.regclass
      , i.regconfig
      , i.regdictionary
      , i.regnamespace
      , i.regoperator
      , i.regprocedure
      , i.regtype
      , i.object_oid
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
      , i.regclass
      , i.regconfig
      , i.regdictionary
      , i.regnamespace
      , i.regoperator
      , i.regprocedure
      , i.regtype
      , i.object_oid
      , s.*
    FROM _object_reference.object o
      LEFT JOIN _object_reference._object_oid i USING(object_id)
      , _object_reference._sanity(o, i) s
    FOR UPDATE OF o
;

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
        o.object_type, a.classid, a.objid, a.subobjid
      FROM _object_reference.object o
        , pg_catalog.pg_get_object_address(o.object_type::text, o.object_names, o.object_args) a
      WHERE o.object_id = _object_oid__add.object_id
    ;
  END IF;
  DECLARE
    c_reg_type name := cat_tools.object__reg_type(object_type); -- Verifies regtype is supported, if there is one
    c_oid_field CONSTANT name := coalesce(c_reg_type, 'object_oid');

    c_oid_insert CONSTANT text := format(
      --USING object_id, classid, objid, objsubid
        $$INSERT INTO _object_reference._object_oid(object_id, classid, objid, objsubid, %I)
            SELECT $1, $2, $3, $4, $3::%I$$
        , c_oid_field
        , coalesce(c_reg_type, 'oid')
      )
    ;
  BEGIN
    RAISE DEBUG E'%\n    USING  %, %, %, %'
      , c_oid_insert
      , object_id, classid, objid, objsubid
    ;
    EXECUTE c_oid_insert
      USING object_id, classid, objid, objsubid
    ;

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
 * fix_refs / post_restore
 */
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
SELECT __object_reference.create_function(
  'object_reference.post_restore'
  , ''
  , 'void SECURITY DEFINER LANGUAGE sql'
  , 'SELECT _object_reference.fix_refs(false)'
  , 'Ensures all object references are correct after a restore.'
  , 'object_reference__usage'
);


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

/*
 * Unsupported object types
 */
SELECT __object_reference.create_function(
  'object_reference.unsupported'
  , ''
  , 'cat_tools.object_type[] LANGUAGE sql IMMUTABLE'
  , $body$
SELECT cat_tools.objects__shared()
  || cat_tools.objects__address_unsupported()
  || '{event trigger}'
$body$
  , 'Returns array of object types that are not supported.'
  , 'object_reference__usage'
);
SELECT __object_reference.create_function(
  'object_reference.unsupported_srf'
  , ''
  , 'SETOF cat_tools.object_type LANGUAGE sql IMMUTABLE'
  , $body$
SELECT * FROM unnest(object_reference.unsupported())
$body$
  , 'Returns set of object types that are not supported.'
  , 'object_reference__usage'
);
SELECT __object_reference.create_function(
  'object_reference.unsupported'
  , 'object_type cat_tools.object_type'
  , 'boolean LANGUAGE sql IMMUTABLE'
  , $body$
SELECT object_type = ANY(object_reference.unsupported())
$body$
  , 'Is a object_type unsupported?'
  , 'object_reference__usage'
);
SELECT __object_reference.create_function(
  'object_reference.unsupported'
  , 'object_type text'
  , 'boolean LANGUAGE sql IMMUTABLE'
  , $body$
SELECT object_reference.unsupported(object_type::cat_tools.object_type)
$body$
  , 'Is a object_type unsupported?'
  , 'object_reference__usage'
);

/*
 * Untested object types
 */
SELECT __object_reference.create_function(
  'object_reference.untested'
  , ''
  , 'cat_tools.object_type[] LANGUAGE sql IMMUTABLE'
  , $body$
SELECT '{
foreign table, foreign table column, aggregate, collation, conversion, language,
large object, operator, operator class, operator family, operator of access method,
function of access method, rule, text search parser, text search dictionary,
text search template, text search configuration, foreign-data wrapper, server,
user mapping, default acl, transform, access method, extension, policy
}'::cat_tools.object_type[]
$body$
  , 'Returns array of object types that have not been tested.'
  , 'object_reference__usage'
);
SELECT __object_reference.create_function(
  'object_reference.untested_srf'
  , ''
  , 'SETOF cat_tools.object_type LANGUAGE sql IMMUTABLE'
  , $body$
SELECT * FROM unnest(object_reference.untested())
$body$
  , 'Returns set of object types that have not been tested.'
  , 'object_reference__usage'
);
SELECT __object_reference.create_function(
  'object_reference.untested'
  , 'object_type cat_tools.object_type'
  , 'boolean LANGUAGE sql IMMUTABLE'
  , $body$
SELECT object_type = ANY(object_reference.untested())
$body$
  , 'Is a object_type untested?'
  , 'object_reference__usage'
);
SELECT __object_reference.create_function(
  'object_reference.untested'
  , 'object_type text'
  , 'boolean LANGUAGE sql IMMUTABLE'
  , $body$
SELECT object_reference.untested(object_type::cat_tools.object_type)
$body$
  , 'Is a object_type untested?'
  , 'object_reference__usage'
);


/*
 * OBJECT GROUP
 */
CREATE TABLE _object_reference.object_group(
  object_group_id         serial        PRIMARY KEY
  , object_group_name     varchar(200)  NOT NULL
);
CREATE UNIQUE INDEX object_group__u_object_group_name__lower ON _object_reference.object_group(lower(object_group_name));
SELECT __object_reference.safe_dump('_object_reference.object_group');

CREATE TABLE _object_reference.object_group__object(
  object_group_id         int     NOT NULL REFERENCES _object_reference.object_group
  , object_id             int     NOT NULL REFERENCES _object_reference.object
  , CONSTRAINT object_group__object__u_object_group_id__object_id UNIQUE( object_group_id, object_id )
);
SELECT __object_reference.safe_dump('_object_reference.object_group__object');

-- __get
SELECT __object_reference.create_function(
  'object_reference.object_group__get'
  , $args$
  object_group_name _object_reference.object_group.object_group_name%TYPE
$args$
  , '_object_reference.object_group LANGUAGE plpgsql STABLE'
  , $body$
DECLARE
  r _object_reference.object_group;
BEGIN
  SELECT INTO STRICT r
    *
    FROM _object_reference.object_group ogo
    WHERE lower(ogo.object_group_name) = lower(object_group__get.object_group_name)
  ;
  RETURN r;
EXCEPTION WHEN no_data_found THEN
  RAISE 'object group "%" does not exist', object_group_name
    USING ERRCODE = 'no_data_found'
  ;
END
$body$
  , 'Get details about the specified object group'
  , 'object_reference__usage'
);
SELECT __object_reference.create_function(
  'object_reference.object_group__get'
  , $args$
  object_group_id _object_reference.object_group.object_group_id%TYPE
$args$
  , '_object_reference.object_group LANGUAGE plpgsql STABLE'
  , $body$
DECLARE
  r _object_reference.object_group;
BEGIN
  SELECT INTO STRICT r
    *
    FROM _object_reference.object_group ogo
    WHERE (ogo.object_group_id) = (object_group__get.object_group_id)
  ;
  RETURN r;
EXCEPTION WHEN no_data_found THEN
  RAISE 'object group id % does not exist', object_group_id
    USING ERRCODE = 'no_data_found'
  ;
END
$body$
  , 'Get details about the specified object group'
  , 'object_reference__usage'
);

-- __create
SELECT __object_reference.create_function(
  'object_reference.object_group__create'
  , $args$
  object_group_name _object_reference.object_group.object_group_name%TYPE
$args$
  , 'int LANGUAGE sql'
  , $body$
INSERT INTO _object_reference.object_group(object_group_name) VALUES(object_group_name)
  RETURNING object_group_id
$body$
  , 'Create a new object group.'
  , 'object_reference__usage'
);

-- __remove
SELECT __object_reference.create_function(
  'object_reference.object_group__remove'
  , $args$
  object_group_id _object_reference.object_group.object_group_id%TYPE
  , force boolean DEFAULT false
$args$
  , 'void LANGUAGE plpgsql'
  , $body$
DECLARE
  -- This is to ensure group exists
  c_object_group_id CONSTANT int := (object_reference.object_group__get($1)).object_group_id;
BEGIN
  IF force IS TRUE THEN
    DELETE FROM _object_reference.object_group__object
      WHERE object_group__object.object_group_id = c_object_group_id
    ;
  END IF;
  DELETE FROM _object_reference.object_group
    WHERE object_group.object_group_id = c_object_group_id
  ;
END
$body$
  , 'Remove a object group. If force is true, remove group even if it still references objects.'
  , 'object_reference__usage'
);
SELECT __object_reference.create_function(
  'object_reference.object_group__remove'
  , $args$
  object_group_name _object_reference.object_group.object_group_name%TYPE
  , force boolean DEFAULT false
$args$
  , 'void LANGUAGE sql'
  , $body$
SELECT object_reference.object_group__remove(
  (object_reference.object_group__get($1)).object_group_id
  , $2
);
$body$
  , 'Remove a object group. If force is true, remove group even if it still references objects.'
  , 'object_reference__usage'
);

-- __object__add
SELECT __object_reference.create_function(
  'object_reference.object_group__object__add'
  , $args$
  object_group_id _object_reference.object_group__object.object_group_id%TYPE
  , object_id _object_reference.object_group__object.object_id%TYPE
$args$
  , 'void LANGUAGE sql'
  , $body$
  INSERT INTO _object_reference.object_group__object AS ogo(object_group_id, object_id)
    VALUES($1, $2)
    ON CONFLICT (object_group_id, object_id) DO NOTHING
$body$
  , 'Add a object_id to a object group.'
  , 'object_reference__usage'
);

-- __object__remove
SELECT __object_reference.create_function(
  'object_reference.object_group__object__remove'
  , $args$
  object_group_id _object_reference.object_group__object.object_group_id%TYPE
  , object_id _object_reference.object_group__object.object_id%TYPE
$args$
  , 'void LANGUAGE plpgsql'
  , $body$
BEGIN
  DELETE FROM _object_reference.object_group__object AS ogo
    WHERE
      (
        ogo.object_group_id
        , ogo.object_id
      ) = (
        -- This is to ensure group exists
        (object_reference.object_group__get($1)).object_group_id
        , object_group__object__remove.object_id
      )
  ;

  IF NOT FOUND THEN
    -- We know group exists, so issue must be that object doesn't exist
    RAISE 'object id % does not exist', object_id
      USING ERRCODE = 'no_data_found'
    ;
  END IF;
END
$body$
  , 'Remove a object_id from a object group.'
  , 'object_reference__usage'
);


/*
 * REFERENCES
 */

SELECT __object_reference.create_function(
  'object_reference.object_group__dependency__add'
  , $args$
  table_name text
  , field_name name
$args$
  , 'void LANGUAGE plpgsql'
  , $body$
DECLARE
  -- Do this to sanitize input
  o_table CONSTANT regclass := table_name;
BEGIN
  PERFORM _object_reference.exec( format( 'ALTER TABLE %s ADD FOREIGN KEY( %I ) REFERENCES _object_reference.object_group', table_name, field_name ) );
END
$body$
  , 'Add a foreign key from <table_name>.<field_name> to the object_group table.'
  , 'object_reference__dependency'
);
-- s/object_group/object/
SELECT __object_reference.create_function(
  'object_reference.object__dependency__add'
  , $args$
  table_name text
  , field_name name
$args$
  , 'void LANGUAGE plpgsql'
  , $body$
DECLARE
  -- Do this to sanitize input
  o_table CONSTANT regclass := table_name;
BEGIN
  PERFORM _object_reference.exec( format( 'ALTER TABLE %s ADD FOREIGN KEY( %I ) REFERENCES _object_reference.object', table_name, field_name ) );
END
$body$
  , 'Add a foreign key from <table_name>.<field_name> to the object table.'
  , 'object_reference__dependency'
);

/*
 * OBJECT GETSERT
 */
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

/*
 * ddl_capture
 */
SELECT __object_reference.create_function(
  'object_reference.capture__get_all'
  , $args$
  OUT capture_level int
  , OUT object_group_id _object_reference.object_group.object_group_id%TYPE
  , OUT object_group_name _object_reference.object_group.object_group_name%TYPE
$args$
  , 'SETOF RECORD LANGUAGE plpgsql'
  , $body$
DECLARE
BEGIN
  RETURN QUERY SELECT c.capture_level, c.object_group_id, og.object_group_name
    FROM pg_temp.__object_reference__ddl_capture c
    JOIN _object_reference.object_group og USING(object_group_id)
    ORDER BY capture_level DESC
  ;
EXCEPTION WHEN undefined_table THEN
  RETURN;
END
$body$
  , 'Return stack of object groups that are being captured to.'
  , 'object_reference__usage'
);
SELECT __object_reference.create_function(
  'object_reference.capture__get_current'
  , $args$
  OUT capture_level int
  , OUT object_group_id _object_reference.object_group.object_group_id%TYPE
  , OUT object_group_name _object_reference.object_group.object_group_name%TYPE
$args$
  , 'RECORD LANGUAGE sql'
  , $body$
SELECT * FROM object_reference.capture__get_all() LIMIT 1
$body$
  , 'Return object group that object creation currently is being captured to.'
  , 'object_reference__usage'
);

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
  /*
  CREATE TEMP TABLE __object_reference__ddl_capture AS
    SELECT c_next_level, capture__start.object_group_id
  ;
  */
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
SELECT __object_reference.create_function(
  'object_reference.capture__start'
  , $args$
  object_group_name _object_reference.object_group.object_group_name%TYPE
$args$
  , 'int LANGUAGE sql'
  , $body$
SELECT object_reference.capture__start(
  (object_reference.object_group__get(object_group_name)).object_group_id
);
$body$
  , 'Begin capturing newly created objects to <object_group_id>. Returns current capture level.'
  , 'object_reference__usage'
);

SELECT __object_reference.create_function(
  'object_reference.capture__stop'
  , $args$
  object_group_id _object_reference.object_group.object_group_id%TYPE
$args$
  , 'void SECURITY DEFINER LANGUAGE plpgsql'
  , $body$
DECLARE
  r record;
BEGIN
  SELECT INTO STRICT r
      *
    FROM object_reference.capture__get_current()
  ;
  IF r.capture_level IS NULL THEN
    RAISE 'not capturing DDL'
      USING HINT = 'Did you forget to call object_referenc.capture__start()?'
      -- TODO: use better status code
    ;
  END IF;

  IF r.object_group_id <> coalesce(object_group_id) THEN
    RAISE 'object_group mismatch'
      USING DETAIL = format(
        'currently capturing for group %L (id %s), expecting group %L (id %s)'
        , r.object_group_name
        , r.object_group_id
        -- This will error if the group doesn't exist
        , (object_reference.object_group__get(object_group_id)).object_group_name
        , capture__stop.object_group_id
      )
    ;
  END IF;

  DELETE FROM pg_temp.__object_reference__ddl_capture WHERE capture_level = r.capture_level;
EXCEPTION WHEN undefined_table THEN
  RAISE 'not capturing DDL'
    USING HINT = 'Did you forget to call object_referenc.capture__start()?'
  ;
END
$body$
  , 'Begin capturing newly created objects to <object_group_id>. Returns current capture level.'
  , 'object_reference__usage'
);
SELECT __object_reference.create_function(
  'object_reference.capture__stop'
  , $args$
  object_group_name _object_reference.object_group.object_group_name%TYPE
$args$
  , 'void LANGUAGE sql'
  , $body$
SELECT object_reference.capture__stop(
  (object_reference.object_group__get(object_group_name)).object_group_id
)
$body$
  , 'Begin capturing newly created objects to <object_group_id>. Returns current capture level.'
  , 'object_reference__usage'
);

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
END
$body$
  , 'Trigger function to ensure capture__stop() is called an appropriate number of times.'
);
SELECT __object_reference.create_function(
  '_object_reference._etg_capture'
  , ''
  , 'event_trigger SECURITY DEFINER LANGUAGE plpgsql'
  , $body$
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
SELECT __object_reference.create_function(
  '_object_reference._etg_drop'
  , ''
  , 'event_trigger LANGUAGE plpgsql'
  , $body$
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
$body$
  , 'Event trigger function to drop object records when objects are removed.'
);

/*
CREATE OR REPLACE FUNCTION snitch() RETURNS event_trigger AS $$
BEGIN
    RAISE WARNING 'snitch: % %', tg_event, tg_tag;
END;
$$ LANGUAGE plpgsql;
CREATE EVENT TRIGGER snitch ON ddl_command_start EXECUTE PROCEDURE snitch();
*/

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

/*
 * Drop "temporary" objects
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
