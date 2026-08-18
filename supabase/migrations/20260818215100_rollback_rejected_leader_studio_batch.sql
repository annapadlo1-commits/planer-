-- The first Studio batch prototype was withdrawn after product review.
-- Keep the database contract aligned with the accepted fullscreen Studio design.
drop function if exists public.optimizer_leader_assignment_batch_validate_uat_v1(uuid, jsonb);
drop function if exists public.optimizer_leader_assignment_batch_save_uat_v1(uuid, jsonb, text);

notify pgrst, 'reload schema';
