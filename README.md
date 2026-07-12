# Object Reference Framework

This framework provides tracking and management of references to database objects. It's designed to maintain referential integrity for objects that may be created, dropped, or renamed, and provides facilities for automatically capturing newly created objects into organized groups.

Key capabilities:
- Track references to database objects that may be created, dropped, or renamed
- Group related objects for organization and DDL capture
- Automatically capture DDL operations to track new objects
- Manage dependencies between objects and external tables
- Support for object lifecycle management

# A word on documentation...

Good documentation should be like good code comments - explain things concisely without being overly verbose. Towards that end, this doc does *not* provide definition for things that should be inherently obvious, other than mentioning their existence. For example, we never define what is meant by `object_type`. The name itself should provide enough information.

# Installation

This extension depends on the `cat_tools` extension.

```sql
CREATE EXTENSION object_reference CASCADE;
```

The extension creates two schemas:
- `object_reference` - Contains the public API functions
- `_object_reference` - Contains internal implementation details (do not use directly)

To grant users access to the extension:
```sql
GRANT object_reference__usage TO role1, role2, role3;
```

# Security

There are two roles associated with the extension:

- `object_reference__usage` - Allows using the extension's public API functions. Grant this to users who need to track and manage object references.
- `object_reference__dependency` - Special role for creating foreign key dependencies to the internal object table. Only grant this to schemas/applications that need to create referential integrity constraints against the object tracking system. See [Referring to Objects](#referring-to-objects) below.

Most users will only need `object_reference__usage`. The `object_reference__dependency` role is only needed when using `object__dependency__add()` or `object_group__dependency__add()` functions.

# Key Concepts

## Objects vs OIDs

The framework separates object metadata (names, types, arguments) from their actual database OIDs. This allows tracking objects that don't exist yet, or that may be recreated. OID resolution is performed lazily - only when actually needed.

## Object Groups

Objects can be organized into named groups for logical organization. This is particularly useful for tracking all objects created during a specific operation or time period, especially when combined with DDL capture.

## DDL Capture

The framework can automatically capture newly created objects during DDL operations and add them to a specified object group. This is implemented using PostgreSQL event triggers.

## Referring to Objects

The framework supports removing objects that are no longer referenced. Because of this, *it is critical that any tables that store an `object_id` are registered with `object__dependency__add()`*.

# API

Note that all API routines live in the `object_reference` schema. Objects in the `_object_reference` schema are considered internal-only and should not be accessed directly.

Most routines work with the `cat_tools.object_type` enum for specifying object types. You can also pass object types as text strings which will be converted automatically.

## Core Object Functions

### `object__getsert(...) RETURNS int`

```sql
object__getsert(
  object_type         text | cat_tools.object_type
  , object_name       text
  , secondary         text                DEFAULT NULL
  , object_group_name text                DEFAULT NULL  
  , loose             boolean             DEFAULT false
) RETURNS int
```

Get or insert an object reference, returning the `object_id`. This is the primary function for tracking objects.

Arguments:
- `object_type` - Type of object (table, function, index, etc.)
- `object_name` - Fully qualified name of the object
- `secondary` - Additional identifier for objects that need it (e.g., function arguments)
- `object_group_name` - Optional object group to add this object to
- `loose` - If true, allows creating references to objects that don't exist

### `object__getsert_w_group_id(...) RETURNS int`

```sql
object__getsert_w_group_id(
  object_type       cat_tools.object_type
  , object_name     text
  , secondary       text      DEFAULT NULL
  , object_group_id int       DEFAULT NULL
  , loose           boolean   DEFAULT false  
) RETURNS int
```

Same as `object__getsert()` but accepts a numeric `object_group_id` instead of group name.

### `object__describe(object_id int) RETURNS text`

Returns a human-readable description of the object, matching the format of PostgreSQL's `pg_describe_object()` function.

### `object__identity(object_id int) RETURNS record`

Returns object identification information matching the format of PostgreSQL's `pg_identify_object()` function. Returns a record with columns: `type`, `schema`, `name`, `identity`.


## Object Group Functions

### `object_group__create(...) RETURNS int`

```sql
object_group__create(
  object_group_name text
) RETURNS int
```

Create a new object group and return its ID.

### `object_group__get(...) RETURNS object_group`

```sql
object_group__get(
  object_group_name text | object_group_id int
) RETURNS _object_reference.object_group
```

Retrieve an object group by name or ID. Throws an error if the group doesn't exist.

### `object_group__remove(...) RETURNS void`

```sql
object_group__remove(
  object_group_name text | object_group_id int
  , force boolean DEFAULT false
) RETURNS void
```

Remove an object group. This does not delete the objects themselves, only the grouping.

### `object_group__object__add(...) RETURNS void`

```sql
object_group__object__add(
  object_group_id int
  , object_id int
) RETURNS void
```

Add an existing object to an object group.

### `object_group__object__remove(...) RETURNS void`

```sql
object_group__object__remove(
  object_group_id int
  , object_id int  
) RETURNS void
```

Remove an object from an object group.

## Dependency Functions

These functions create foreign key dependencies to the object tracking system. They require the `object_reference__dependency` role.

### `object__dependency__add(...) RETURNS void`

```sql
object__dependency__add(
  table_name text
  , field_name name
) RETURNS void
```

Create a foreign key dependency from the specified table to the object tracking system.

Arguments:
- `table_name` - Name of table to add dependency to
- `field_name` - Name of the field to create the foreign key on

### `object_group__dependency__add(...) RETURNS void`

```sql
object_group__dependency__add(
  table_name text
  , field_name name
) RETURNS void
```

Create a foreign key dependency from the specified table to the object group system.

## DDL Capture Functions

DDL capture allows you to automatically track objects created during DDL operations.

### `capture__start(...) RETURNS int`

```sql
capture__start(
  object_group_name text | object_group_id int
) RETURNS int
```

Begin capturing newly created objects to the specified group. The group must
already exist. Returns the capture level (for nested captures).

### `capture__stop(...) RETURNS void`

```sql
capture__stop(
  object_group_name text | object_group_id int
) RETURNS void
```

Stop capturing objects to the specified group.

### `capture__get_current(...) RETURNS record`

```sql
capture__get_current(
  OUT capture_level int
  , OUT object_group_id int  
) RETURNS record
```

Get information about the current capture state.

### `capture__get_all(...) RETURNS SETOF record`

```sql  
capture__get_all(
  OUT capture_level int
  , OUT object_group_id int
) RETURNS SETOF record
```

Get information about all active capture levels.

## Utility Functions

### `post_restore() RETURNS void`

```sql
post_restore() RETURNS void
```

Ensures all object references are correct after a database restore. Run this after restoring from backup to fix any OID mismatches.

### `object__cleanup(object_id int) RETURNS void`

```sql
object__cleanup(object_id int) RETURNS void
```

Attempts to delete an object from the tracking system. Silently returns if the object is still referenced by other tables (via foreign keys). This function is automatically called when objects are removed from object groups.

### Object Type Information Functions

**Get lists of unsupported/untested object types:**

```sql
unsupported() RETURNS cat_tools.object_type[]
unsupported_srf() RETURNS SETOF cat_tools.object_type

untested() RETURNS cat_tools.object_type[]
untested_srf() RETURNS SETOF cat_tools.object_type
```

**Check if specific object types are supported/tested:**

```sql
unsupported(object_type text | cat_tools.object_type) RETURNS boolean
untested(object_type text | cat_tools.object_type) RETURNS boolean
```

These functions help determine which object types are supported by the framework. Unsupported types cannot be tracked, while untested types may work but haven't been fully validated.

# Event Triggers

The extension automatically installs several event triggers that:

- Capture object creation when DDL capture is active
- Update object identity information when objects are renamed
- Clean up object references when objects are dropped

These event triggers operate transparently and require no user intervention. However, be aware that they may add slight overhead to DDL operations.

# Examples

## Basic Object Tracking

```sql
-- Track a table  
SELECT object_reference.object__getsert('table', 'public.my_table');

-- Track a function with its signature
SELECT object_reference.object__getsert('function', 'public.my_func', 'integer, text');
```

## Using Object Groups

```sql
-- Create a group for related objects
SELECT object_reference.object_group__create('my_feature_objects');

-- Add objects to the group
SELECT object_reference.object__getsert('table', 'public.feature_table', NULL, 'my_feature_objects');
SELECT object_reference.object__getsert('view', 'public.feature_view', NULL, 'my_feature_objects');
```

## DDL Capture

```sql
-- Create a group first
SELECT object_reference.object_group__create('migration_v2_objects');

-- Start capturing new objects to that group
SELECT object_reference.capture__start('migration_v2_objects');

-- Run your DDL commands
CREATE TABLE public.new_table (id int, name text);
CREATE INDEX idx_new_table_name ON public.new_table (name);

-- Stop capturing  
SELECT object_reference.capture__stop('migration_v2_objects');

-- All objects created between start/stop are now tracked in the 'migration_v2_objects' group
```