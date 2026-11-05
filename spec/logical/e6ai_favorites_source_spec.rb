# frozen_string_literal: true

require "rails_helper"

RSpec.describe E6aiFavoritesSource do
  let(:stubs) { Faraday::Adapter::Test::Stubs.new }
  let(:connection) { Faraday.new("https://e6ai.example") { |f| f.adapter(:test, stubs) } }
  let(:scrape_path) { Dir.mktmpdir("e6ai-favorites") }
  let(:source) { source_for(42) }
  let(:user_dir) { File.join(scrape_path, "42") }

  after { FileUtils.rm_rf(scrape_path) }

  def source_for(user_id, path: scrape_path)
    described_class.new(user_id, base_url: "https://e6ai.example", scrape_path: path, connection: connection).tap do |s|
      allow(s).to receive(:sleep)
    end
  end

  def write_page(user_id, page, post_ids)
    dir = File.join(scrape_path, user_id.to_s)
    FileUtils.mkdir_p(dir)
    Zlib::GzipWriter.open(File.join(dir, format("%06d.json.gz", page))) do |gz|
      gz.write({ user_id: user_id, page: page, limit: 320, http_status: 200, post_ids: post_ids }.to_json)
    end
  end

  def read_page(page)
    JSON.parse(Zlib::GzipReader.open(File.join(user_dir, format("%06d.json.gz", page)), &:read))
  end

  def page_body(ids) = { posts: ids.map { |id| { id: id } } }.to_json

  def stub_page(page, body, status: 200)
    stubs.get("/favorites.json?limit=320&page=#{page}&user_id=42") { [status, {}, body] }
  end

  describe "#scraped" do
    it "returns a finished crawl in order, without duplicates" do
      write_page(42, 1, (1..320).to_a)
      write_page(42, 2, [320, 321])
      expect(source.scraped).to have_attributes(source: "scrape", post_ids: (1..321).to_a)
    end

    it "is nil unless the crawl is finished and readable, so the import goes live" do
      write_page(1, 1, (1..320).to_a)              # more pages may follow
      write_page(2, 1, (1..320).to_a)
      write_page(2, 3, [1])                        # page 2 missing
      write_page(3, 1, [])                         # empty or hidden
      write_page(4, 1, [1, "2"])                   # invalid post ID
      FileUtils.mkdir_p(File.join(scrape_path, "5"))
      File.binwrite(File.join(scrape_path, "5", "000001.json.gz"), "not gzip")
      expect([1, 2, 3, 4, 5, 6].map { |id| source_for(id).scraped }).to all(be_nil)
      expect(source_for(1, path: nil).scraped).to be_nil
    end
  end

  describe "#live" do
    it "asks for the crawl's compact pages until a short one, reporting progress" do
      requests = []
      stubs.get("/favorites.json") do |env|
        requests << env.params
        ids = env.params["page"] == "1" ? (1..320).to_a : [321, 1]
        [200, {}, ids.map { |id| { id: id } }.to_json] # the compact form is a bare array
      end
      progress = []
      expect(source.live { |pages, found| progress << [pages, found] }.post_ids).to eq((1..321).to_a)
      expect(progress).to eq([[1, 320], [2, 322]])
      expect(requests.first).to include("v2" => "true", "mode" => "thumbnail", "limit" => "320", "user_id" => "42")
    end

    it "backs off on 429 and network errors, recovers, and gives up if refused for too long" do
      calls = 0
      flaky_stubs = Faraday::Adapter::Test::Stubs.new
      flaky_stubs.get("/favorites.json?limit=320&page=1&user_id=42") do
        calls += 1
        raise Faraday::ConnectionFailed, "reset" if calls == 2
        calls == 1 ? [429, {}, ""] : [200, {}, page_body([7])]
      end
      flaky = described_class.new(42, base_url: "https://e6ai.example", scrape_path: nil, connection: Faraday.new { |f| f.adapter(:test, flaky_stubs) })
      allow(flaky).to receive(:sleep)
      expect(flaky.live.post_ids).to eq([7])
      expect(flaky).to have_received(:sleep).with(0.05).ordered
      expect(flaky).to have_received(:sleep).with(0.5).ordered
      expect(flaky).to have_received(:sleep).with(1.0).ordered

      stub_page(1, "", status: 429)
      expect { source.live }.to raise_error(E6aiFavoritesSource::Error, /not responding/)
    end

    it "rejects anything the crawl would reject, and explains hidden favorites" do
      bad = [{ success: false }.to_json, [{ id: 1 }, { id: "2" }].to_json, page_body((1..321).to_a), "<html>"]
      bad.each do |body|
        bad_stubs = Faraday::Adapter::Test::Stubs.new
        bad_stubs.get("/favorites.json?limit=320&page=1&user_id=42") { [200, {}, body] }
        strict = described_class.new(42, base_url: "https://e6ai.example", scrape_path: scrape_path, connection: Faraday.new { |f| f.adapter(:test, bad_stubs) })
        allow(strict).to receive(:sleep)
        expect { strict.live }.to raise_error(E6aiFavoritesSource::Error, /unexpected response/)
      end
      expect(Dir.exist?(user_dir)).to be(false) # nothing was saved for the crawl

      stub_page(1, "", status: 403)
      expect { source.live }.to raise_error(E6aiFavoritesSource::Error, /make them public/)
    end

    it "stops on a repeated page and at e6ai.net's page limit" do
      stub_page(1, page_body((1..320).to_a))
      stub_page(2, page_body((1..320).to_a))
      expect { source.live }.to raise_error(E6aiFavoritesSource::Error, /same page twice/)

      stub_const("E6aiFavoritesSource::MAX_PAGES", 1)
      expect { source_for(42).live }.to raise_error(E6aiFavoritesSource::Error, /too long/)
    end

    it "saves each page in the crawl's format, which the crawl and later imports then use" do
      stub_page(1, page_body((1..320).to_a))
      stub_page(2, page_body([321]))
      source.live
      expect(read_page(2)).to include("user_id" => 42, "page" => 2, "limit" => 320, "http_status" => 200, "post_ids" => [321],
                                      "response_sha256" => Digest::SHA256.hexdigest(page_body([321])))
      expect(source.scraped.post_ids).to eq((1..321).to_a)
    end

    it "never replaces a crawl page, even when this host still sees it as missing" do
      write_page(42, 1, [])
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(File.join(user_dir, "000001.json.gz")).and_return(false)
      stub_page(1, page_body([9]))
      expect(source.live.post_ids).to eq([9])
      expect(read_page(1)["post_ids"]).to eq([])
      expect(Dir.children(user_dir)).to eq(["000001.json.gz"]) # no temporary file left behind
    end

    it "imports anyway when a page cannot be saved, and never creates the shared directory" do
      stub_page(1, page_body([9]))
      allow(File).to receive(:open).and_call_original
      allow(File).to receive(:open).with(/\.tmp\z/, "wb", 0o600).and_raise(IOError)
      expect(source.live.post_ids).to eq([9])
      expect(Dir.children(user_dir)).to be_empty

      missing = File.join(scrape_path, "not-mounted")
      expect(source_for(42, path: missing).live.post_ids).to eq([9])
      expect(Dir.exist?(missing)).to be(false)
    end
  end

  it "reads the profile's favorite count, and explains a user that does not exist" do
    stubs.get("/users/42.json") { [200, {}, { favorite_count: 1865 }.to_json] }
    stubs.get("/users/43.json") { [200, {}, { id: 43 }.to_json] }
    stubs.get("/users/44.json") { [404, {}, ""] }
    expect(source.profile_favorite_count).to eq(1865)
    expect(source_for(43).profile_favorite_count).to be_nil
    expect { source_for(44).profile_favorite_count }.to raise_error(E6aiFavoritesSource::Error, /no e6ai.net user with ID 44/)
  end
end
