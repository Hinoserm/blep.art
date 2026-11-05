# frozen_string_literal: true

module Security
  module Lockdown
    # Panic
    def self.uploads_disabled?
      Setting.uploads_disabled?
    end

    def self.uploads_disabled=(state)
      Setting.uploads_disabled = state == "1"
    end

    def self.post_replacements_disabled?
      Setting.post_replacements_disabled?
    end

    def self.post_replacements_disabled=(state)
      Setting.post_replacements_disabled = state == "1"
    end

    def self.pools_disabled?
      Setting.pools_disabled?
    end

    def self.pools_disabled=(state)
      Setting.pools_disabled = state == "1"
    end

    def self.post_sets_disabled?
      Setting.post_sets_disabled?
    end

    def self.post_sets_disabled=(state)
      Setting.post_sets_disabled = state == "1"
    end

    def self.comments_disabled?
      Setting.comments_disabled?
    end

    def self.comments_disabled=(state)
      Setting.comments_disabled = state == "1"
    end

    def self.forums_disabled?
      Setting.forums_disabled?
    end

    def self.forums_disabled=(state)
      Setting.forums_disabled = state == "1"
    end

    def self.blips_disabled?
      Setting.blips_disabled?
    end

    def self.blips_disabled=(state)
      Setting.blips_disabled = state == "1"
    end

    def self.aiburs_disabled?
      Setting.aiburs_disabled?
    end

    def self.aiburs_disabled=(state)
      Setting.aiburs_disabled = state == "1"
    end

    def self.favorites_disabled?
      Setting.favorites_disabled?
    end

    def self.favorites_disabled=(state)
      Setting.favorites_disabled = state == "1"
    end

    def self.votes_disabled?
      Setting.votes_disabled?
    end

    def self.votes_disabled=(state)
      Setting.votes_disabled = state == "1"
    end

    def self.takedowns_disabled?
      Setting.takedowns_disabled?
    end

    def self.takedowns_disabled=(state)
      Setting.takedowns_disabled = state == "1"
    end

    # New-account wait limits: hours after signup before an account can do each action (0 = no wait).
    # Each is its own setting; the defaults are the values that used to be hard-coded.
    WAIT_LIMITS = {
      upload:         { label: "Upload posts",                                        default: 168 },
      post_edit:      { label: "Edit posts (tags, rating, source, description)",     default: 168 },
      comment:        { label: "Comment",                                             default: 168 },
      wiki_edit:      { label: "Edit wiki pages",                                     default: 168 },
      artist_edit:    { label: "Edit artists",                                        default: 168 },
      pool:           { label: "Create pools",                                        default: 168 },
      pool_post_edit: { label: "Add posts to pools",                                  default: 168 },
      suggest_tag:    { label: "Suggest tag aliases, implications and bulk updates",  default: 168 },
      dmail:          { label: "Send DMails",                                         default: 168 },
      forum_post:     { label: "Post in the forum",                                   default: 72 },
      note_edit:      { label: "Edit notes",                                          default: 72 },
      blip:           { label: "Post blips",                                          default: 72 },
      comment_vote:   { label: "Vote on comments",                                    default: 72 },
      forum_vote:     { label: "Vote on forum posts",                                 default: 72 },
      post_flag:      { label: "Flag posts",                                          default: 72 },
      ticket:         { label: "File reports and appeals",                            default: 72 },
      pool_edit:      { label: "Edit pool details",                                   default: 72 },
    }.freeze

    def self.wait_hours(key)
      Setting.public_send(:"#{key}_wait_hours")
    end

    def self.set_wait_hours(key, hours)
      Setting.public_send(:"#{key}_wait_hours=", hours)
    end

    def self.upload_wait_hours
      wait_hours(:upload)
    end

    def self.upload_wait_hours=(hours)
      set_wait_hours(:upload, hours)
    end

    # Uploader level override
    def self.uploads_min_level
      Setting.uploads_min_level
    end

    def self.uploads_min_level=(min_upload_level)
      Setting.uploads_min_level = min_upload_level
    end

    # `Integer`:&nbsp; The number of hours pending posts should be hidden for.
    def self.hide_pending_posts_for
      Setting.hide_pending_posts_for
    end

    def self.hide_pending_posts_for=(duration)
      Setting.hide_pending_posts_for = duration
    end

    def self.post_visible?(post, user)
      if hide_pending_posts_for <= 0
        return true
      end

      post.uploader_id == user.id || user.is_staff? || !post.is_pending? || post.created_at.before?(hide_pending_posts_for.hours.ago)
    end
  end
end
