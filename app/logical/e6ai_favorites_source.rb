# frozen_string_literal: true

# Public favorites of one e6ai.net user, newest first.
#
# Uses the public favorites crawl when it holds the user's whole list, and the
# e6ai.net API otherwise. The crawl writes one gzipped JSON file per page, to a
# temporary name that is fsynced and then renamed, so a visible file is always
# complete and the crawl can be read while it is still running. Pages fetched
# live are saved in the same format, and the crawl uses a saved page instead of
# requesting it again.
class E6aiFavoritesSource
  PAGE_LIMIT = 320
  # e6ai.net refuses numbered pages past 750; the crawl stops there too.
  MAX_PAGES = 750
  MIN_DELAY = 0.05
  MAX_DELAY = 30.0
  RETRYABLE = [429, 502, 503, 504].freeze
  NETWORK_ERRORS = [Faraday::TimeoutError, Faraday::ConnectionFailed].freeze

  # Raised with a message meant for the user.
  class Error < StandardError; end

  Result = Struct.new(:source, :post_ids, keyword_init: true)

  attr_reader :user_id

  def initialize(user_id, base_url: Danbooru.config.e6ai_favorites_import_url,
                 scrape_path: Danbooru.config.e6ai_favorites_scrape_path, connection: nil)
    @user_id = Integer(user_id)
    @base_url = base_url
    @scrape_path = scrape_path
    @connection = connection
  end

  def hidden_message
    "No public favorites were found for e6ai.net user #{user_id}. If your favorites are hidden there, make them public, then try again."
  end

  # The crawled list when the crawl finished this user, otherwise nil.
  # An empty crawled list returns nil too: the user may have unhidden their favorites since.
  # A crawl that cannot be read is treated as absent, so the import falls back to e6ai.net.
  def scraped
    return nil if @scrape_path.blank?
    dir = File.join(@scrape_path, user_id.to_s)
    return nil unless Dir.exist?(dir)
    files = Dir.children(dir).grep(/\A\d+\.json\.gz\z/).sort
    return nil if files.empty?

    pages = files.map { |name| JSON.parse(Zlib::GzipReader.open(File.join(dir, name), &:read)) }
    contiguous = pages.each_with_index.all? do |page, i|
      page.is_a?(Hash) && page["page"] == i + 1 && page["http_status"] == 200 && valid_ids?(page["post_ids"])
    end
    return nil unless contiguous && pages.last["post_ids"].size < PAGE_LIMIT

    ids = pages.flat_map { |page| page["post_ids"] }.uniq
    ids.empty? ? nil : Result.new(source: "scrape", post_ids: ids)
  rescue StandardError => e
    Rails.logger.warn("E6aiFavoritesSource: crawl for user #{user_id} unreadable, fetching live: #{e.class}: #{e.message}")
    nil
  end

  # The favorite count on the user's e6ai.net profile, or nil when the profile does not give one.
  def profile_favorite_count
    response = request("/users/#{user_id}.json")
    raise Error, "There is no e6ai.net user with ID #{user_id}." if response.status == 404
    raise Error, "e6ai.net returned an error (HTTP #{response.status}). Please try again later." unless response.status == 200
    count = parse_json(response.body)
    count = count["favorite_count"] if count.is_a?(Hash)
    count.is_a?(Integer) && count >= 0 ? count : nil
  end

  # Every page from the API, one request at a time. Yields (pages so far, favorites so far).
  def live
    ids = []
    previous = nil
    (1..MAX_PAGES).each do |page|
      response = request("/favorites.json", user_id: user_id, limit: PAGE_LIMIT, page: page, v2: "true", mode: "thumbnail")
      raise Error, hidden_message if response.status == 403
      raise Error, "e6ai.net returned an error (HTTP #{response.status}). Please try again later." unless response.status == 200
      batch = page_ids(response.body)
      raise Error, "e6ai.net returned the same page twice. Please try again later." if batch.any? && batch == previous

      save_page(page, batch, response.body)
      ids.concat(batch)
      yield(page, ids.size) if block_given?
      return Result.new(source: "live", post_ids: ids.uniq) if batch.size < PAGE_LIMIT
      previous = batch
    end
    raise Error, "This favorites list is too long to import."
  end

  private

  # The checks the crawl applies before it saves a page.
  def page_ids(body)
    rows = parse_json(body)
    rows = rows["posts"] if rows.is_a?(Hash)
    ids = rows.is_a?(Array) ? rows.map { |row| row.is_a?(Hash) ? row["id"] : nil } : nil
    raise Error, "e6ai.net sent an unexpected response. Please try again later." unless valid_ids?(ids)
    ids
  end

  def valid_ids?(ids)
    ids.is_a?(Array) && ids.size <= PAGE_LIMIT && ids.all? { |id| id.is_a?(Integer) && id >= 1 }
  end

  def parse_json(body)
    JSON.parse(body)
  rescue JSON::ParserError
    raise Error, "e6ai.net sent an unexpected response. Please try again later."
  end

  # Writes a page in the crawl's own format. The page is hard-linked into place, which fails
  # atomically if the crawl already has it, so an existing page is never replaced even when
  # this host's view of the shared directory is out of date. Only the user's own directory is
  # created; if the shared directory itself is missing, nothing is written.
  # Saving is best effort: a failure here never fails the import.
  def save_page(page, post_ids, raw)
    return if @scrape_path.blank? || !Dir.exist?(@scrape_path)
    dir = File.join(@scrape_path, user_id.to_s)
    path = File.join(dir, format("%06d.json.gz", page))
    return if File.exist?(path)

    record = {
      user_id: user_id, page: page, limit: PAGE_LIMIT, http_status: 200, post_ids: post_ids,
      fetched_at: Time.now.utc.iso8601, response_sha256: Digest::SHA256.hexdigest(raw),
      scope: "anonymous public favorites; no favorite timestamps supplied by API",
      fetched_by: "blep.art favorites import",
    }
    begin
      Dir.mkdir(dir, 0o700)
    rescue Errno::EEXIST
      nil
    end
    temporary = "#{path}.blep-#{Process.pid}-#{Thread.current.object_id}.tmp"
    File.open(temporary, "wb", 0o600) do |file|
      file.write(ActiveSupport::Gzip.compress(record.to_json))
      file.flush
      file.fsync
    end
    begin
      File.link(temporary, path)
    rescue Errno::EEXIST
      return
    end
    File.open(dir) { |d| d.fsync } # as the crawl does, so the new name survives a crash
  rescue StandardError => e
    Rails.logger.warn("E6aiFavoritesSource: could not save page #{page} of user #{user_id}: #{e.class}: #{e.message}")
  ensure
    File.unlink(temporary) if temporary && File.exist?(temporary)
  end

  # A very short pause between requests that doubles while e6ai.net pushes back or the
  # network fails, and halves again after each success.
  def request(path, params = {})
    @delay ||= MIN_DELAY
    loop do
      sleep(@delay)
      begin
        response = connection.get(path, params)
      rescue *NETWORK_ERRORS
        response = nil
      end
      if response.nil? || RETRYABLE.include?(response.status)
        raise Error, "e6ai.net is not responding. Please try again later." if @delay >= MAX_DELAY
        @delay = (@delay * 2).clamp(0.5, MAX_DELAY)
        next
      end
      @delay = [@delay / 2, MIN_DELAY].max
      return response
    end
  end

  def connection
    @connection ||= Faraday.new(@base_url, headers: Danbooru.config.http_headers, request: { timeout: 60 })
  end
end
