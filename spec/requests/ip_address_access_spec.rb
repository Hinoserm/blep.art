# frozen_string_literal: true

require "rails_helper"

# IP addresses are PII: only MakeFox flag holders see or search them. Admins without the
# flag keep everything else (emails, ban reasons, other admin pages).
RSpec.describe "IP address access" do
  let(:admin) { create(:bd_staff_user) }
  let(:makefox) { create(:makefox_admin_user) }

  describe "pages that exist only for IPs" do
    {
      "IP bans" => -> { ip_bans_path },
      "IP address search" => -> { staff_ip_addrs_path },
      "alt list" => -> { alt_list_staff_users_path },
    }.each do |label, path|
      it "denies the #{label} page to an admin without the flag" do
        sign_in_as admin
        get instance_exec(&path)
        expect(response).to have_http_status(:forbidden)
      end

      it "allows the #{label} page to a MakeFox holder" do
        sign_in_as makefox
        get instance_exec(&path)
        expect(response).to have_http_status(:ok)
      end
    end

    it "lists them in the site map only for MakeFox holders" do
      labels = ->(user) { SiteMap.sections_for(user).flat_map { |s| s[:links].pluck(:label) } }
      expect(labels.call(admin)).not_to include("IP Bans", "IP Addresses", "Alt list")
      expect(labels.call(makefox)).to include("IP Bans", "IP Addresses", "Alt list")
    end
  end

  describe "IPs shown on content" do
    let(:comment) do
      CurrentUser.scoped(create(:user), "10.20.30.40") { create(:comment) }
    end

    before { comment }

    it "hides a comment's IP from an admin without the flag" do
      sign_in_as admin
      get post_path(comment.post)
      expect(response.body).not_to include("10.20.30.40")
    end

    it "shows a comment's IP to a MakeFox holder" do
      sign_in_as makefox
      get post_path(comment.post)
      expect(response.body).to include("10.20.30.40")
    end
  end

  describe "a user's last IP" do
    let(:target) { create(:user, email: "target@example.com") }

    before { target.update_columns(last_ip_addr: "10.9.8.7") }

    it "hides it from an admin without the flag, who still sees the email" do
      sign_in_as admin
      get user_path(target)
      expect(response.body).not_to include("10.9.8.7")
      expect(response.body).to include("target@example.com")
    end

    it "shows it to a MakeFox holder" do
      sign_in_as makefox
      get user_path(target)
      expect(response.body).to include("10.9.8.7")
    end
  end

  describe "searching by IP" do
    let!(:match) { create(:user) }
    let!(:other) { create(:user) }

    before do
      match.update_columns(last_ip_addr: "10.9.8.7")
      other.update_columns(last_ip_addr: "10.1.1.1")
    end

    def found_ids
      response.parsed_body.pluck("id")
    end

    it "refuses the IP filter from an admin without the flag" do
      sign_in_as admin
      get users_path(format: :json, search: { ip_addr: "10.9.8.7" })
      expect(response.status).to be_between(400, 499)
      expect(response.body).not_to include("10.9.8.7")
    end

    it "applies it for a MakeFox holder" do
      sign_in_as makefox
      get users_path(format: :json, search: { ip_addr: "10.9.8.7" })
      expect(found_ids).to include(match.id)
      expect(found_ids).not_to include(other.id)
    end
  end

  describe "IP bans in the mod action log" do
    let(:entry) { ModAction.log(:ip_ban_create, { ip_addr: "10.4.4.4", reason: "spam waves" }) }

    it "gives an admin without the flag the reason but not the address" do
      CurrentUser.scoped(admin) do
        text = entry.decorate.format_description
        expect(text).to include("spam waves")
        expect(text).not_to include("10.4.4.4")
        expect(entry.values).not_to have_key("ip_addr")
      end
    end

    it "gives a MakeFox holder both" do
      CurrentUser.scoped(makefox) do
        text = entry.decorate.format_description
        expect(text).to include("10.4.4.4", "spam waves")
        expect(entry.values).to include("ip_addr" => "10.4.4.4")
      end
    end
  end

  describe "error logs" do
    let(:log) do
      create(:exception_log, message: "failed for 10.6.6.6 / someone@example.com",
                             extra_params: { "params" => { "q" => "10.6.6.6 someone@example.com" } })
    end

    it "scrubs IPs but keeps emails for an admin without the flag" do
      CurrentUser.scoped(admin) do
        expect(log.viewable_message).not_to include("10.6.6.6")
        expect(log.viewable_message).to include("someone@example.com")
        expect(log.viewable_extra_params.to_s).not_to include("10.6.6.6")
        expect(log.viewable_extra_params.to_s).to include("someone@example.com")
      end
    end

    it "shows both to a MakeFox admin" do
      CurrentUser.scoped(makefox) do
        expect(log.viewable_message).to include("10.6.6.6", "someone@example.com")
        expect(log.viewable_extra_params.to_s).to include("10.6.6.6")
      end
    end

    it "scrubs both for a moderator" do
      CurrentUser.scoped(create(:moderator_user)) do
        expect(log.viewable_message).not_to include("10.6.6.6")
        expect(log.viewable_message).not_to include("someone@example.com")
      end
    end
  end
end
