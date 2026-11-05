# frozen_string_literal: true

require "rails_helper"

# Index pages viewed without a search used to offer 750 pages no matter how small the table was.
RSpec.describe "Pagination of unsearched index pages" do
  include_context "as admin"

  before { create_list(:tag, 5, post_count: 1) }

  it "links to the real last page instead of page 750" do
    get tags_path(limit: 2)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("page=3")
    expect(response.body).not_to include("page=4")
    expect(response.body).not_to include("page=750")
  end

  it "shows a single page when everything fits" do
    get tags_path(limit: 20)
    expect(response.body).not_to include("page=2")
  end

  it "does the same for wiki pages" do
    create_list(:wiki_page, 3)
    get wiki_pages_path(limit: 2)
    expect(response.body).to include("page=2")
    expect(response.body).not_to include("page=750")
  end
end
