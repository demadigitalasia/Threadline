-- New workflow states. Keep this migration separate because PostgreSQL enum
-- values cannot be used until the transaction that adds them has committed.
alter type public.job_status add value if not exists 'Preview';
alter type public.job_status add value if not exists 'Finished';
