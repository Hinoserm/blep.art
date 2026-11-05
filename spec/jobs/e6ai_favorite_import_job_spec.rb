# frozen_string_literal: true

require "rails_helper"

RSpec.describe E6aiFavoriteImportJob do
  include_context "as member"

  let(:user) { create(:user) }
  let(:posts) { create_list(:post, 5) }
  let(:import) { E6aiFavoriteImport.create!(user: user, e6ai_user_id: 42) }
  let(:source) { instance_double(E6aiFavoritesSource, scraped: nil, hidden_message: "No public favorites were found") }
  let(:job) { described_class.new }

  before do
    allow(E6aiFavoritesSource).to receive(:new).with(42).and_return(source)
    allow(BulkIndexUpdateJob).to receive(:perform_async)
  end

  def result(source_name, ids) = E6aiFavoritesSource::Result.new(source: source_name, post_ids: ids)

  # The order the favorites page shows: PostSets::Favorites sorts by created_at, newest first.
  def favorites_page_order = Favorite.where(user_id: user.id).order(created_at: :desc).pluck(:post_id)

  context "when the crawl has the whole list" do
    # newest first, as e6ai.net lists them. 999_999 is not on this site; posts[4] is mid-transfer.
    let(:newest_first) { [posts[2].id, 999_999, posts[4].id, posts[0].id, posts[3].id, posts[1].id] }

    before do
      allow(source).to receive(:scraped).and_return(result("scrape", newest_first))
      posts[4].update_columns(bit_flags: posts[4].bit_flags | Post.flag_value_for("favorites_transfer_in_progress"))
    end

    it "saves the favorites in e6ai.net's order, with every count and the search index updated" do
      Favorite.create!(user_id: user.id, post_id: posts[3].id)          # already a favorite
      Favorite.create!(user_id: create(:user).id, post_id: posts[0].id) # someone else's
      posts[0].update_columns(fav_count: 0)                              # a count that had drifted

      job.perform(import.id, 1)

      expect(favorites_page_order.excluding(posts[3].id)).to eq([posts[2].id, posts[0].id, posts[1].id])
      expect(Favorite.where(user_id: user.id).distinct.count(:created_at)).to eq(4)
      expect(import.reload).to have_attributes(status: "done", source: "scrape", imported_count: 3, already_count: 1, missing_count: 2)
      expect(posts[0].reload.fav_count).to eq(2) # recounted, not incremented
      expect(user.reload.favorite_count).to eq(4)
      expect(BulkIndexUpdateJob).to have_received(:perform_async).with("Post", contain_exactly(posts[0].id, posts[1].id, posts[2].id))
    end

    it "keeps the order across batches, and the newest when the list exceeds the favorite limit" do
      stub_const("E6aiFavoriteImportJob::BATCH_SIZE", 1)
      allow_any_instance_of(User).to receive(:favorite_limit).and_return(3) # rubocop:disable RSpec/AnyInstance
      job.perform(import.id, 1)
      expect(favorites_page_order).to eq([posts[2].id, posts[0].id, posts[3].id])
      expect(import.reload.over_limit_count).to eq(1)
    end

    it "still recounts the user's favorites when saving fails part way" do
      stub_const("E6aiFavoriteImportJob::BATCH_SIZE", 2)
      allow(BulkIndexUpdateJob).to receive(:perform_async).and_raise(StandardError, "queue unavailable")
      job.perform(import.id, 1)
      expect(import.reload).to have_attributes(status: "failed", error: E6aiFavoriteImportJob::GENERIC_ERROR)
      expect(Favorite.where(user_id: user.id).count).to eq(2) # the first batch, committed whole
      expect(user.reload.favorite_count).to eq(2)
    end
  end

  context "when the crawl does not have the list" do
    before do
      allow(source).to receive(:profile_favorite_count).and_return(2)
      allow(source).to receive(:live).and_yield(1, 2).and_return(result("live", [posts[3].id, posts[2].id]))
    end

    it "fetches live and records progress" do
      job.perform(import.id, 1)
      expect(import.reload).to have_attributes(status: "done", source: "live", expected_count: 2, pages_fetched: 1, imported_count: 2)
    end

    it "fails with a message the user can act on, and no internal details" do
      failures = {
        -> { allow(source).to receive(:live).and_return(result("live", [])) } => "No public favorites were found",
        -> { allow(source).to receive(:live).and_raise(E6aiFavoritesSource::Error, "There is no e6ai.net user with ID 42.") } => "There is no e6ai.net user with ID 42.",
        -> { allow(source).to receive(:live).and_raise(Errno::ENOENT, "/home/blep/data/secret") } => E6aiFavoriteImportJob::GENERIC_ERROR,
      }
      failures.each do |setup, message|
        import.update_columns(status: "queued")
        setup.call
        job.perform(import.id, 1)
        expect(import.reload).to have_attributes(status: "failed", error: message)
      end
    end

    it "leaves a restarted or finished import alone" do
      allow(source).to receive(:live) do |&block|
        import.update_columns(attempt: 2, status: "queued") # restarted while this job was fetching
        block.call(1, 2)
      end
      job.perform(import.id, 1)
      expect(import.reload).to have_attributes(attempt: 2, status: "queued", error: nil)
      expect(Favorite.where(user_id: user.id)).to be_empty

      job.perform(import.id, 1)                       # an old attempt
      import.update_columns(status: "done")
      job.perform(import.id, 2)                       # already finished
      expect(source).to have_received(:live).once
    end

    it "waits its turn while another import is fetching, without looking stalled" do
      import.update_columns(updated_at: 9.minutes.ago)
      allow(job).to receive(:with_live_lock).and_return(false)
      allow(described_class).to receive(:perform_in)
      job.perform(import.id, 1)
      expect(described_class).to have_received(:perform_in).with(5, import.id, 1)
      expect(import.reload).to have_attributes(status: "queued")
      expect(import.updated_at).to be > 1.minute.ago
    end
  end

  it "holds the live-fetch lock only while fetching, releasing it when the fetch raises" do
    # A separate session: transactional tests share one connection, and a session can re-take its own lock.
    free_elsewhere = lambda do
      other = PG.connect(ActiveRecord::Base.connection.raw_connection.conninfo_hash.compact)
      got = other.exec("SELECT pg_try_advisory_lock(#{described_class::LIVE_FETCH_LOCK})").getvalue(0, 0) == "t"
      other.exec("SELECT pg_advisory_unlock(#{described_class::LIVE_FETCH_LOCK})") if got
      got
    ensure
      other&.close
    end
    held = nil
    expect { job.send(:with_live_lock) { held = !free_elsewhere.call; raise "fetch failed" } }.to raise_error("fetch failed")
    expect(held).to be(true)
    expect(free_elsewhere.call).to be(true)
  end
end
