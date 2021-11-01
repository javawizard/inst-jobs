# frozen_string_literal: true

class UpdateAfterDeleteTriggerForSingletonIndex < ActiveRecord::Migration[6.0]
  def up
    execute(<<~SQL)
      CREATE OR REPLACE FUNCTION delayed_jobs_after_delete_row_tr_fn () RETURNS trigger AS $$
      DECLARE
        running_count integer;
        should_lock boolean;
        should_be_precise boolean;
        update_query varchar;
        skip_locked varchar;
      BEGIN
        IF OLD.strand IS NOT NULL THEN
          should_lock := true;
          should_be_precise := OLD.id % (OLD.max_concurrent * 4) = 0;

          IF NOT should_be_precise AND OLD.max_concurrent > 16 THEN
            running_count := (SELECT COUNT(*) FROM (
              SELECT 1 as one FROM delayed_jobs WHERE strand = OLD.strand AND next_in_strand = 't' LIMIT OLD.max_concurrent
            ) subquery_for_count);
            should_lock := running_count < OLD.max_concurrent;
          END IF;

          IF should_lock THEN
            PERFORM pg_advisory_xact_lock(half_md5_as_bigint(OLD.strand));
          END IF;

          -- note that we don't really care if the row we're deleting has a singleton, or if it even
          -- matches the row(s) we're going to update. we just need to make sure that whatever
          -- singleton we grab isn't already running (which is a simple existence check, since
          -- the unique indexes ensure there is at most one singleton running, and one queued)
          update_query := 'UPDATE delayed_jobs SET next_in_strand=true WHERE id IN (
            SELECT id FROM delayed_jobs j2
              WHERE next_in_strand=false AND
                j2.strand=$1.strand AND
                (j2.singleton IS NULL OR NOT EXISTS (SELECT 1 FROM delayed_jobs j3 WHERE j3.singleton=j2.singleton AND j3.id<>j2.id AND (j3.locked_by IS NULL OR j3.locked_by IS NOT NULL)))
              ORDER BY j2.strand_order_override ASC, j2.id ASC
              LIMIT ';

          IF should_be_precise THEN
            running_count := (SELECT COUNT(*) FROM (
              SELECT 1 FROM delayed_jobs WHERE strand = OLD.strand AND next_in_strand = 't' LIMIT OLD.max_concurrent
            ) s);
            IF running_count < OLD.max_concurrent THEN
              update_query := update_query || '($1.max_concurrent - $2)';
            ELSE
              -- we have too many running already; just bail
              RETURN OLD;
            END IF;
          ELSE
            update_query := update_query || '1';

            -- n-strands don't require precise ordering; we can make this query more performant
            IF OLD.max_concurrent > 1 THEN
              skip_locked := ' SKIP LOCKED';
            END IF;
          END IF;

          update_query := update_query || ' FOR UPDATE' || COALESCE(skip_locked, '') || ')';
          EXECUTE update_query USING OLD, running_count;
        ELSIF OLD.singleton IS NOT NULL THEN
          UPDATE delayed_jobs SET next_in_strand = 't' WHERE singleton=OLD.singleton AND next_in_strand=false AND locked_by IS NULL;
        END IF;
        RETURN OLD;
      END;
      $$ LANGUAGE plpgsql;
    SQL
  end

  def down
    execute(<<~SQL)
      CREATE OR REPLACE FUNCTION delayed_jobs_after_delete_row_tr_fn () RETURNS trigger AS $$
      DECLARE
        running_count integer;
        should_lock boolean;
        should_be_precise boolean;
        update_query varchar;
        skip_locked varchar;
      BEGIN
        IF OLD.strand IS NOT NULL THEN
          should_lock := true;
          should_be_precise := OLD.id % (OLD.max_concurrent * 4) = 0;

          IF NOT should_be_precise AND OLD.max_concurrent > 16 THEN
            running_count := (SELECT COUNT(*) FROM (
              SELECT 1 as one FROM delayed_jobs WHERE strand = OLD.strand AND next_in_strand = 't' LIMIT OLD.max_concurrent
            ) subquery_for_count);
            should_lock := running_count < OLD.max_concurrent;
          END IF;

          IF should_lock THEN
            PERFORM pg_advisory_xact_lock(half_md5_as_bigint(OLD.strand));
          END IF;

          -- note that we don't really care if the row we're deleting has a singleton, or if it even
          -- matches the row(s) we're going to update. we just need to make sure that whatever
          -- singleton we grab isn't already running (which is a simple existence check, since
          -- the unique indexes ensure there is at most one singleton running, and one queued)
          update_query := 'UPDATE delayed_jobs SET next_in_strand=true WHERE id IN (
            SELECT id FROM delayed_jobs j2
              WHERE next_in_strand=false AND
                j2.strand=$1.strand AND
                (j2.singleton IS NULL OR NOT EXISTS (SELECT 1 FROM delayed_jobs j3 WHERE j3.singleton=j2.singleton AND j3.id<>j2.id))
              ORDER BY j2.strand_order_override ASC, j2.id ASC
              LIMIT ';

          IF should_be_precise THEN
            running_count := (SELECT COUNT(*) FROM (
              SELECT 1 FROM delayed_jobs WHERE strand = OLD.strand AND next_in_strand = 't' LIMIT OLD.max_concurrent
            ) s);
            IF running_count < OLD.max_concurrent THEN
              update_query := update_query || '($1.max_concurrent - $2)';
            ELSE
              -- we have too many running already; just bail
              RETURN OLD;
            END IF;
          ELSE
            update_query := update_query || '1';

            -- n-strands don't require precise ordering; we can make this query more performant
            IF OLD.max_concurrent > 1 THEN
              skip_locked := ' SKIP LOCKED';
            END IF;
          END IF;

          update_query := update_query || ' FOR UPDATE' || COALESCE(skip_locked, '') || ')';
          EXECUTE update_query USING OLD, running_count;
        ELSIF OLD.singleton IS NOT NULL THEN
          UPDATE delayed_jobs SET next_in_strand = 't' WHERE singleton=OLD.singleton AND next_in_strand=false;
        END IF;
        RETURN OLD;
      END;
      $$ LANGUAGE plpgsql;
    SQL
  end
end
