-- Apply only after the Hold’em client has been published successfully.
BEGIN;
UPDATE public.game_catalog SET playable=true WHERE id='poker';
NOTIFY pgrst, 'reload schema';
COMMIT;
