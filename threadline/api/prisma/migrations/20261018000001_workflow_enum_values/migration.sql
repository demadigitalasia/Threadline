-- Add new workflow enum values in their own committed migration.
-- PostgreSQL does not allow using an enum value until this migration commits.
ALTER TYPE public.job_status ADD VALUE IF NOT EXISTS 'Preview';
ALTER TYPE public.job_status ADD VALUE IF NOT EXISTS 'Finished';
