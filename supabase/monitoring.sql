-- Read-only operator queries: run in the SQL editor as a trusted administrator.
-- Aggregate counts only; never expose this file as a browser RPC.
select status, count(*) as rooms from game_private.lobbies group by status;
select count(*) as expired_connection_leases from game_private.connections where expires_at <= now();
select count(*) as terminal_rooms_past_retention from game_private.lobbies
where status in ('closed','finished') and closed_at < now()-interval '7 days';
select count(*) as anonymous_users from auth.users where is_anonymous;
select count(*) as budgeted_guests, max(request_count) as highest_minute_units
from game_private.request_buckets where window_start >= date_trunc('minute',now());
select j.jobname, r.status, r.start_time, r.end_time
from cron.job j join cron.job_run_details r using (jobid)
where j.jobname='game-hub-lobby-cleanup' order by r.start_time desc limit 10;
