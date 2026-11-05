# frozen_string_literal: true

# A user's one-time copy of their public e6ai.net favorites. A failed or stalled import can be retried.
#
# Each start or restart bumps `attempt`, and the job only writes while the attempt it was
# given is still current, so a restarted import cannot be overwritten by an older job.
class E6aiFavoriteImport < ApplicationRecord
  STATUSES = %w[queued fetching saving done failed].freeze
  # The job records progress at least once per page or batch, and while it waits its turn.
  # Longer than this without any means the job died without reporting.
  STALE_AFTER = 10.minutes
  MAX_E6AI_USER_ID = (2**31) - 1
  RESET_ATTRIBUTES = {
    status: "queued", source: nil, error: nil, expected_count: nil, pages_fetched: 0, found_count: 0,
    imported_count: 0, already_count: 0, missing_count: 0, over_limit_count: 0
  }.freeze
  STALLED_MESSAGE = "The import stopped responding. Please try again."
  # A bare ID, or a profile link such as https://e6ai.net/users/1234 (scheme and host optional).
  PROFILE_LINK = %r{\A(?:(?:https?://)?[\w.-]+)?/users/(\d+)/?(?:[?#]\S*)?\z}i

  belongs_to :user

  validates :e6ai_user_id, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_E6AI_USER_ID }
  validates :status, inclusion: { in: STATUSES }

  scope :restartable, -> { where(status: "failed").or(where.not(status: "done").where(updated_at: ...STALE_AFTER.ago)) }

  def self.parse_user_id(input)
    text = input.to_s.strip
    match = text.match(/\A(\d+)\z/) || text.match(PROFILE_LINK)
    match && match[1].to_i
  end

  def done? = status == "done"
  def failed? = status == "failed"
  def finished? = done? || failed?
  def stalled? = !finished? && updated_at < STALE_AFTER.ago
  def restartable? = failed? || stalled?

  # What the user sees: a stalled import is shown as failed so it can be retried.
  def display_status = stalled? ? "failed" : status
  def display_error = stalled? ? STALLED_MESSAGE : error

  def percent
    return 100 if done?
    return 0 if expected_count.to_i <= 0
    [(found_count * 100 / expected_count), 99].min
  end

  def progress_json
    {
      status: display_status,
      percent: percent,
      pages_fetched: pages_fetched,
      found_count: found_count,
      expected_count: expected_count,
      imported_count: imported_count,
      already_count: already_count,
      missing_count: missing_count,
      over_limit_count: over_limit_count,
      error: display_error,
    }
  end
end
