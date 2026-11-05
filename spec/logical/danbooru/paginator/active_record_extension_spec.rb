# frozen_string_literal: true

require "rails_helper"

# Counting for index pages viewed without a search: predict the cost from PostgreSQL's
# row estimate, then count exactly (with a time limit on large tables).
RSpec.describe Danbooru::Paginator::ActiveRecordExtension do
  include_context "as admin"

  let!(:tags) { create_list(:tag, 5) }

  def unsearched(page = "1", limit: 2)
    Tag.paginate(page, limit: limit, search_count: nil)
  end

  def statement_timeout
    Tag.connection.select_value("SHOW statement_timeout")
  end

  # A count that takes about half a second, so a short time limit cuts it off.
  def make_count_slow(relation)
    allow(relation).to receive(:count_without_pagination) do
      relation.connection.select_value("SELECT pg_sleep(0.5)")
      5
    end
  end

  describe "#estimated_row_count" do
    it "returns PostgreSQL's estimate once the table has been analyzed" do
      Tag.connection.execute("ANALYZE tags")
      expect(unsearched.estimated_row_count).to eq(Tag.count)
    end

    it "returns nil when PostgreSQL has no estimate (reltuples = -1)" do
      relation = unsearched
      allow(relation.connection).to receive(:select_value).and_call_original
      allow(relation.connection).to receive(:select_value).with(/reltuples/).and_return(-1)
      expect(relation.estimated_row_count).to be_nil
    end

    it "returns nil when the table can't be found" do
      relation = unsearched
      allow(relation).to receive(:table_name).and_return("no_such_table")
      expect(relation.estimated_row_count).to be_nil
    end
  end

  describe "#count_with_timeout" do
    it "returns the exact count when it finishes in time" do
      expect(unsearched.count_with_timeout(5_000)).to eq(5)
    end

    it "returns nil when the count runs out of time" do
      relation = unsearched
      make_count_slow(relation)
      expect(relation.count_with_timeout(50)).to be_nil
    end

    it "puts the statement timeout back after a count that finished" do
      before = statement_timeout
      unsearched.count_with_timeout(1_234)
      expect(statement_timeout).to eq(before)
    end

    it "puts the statement timeout back after a count that timed out" do
      before = statement_timeout
      relation = unsearched
      make_count_slow(relation)
      relation.count_with_timeout(50)
      expect(statement_timeout).to eq(before)
    end

    it "leaves the connection usable after a timeout" do
      relation = unsearched
      make_count_slow(relation)
      relation.count_with_timeout(50)
      expect(Tag.count).to eq(5)
    end
  end

  describe "#unsearched_count" do
    it "counts a small table exactly" do
      relation = unsearched
      allow(relation).to receive(:estimated_row_count).and_return(5)
      expect(relation).not_to receive(:count_with_timeout)
      expect(relation.unsearched_count).to eq(5)
    end

    it "counts exactly when there is no estimate yet" do
      relation = unsearched
      allow(relation).to receive(:estimated_row_count).and_return(nil)
      expect(relation.unsearched_count).to eq(5)
    end

    it "counts a large table exactly when the count finishes in time" do
      relation = unsearched
      allow(relation).to receive(:estimated_row_count).and_return(50_000_000)
      expect(relation.unsearched_count).to eq(5)
    end

    it "uses the time limit from the config for a large table" do
      relation = unsearched
      allow(relation).to receive(:estimated_row_count).and_return(50_000_000)
      allow(Danbooru.config.custom_configuration).to receive(:paginator_count_timeout).and_return(321)
      expect(relation).to receive(:count_with_timeout).with(321).and_call_original
      relation.unsearched_count
    end

    it "falls back to the estimate when a large table's count runs out of time" do
      relation = unsearched
      allow(relation).to receive(:estimated_row_count).and_return(50_000_000)
      allow(Danbooru.config.custom_configuration).to receive(:paginator_count_timeout).and_return(50)
      make_count_slow(relation)
      expect(relation.unsearched_count).to eq(50_000_000)
    end

    it "treats the row limit as the size where the timed count starts" do
      relation = unsearched
      allow(Danbooru.config.custom_configuration).to receive(:paginator_exact_count_max_rows).and_return(5)
      allow(relation).to receive(:estimated_row_count).and_return(5)
      expect(relation).to receive(:count_with_timeout).and_call_original
      expect(relation.unsearched_count).to eq(5)
    end
  end

  describe "#total_count" do
    it "no longer assumes 1,000,000 rows when nothing is searched" do
      expect(unsearched.total_count).to eq(5)
    end

    it "gives real page numbers when nothing is searched" do
      expect(unsearched("1", limit: 2).total_pages).to eq(3)
    end

    it "counts the search's own results when searching" do
      relation = Tag.where(id: tags.first(2).map(&:id)).paginate("1", limit: 2, search_count: { name: "x" })
      expect(relation.total_count).to eq(2)
    end

    it "still prefers an explicit total_count option" do
      expect(Tag.paginate("1", limit: 2, search_count: nil, total_count: 42).total_count).to eq(42)
    end

    it "counts only once per page" do
      relation = unsearched
      expect(relation).to receive(:count_without_pagination).once.and_call_original
      2.times { relation.total_count }
    end

    it "respects conditions already on the relation" do
      relation = Tag.where(id: tags.first(3).map(&:id)).paginate("1", limit: 2, search_count: nil)
      expect(relation.total_count).to eq(3)
    end
  end
end
