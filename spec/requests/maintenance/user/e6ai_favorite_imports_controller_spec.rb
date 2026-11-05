# frozen_string_literal: true

require "rails_helper"

RSpec.describe Maintenance::User::E6aiFavoriteImportsController do
  include_context "as member"

  let(:user) { create(:user) }
  let(:path) { maintenance_user_e6ai_favorite_import_path }

  before { allow(E6aiFavoriteImportJob).to receive(:perform_async) }

  def start(value) = post(path, params: { e6ai_favorite_import: { e6ai_user_id: value } })
  def import = E6aiFavoriteImport.find_by(user_id: user.id)

  it "sends anonymous visitors to the login page" do
    get path
    expect(response).to redirect_to(new_session_path(url: path))
  end

  context "when logged in" do
    before { sign_in_as(user) }

    it "starts an import from an ID or a profile link" do
      start("e6ai.net/users/1234/")
      expect(import).to have_attributes(e6ai_user_id: 1234, status: "queued", attempt: 1)
      expect(E6aiFavoriteImportJob).to have_received(:perform_async).with(import.id, 1)
      expect(response).to redirect_to(path)
    end

    it "rejects anything that is not a user ID, leaving a failed import as it was" do
      ["someone", "https://e6ai.net/posts/12345", "99999999999"].each do |value|
        start(value)
        expect(response).to have_http_status(:unprocessable_content)
      end
      post path, params: { e6ai_favorite_import: "1234" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(import).to be_nil

      E6aiFavoriteImport.create!(user: user, e6ai_user_id: 1, status: "failed", error: "hidden")
      start("someone")
      expect(response.body).to include("Your e6ai.net user ID")
      expect(import).to have_attributes(status: "failed", e6ai_user_id: 1, attempt: 1)
      expect(E6aiFavoriteImportJob).not_to have_received(:perform_async)
    end

    it "does not start again while an import is running or once it is done" do
      E6aiFavoriteImport.create!(user: user, e6ai_user_id: 1, status: "fetching")
      start("2")
      expect(flash[:notice]).to eq("Your import is already running.")
      import.update_columns(status: "done")
      start("2")
      expect(flash[:notice]).to eq("You have already imported your e6ai.net favorites.")
      expect(import).to have_attributes(e6ai_user_id: 1, attempt: 1)
      expect(E6aiFavoriteImportJob).not_to have_received(:perform_async)
    end

    it "restarts a failed or stalled import as a new attempt" do
      E6aiFavoriteImport.create!(user: user, e6ai_user_id: 1, status: "failed", error: "hidden", found_count: 5)
      start("2")
      expect(import).to have_attributes(e6ai_user_id: 2, status: "queued", error: nil, found_count: 0, attempt: 2)

      import.update_columns(status: "saving", updated_at: 11.minutes.ago)
      start("2")
      expect(import).to have_attributes(status: "queued", attempt: 3)
      expect(E6aiFavoriteImportJob).to have_received(:perform_async).with(import.id, 3)
    end

    it "marks the import failed when the job cannot be queued, and refuses during a favorites lockdown" do
      allow(E6aiFavoriteImportJob).to receive(:perform_async).and_raise(StandardError, "queue unavailable")
      start("1234")
      expect(import).to have_attributes(status: "failed", error: "The import could not be started. Please try again.")

      import.destroy!
      allow(Security::Lockdown).to receive(:favorites_disabled?).and_return(true)
      start("1234")
      expect(response).to redirect_to(path)
      expect(import).to be_nil
    end

    it "shows progress while running, and a stalled import as failed so it can be retried" do
      E6aiFavoriteImport.create!(user: user, e6ai_user_id: 1, status: "fetching", found_count: 640, expected_count: 1280)
      get path, params: { format: :json }
      expect(response.parsed_body).to include("status" => "fetching", "percent" => 50, "found_count" => 640)
      get path
      expect(response.body).to include("e6ai-import-progress")

      import.update_columns(updated_at: 11.minutes.ago)
      get path, params: { format: :json }
      expect(response.parsed_body).to include("status" => "failed", "error" => E6aiFavoriteImport::STALLED_MESSAGE)
      get path
      expect(response.body).to include("Your e6ai.net user ID")
    end
  end
end
