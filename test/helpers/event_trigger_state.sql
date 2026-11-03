/*
 * Asserts the enabled state of the extension's three event triggers (used by
 * test/build/update.sql).
 */
CREATE FUNCTION pg_temp.assert_event_trigger_state(
  step text
  , capture_state "char"
  , fix_identity_state "char"
  , drop_state "char"
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_mismatches text;
BEGIN
  SELECT string_agg(
        format('%I is %L, expected %L.', e.evtname, t.evtenabled, e.evtenabled)
        , ' ' ORDER BY e.evtname
      )
    INTO v_mismatches
    FROM (VALUES
        ('zzz_object_reference_capture'::name, capture_state)
      , ('zzz_object_reference__fix_identity', fix_identity_state)
      , ('zzz__object_reference_drop', drop_state)
    ) e(evtname, evtenabled)
    LEFT JOIN pg_catalog.pg_event_trigger t USING (evtname)
    WHERE t.evtenabled IS DISTINCT FROM e.evtenabled
  ;
  IF v_mismatches IS NOT NULL THEN
    RAISE EXCEPTION 'unexpected event trigger state %', step
      USING DETAIL = v_mismatches
    ;
  END IF;
END
$$;
