# frozen_string_literal: true

module Danbooru
  module Paginator
    module BaseExtension
      attr_reader :current_page, :pagination_mode, :records_per_page

      def paginate(page, options = {})
        @paginator_options = options
        @records_per_page = parse_limit(options[:limit])
        @current_page, @pagination_mode = parse_page(page)

        case @pagination_mode
        when :numbered
          paginate_numbered
        when :sequential_before
          paginate_sequential_before
        when :sequential_after
          paginate_sequential_after
        end
      end

      # Only paginating posts should respect the per_page user setting
      def paginate_posts(page, options = {})
        options[:limit] ||= CurrentUser.user&.per_page || Danbooru.config.records_per_page
        paginate(page, options)
      end

      ### Counting and Page Calculation ###

      def total_pages
        if @pagination_mode == :numbered
          if records_per_page > 0
            (total_count.to_f / records_per_page).ceil
          else
            1
          end
        end
      end

      def max_numbered_pages
        return 1 if records_per_page == 0
        if @paginator_options[:max_count]
          # max_count caps the OpenSearch result window (from + size).
          # We have to round down here to avoid "Result window is too large" on the last page.
          [Danbooru.config.max_numbered_pages, @paginator_options[:max_count] / records_per_page].min
        else
          Danbooru.config.max_numbered_pages
        end
      end

      # When calling paginate you can pass an optional :search_count key which points to
      # the search params. If they are present we're doing a search and count it normally.
      # If they're blank, the page is an unfiltered index of a possibly huge table, and
      # unsearched_count decides how to count it without an expensive full-table scan.
      def total_count
        return @paginator_options[:total_count] if @paginator_options[:total_count]

        @total_count ||=
          if @paginator_options.key?(:search_count) && @paginator_options[:search_count].blank?
            unsearched_count
          else
            real_count
          end
      end

      # Fallback for collections that can't estimate their size.
      def unsearched_count
        1_000_000
      end

      ### Parsing and Validation ###

      def parse_limit(limit)
        return Danbooru.config.records_per_page if limit.blank?

        int_value =
          case limit
          when Integer
            limit
          when String
            raise Danbooru::Paginator::PaginationError, "Invalid limit." unless limit.match?(/\A\d+\z/)
            limit.to_i
          else
            raise Danbooru::Paginator::PaginationError, "Invalid limit."
          end

        unless int_value.between?(0, Danbooru.config.max_per_page)
          raise Danbooru::Paginator::PaginationError, "Limit must be between 0 and #{Danbooru.config.max_per_page}."
        end
        int_value
      end

      def parse_page(page)
        return [1, :numbered] if page.blank?

        case page.to_s
        when /\A\d+\z/
          [validate_numbered_page!(page.to_s.to_i), :numbered]
        when /\Ab(\d+)\z/
          [validate_sequential_page!(Regexp.last_match(1)), :sequential_before]
        when /\Aa(\d+)\z/
          [validate_sequential_page!(Regexp.last_match(1)), :sequential_after]
        else
          raise Danbooru::Paginator::PaginationError, "Invalid page number."
        end
      end

      def validate_numbered_page!(value)
        raise Danbooru::Paginator::PaginationError, "Invalid page number." if value < 1
        if value > max_numbered_pages
          raise Danbooru::Paginator::PaginationError, "You cannot go beyond page #{max_numbered_pages}. Please narrow your search terms."
        end
        value
      end

      def validate_sequential_page!(value)
        int_value = value.to_i
        # Many tables still use 32-bit integer IDs, so we cap at integer max
        # rather than bigint max to avoid Postgres errors on the underlying query.
        if int_value > 2_147_483_647 || int_value < 0
          raise Danbooru::Paginator::PaginationError, "Page parameter is out of valid range."
        end
        int_value
      end
    end
  end
end
