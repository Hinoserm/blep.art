# frozen_string_literal: true

module Danbooru
  module Paginator
    module ActiveRecordExtension
      include BaseExtension

      def paginate_numbered
        limit(records_per_page).offset((current_page - 1) * records_per_page)
      end

      def paginate_sequential_before
        q = limit(records_per_page + 1)
        q = q.where("#{table_name}.id < ?", current_page)
        q.reorder("#{table_name}.id desc")
      end

      def paginate_sequential_after
        q = limit(records_per_page + 1)
        q = q.where("#{table_name}.id > ?", current_page)
        q.reorder("#{table_name}.id asc")
      end

      def is_first_page?
        case @pagination_mode
        when :numbered
          current_page == 1
        when :sequential_before
          load
          @records.empty?
        when :sequential_after
          load
          @records.size <= records_per_page
        end
      end

      def is_last_page?
        case @pagination_mode
        when :numbered
          current_page >= total_pages
        when :sequential_before
          load
          @records.size <= records_per_page
        when :sequential_after
          load
          @records.empty? || @records.first.id <= 1
        end
      end

      # XXX Hack: in sequential pagination we fetch one more record than we need
      # so that we can tell when we're on the first or last page. Here we override
      # a rails internal method to discard that extra record. See #2044, #3642.
      def records
        case @pagination_mode
        when :numbered
          super
        when :sequential_before
          super.first(records_per_page)
        when :sequential_after
          super.first(records_per_page).reverse
        end
      end

      # taken from kaminari (https://github.com/amatsuda/kaminari)
      def real_count
        count_without_pagination
      rescue ActiveRecord::StatementInvalid => e
        if e.to_s =~ /statement timeout/
          1_000_000
        else
          raise
        end
      end

      # Count for an index page with no search applied. PostgreSQL's row estimate predicts
      # how expensive an exact count would be:
      # - small tables (or no estimate yet) are counted exactly;
      # - large tables are counted exactly if that finishes within paginator_count_timeout,
      #   otherwise the estimate is used.
      def unsearched_count
        estimate = estimated_row_count
        return real_count if estimate.nil? || estimate < Danbooru.config.paginator_exact_count_max_rows

        count_with_timeout(Danbooru.config.paginator_count_timeout) || estimate
      end

      # PostgreSQL's planner estimate of the table's row count (pg_class.reltuples), or nil if
      # the table has never been vacuumed or analyzed.
      def estimated_row_count
        estimate = connection.select_value(
          "SELECT reltuples::bigint FROM pg_class WHERE oid = to_regclass(#{connection.quote(connection.quote_table_name(table_name))})",
        )
        estimate.to_i if estimate.present? && estimate.to_i >= 0
      end

      # Exact count, given up after timeout_ms. Returns nil if it ran out of time.
      def count_with_timeout(timeout_ms)
        transaction(requires_new: true) do
          previous = connection.select_value("SHOW statement_timeout")
          connection.execute("SET LOCAL statement_timeout = #{timeout_ms.to_i}")
          count_without_pagination.tap do
            # SET LOCAL lasts until the outermost transaction ends; put it back for whatever runs next.
            connection.execute("SET LOCAL statement_timeout = #{connection.quote(previous)}")
          end
        end
      rescue ActiveRecord::QueryCanceled
        nil
      end

      def count_without_pagination
        c = except(:offset, :limit, :order)
        c = c.reorder(nil)
        c = c.count
        c.respond_to?(:count) ? c.count : c
      end
    end
  end
end
