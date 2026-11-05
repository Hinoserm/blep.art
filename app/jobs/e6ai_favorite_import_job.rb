# frozen_string_literal: true

# Copies a user's public e6ai.net favorites. Lists the crawl already holds are
# saved straight away; the rest are fetched live, one import at a time.
class E6aiFavoriteImportJob < ApplicationJob
  sidekiq_options queue: "low_prio", retry: false

  LIVE_FETCH_LOCK = 0x6e6a1f
  BUSY_RETRY_SECONDS = 5
  BATCH_SIZE = 5_000
  GENERIC_ERROR = "Something went wrong while importing. Please try again later."

  # The import was restarted and a newer job owns it.
  class Superseded < StandardError; end

  def perform(import_id, attempt)
    @import = E6aiFavoriteImport.find_by(id: import_id)
    @attempt = attempt
    return if @import.nil? || @import.attempt != attempt || @import.finished?

    source = E6aiFavoritesSource.new(@import.e6ai_user_id)
    result = source.scraped || fetch_live(source)
    save!(result) if result
  rescue Superseded
    nil
  rescue E6aiFavoritesSource::Error => e
    fail!(e.message)
  rescue StandardError => e
    Rails.logger.error("E6aiFavoriteImportJob #{import_id}: #{e.class}: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}")
    fail!(GENERIC_ERROR)
  end

  private

  # Records progress, and refreshes updated_at so the import is not taken for stalled.
  # Writes only while this job's attempt is current.
  def progress!(**attributes)
    updated = E6aiFavoriteImport.where(id: @import.id, attempt: @attempt).update_all(attributes.merge(updated_at: Time.current))
    raise Superseded if updated.zero?
  end

  def fail!(message)
    return unless @import
    E6aiFavoriteImport.where(id: @import.id, attempt: @attempt).update_all(status: "failed", error: message, updated_at: Time.current)
  end

  # Returns nil after requeueing when another live import holds the lock.
  def fetch_live(source)
    unless with_live_lock { return fetch_live_locked(source) }
      progress!
      self.class.perform_in(BUSY_RETRY_SECONDS, @import.id, @attempt)
    end
    nil
  end

  def fetch_live_locked(source)
    progress!(status: "fetching")
    @expected = source.profile_favorite_count
    progress!(expected_count: @expected)
    result = source.live { |pages, found| progress!(pages_fetched: pages, found_count: found) }
    raise E6aiFavoritesSource::Error, source.hidden_message if result.post_ids.empty?
    result
  end

  def with_live_lock
    conn = ActiveRecord::Base.connection
    return false unless conn.select_value("SELECT pg_try_advisory_lock(#{LIVE_FETCH_LOCK})")
    begin
      yield
    ensure
      conn.select_value("SELECT pg_advisory_unlock(#{LIVE_FETCH_LOCK})")
    end
    true
  end

  # post_ids arrive newest first. The newest are kept when the list does not fit under the
  # favorite limit. Each favorite gets its own created_at, one microsecond apart, because the
  # favorites page sorts by created_at: the newest on e6ai.net becomes the newest here.
  def save!(result)
    post_ids = result.post_ids
    user = @import.user
    progress!(status: "saving", source: result.source, found_count: post_ids.size, expected_count: @expected || post_ids.size)

    transfer_flag = Post.flag_value_for("favorites_transfer_in_progress")
    on_blep = Set.new
    post_ids.each_slice(BATCH_SIZE) do |slice|
      on_blep.merge(Post.where(id: slice).where("bit_flags & ? = 0", transfer_flag).pluck(:id))
    end
    already = Favorite.where(user_id: user.id).pluck(:post_id).to_set

    wanted = post_ids.select { |id| on_blep.include?(id) && !already.include?(id) }
    room = [user.favorite_limit - already.size, 0].max
    oldest_first = wanted.first(room).reverse
    newest_at = Time.current

    imported = 0
    begin
      oldest_first.each_slice(BATCH_SIZE).with_index do |slice, batch|
        progress!
        rows = slice.each_with_index.map do |post_id, i|
          from_newest = oldest_first.size - 1 - (batch * BATCH_SIZE) - i
          { user_id: user.id, post_id: post_id, created_at: newest_at - Rational(from_newest, 1_000_000) }
        end
        inserted = insert_batch(rows)
        BulkIndexUpdateJob.perform_async("Post", inserted) if inserted.any?
        imported += inserted.size
      end
    ensure
      UserStatus.where(user_id: user.id).update_all(["favorite_count = (SELECT COUNT(*) FROM favorites WHERE user_id = ?)", user.id])
    end

    progress!(
      status: "done",
      imported_count: imported,
      already_count: post_ids.count { |id| already.include?(id) },
      missing_count: post_ids.count { |id| !on_blep.include?(id) },
      over_limit_count: wanted.size - [room, wanted.size].min,
    )
  end

  # The favorites and their posts' counts commit together. Counts are recomputed rather than
  # incremented, so a favorite added or removed at the same moment cannot be counted twice.
  def insert_batch(rows)
    Favorite.transaction do
      inserted = Favorite.without_timeout { Favorite.insert_all(rows, returning: [:post_id]) }.rows.flatten
      if inserted.any?
        Post.without_timeout do
          Post.where(id: inserted).update_all("fav_count = (SELECT COUNT(*) FROM favorites WHERE favorites.post_id = posts.id)")
        end
      end
      inserted
    end
  end
end
