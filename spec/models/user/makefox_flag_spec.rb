# frozen_string_literal: true

require "rails_helper"

RSpec.describe User do
  describe "#can_view_ip_addresses?" do
    it "is true for a MakeFox flag holder" do
      expect(build(:makefox_admin_user).can_view_ip_addresses?).to be true
    end

    it "is false for an admin without the flag" do
      expect(build(:admin_user).can_view_ip_addresses?).to be false
    end

    it "is false for a staff-flag admin without the flag" do
      expect(build(:bd_staff_user).can_view_ip_addresses?).to be false
    end

    it "comes from the flag alone, not the level" do
      expect(build(:user, is_makefox: true).can_view_ip_addresses?).to be true
    end
  end

  describe "the is_makefox bit" do
    it "is stored without disturbing the other flags" do
      user = create(:bd_staff_user, is_bd_auditor: true)
      user.update!(is_makefox: true)
      user.reload
      expect(user.is_makefox?).to be true
      expect(user.is_bd_staff?).to be true
      expect(user.is_bd_auditor?).to be true
      expect(user.can_approve_posts?).to be true
    end
  end
end
